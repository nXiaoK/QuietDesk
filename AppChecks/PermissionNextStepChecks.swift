import Foundation

private struct NextStepFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main private struct PermissionNextStepChecks {
    static func main() {
        var passed = 0, failed = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NextStepFailure(message) }
        }
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func remote(connected: Bool = true, reconnecting: Bool = false, control: Bool = true,
                    updates: Bool = true, actions: Bool = true, suspended: Bool = false) -> PermissionNextStep {
            .remoteKeyboard(connected: connected, reconnecting: reconnecting, canControl: control,
                livePermissionUpdates: updates, supportsInputActions: actions, inputSuspended: suspended)
        }
        print("Permission next steps use pure supplied state only; no actual permissions or model.")
        run("Missing capture blocks sharing regardless of Accessibility and never auto-starts") {
            for accessibility in [false, true] {
                let step = PermissionNextStep.sharing(screenRecording: false, accessibility: accessibility, started: false)
                try require(step.action == .screenRecording && step.detail.contains("无法开始"), "Capture prerequisite hidden")
                try require(step.detail.contains("仍需点“开启共享”") && step.detail.contains("不会自动开始"), "Grant implied automatic sharing")
            }
        }
        run("Capture revoked during sharing does not instruct a duplicate start while still running") {
            let step = PermissionNextStep.sharing(screenRecording: false, accessibility: true, started: true)
            try require(step.action == .screenRecording && step.detail.contains("若共享已停止"), "Capture revocation implied duplicate start")
        }
        run("Accessibility is optional for view-only sharing, not a second start prerequisite") {
            let step = PermissionNextStep.sharing(screenRecording: true, accessibility: false, started: false)
            try require(step.action == .accessibility && step.detail.contains("如只需观看，可点“开启共享”"), "View-only sharing blocked")
        }
        run("Running sharing does not tell the user to start it again") {
            let step = PermissionNextStep.sharing(screenRecording: true, accessibility: false, started: true)
            try require(step.detail.contains("当前权限仅允许观看") && !step.detail.contains("可点“开启共享”"), "Running session was treated as idle")
        }
        run("Effective idle permissions still leave pairing and port checks to the original start") {
            let step = PermissionNextStep.sharing(screenRecording: true, accessibility: true, started: false)
            try require(step.action == nil && step.detail.contains("配对码、端口与画面准备"), "Permissions claimed overall readiness")
        }
        run("Effective running permissions do not claim a controller is already authenticated") {
            let step = PermissionNextStep.sharing(screenRecording: true, accessibility: true, started: true)
            try require(step.action == nil && step.detail.contains("仍需连接并通过验证"), "Permissions implied a connection")
        }
        run("Local keyboard guidance offers the missing Accessibility setting first") {
            let step = PermissionNextStep.localKeyboard(accessibility: false, inputMonitoring: false, capsEnabled: true, capsRunning: false)
            try require(step.action == .accessibility && step.detail.contains("不代替被控 Mac"), "Wrong machine or setting")
        }
        run("Only missing Input Monitoring routes to that local setting") {
            let step = PermissionNextStep.localKeyboard(accessibility: true, inputMonitoring: false, capsEnabled: false, capsRunning: false)
            try require(step.action == .inputMonitoring, "Input Monitoring next step missing for system shortcut capture")
        }
        run("Allowed permissions do not masquerade as a running Caps Lock listener") {
            let step = PermissionNextStep.localKeyboard(accessibility: true, inputMonitoring: true, capsEnabled: true, capsRunning: false)
            try require(step.action == .recheck && step.title.contains("尚未就绪"), "Permission green implied listener success")
            try require(step.actionTitle == "重新检测并重试监听", "Recovery action omitted actual retry")
        }
        run("Caps Lock off is not a failed listener and never offers to enable it automatically") {
            let step = PermissionNextStep.localKeyboard(accessibility: true, inputMonitoring: true, capsEnabled: false, capsRunning: false)
            try require(step.action == nil && step.title.contains("未开启"), "Disabled preference treated as failure")
        }
        run("Local readiness is explicitly not proof of remote readiness or current capture") {
            let step = PermissionNextStep.localKeyboard(accessibility: true, inputMonitoring: true, capsEnabled: true, capsRunning: true)
            try require(step.action == nil && step.detail.contains("还需对端支持并允许控制") && step.detail.contains("安全输入"), "Capture boundaries hidden")
        }
        run("Disconnected and reconnecting cannot invent the other Mac's permission state") {
            for reconnecting in [false, true] {
                let step = remote(connected: false, reconnecting: reconnecting, control: false)
                try require(step.action == nil && !step.title.contains("仅观看"), "Disconnected guessed remote authorization")
                try require(step.detail.contains("本次连接收到的状态"), "Last-known scope missing")
            }
        }
        run("Modern view-only sessions wait for subscribed permission updates, not a forced reconnect") {
            let step = remote(control: false)
            try require(step.action == nil && step.title.contains("本次连接仅观看"), "Remote permission reason missing")
            try require(step.detail.contains("被控端重新检测") && step.detail.contains("支持接收权限变化") && !step.detail.contains("需断开再连接"), "Modern subscription bypassed")
        }
        run("Legacy view-only sessions explain last-known state and explicit reconnect after remote grant") {
            let step = remote(control: false, updates: false)
            try require(step.action == nil && step.detail.contains("未协商权限更新") && step.detail.contains("生效后，需断开再连接"), "Legacy stale permission state hidden")
        }
        run("Remote restriction cannot route to a local setting or be hidden by a missing capability") {
            let step = remote(control: false, actions: false, suspended: true)
            try require(step.title.contains("仅观看") && step.action == nil && step.detail.contains("在这台控制 Mac 授权不能解除"), "Wrong permission remedy")
        }
        run("Unsupported remote Caps Lock actions point to a remote upgrade, not more local grants") {
            let step = remote(actions: false)
            try require(step.action == nil && step.title.contains("不支持 Caps Lock") && step.detail.contains("普通键盘鼠标仍按原能力"), "Capability confused with authorization")
        }
        run("Suspended input cannot be presented as currently controlling despite remote authorization") {
            let step = remote(suspended: true)
            try require(step.action == nil && step.title.contains("等待画面恢复") && step.detail.contains("不发送输入"), "Input suspension hidden")
        }
        run("Remote readiness requires explicit refocus and does not seize input on close") {
            let step = remote()
            try require(step.action == nil && step.detail.contains("点按远程画面") && step.detail.contains("不会自动捕获"), "Input ownership changed")
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
