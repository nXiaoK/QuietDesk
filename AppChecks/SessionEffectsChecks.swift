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

@main
enum SessionEffectsCancellationChecks {
    @MainActor static func main() async {
        var failures = 0
        let privacy = FakeSessionPrivacy()
        let audio = FakeSessionAudio()
        let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock())
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock())
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock())
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
        let failing = HostSessionEffects(audio: failingAudio, privacy: FakeSessionPrivacy(), screenLock: FakeScreenLock())
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: FakeScreenLock())
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: lock)
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
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock)
            _ = try await effects.apply(.init(lockOnDisconnect: true)) { _ in }
            let switchedOff = try await effects.apply(.init()) { _ in }
            let message = await effects.reset()
            let untouched = HostSessionEffects(audio: FakeSessionAudio(), privacy: FakeSessionPrivacy(), screenLock: lock)
            let untouchedMessage = await untouched.reset()
            if !switchedOff.lockOnDisconnect, lock.lockCalls == 0, message == nil, untouchedMessage == nil, effects.endSession() == nil {
                print("PASS a session that switched the lock off or never asked for it ends without locking")
            } else { failures += 1; print("FAIL an unrequested session lock was issued: \(lock.lockCalls)") }
        } catch { failures += 1; print("FAIL unrequested lock setup: \(error)") }
        do {
            let privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock())
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
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock())
            var refused = false
            do { _ = try await effects.apply(.init(privacy: true)) { _ in throw DeskError.invalid("fake exclusion failure") } }
            catch { refused = error.localizedDescription == "fake exclusion failure" }
            if refused, privacy.shows == 0, !privacy.prepared, effects.state == SessionEffectsState() {
                print("PASS a cover that capture could not leave out is removed without ever turning opaque")
            } else { failures += 1; print("FAIL failed exclusion left a cover behind") }
        }
        print("\(15 - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
