import Foundation
import QuietDeskCore

@MainActor
private final class FakeKeys: UnlockKeyTyping {
    var typed = ""
    var returns = 0
    var wakes = 0
    var afterType: ((String) -> Void)?
    var onReturn: (() -> Void)?
    func wake() { wakes += 1 }
    func type(_ character: Character) -> Bool { typed.append(character); afterType?(typed); return true }
    func pressReturn() -> Bool { returns += 1; onReturn?(); return true }
}

@main
enum ScreenUnlockChecks {
    @MainActor static func main() async {
        var failures = 0
        func report(_ passed: Bool, _ name: String) {
            if passed { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        let noPause: (Duration) async -> Void = { _ in await Task.yield() }
        do {
            var locked = true
            let keys = FakeKeys()
            keys.onReturn = { locked = false }
            let unlocker = HostScreenUnlocker(isLocked: { locked }, isTrusted: { true }, keys: keys, pause: noPause)
            let request = try SessionUnlockRequest(password: "Ab1 £")
            let result = await unlocker.unlock(request)
            report(result == SessionUnlockResult(id: request.id, outcome: .unlocked) && keys.typed == "Ab1 £"
                   && keys.returns == 1 && keys.wakes == 1 && !unlocker.typing,
                   "a locked host wakes the lock screen, types every character, presses Return once and reports the unlock")

            let notLocked = await unlocker.unlock(request)
            report(notLocked.outcome == .notLocked && keys.typed == "Ab1 £" && keys.returns == 1 && keys.wakes == 1,
                   "an unlocked host types nothing and reports that it was not locked")
        } catch { failures += 1; print("FAIL unlock setup: \(error)") }

        do {
            var locked = true
            let keys = FakeKeys()
            keys.afterType = { typed in if typed.count == 2 { locked = false } }
            let unlocker = HostScreenUnlocker(isLocked: { locked }, isTrusted: { true }, keys: keys, pause: noPause)
            let result = await unlocker.unlock(try SessionUnlockRequest(password: "secret"))
            report(result.outcome == .notLocked && keys.typed == "se" && keys.returns == 0,
                   "a local unlock while typing stops before the next character and never presses Return")
        } catch { failures += 1; print("FAIL local unlock setup: \(error)") }

        do {
            let keys = FakeKeys()
            let untrusted = HostScreenUnlocker(isLocked: { true }, isTrusted: { false }, keys: keys, pause: noPause)
            let refused = await untrusted.unlock(try SessionUnlockRequest(password: "secret"))
            let stuck = HostScreenUnlocker(isLocked: { true }, isTrusted: { true }, keys: keys, pause: noPause)
            let wrong = await stuck.unlock(try SessionUnlockRequest(password: "x"))
            report(refused.outcome == .failed && keys.typed == "x" && wrong.outcome == .failed && keys.returns == 1,
                   "missing accessibility types nothing, and a screen that stays locked after Return is reported as a failure")
        } catch { failures += 1; print("FAIL refusal setup: \(error)") }

        do {
            var release: CheckedContinuation<Void, Never>?
            let keys = FakeKeys()
            let unlocker = HostScreenUnlocker(isLocked: { true }, isTrusted: { true }, keys: keys,
                                              pause: { _ in await withCheckedContinuation { release = $0 } })
            let first = Task { @MainActor in await unlocker.unlock(try! SessionUnlockRequest(password: "abc")) }
            while release == nil { await Task.yield() }
            let second = await unlocker.unlock(try SessionUnlockRequest(password: "zzz"))
            first.cancel()
            release?.resume(); release = nil
            var steps = 0
            while unlocker.typing, steps < 1000 {
                if let pending = release { release = nil; pending.resume() }
                await Task.yield(); steps += 1
            }
            let firstResult = await first.value
            report(second.outcome == .failed && !keys.typed.contains("z") && firstResult.outcome == .failed && keys.returns == 0,
                   "an overlapping request is refused and a cancelled attempt stops without submitting")
        } catch { failures += 1; print("FAIL overlap setup: \(error)") }
        print("\(5 - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
