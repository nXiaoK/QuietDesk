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
