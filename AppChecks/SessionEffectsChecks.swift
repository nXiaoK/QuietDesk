import CoreGraphics
import Foundation
import QuietDeskCore

@MainActor
private final class FakeSessionAudio: SessionAudioControlling {
    var isMuted = false
    var enableCalls = 0
    var restoreCalls = 0
    var holdRestores = false
    var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    var restoreError: String?
    var onChange: ((Bool, String?) -> Void)?
    func enable() async throws { enableCalls += 1; isMuted = true }
    func restoreAndStop() async throws {
        restoreCalls += 1
        if holdRestores { await withCheckedContinuation { restoreWaiters.append($0) } }
        if let restoreError { throw DeskError.invalid(restoreError) }
        isMuted = false
    }
}

@MainActor
private final class FakeSessionPrivacy: SessionPrivacyCover {
    var isVisible = false
    var prepared = false
    var onExit: (() -> Void)?
    var onWindowsChanged: (([CGWindowID]) -> Void)?
    var shows = 0
    var windowIDs: [CGWindowID] { prepared ? [41, 42] : [] }
    func prepare() throws -> [CGWindowID] { prepared = true; return windowIDs }
    func reveal() { isVisible = true; shows += 1 }
    func hide() { isVisible = false; prepared = false }
}

@MainActor
private final class FakeScreenLock: SessionScreenLocking {
    var unavailableReason: String?
    var lockCalls = 0
    var confirmation: String?
    var holdConfirmation = false
    var confirmWaiters: [CheckedContinuation<Void, Never>] = []
    func lock() -> String? { lockCalls += 1; return nil }
    func confirmLocked() async -> String? {
        if holdConfirmation { await withCheckedContinuation { confirmWaiters.append($0) } }
        return confirmation
    }
}

private final class PipeReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0, ended = false
    var state: (bytes: Int, ended: Bool) { lock.withLock { (bytes, ended) } }
    func received(_ count: Int) { lock.withLock { bytes += count } }
    func finish() { lock.withLock { ended = true } }
}

@MainActor
private final class FakeDisplayDimmer: SessionDisplayDimming {
    var unavailableReason: String?
    var isDimmed = false
    var onEnded: ((String) -> Void)?
    var dimCalls = 0, restoreCalls = 0, lockHolds = 0
    var restoreFailure: String?
    var holdDim = false
    var dimWaiters: [CheckedContinuation<Void, Never>] = []
    func dim() async throws {
        dimCalls += 1
        if holdDim { await withCheckedContinuation { dimWaiters.append($0) } }
        isDimmed = true
    }
    func restore() -> String? {
        restoreCalls += 1
        guard isDimmed else { return nil }
        if let restoreFailure { return restoreFailure }
        isDimmed = false
        return nil
    }
    func holdForLock() { lockHolds += 1 }
}

private final class RecordingBrightness: DisplayBrightnessIO {
    var value: Float
    var writes: [Float] = []
    init(_ value: Float) { self.value = value }
    func brightness() throws -> Float { value }
    func setBrightness(_ value: Float) throws { writes.append(value); self.value = value }
}

/// Stands in for the display when this check program runs as the brightness helper; the file is chosen by display number.
private struct FileBrightness: DisplayBrightnessIO {
    let path: String
    init(display: CGDirectDisplayID) { path = NSTemporaryDirectory() + "quietdesk-dim-check-\(display)" }
    func brightness() throws -> Float {
        guard let value = Float(try String(contentsOfFile: path, encoding: .utf8)) else { throw DeskError.invalid("fake brightness unreadable") }
        return value
    }
    func setBrightness(_ value: Float) throws { try String(value).write(toFile: path, atomically: true, encoding: .utf8) }
}

@main
enum SessionEffectsCancellationChecks {
    @MainActor static func main() async {
        if DisplayDimWatchdog.runIfRequested(io: { FileBrightness(display: $0) }, isLocked: { false }) { exit(0) }
        var failures = 0
        let privacy = FakeSessionPrivacy()
        let audio = FakeSessionAudio()
        let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
        var releasePreparation: CheckedContinuation<Void, Never>?
        let pending = Task { @MainActor in
            try await effects.apply(.init(privacy: true)) { _ in
                await withCheckedContinuation { releasePreparation = $0 }
            }
        }
        while releasePreparation == nil { await Task.yield() }
        do {
            _ = try await effects.apply(.init()) { _ in fatalError("Overlapping request should be rejected before preparation") }
            failures += 1
            print("FAIL overlapping effect request accepted")
        } catch { print("PASS overlapping effect request is rejected") }
        let resetError = await effects.reset()
        releasePreparation?.resume()
        do {
            _ = try await pending.value
            failures += 1
            print("FAIL late privacy preparation survived reset")
        } catch is CancellationError {
            if effects.state == SessionEffectsState(), resetError == nil, privacy.shows == 0, !privacy.prepared {
                print("PASS reset cancels late privacy preparation; prepared covers are removed before they turn opaque")
            } else { failures += 1; print("FAIL reset left effects enabled") }
        } catch { failures += 1; print("FAIL unexpected preparation failure: \(error)") }

        let cancelled = Task { @MainActor in try await effects.apply(.init(privacy: true)) { _ in } }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            failures += 1
            print("FAIL cancelled request enabled privacy")
        } catch is CancellationError {
            if effects.state == SessionEffectsState(), privacy.shows == 0 { print("PASS task cancellation leaves both effects disabled") }
            else { failures += 1; print("FAIL cancellation left effects enabled") }
        } catch { failures += 1; print("FAIL unexpected cancellation failure: \(error)") }
        let cancelledAudio = Task { @MainActor in try await effects.apply(.init(muted: true)) { _ in } }
        cancelledAudio.cancel()
        do {
            _ = try await cancelledAudio.value
            failures += 1
            print("FAIL cancelled request started audio")
        } catch is CancellationError {
            if audio.enableCalls == 0 { print("PASS a cancelled request never starts the audio process") }
            else { failures += 1; print("FAIL cancelled request touched audio") }
        } catch { failures += 1; print("FAIL unexpected audio cancellation failure: \(error)") }
        do {
            let audio = FakeSessionAudio(), privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            _ = try await effects.apply(.init(privacy: true)) { _ in }
            audio.isMuted = true; audio.holdRestores = true
            let first = Task { @MainActor in await effects.reset() }
            while audio.restoreWaiters.isEmpty { await Task.yield() }
            var secondStarted = false
            let second = Task { @MainActor in secondStarted = true; return await effects.reset() }
            while !secondStarted { await Task.yield() }
            let shared = audio.restoreCalls == 1 && !privacy.isVisible
            audio.holdRestores = false
            audio.restoreWaiters.forEach { $0.resume() }; audio.restoreWaiters.removeAll()
            let firstError = await first.value, secondError = await second.value
            if shared, firstError == nil, secondError == nil, effects.state == SessionEffectsState() {
                print("PASS concurrent resets share one restore and remove privacy immediately")
            } else { failures += 1; print("FAIL concurrent resets duplicated restoration") }
        } catch { failures += 1; print("FAIL concurrent reset setup: \(error)") }

        do {
            let audio = FakeSessionAudio(), privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            audio.isMuted = true; audio.holdRestores = true
            let unmute = Task { @MainActor in try await effects.apply(.init()) { _ in } }
            while audio.restoreWaiters.isEmpty { await Task.yield() }
            var resetStarted = false
            let reset = Task { @MainActor in resetStarted = true; return await effects.reset() }
            while !resetStarted { await Task.yield() }
            let shared = audio.restoreCalls == 1
            unmute.cancel()
            audio.holdRestores = false
            audio.restoreWaiters.forEach { $0.resume() }; audio.restoreWaiters.removeAll()
            let resetError = await reset.value
            do { _ = try await unmute.value; throw DeskError.invalid("Cancelled unmute request succeeded") }
            catch is CancellationError {}
            if shared, resetError == nil, effects.state == SessionEffectsState() {
                print("PASS cancelled apply and reset share the in-flight audio restore")
            } else { failures += 1; print("FAIL apply and reset duplicated audio restore") }
        } catch { failures += 1; print("FAIL interleaved apply/reset: \(error)") }

        let failingAudio = FakeSessionAudio()
        let failing = HostSessionEffects(audio: failingAudio, privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
        failingAudio.isMuted = true; failingAudio.holdRestores = true; failingAudio.restoreError = "fake restore failure"
        let failedFirst = Task { @MainActor in await failing.reset() }
        while failingAudio.restoreWaiters.isEmpty { await Task.yield() }
        var failedSecondStarted = false
        let failedSecond = Task { @MainActor in failedSecondStarted = true; return await failing.reset() }
        while !failedSecondStarted { await Task.yield() }
        let failureShared = failingAudio.restoreCalls == 1
        failingAudio.holdRestores = false
        failingAudio.restoreWaiters.forEach { $0.resume() }; failingAudio.restoreWaiters.removeAll()
        let firstFailure = await failedFirst.value, secondFailure = await failedSecond.value
        if failureShared, firstFailure == "fake restore failure", secondFailure == firstFailure, failing.state.muted {
            print("PASS shared reset failure reaches all callers and retains actual mute state")
        } else { failures += 1; print("FAIL shared reset lost failure or actual state") }
        let exitBarrier = SessionAudioExitBarrier(), oldToken = UUID()
        exitBarrier.begin(oldToken)
        var nextStarted = false
        var operations: [String] = []
        let nextController = Task { @MainActor in
            nextStarted = true
            let error = await exitBarrier.wait(for: oldToken)
            operations.append("new mute")
            return error
        }
        while !nextStarted { await Task.yield() }
        let heldBeforeCleanup = operations.isEmpty
        operations.append("old restore finished")
        exitBarrier.finish(oldToken, error: nil)
        let nextError = await nextController.value
        if heldBeforeCleanup, nextError == nil, operations == ["old restore finished", "new mute"] {
            print("PASS exit barrier holds the next controller until old cleanup has finished")
        } else { failures += 1; print("FAIL next controller passed the exit barrier early") }

        let old = UUID(), current = UUID()
        exitBarrier.begin(old); exitBarrier.begin(current)
        var currentStarted = false, currentReleased = false
        let currentWaiter = Task { @MainActor in
            currentStarted = true
            let error = await exitBarrier.wait(for: current)
            currentReleased = true
            return error
        }
        while !currentStarted { await Task.yield() }
        exitBarrier.finish(old, error: nil)
        await Task.yield()
        let isolated = !currentReleased
        exitBarrier.finish(current, error: "fake driver recovery failed")
        let currentError = await currentWaiter.value
        let lateError = await exitBarrier.wait(for: current)
        exitBarrier.finish(current, error: nil)
        if isolated, currentError == "fake driver recovery failed", lateError == currentError {
            print("PASS exit barriers isolate process tokens and preserve cleanup failures for late waiters")
        } else { failures += 1; print("FAIL exit barrier lost its token or recovery failure") }

        let replies = Pipe(), reads = PipeReadProbe()
        let replyReader = replies.fileHandleForReading
        DispatchQueue.global().async {
            readAvailableChunks(from: replyReader) { reads.received($0.count) }
            reads.finish()
        }
        try? replies.fileHandleForWriting.write(contentsOf: Data("{\"muted\":true}\n".utf8))
        for _ in 0..<200 where reads.state.bytes == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        let deliveredWhileOpen = reads.state == (15, false)
        try? replies.fileHandleForWriting.close()
        for _ in 0..<200 where !reads.state.ended { try? await Task.sleep(for: .milliseconds(10)) }
        if deliveredWhileOpen, reads.state == (15, true) {
            print("PASS a short helper reply arrives while the pipe stays open and reading ends at EOF")
        } else { failures += 1; print("FAIL helper reply waited for EOF or reading never ended: \(reads.state)") }

        do {
            let audio = FakeSessionAudio(), privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            var updates: [String?] = []
            effects.onStateChange = { _, message in updates.append(message) }
            audio.onChange?(false, nil)
            let quietWhenUnchanged = updates.isEmpty
            audio.onChange?(false, "fake helper failure")
            audio.isMuted = true
            _ = try await effects.apply(.init(muted: true)) { _ in }
            audio.onChange?(false, nil)
            if quietWhenUnchanged, updates == ["fake helper failure", nil], effects.state == SessionEffectsState() {
                print("PASS an unchanged helper exit keeps the last failure while real changes and errors still reach the viewer")
            } else { failures += 1; print("FAIL helper state updates: \(updates)") }
        } catch { failures += 1; print("FAIL helper state update setup: \(error)") }
        do {
            let audio = FakeSessionAudio(), privacy = FakeSessionPrivacy(), lock = FakeScreenLock()
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: lock, dimmer: FakeDisplayDimmer())
            lock.unavailableReason = "fake lock unavailable"
            var refused = false
            do { _ = try await effects.apply(.init(privacy: true, lockOnDisconnect: true)) { _ in } }
            catch { refused = error.localizedDescription == "fake lock unavailable" && effects.state == .init(privacy: true) }
            lock.unavailableReason = nil
            let applied = try await effects.apply(.init(privacy: true, lockOnDisconnect: true)) { _ in }
            lock.holdConfirmation = true
            effects.endSession()
            let issuedAtOnce = lock.lockCalls == 1
            var resetStarted = false
            let reset = Task { @MainActor in resetStarted = true; return await effects.reset() }
            while !resetStarted || lock.confirmWaiters.isEmpty { await Task.yield() }
            await Task.yield()
            let curtainHeld = privacy.isVisible
            effects.endSession()
            lock.confirmation = "fake lock not confirmed"
            lock.holdConfirmation = false
            lock.confirmWaiters.forEach { $0.resume() }; lock.confirmWaiters.removeAll()
            let message = await reset.value
            if refused, applied.lockOnDisconnect, issuedAtOnce, curtainHeld, lock.lockCalls == 1, !privacy.isVisible,
               message == "fake lock not confirmed", !effects.state.lockOnDisconnect {
                print("PASS a session lock is refused when unavailable, issued once at session end and confirmed before the curtain lifts")
            } else { failures += 1; print("FAIL session lock: refused \(refused) once \(issuedAtOnce) held \(curtainHeld) calls \(lock.lockCalls) \(message ?? "nil")") }
        } catch { failures += 1; print("FAIL session lock setup: \(error)") }

        do {
            let lock = FakeScreenLock()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock, dimmer: FakeDisplayDimmer())
            _ = try await effects.apply(.init(lockOnDisconnect: true)) { _ in }
            let switchedOff = try await effects.apply(.init()) { _ in }
            let message = await effects.reset()
            let untouched = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock, dimmer: FakeDisplayDimmer())
            let untouchedMessage = await untouched.reset()
            if !switchedOff.lockOnDisconnect, lock.lockCalls == 0, message == nil, untouchedMessage == nil, effects.endSession() == nil {
                print("PASS a session that switched the lock off or never asked for it ends without locking")
            } else { failures += 1; print("FAIL an unrequested session lock was issued: \(lock.lockCalls)") }
        } catch { failures += 1; print("FAIL unrequested lock setup: \(error)") }
        do {
            let privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            var excluded: [CGWindowID] = []
            var opaqueDuringPreparation = false
            let applied = try await effects.apply(.init(privacy: true)) { windows in
                excluded = windows; opaqueDuringPreparation = privacy.isVisible
            }
            var forwarded: [CGWindowID]?
            effects.onCoverWindowsChanged = { forwarded = $0 }
            privacy.onWindowsChanged?([41, 43])
            if applied.privacy, excluded == [41, 42], !opaqueDuringPreparation, privacy.shows == 1, forwarded == [41, 43] {
                print("PASS capture learns the cover windows before they turn opaque, and later cover changes are forwarded")
            } else { failures += 1; print("FAIL cover exclusion order: \(excluded) opaque \(opaqueDuringPreparation) forwarded \(forwarded ?? [])") }
        } catch { failures += 1; print("FAIL cover exclusion setup: \(error)") }
        do {
            let privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            var refused = false
            do { _ = try await effects.apply(.init(privacy: true)) { _ in throw DeskError.invalid("fake exclusion failure") } }
            catch { refused = error.localizedDescription == "fake exclusion failure" }
            if refused, privacy.shows == 0, !privacy.prepared, effects.state == SessionEffectsState() {
                print("PASS a cover that capture could not leave out is removed without ever turning opaque")
            } else { failures += 1; print("FAIL failed exclusion left a cover behind") }
        }
        do {
            let privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(), dimmer: FakeDisplayDimmer())
            _ = try await effects.apply(.init(privacy: true)) { _ in }
            let wasUp = privacy.isVisible
            let lock = effects.endSession()
            if wasUp, lock == nil, !privacy.isVisible, !privacy.prepared, !effects.state.privacy {
                print("PASS without a pending lock the curtain comes down synchronously when the session ends")
            } else { failures += 1; print("FAIL curtain outlived the session end") }
        } catch { failures += 1; print("FAIL curtain session end setup: \(error)") }
        do {
            let lock = FakeScreenLock(), dimmer = FakeDisplayDimmer()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock, dimmer: dimmer)
            dimmer.unavailableReason = "fake not a laptop"
            var refused = false
            do { _ = try await effects.apply(.init(muted: true, lockOnDisconnect: true, dimBuiltInDisplay: true)) { _ in } }
            catch { refused = error.localizedDescription == "fake not a laptop" }
            let othersKept = effects.state == .init(muted: true, lockOnDisconnect: true) && dimmer.dimCalls == 0
            dimmer.unavailableReason = nil
            let applied = try await effects.apply(.init(muted: true, lockOnDisconnect: true, dimBuiltInDisplay: true)) { _ in }
            let switchedOff = try await effects.apply(.init(muted: true, lockOnDisconnect: true)) { _ in }
            if refused, othersKept, applied == .init(muted: true, lockOnDisconnect: true, dimBuiltInDisplay: true), dimmer.dimCalls == 1,
               switchedOff == .init(muted: true, lockOnDisconnect: true), !dimmer.isDimmed {
                print("PASS a display that cannot be dimmed refuses only dimming, and switching it off brings the brightness back")
            } else { failures += 1; print("FAIL dimming order: refused \(refused) kept \(othersKept) calls \(dimmer.dimCalls) \(switchedOff)") }
        } catch { failures += 1; print("FAIL dimming order setup: \(error)") }
        do {
            let dimmer = FakeDisplayDimmer()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock(), dimmer: dimmer)
            var updates: [(SessionEffectsState, String?)] = []
            effects.onStateChange = { updates.append(($0, $1)) }
            _ = try await effects.apply(.init(dimBuiltInDisplay: true)) { _ in }
            dimmer.isDimmed = false
            dimmer.onEnded?("fake raised on the host")
            let message = await effects.reset()
            if updates.count == 1, updates[0].0 == .init(), updates[0].1 == "fake raised on the host", dimmer.dimCalls == 1,
               !effects.state.dimBuiltInDisplay, message == nil {
                print("PASS a brightness raised on the host turns the switch off with a reason and is not pushed back down")
            } else { failures += 1; print("FAIL raised brightness: \(updates.map { "\($0.0) \($0.1 ?? "nil")" }) calls \(dimmer.dimCalls)") }
        } catch { failures += 1; print("FAIL raised brightness setup: \(error)") }
        do {
            let lock = FakeScreenLock(), dimmer = FakeDisplayDimmer()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock, dimmer: dimmer)
            _ = try await effects.apply(.init(lockOnDisconnect: true, dimBuiltInDisplay: true)) { _ in }
            lock.holdConfirmation = true
            effects.endSession()
            let heldForLock = dimmer.isDimmed && dimmer.lockHolds == 1 && lock.lockCalls == 1
            var resetStarted = false
            let reset = Task { @MainActor in resetStarted = true; return await effects.reset() }
            while !resetStarted || lock.confirmWaiters.isEmpty { await Task.yield() }
            await Task.yield()
            let darkUntilLocked = dimmer.isDimmed
            lock.holdConfirmation = false
            lock.confirmWaiters.forEach { $0.resume() }; lock.confirmWaiters.removeAll()
            let message = await reset.value
            let quick = FakeDisplayDimmer()
            let unlocked = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock(), dimmer: quick)
            _ = try await unlocked.apply(.init(dimBuiltInDisplay: true)) { _ in }
            let pendingLock = unlocked.endSession()
            if heldForLock, darkUntilLocked, message == nil, !dimmer.isDimmed, !effects.state.dimBuiltInDisplay,
               pendingLock == nil, !quick.isDimmed, quick.lockHolds == 0, !unlocked.state.dimBuiltInDisplay {
                print("PASS the brightness comes back only after a requested lock is confirmed, and at once when the session ends without one")
            } else { failures += 1; print("FAIL dim and lock order: held \(heldForLock) dark \(darkUntilLocked) \(message ?? "nil") quick \(quick.isDimmed)") }
        } catch { failures += 1; print("FAIL dim and lock setup: \(error)") }
        do {
            let dimmer = FakeDisplayDimmer()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock(), dimmer: dimmer)
            _ = try await effects.apply(.init(dimBuiltInDisplay: true)) { _ in }
            dimmer.restoreFailure = "fake restore failed"
            var refused = false
            do { _ = try await effects.apply(.init()) { _ in } } catch { refused = error.localizedDescription == "fake restore failed" }
            let stillDark = effects.state.dimBuiltInDisplay
            let message = await effects.reset()
            if refused, stillDark, message == "fake restore failed", effects.state.dimBuiltInDisplay {
                print("PASS a brightness that could not be restored stays reported as dark, with the reason, until it is")
            } else { failures += 1; print("FAIL failed restore: refused \(refused) dark \(stillDark) \(message ?? "nil")") }
        } catch { failures += 1; print("FAIL failed restore setup: \(error)") }
        do {
            let dimmer = FakeDisplayDimmer()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock(), dimmer: dimmer)
            dimmer.holdDim = true
            let pending = Task { @MainActor in try await effects.apply(.init(dimBuiltInDisplay: true)) { _ in } }
            while dimmer.dimWaiters.isEmpty { await Task.yield() }
            let resetMessage = await effects.reset()
            let restoresDuringReset = dimmer.restoreCalls
            dimmer.dimWaiters.forEach { $0.resume() }; dimmer.dimWaiters.removeAll()
            var cancelled = false
            do { _ = try await pending.value } catch is CancellationError { cancelled = true } catch {}
            if resetMessage == nil, cancelled, !dimmer.isDimmed, dimmer.restoreCalls == restoresDuringReset + 1, !effects.state.dimBuiltInDisplay {
                print("PASS a dimming that finishes after the session was reset is undone at once")
            } else { failures += 1; print("FAIL late dimming: cancelled \(cancelled) dimmed \(dimmer.isDimmed) restores \(dimmer.restoreCalls)") }
        }
        do {
            let original = DisplayDimTransaction(original: 0.7)
            let released = RecordingBrightness(0), gone = RecordingBrightness(0), raised = RecordingBrightness(0.25)
            DisplayDimWatchdog.serve(AnyIterator(["release"].makeIterator()), restoring: original, using: released, isLocked: { false })
            DisplayDimWatchdog.serve(AnyIterator([String]().makeIterator()), restoring: original, using: gone, isLocked: { false })
            DisplayDimWatchdog.serve(AnyIterator([String]().makeIterator()), restoring: original, using: raised, isLocked: { false })
            let locking = RecordingBrightness(0)
            var lockChecks = 0, writesBeforeLock = -1
            DisplayDimWatchdog.serve(AnyIterator(["lock"].makeIterator()), restoring: original, using: locking, isLocked: {
                lockChecks += 1
                if lockChecks == 3 { writesBeforeLock = locking.writes.count }
                return lockChecks >= 3
            })
            let neverLocked = RecordingBrightness(0), started = Date()
            DisplayDimWatchdog.serve(AnyIterator(["lock"].makeIterator()), restoring: original, using: neverLocked, isLocked: { false }, lockWait: 0.3)
            let waited = Date().timeIntervalSince(started)
            if released.writes.isEmpty, gone.writes == [0.7], raised.writes.isEmpty, writesBeforeLock == 0, locking.writes == [0.7],
               neverLocked.writes == [0.7], waited >= 0.3 {
                print("PASS the helper restores only when the app goes away without releasing, never over a raised brightness, and after a requested lock")
            } else { failures += 1; print("FAIL helper decisions: \(released.writes) \(gone.writes) \(raised.writes) \(writesBeforeLock) \(locking.writes) \(neverLocked.writes)") }
        }
        do {
            let display = CGDirectDisplayID.random(in: 100_000...999_999)
            let file = FileBrightness(display: display).path
            defer { try? FileManager.default.removeItem(atPath: file) }
            func reading() -> String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
            func eventually(_ condition: () -> Bool) async -> Bool {
                for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
                return condition()
            }
            try "0.0".write(toFile: file, atomically: true, encoding: .utf8)
            var abandoned: DisplayDimWatchdogClient? = try DisplayDimWatchdogClient(display: display, original: 0.55)
            _ = abandoned
            abandoned = nil
            let restored = await eventually { reading() == "0.55" }
            try "0.0".write(toFile: file, atomically: true, encoding: .utf8)
            let released = try DisplayDimWatchdogClient(display: display, original: 0.55)
            var releasedReported = false
            released.onExit = { releasedReported = true }
            released.release()
            let releasedEnded = await eventually { released.hasExited }
            let untouched = reading() == "0.0"
            let killed = try DisplayDimWatchdogClient(display: display, original: 0.55)
            var killReported = false
            killed.onExit = { killReported = true }
            kill(killed.processIdentifier, SIGKILL)
            let reported = await eventually { killReported }
            if restored, releasedEnded, untouched, !releasedReported, reported, killed.hasExited {
                print("PASS a real helper process restores after the app lets go without releasing, stays quiet when released, and its death is reported")
            } else { failures += 1; print("FAIL helper process: restored \(restored) released \(releasedEnded) untouched \(untouched) \(releasedReported) killed \(reported)") }
        } catch { failures += 1; print("FAIL helper process setup: \(error)") }
        print("\(23 - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
