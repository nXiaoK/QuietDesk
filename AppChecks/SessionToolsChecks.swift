import AppKit
import Foundation
import SwiftUI

private struct ToolsCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct SessionToolsChecks {
    static func main() {
        var passed = 0, failed = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw ToolsCheckFailure(message) }
        }
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func control(reconnecting: Bool = false, paused: Bool = false, suspended: Bool = false,
                     allowed: Bool = true, focused: Bool = false) -> SessionControlPresentation {
            SessionControlPresentation(reconnecting: reconnecting, sessionPaused: paused,
                inputSuspended: suspended, canControl: allowed, controlling: focused)
        }
        func tools(connected: Bool = true, reconnecting: Bool = false, hasSession: Bool = true, fullScreen: Bool = false,
                   latency: String = "12 ms", control state: SessionControlPresentation? = nil) -> SessionToolsPresentation {
            SessionToolsPresentation(connected: connected, reconnecting: reconnecting, hasSession: hasSession, fullScreen: fullScreen,
                remoteName: "SYNTHETIC Mac", latency: latency, control: state ?? control(), keyboardSummary: "Caps Lock 待生效")
        }
        print("Session tools checks use pure presentation and local callbacks only; no app model, permission API, input posting, network or clipboard access.")
        run("Window and full-screen control state preserve the original precedence for every input combination") {
            for reconnecting in [false, true] {
                for paused in [false, true] {
                    for suspended in [false, true] {
                        for allowed in [false, true] {
                            for focused in [false, true] {
                                let value = control(reconnecting: reconnecting, paused: paused, suspended: suspended, allowed: allowed, focused: focused)
                                let expected: SessionControlPresentation.State
                                if paused && reconnecting { expected = .pausedReconnect }
                                else if suspended { expected = .suspended }
                                else if reconnecting { expected = .reconnecting }
                                else if !allowed { expected = .viewing }
                                else { expected = focused ? .controlling : .released }
                                try require(value.state == expected, "Changed control precedence")
                            }
                        }
                    }
                }
            }
        }
        run("Released and controlling states explain explicit refocus and the emergency release key") {
            try require(control().title == "已释放 · 点按画面开始控制", "Release suggested automatic control")
            try require(control(focused: true).title == "正在控制远端 · ⌃⌥Esc 释放键盘鼠标", "Emergency release missing")
        }
        run("Viewing, suspended and reconnecting states never claim remote input is active") {
            try require(control(allowed: false, focused: true).title == "仅观看 · 共享端辅助功能未生效", "Permission was inferred from focus")
            try require(control(suspended: true, focused: true).title.contains("暂不发送"), "Suspension hidden by focus")
            try require(control(reconnecting: true, focused: true).title.contains("暂不发送"), "Reconnect hidden by focus")
            try require(control(reconnecting: true, paused: true).title == "空闲暂停 · 返回窗口后继续连接", "Paused retry state lost")
        }
        run("Connection summaries do not append stale RTT to a disconnected or reconnecting session") {
            try require(tools(connected: false, reconnecting: true, control: control(reconnecting: true)).connectionSummary == "正在重连", "Stale reconnect RTT exposed")
            try require(tools(connected: false).connectionSummary == "未连接", "Disconnected summary claimed RTT")
            try require(tools(latency: "").connectionSummary == "已连接", "Empty latency left a separator")
            try require(tools().connectionSummary == "已连接 · 12 ms", "Real supplied RTT missing")
        }
        run("Fresh-frame suspension during wake reconnect cannot hide the explicit connection state") {
            let value = tools(connected: false, reconnecting: true,
                control: control(reconnecting: true, suspended: true))
            try require(value.control.state == .suspended && value.connectionSummary == "正在重连",
                        "Wake reconnect was mislabeled as disconnected when input waits for a fresh frame")
        }
        run("Both surfaces use the same action set, labels and existing shortcuts") {
            try require(SessionToolAction.allCases.count == 9, "Action inventory changed")
            for action in SessionToolAction.allCases where action != .fullScreen {
                try require(action.title(fullScreen: false) == action.title(fullScreen: true), "Window and full-screen names differ")
                try require(!action.symbol().isEmpty && !action.help.isEmpty, "Missing accessible action description")
            }
            try require(SessionToolAction.releaseControl.shortcut == "⌃⌥Esc"
                && SessionToolAction.fullScreen.shortcut == "⌃⌘F"
                && SessionToolAction.captureFrame.shortcut == "⌃⌘S", "Existing shortcuts changed")
            try require(SessionToolAction.allCases.filter { $0.shortcut != nil }.count == 3, "Added a conflicting shortcut")
        }
        run("Screen switching and ending the session retain separate labels and meanings") {
            try require(SessionToolAction.fullScreen.title() == "进入全屏"
                && SessionToolAction.fullScreen.title(fullScreen: true) == "退出全屏", "Incorrect screen direction")
            try require(SessionToolAction.endSession.title(hasSession: false) == "返回连接"
                && SessionToolAction.endSession.title() == "断开", "Return confused with disconnect")
            try require(SessionToolAction.fullScreen.help.contains("不结束连接"), "Screen switching implies disconnect")
        }
        run("Every enabled local tool releases remote input before its operation exactly once") {
            for action in SessionToolAction.allCases {
                var calls: [String] = []
                tools().perform(action, releaseControl: { calls.append("release") }, operation: { calls.append("operation") })
                try require(calls == ["release", "operation"], "Release ordering changed for \(action)")
            }
        }
        run("Disconnected clipboard and screenshot callbacks remain blocked even if invoked directly") {
            for action in [SessionToolAction.sendText, .receiveText, .captureFrame] {
                var calls: [String] = []
                tools(connected: false).perform(action, releaseControl: { calls.append("release") }, operation: { calls.append("operation") })
                try require(calls.isEmpty, "A disabled tool still invoked a callback")
            }
        }
        run("Read-only sessions keep clipboard and screenshots independent of remote input permission") {
            let viewing = tools(control: control(allowed: false))
            for action in [SessionToolAction.sendText, .receiveText, .captureFrame] {
                try require(viewing.isEnabled(action), "Viewing permission incorrectly disabled existing non-input tools")
            }
        }
        run("Local release, keyboard and settings stay reachable during reconnect") {
            let reconnecting = tools(connected: false, reconnecting: true, control: control(reconnecting: true))
            for action in [SessionToolAction.releaseControl, .keyboard, .privacy, .traffic, .fullScreen, .endSession] {
                try require(reconnecting.isEnabled(action), "Local recovery tool unavailable")
            }
        }
        run("Remote desktop actions render inline on the main page without requiring subpage navigation") {
            final class DesktopMountProbe: NSView {
                var mountedInWindow = false
                override func viewDidMoveToWindow() {
                    super.viewDidMoveToWindow()
                    if window != nil { mountedInWindow = true }
                }
            }
            struct InlineDesktopFixture: NSViewRepresentable {
                let probe: DesktopMountProbe
                func makeNSView(context: Context) -> DesktopMountProbe { probe }
                func updateNSView(_ nsView: DesktopMountProbe, context: Context) {}
            }
            let mounted = MainActor.assumeIsolated {
                let probe = DesktopMountProbe(frame: NSRect(x: 0, y: 0, width: 120, height: 32))
                let view = SessionToolsView(
                    presentation: tools(fullScreen: true),
                    settings: Text("Synthetic settings"),
                    keyboard: Text("Synthetic keyboard"),
                    desktop: InlineDesktopFixture(probe: probe),
                    perform: { _ in },
                    close: {}
                )
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let hosting = NSHostingView(rootView: view)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                return probe.mountedInWindow
            }
            try require(mounted, "Desktop actions were hidden behind a subpage instead of inline on main")
        }
        run("Return is unavailable in an idle window and remains available in disconnected full screen") {
            try require(!tools(connected: false, hasSession: false).isEnabled(.endSession), "Idle window disconnect is active")
            try require(tools(connected: false, hasSession: false, fullScreen: true).isEnabled(.endSession), "No return from disconnected full screen")
            var calls: [String] = []
            tools(connected: false, hasSession: false).perform(.endSession,
                releaseControl: { calls.append("release") }, operation: { calls.append("end") })
            try require(calls.isEmpty, "Disabled return had side effects")
        }
        run("Keyboard summary is real supplied state rather than a grant inferred by the panel") {
            let value = tools()
            try require(value.keyboardSummary == "Caps Lock 待生效", "Pending permission replaced with success")
            try require(SessionToolAction.keyboard.help.contains("实际生效"), "Keyboard entry lost actual-state explanation")
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
