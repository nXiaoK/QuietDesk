import Foundation

public struct RetryBackoff {
    public private(set) var attempt = 0
    public init() {}
    public mutating func next() -> TimeInterval {
        attempt += 1
        return min(30, pow(2, Double(min(attempt - 1, 5))))
    }
    public mutating func reset() { attempt = 0 }
}

// After an automatic relay fallback fails, later media-only fallbacks to the same target wait
// 30/60/120/300 seconds, so a direct session and an unreachable relay cannot alternate endlessly.
public struct RelayFallbackCooldown {
    public private(set) var failures = 0
    private var retryAt: TimeInterval = 0
    public init() {}
    public func allows(now: TimeInterval) -> Bool { failures == 0 || now >= retryAt }
    public mutating func failed(now: TimeInterval) {
        failures += 1
        retryAt = now + [30, 60, 120, 300][min(failures - 1, 3)]
    }
    public mutating func reset() { failures = 0; retryAt = 0 }
}

public struct ConnectionRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public var address: String
    public var port: UInt16
    public var name: String
    public var lastConnected: Date
    public var videoSettings: StreamSettings?
    public var relay: RelayConnectionInfo?
    public init(id: UUID = UUID(), address: String, port: UInt16, name: String, lastConnected: Date = Date(), videoSettings: StreamSettings? = nil, relay: RelayConnectionInfo? = nil) {
        self.id = id; self.address = address; self.port = port; self.name = name; self.lastConnected = lastConnected
        self.videoSettings = videoSettings
        self.relay = relay
    }
    public func matches(address: String, port: UInt16) -> Bool {
        self.port == port && self.address.caseInsensitiveCompare(address) == .orderedSame
    }
}
