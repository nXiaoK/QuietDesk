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
    var onExit: (() -> Void)?
    var shows = 0
    func show() throws { isVisible = true; shows += 1 }
    func hide() { isVisible = false }
}

@main
enum SessionEffectsCancellationChecks {
    @MainActor static func main() async {
        var failures = 0
        let privacy = FakeSessionPrivacy()
        let audio = FakeSessionAudio()
        let effects = HostSessionEffects(audio: audio, privacy: privacy)
        var releasePreparation: CheckedContinuation<Void, Never>?
        let pending = Task { @MainActor in
            try await effects.apply(.init(privacy: true)) {
                await withCheckedContinuation { releasePreparation = $0 }
            }
        }
        while releasePreparation == nil { await Task.yield() }
        do {
            _ = try await effects.apply(.init()) { fatalError("Overlapping request should be rejected before preparation") }
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
            if effects.state == SessionEffectsState(), resetError == nil, privacy.shows == 0 {
                print("PASS reset cancels late privacy preparation before any window or audio is created")
            } else { failures += 1; print("FAIL reset left effects enabled") }
        } catch { failures += 1; print("FAIL unexpected preparation failure: \(error)") }

        let cancelled = Task { @MainActor in try await effects.apply(.init(privacy: true)) {} }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            failures += 1
            print("FAIL cancelled request enabled privacy")
        } catch is CancellationError {
            if effects.state == SessionEffectsState(), privacy.shows == 0 { print("PASS task cancellation leaves both effects disabled") }
            else { failures += 1; print("FAIL cancellation left effects enabled") }
        } catch { failures += 1; print("FAIL unexpected cancellation failure: \(error)") }
        let cancelledAudio = Task { @MainActor in try await effects.apply(.init(muted: true)) {} }
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy)
            _ = try await effects.apply(.init(privacy: true)) {}
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
            let effects = HostSessionEffects(audio: audio, privacy: privacy)
            audio.isMuted = true; audio.holdRestores = true
            let unmute = Task { @MainActor in try await effects.apply(.init()) {} }
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
        let failing = HostSessionEffects(audio: failingAudio, privacy: FakeSessionPrivacy())
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
        print("\(9 - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
