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

private final class SessionCursorProbe {
    var calls: [String] = []
    var hideResult = CGError.success, showResult = CGError.success
    var backend: PrivacyCursorBackend {
        PrivacyCursorBackend(setBackground: { self.calls.append($0 ? "background on" : "background off") },
            hide: { self.calls.append("hide"); return self.hideResult },
            show: { self.calls.append("show"); return self.showResult })
    }
}

@MainActor
private func checkPrivacyCursorLifecycle() async -> (count: Int, failures: Int) {
    var count = 0, failures = 0
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DeskError.invalid(message) }
    }
    func run(_ name: String, _ body: () async throws -> Void) async {
        count += 1
        do { try await body(); print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
    }

    await run("capture exclusion completes before the local cursor is hidden and the curtain is revealed") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let hider = PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend))
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
                                        dimmer: FakeDisplayDimmer(), privacyCursor: hider)
        try require(effects.setIndependentCursor(true) == nil && probe.calls.isEmpty, "Idle cursor mode changed the host cursor")
        let applied = try await effects.apply(.init(privacy: true)) { windows in
            try require(windows == [41, 42] && privacy.prepared && !privacy.isVisible && probe.calls.isEmpty,
                        "The curtain or cursor changed before capture exclusion")
            probe.calls.append("excluded")
        }
        try require(applied.privacy && hider.isActive && effects.cursorNotice == nil && privacy.shows == 1 &&
                    probe.calls == ["excluded", "background on", "hide"], "Capture-to-cursor activation order was wrong")
        _ = await effects.reset()
    }
    await run("repeated privacy enable and cursor mode confirmation keep a single hide count") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        _ = try await effects.apply(.init(privacy: true)) { _ in throw DeskError.invalid("Duplicate enable prepared capture again") }
        effects.setIndependentCursor(true)
        try require(privacy.shows == 1 && probe.calls == ["background on", "hide"], "Duplicate enable hid again")
        _ = try await effects.apply(.init()) { _ in }
        _ = await effects.reset()
        try require(!privacy.isVisible && probe.calls == ["background on", "hide", "show", "background off"],
                    "Repeated cleanup over-restored the cursor")
    }
    await run("legacy or video cursor mode keeps the curtain and explains why the cursor remains visible") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        let applied = try await effects.apply(.init(privacy: true)) { _ in }
        try require(applied.privacy && probe.calls.isEmpty && effects.cursorNotice?.contains("本地即时光标") == true,
                    "Legacy mode hid the video cursor or omitted the notice")
        _ = await effects.reset()
        try require(probe.calls.isEmpty, "Legacy cleanup touched the cursor")
    }
    await run("cursor mode changes restore and rehide the cursor without rebuilding the curtain") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        var messages: [String?] = []
        effects.onStateChange = { _, message in messages.append(message) }
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        try require(effects.setIndependentCursor(true) == nil && effects.cursorNotice == nil, "Independent mode did not hide")
        try require(effects.setIndependentCursor(false) == nil && effects.cursorNotice?.contains("本地即时光标") == true,
                    "Video mode did not restore or explain the cursor")
        try require(effects.setIndependentCursor(true) == nil && effects.cursorNotice == nil, "Independent mode did not rehide")
        try require(privacy.isVisible && privacy.shows == 1 && messages.count == 3 &&
                    probe.calls == ["background on", "hide", "show", "background off", "background on", "hide"],
                    "Mode change disturbed the curtain or cursor count")
        _ = await effects.reset()
    }
    await run("a failed cursor restore refuses the switch to video mode and can be retried") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        probe.showResult = .failure
        try require(effects.setIndependentCursor(false)?.contains("恢复本机光标失败") == true,
                    "Capture could switch to video despite a failed show")
        try require(privacy.isVisible && probe.calls == ["background on", "hide", "show"],
                    "Failed show disabled background support or the curtain")
        probe.showResult = .success
        try require(effects.setIndependentCursor(false) == nil && effects.cursorNotice?.contains("本地即时光标") == true,
                    "Video mode restore did not recover")
        _ = await effects.reset()
    }
    await run("the local exit callback releases the cursor and reports the curtain's actual state") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        var state: SessionEffectsState?, message: String?
        effects.onStateChange = { state = $0; message = $1 }
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        // The real hotkey and no-display callback remove the cover before notifying the session.
        privacy.hide(); privacy.onExit?()
        try require(state == .init() && effects.state == .init() && message == "本机已退出防窥" &&
                    probe.calls == ["background on", "hide", "show", "background off"], "Local exit left the cursor hidden")
        _ = await effects.reset()
        try require(probe.calls.count == 4, "Reset after local exit showed twice")
    }
    for operation in ["reset", "cancellation", "local exit"] {
        await run("\(operation) during capture preparation never hides the cursor") {
            let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
            let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
                dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
            effects.setIndependentCursor(true)
            var continuation: CheckedContinuation<Void, Never>?
            let pending = Task { @MainActor in
                try await effects.apply(.init(privacy: true)) { _ in
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            while continuation == nil { await Task.yield() }
            if operation == "reset" { _ = await effects.reset() }
            else if operation == "cancellation" { pending.cancel() }
            else { privacy.hide(); privacy.onExit?() }
            continuation?.resume()
            var cancelled = false, reason: String?
            do { _ = try await pending.value }
            catch is CancellationError { cancelled = true }
            catch { reason = error.localizedDescription }
            let expectedFailure = operation == "local exit" ? !cancelled && reason == "本机已退出防窥" : cancelled
            try require(expectedFailure && !privacy.prepared && privacy.shows == 0 && effects.state == .init() && probe.calls.isEmpty,
                        "Late capture preparation hid a cursor or revealed a curtain")
        }
    }
    await run("local exit during privacy preparation preserves mute, dimming and the disconnect lock") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy(), audio = FakeSessionAudio()
        let lock = FakeScreenLock(), dimmer = FakeDisplayDimmer()
        let effects = HostSessionEffects(audio: audio, privacy: privacy, screenLock: lock, dimmer: dimmer,
            privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        let existing = SessionEffectsState(muted: true, lockOnDisconnect: true, dimBuiltInDisplay: true)
        _ = try await effects.apply(existing) { _ in throw DeskError.invalid("Unrequested privacy preparation") }
        let audioRestores = audio.restoreCalls, displayRestores = dimmer.restoreCalls
        var continuation: CheckedContinuation<Void, Never>?
        let pending = Task { @MainActor in
            try await effects.apply(.init(muted: true, privacy: true, lockOnDisconnect: true, dimBuiltInDisplay: true)) { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        privacy.hide(); privacy.onExit?()
        continuation?.resume()
        var reason: String?
        do { _ = try await pending.value } catch { reason = error.localizedDescription }
        try require(reason == "本机已退出防窥" && effects.state == existing && audio.isMuted && dimmer.isDimmed &&
                    audio.restoreCalls == audioRestores && dimmer.restoreCalls == displayRestores && lock.lockCalls == 0 &&
                    !privacy.prepared && privacy.shows == 0 && probe.calls.isEmpty,
                    "Local privacy exit reset unrelated effects, locked the session or hid the cursor")
        _ = await effects.reset()
    }
    await run("cursor hiding failure keeps the existing curtain and supplies a truthful notice") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy(); probe.hideResult = .failure
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        let applied = try await effects.apply(.init(privacy: true)) { _ in }
        try require(applied.privacy && privacy.isVisible && effects.cursorNotice?.contains("隐藏本机光标失败") == true &&
                    effects.cursorNotice?.contains("防窥未开启") == false && probe.calls == ["background on", "hide", "background off"],
                    "Failed hide removed the curtain or misreported success")
        probe.hideResult = .success
        try require(effects.setIndependentCursor(true) == nil && effects.cursorNotice == nil && privacy.shows == 1,
                    "A later successful hide could not clear the failure")
        _ = await effects.reset()
    }
    await run("reset reports failed cursor restoration and a later reset finishes the same hide") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        probe.showResult = .failure
        let failure = await effects.reset()
        try require(failure?.contains("恢复本机光标失败") == true && !privacy.isVisible && effects.state == .init() &&
                    !probe.calls.contains("background off"), "Failed restoration was lost or background support ended early")
        probe.showResult = .success
        let restored = await effects.reset()
        try require(restored == nil && probe.calls.filter { $0 == "hide" }.count == 1 &&
                    probe.calls.filter { $0 == "background off" }.count == 1 && Array(probe.calls.suffix(2)) == ["show", "background off"],
                    "Retry added another hide or did not restore")
    }
    await run("lock confirmation keeps the curtain and cursor hidden until the system lock completes") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy(), lock = FakeScreenLock()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: lock,
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true, lockOnDisconnect: true)) { _ in }
        lock.holdConfirmation = true
        effects.endSession()
        let reset = Task { @MainActor in await effects.reset() }
        while lock.confirmWaiters.isEmpty { await Task.yield() }
        let held = privacy.isVisible && probe.calls == ["background on", "hide"] && lock.lockCalls == 1
        lock.holdConfirmation = false
        lock.confirmWaiters.forEach { $0.resume() }; lock.confirmWaiters.removeAll()
        let failure = await reset.value
        try require(held && failure == nil && !privacy.isVisible && probe.calls == ["background on", "hide", "show", "background off"],
                    "Cursor or curtain was restored before lock confirmation")
    }
    await run("ending an unlocked session restores the cursor synchronously") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let effects = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend)))
        effects.setIndependentCursor(true)
        _ = try await effects.apply(.init(privacy: true)) { _ in }
        try require(effects.endSession() == nil && !privacy.isVisible && !effects.state.privacy &&
                    probe.calls == ["background on", "hide", "show", "background off"], "EndSession deferred cursor restoration")
        _ = await effects.reset()
        try require(probe.calls.count == 4, "Reset after endSession showed twice")
    }
    await run("releasing the effects and its last cursor owner restores the process hide") {
        let probe = SessionCursorProbe(), privacy = FakeSessionPrivacy()
        let controller = PrivacyCursorController(backend: probe.backend)
        var effects: HostSessionEffects? = HostSessionEffects(audio: FakeSessionAudio(), privacy: privacy, screenLock: FakeScreenLock(),
            dimmer: FakeDisplayDimmer(), privacyCursor: PrivacyCursorHider(controller: controller))
        effects?.setIndependentCursor(true)
        _ = try await effects?.apply(.init(privacy: true)) { _ in }
        effects = nil
        try require(probe.calls == ["background on", "hide", "show", "background off"],
                    "Effects retained its cursor owner or dropping the owner did not restore")
        try require(controller.retryRestoration() == nil && probe.calls.count == 4, "Post-release cleanup showed twice")
    }
    return (count, failures)
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
        let cursorChecks = await checkPrivacyCursorLifecycle()
        failures += cursorChecks.failures
        print("\(23 + cursorChecks.count - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
