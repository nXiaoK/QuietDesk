import Foundation

public enum RemoteDesktopAction: String, Codable, CaseIterable, Sendable {
    case previousSpace, nextSpace, missionControl
}

public struct DesktopActionRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let action: RemoteDesktopAction

    public init(id: UUID = UUID(), action: RemoteDesktopAction) {
        self.id = id; self.action = action
    }
}

/// A successful reply confirms only that the host sent the system shortcut, not that macOS changed Spaces.
public struct DesktopActionResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let error: String?

    public init(id: UUID, error: String? = nil) {
        self.id = id; self.error = error
    }
}
