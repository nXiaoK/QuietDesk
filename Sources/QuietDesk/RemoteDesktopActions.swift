import AppKit
import Carbon
import QuietDeskCore

@MainActor
final class RemoteDesktopActionExecutor {
    private(set) var isExecuting = false
    private let isLocked: () -> Bool
    private let isTrusted: () -> Bool
    private let isSecureInput: () -> Bool
    private let postEvent: (CGEvent) -> Void
    private let makeKeyEvent: (CGKeyCode, Bool) -> CGEvent?
    private let currentFlags: () -> CGEventFlags
    private let waitForKeyRelease: () async throws -> Void
    private var generation = UUID()
    private var pendingReleases: [CGEvent] = []

    init(isLocked: @escaping () -> Bool = { ScreenLockState.isLockedOnConsole },
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         makeKeyEvent: @escaping (CGKeyCode, Bool) -> CGEvent? = {
             CGEvent(keyboardEventSource: nil, virtualKey: $0, keyDown: $1)
         },
         currentFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
         waitForKeyRelease: @escaping () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(30))
         }) {
        self.isLocked = isLocked
        self.isTrusted = isTrusted
        self.isSecureInput = isSecureInput
        self.postEvent = postEvent
        self.makeKeyEvent = makeKeyEvent
        self.currentFlags = currentFlags
        self.waitForKeyRelease = waitForKeyRelease
    }

    // The caller releases ordinary remote input and suspends it for this operation.
    // Success only means the default system shortcut was sent, not that a Space changed.
    func perform(_ action: RemoteDesktopAction) async -> String? {
        guard !isExecuting else { return "正在发送上一次桌面操作，请稍候" }
        guard !Task.isCancelled else { return "桌面操作已取消" }
        if let error = unavailableReason { return error }
        let key: CGKeyCode
        switch action {
        case .previousSpace: key = CGKeyCode(kVK_LeftArrow)
        case .nextSpace: key = CGKeyCode(kVK_RightArrow)
        case .missionControl: key = CGKeyCode(kVK_UpArrow)
        }
        // Prepare releases before sending any press, including allocation failure paths.
        guard let controlDown = makeKeyEvent(CGKeyCode(kVK_Control), true),
              let controlUp = makeKeyEvent(CGKeyCode(kVK_Control), false),
              let keyDown = makeKeyEvent(key, true),
              let keyUp = makeKeyEvent(key, false) else {
            return "无法建立远端桌面快捷键事件"
        }
        let capsLock = currentFlags().intersection(.maskAlphaShift)
        controlDown.type = .flagsChanged
        controlDown.flags = capsLock.union(.maskControl)
        controlUp.type = .flagsChanged
        controlUp.flags = capsLock
        for event in [keyDown, keyUp] {
            event.flags = capsLock.union(.maskControl)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }

        let token = UUID()
        generation = token
        isExecuting = true
        defer {
            releaseKeys()
            isExecuting = false
        }
        pendingReleases.append(controlUp)
        postEvent(controlDown)
        guard generation == token, !Task.isCancelled else { return "桌面操作已取消" }
        if let error = unavailableReason { return error }
        pendingReleases.insert(keyUp, at: 0)
        postEvent(keyDown)
        do { try await waitForKeyRelease() }
        catch { return "桌面操作已取消" }
        guard generation == token, !Task.isCancelled else { return "桌面操作已取消" }
        if let error = unavailableReason { return error }
        return nil
    }

    func cancel() {
        generation = UUID()
        releaseKeys()
    }

    private var unavailableReason: String? {
        if isLocked() { return "远端已锁屏，暂不能选择桌面" }
        if !isTrusted() { return "远端辅助功能权限未生效，无法选择桌面" }
        if isSecureInput() { return "远端安全输入已开启，暂不能选择桌面" }
        return nil
    }

    private func releaseKeys() {
        let releases = pendingReleases
        pendingReleases.removeAll()
        for event in releases { postEvent(event) }
    }
}
