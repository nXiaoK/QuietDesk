import Foundation

/// Local session UI (a toolbar menu, the settings panel, a sheet) takes the keyboard from a remote picture
/// that was being controlled. Once that UI is gone the keyboard goes back to the picture by itself, so no
/// click is needed that the remote Mac would receive as well. A release the user asked for stays released.
public struct ControlResumption: Sendable {
    /// How long after the local UI closed the session window may take to become key again.
    public static let window: TimeInterval = 1
    private var armed = false
    private var deadline: TimeInterval?

    public init() {}

    /// Local UI is taking the keyboard; only a picture that was being controlled gets it back.
    public mutating func localUIOpened(controlling: Bool) {
        guard controlling else { return }
        armed = true; deadline = nil
    }

    /// The local UI is gone.
    public mutating func localUIClosed(now: TimeInterval) {
        guard armed, now.isFinite else { return }
        deadline = now + Self.window
    }

    /// The user released control on purpose, or the session ended.
    public mutating func cancel() { armed = false; deadline = nil }

    /// Whether to hand the keyboard back now. `ready` is false while the session window cannot take it yet;
    /// asking again within the window may succeed.
    public mutating func takeResume(now: TimeInterval, canControl: Bool, ready: Bool) -> Bool {
        guard armed, let deadline else { return false }
        guard now <= deadline, canControl else { cancel(); return false }
        guard ready else { return false }
        cancel()
        return true
    }
}
