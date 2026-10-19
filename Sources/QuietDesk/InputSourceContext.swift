import AppKit
import QuietDeskCore

@MainActor
protocol InputSourceFocusAccess: AnyObject {
    var originalProcessID: pid_t? { get }
    var currentProcessID: pid_t { get }
    var frontmostProcessID: pid_t? { get }
    var isRefreshWindowKey: Bool { get }
    func activateRefreshWindow() -> Bool
    func restoreOriginalApplication() -> Bool
    func closeRefreshWindow()
}

@MainActor
private final class InputSourceRefreshPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SystemInputSourceFocus: InputSourceFocusAccess {
    private let originalApplication = NSWorkspace.shared.frontmostApplication
    private var panel: InputSourceRefreshPanel?
    var originalProcessID: pid_t? { originalApplication?.processIdentifier }
    var currentProcessID: pid_t { ProcessInfo.processInfo.processIdentifier }
    var frontmostProcessID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var isRefreshWindowKey: Bool { panel?.isKeyWindow == true }

    func activateRefreshWindow() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let panel = InputSourceRefreshPanel(
            contentRect: NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = .floating
        panel.setAccessibilityElement(false)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func restoreOriginalApplication() -> Bool {
        guard let originalApplication, !originalApplication.isTerminated else { return false }
        NSApp.yieldActivation(to: originalApplication)
        return originalApplication.activate(from: .current, options: [])
    }

    func closeRefreshWindow() {
        panel?.close()
        panel = nil
    }
}

@MainActor
final class InputSourceContextRefresh {
    private let access: InputSourceFocusAccess
    private let waitForChange: () async throws -> Void

    init(access: InputSourceFocusAccess? = nil, waitForChange: @escaping () async throws -> Void = {
        try await Task.sleep(nanoseconds: 20_000_000)
    }) {
        self.access = access ?? SystemInputSourceFocus()
        self.waitForChange = waitForChange
    }

    func refresh(isCancelled: () -> Bool) async throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
        guard let original = access.originalProcessID else { throw DeskError.invalid("无法读取远端输入应用，请重试") }
        guard access.frontmostProcessID == original else { throw DeskError.invalid("远端输入焦点已改变") }
        // TIS already activates the input context when the target belongs to this process.
        guard original != access.currentProcessID else { return }
        defer {
            // A user-selected third application must never be replaced by our saved application.
            if access.frontmostProcessID == access.currentProcessID { _ = access.restoreOriginalApplication() }
            access.closeRefreshWindow()
        }
        guard access.activateRefreshWindow() else { throw DeskError.invalid("无法刷新远端输入焦点") }
        var activated = false
        for _ in 0..<25 {
            try await waitForChange()
            guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
            let frontmost = access.frontmostProcessID
            guard frontmost == original || frontmost == access.currentProcessID else {
                throw DeskError.invalid("远端输入焦点已改变")
            }
            if frontmost == access.currentProcessID, access.isRefreshWindowKey { activated = true; break }
        }
        guard activated else { throw DeskError.invalid("远端输入焦点刷新未生效") }
        // Give TextInputSwitcher separate main-loop turns before reactivating the original app.
        for _ in 0..<8 {
            try await waitForChange()
            guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
            guard access.frontmostProcessID == access.currentProcessID, access.isRefreshWindowKey else {
                throw DeskError.invalid("远端输入焦点已改变")
            }
        }
        guard access.restoreOriginalApplication() else { throw DeskError.invalid("无法恢复远端输入应用") }
        for _ in 0..<25 {
            try await waitForChange()
            guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
            if access.frontmostProcessID == original { return }
            guard access.frontmostProcessID == access.currentProcessID else {
                throw DeskError.invalid("远端输入焦点已改变")
            }
        }
        throw DeskError.invalid("远端输入应用尚未恢复")
    }
}
