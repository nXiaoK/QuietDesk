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

public struct ConnectionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var address: String
    public var port: UInt16
    public var name: String
    public var lastConnected: Date
    public var videoSettings: StreamSettings?
    public var chromaSubsampling: VideoChromaSubsampling?
    public var relay: RelayConnectionInfo?
    public var deviceID: UUID?
    public var wakeOnLAN: WakeOnLANConfiguration?
    /// The size the codecs of this pair kept up with when the saved choice asked for more. A session on a
    /// path that is not the local network starts from it; a new saved choice clears it.
    public var sustainedVideoSize: SustainedVideoSize?
    public init(id: UUID = UUID(), address: String, port: UInt16, name: String, lastConnected: Date = Date(), videoSettings: StreamSettings? = nil, chromaSubsampling: VideoChromaSubsampling? = nil, relay: RelayConnectionInfo? = nil, deviceID: UUID? = nil, wakeOnLAN: WakeOnLANConfiguration? = nil, sustainedVideoSize: SustainedVideoSize? = nil) {
        self.id = id; self.address = address; self.port = port; self.name = name; self.lastConnected = lastConnected
        self.videoSettings = videoSettings
        self.chromaSubsampling = chromaSubsampling
        self.relay = relay
        self.deviceID = deviceID
        self.wakeOnLAN = wakeOnLAN
        self.sustainedVideoSize = sustainedVideoSize
    }
    private enum CodingKeys: String, CodingKey {
        case id, address, port, name, lastConnected, videoSettings, chromaSubsampling, relay, higherFrameRateVideoSettings, deviceID, wakeOnLAN
        case sustainedVideoSize
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        address = try values.decode(String.self, forKey: .address)
        port = try values.decode(UInt16.self, forKey: .port)
        name = try values.decode(String.self, forKey: .name)
        lastConnected = try values.decode(Date.self, forKey: .lastConnected)
        videoSettings = try values.decodeIfPresent(StreamSettings.self, forKey: .videoSettings)
        chromaSubsampling = try? values.decode(VideoChromaSubsampling.self, forKey: .chromaSubsampling)
        relay = try values.decodeIfPresent(RelayConnectionInfo.self, forKey: .relay)
        deviceID = try? values.decode(UUID.self, forKey: .deviceID)
        wakeOnLAN = try? values.decode(WakeOnLANConfiguration.self, forKey: .wakeOnLAN)
        sustainedVideoSize = try? values.decode(SustainedVideoSize.self, forKey: .sustainedVideoSize)
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
        try values.encodeIfPresent(chromaSubsampling, forKey: .chromaSubsampling)
        try values.encodeIfPresent(relay, forKey: .relay)
        try values.encodeIfPresent(deviceID, forKey: .deviceID)
        try values.encodeIfPresent(wakeOnLAN, forKey: .wakeOnLAN)
        try values.encodeIfPresent(sustainedVideoSize, forKey: .sustainedVideoSize)
        if let videoSettings, videoSettings.framesPerSecond > 60 {
            try values.encode(videoSettings, forKey: .higherFrameRateVideoSettings)
        }
    }
    public func matches(address: String, port: UInt16) -> Bool {
        self.port == port && self.address.caseInsensitiveCompare(address) == .orderedSame
    }
}
