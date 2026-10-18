import AppKit
import QuietDeskCore

private struct CapsLockCheckFailure: Error { let message: String }

@MainActor
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CapsLockCheckFailure(message: message) }
}

@main
private struct CapsLockMonitorChecks {
    @MainActor
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("A timeout with valid permissions restores capture without reporting a permanent failure") {
            var restored = 0, failures = 0
            let monitor = CapsLockMonitor(permissionsGranted: { true }, restoreTap: { _ in restored += 1; return true })
            monitor.onFailure = { _ in failures += 1 }
            let generation = monitor.generation
            monitor.handleTapInterruption(.tapDisabledByTimeout)
            try require(restored == 1 && failures == 0 && monitor.generation == generation,
                        "Transient timeout stopped or replaced a healthy listener")
        }
        run("Recovery clears an interrupted press and forwards subsequent short and long presses once") {
            let monitor = CapsLockMonitor(permissionsGranted: { true }, restoreTap: { _ in true })
            var actions: [RemoteInput.Kind] = []
            monitor.isActive = { true }
            monitor.onAction = { actions.append($0) }
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 1)
            monitor.handleTapInterruption(.tapDisabledByTimeout)
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 2)
            try require(actions.isEmpty, "Interrupted press became a phantom action")
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 3)
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 3.1)
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 4)
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 4.7)
            try require(actions == [.switchInputSource, .toggleCapsLock], "Recovered gestures were lost or duplicated")
        }
        run("Revoked permission and a user-disabled tap are never automatically reenabled") {
            for reason: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
                var restored = 0, failures = 0
                let monitor = CapsLockMonitor(permissionsGranted: { reason != .tapDisabledByTimeout },
                                              restoreTap: { _ in restored += 1; return true })
                monitor.onFailure = { _ in failures += 1 }
                monitor.handleTapInterruption(reason)
                try require(restored == 0 && failures == 1, "Recovery bypassed permissions or explicit system disable")
            }
        }
        run("An unsuccessful reenable retains the visible failure path") {
            var failures = 0
            let monitor = CapsLockMonitor(permissionsGranted: { true }, restoreTap: { _ in false })
            monitor.onFailure = { _ in failures += 1 }
            monitor.handleTapInterruption(.tapDisabledByTimeout)
            try require(failures == 1, "Failed recovery was reported as working")
        }
        run("Focus changes discard held gestures and duplicate HID reports do not double toggle") {
            var active = true
            let monitor = CapsLockMonitor(permissionsGranted: { true }, restoreTap: { _ in true })
            var actions: [RemoteInput.Kind] = []
            monitor.isActive = { active }; monitor.onAction = { actions.append($0) }
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 1)
            active = false
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 1.1)
            active = true
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 1.2)
            try require(actions.isEmpty, "A focus-lost press leaked into the next control scope")
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 2)
            monitor.receiveCapsLockValue(device: 1, isDown: true, time: 2.01)
            monitor.receiveCapsLockValue(device: 2, isDown: true, time: 2.02)
            monitor.receiveCapsLockValue(device: 1, isDown: false, time: 2.1)
            monitor.receiveCapsLockValue(device: 2, isDown: false, time: 2.2)
            monitor.receiveCapsLockValue(device: 2, isDown: false, time: 2.3)
            try require(actions == [.switchInputSource], "Multi-keyboard or duplicate reports produced extra actions")
        }
        print("Caps Lock monitor checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
