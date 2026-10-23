import Foundation

/// A host advertises this optional extension in Hello; only a subscribed viewer receives an ending notice.
public struct SessionTermination: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case subscribe, ended }
    public let operation: Operation
    public static let hostEndedReason = "被控端已结束本次连接"

    public init(_ operation: Operation) { self.operation = operation }

    public func message() throws -> Message { try Wire.json(.sessionTermination, self) }

    public static func read(_ payload: Data) throws -> Self {
        try Wire.readJSON(Self.self, payload)
    }
}

extension Peer {
    /// Resources are revoked by the caller first. Delivery is best effort and cannot keep the old peer alive
    /// indefinitely behind a stalled video/send queue; neither completion path refers to the next session.
    public func closeAfterSessionTermination(notify: Bool, timeout: TimeInterval = 0.5) {
        guard notify, let message = try? SessionTermination(.ended).message() else {
            close(SessionTermination.hostEndedReason)
            return
        }
        send(message) { [self] _ in close(SessionTermination.hostEndedReason) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, min(timeout, 2))) { [self] in
            close(SessionTermination.hostEndedReason)
        }
    }
}
