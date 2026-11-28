import Foundation

/// A host advertises this optional extension in Hello; only a subscribed viewer receives an ending notice.
public struct SessionTermination: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case subscribe, ended }
    public let operation: Operation
    public let supportsUpdateRestart: Bool?
    public static let hostEndedReason = "被控端已结束本次连接"

    public init(_ operation: Operation, supportsUpdateRestart: Bool? = nil) {
        self.operation = operation
        self.supportsUpdateRestart = supportsUpdateRestart
    }

    public func message() throws -> Message { try Wire.json(.sessionTermination, self) }

    public static func read(_ payload: Data) throws -> Self {
        try Wire.readJSON(Self.self, payload)
    }
}

public struct HostUpdateRestartNotice: Codable, Equatable, Sendable {
    public static let maximumWaitSeconds: TimeInterval = 180
    public static let fastReconnectInterval: TimeInterval = 2
    private static let maximumVersionBytes = 128
    public let targetVersion: String

    public init(targetVersion: String) { self.targetVersion = targetVersion }

    public func validate() throws {
        guard targetVersion.utf8.count <= Self.maximumVersionBytes else {
            throw UpdateManifestError.invalidField("version")
        }
        _ = try UpdateVersion(targetVersion)
    }

    public static func reconnectDelay(startedAt: TimeInterval, now: TimeInterval) -> TimeInterval? {
        let elapsed = now - startedAt
        guard elapsed.isFinite, elapsed < maximumWaitSeconds else { return nil }
        return min(maximumWaitSeconds - elapsed, elapsed < 60 ? fastReconnectInterval : 5)
    }

    public func message() throws -> Message {
        try validate()
        return try Wire.json(.hostUpdateRestart, self)
    }

    public static func read(_ payload: Data) throws -> Self {
        let notice = try Wire.readJSON(Self.self, payload)
        try notice.validate()
        return notice
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

    /// Only a subscribed viewer receives the restart notice. The callback runs once after local closure.
    public func closeAfterHostUpdateRestart(version: String?, notify: Bool, timeout: TimeInterval = 0.4,
                                            completion: (() -> Void)? = nil) {
        let reason = "被控端正在安装更新并重新启动"
        guard notify, let version, let message = try? HostUpdateRestartNotice(targetVersion: version).message() else {
            close(reason, retryable: true, completion: completion)
            return
        }
        // The send completion and bounded fallback both run on the serial peer queue.
        var closing = false
        let closeOnce = { [self] in
            guard !closing else { return }
            closing = true
            close(reason, retryable: true, completion: completion)
        }
        send(message) { _ in closeOnce() }
        queue.asyncAfter(deadline: .now() + max(0, min(timeout, 1))) { closeOnce() }
    }
}
