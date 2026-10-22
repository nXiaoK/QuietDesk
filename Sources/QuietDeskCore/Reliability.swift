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
    private enum CodingKeys: String, CodingKey {
        case id, address, port, name, lastConnected, videoSettings, relay, higherFrameRateVideoSettings
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        address = try values.decode(String.self, forKey: .address)
        port = try values.decode(UInt16.self, forKey: .port)
        name = try values.decode(String.self, forKey: .name)
        lastConnected = try values.decode(Date.self, forKey: .lastConnected)
        videoSettings = try values.decodeIfPresent(StreamSettings.self, forKey: .videoSettings)
        relay = try values.decodeIfPresent(RelayConnectionInfo.self, forKey: .relay)
        if let higher = try? values.decode(StreamSettings.self, forKey: .higherFrameRateVideoSettings),
           higher.framesPerSecond > 60, (try? higher.validateControlValues()) != nil,
           higher.highRefreshCompatible == videoSettings {
            videoSettings = higher
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(address, forKey: .address)
        try values.encode(port, forKey: .port)
        try values.encode(name, forKey: .name)
        try values.encode(lastConnected, forKey: .lastConnected)
        try values.encodeIfPresent(videoSettings?.highRefreshCompatible, forKey: .videoSettings)
        try values.encodeIfPresent(relay, forKey: .relay)
        if let videoSettings, videoSettings.framesPerSecond > 60 {
            try values.encode(videoSettings, forKey: .higherFrameRateVideoSettings)
        }
    }
    public func matches(address: String, port: UInt16) -> Bool {
        self.port == port && self.address.caseInsensitiveCompare(address) == .orderedSame
    }
}
