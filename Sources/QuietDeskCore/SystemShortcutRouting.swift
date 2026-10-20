public struct SystemShortcutScope: Equatable, Sendable {
    public var sessionActive: Bool
    public var canControl: Bool
    public var fullScreen: Bool
    public var keyWindow: Bool
    public var canvasFocused: Bool
    public init(sessionActive: Bool = false, canControl: Bool = false, fullScreen: Bool = false,
                keyWindow: Bool = false, canvasFocused: Bool = false) {
        self.sessionActive = sessionActive; self.canControl = canControl; self.fullScreen = fullScreen
        self.keyWindow = keyWindow; self.canvasFocused = canvasFocused
    }
    public var isActive: Bool { sessionActive && canControl && fullScreen && keyWindow && canvasFocused }
}

public enum LocalControlShortcut: Equatable, Sendable {
    case releaseControl, toggleFullScreen, captureRemoteFrame
}

public struct SystemShortcutRouting: Sendable {
    public enum Decision: Equatable, Sendable { case passThrough, capture }
    public private(set) var capturedKeys = Set<UInt16>()
    public init() {}

    public mutating func route(kind: RemoteInput.Kind, keyCode: UInt16, scope: SystemShortcutScope) -> Decision {
        guard scope.isActive else { reset(); return .passThrough }
        guard keyCode <= 127, keyCode != 57 else { return .passThrough }
        switch kind {
        case .keyDown:
            capturedKeys.insert(keyCode)
            return .capture
        case .keyUp:
            return capturedKeys.remove(keyCode) != nil ? .capture : .passThrough
        case .flags:
            return [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode) ? .capture : .passThrough
        default: return .passThrough
        }
    }

    public mutating func reset() { capturedKeys.removeAll() }

    public static func localAction(keyCode: UInt16, flags: UInt64) -> LocalControlShortcut? {
        let control: UInt64 = 1 << 18, option: UInt64 = 1 << 19, command: UInt64 = 1 << 20, shift: UInt64 = 1 << 17
        let modifiers = flags & (control | option | command | shift)
        if keyCode == 53, modifiers & (control | option) == (control | option) { return .releaseControl }
        if keyCode == 3, modifiers == (control | command) { return .toggleFullScreen }
        if keyCode == 1, modifiers == (control | command) { return .captureRemoteFrame }
        return nil
    }
}
