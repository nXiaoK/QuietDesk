import Foundation

public struct VideoStreamState: Codable, Equatable, Sendable {
    public let settings: StreamSettings
    public let width: Int
    public let height: Int
    public init(settings: StreamSettings, width: Int, height: Int) {
        self.settings = settings; self.width = width; self.height = height
    }
    public func validate() throws {
        try settings.validateControlValues()
        guard (2...8192).contains(width), (2...8192).contains(height), width % 2 == 0, height % 2 == 0,
              width * height <= 36_000_000 else { throw DeskError.invalid("画质回复的分辨率无效") }
    }
}

public struct StreamSettingsRequest: Codable, Sendable {
    public let id: UUID
    public let settings: StreamSettings
    // Sent only to a host that advertised hevcVideoV1. Missing means H.264, which an older viewer can decode.
    public let codec: VideoCodec?
    // Sent only to a host that advertised hevc444VideoV1. Missing means 4:2:0.
    public let chromaSubsampling: VideoChromaSubsampling?
    public init(id: UUID = UUID(), settings: StreamSettings, codec: VideoCodec? = nil,
                chromaSubsampling: VideoChromaSubsampling? = nil) {
        self.id = id
        self.settings = settings
        self.codec = codec
        self.chromaSubsampling = chromaSubsampling
    }
}

public struct StreamSettingsResult: Codable, Sendable {
    public let id: UUID
    public let state: VideoStreamState
    public let error: String?
    // The codec the host encodes with, echoed only to a request that named one; missing means H.264.
    public let codec: VideoCodec?
    // The chroma subsampling the host encodes with, echoed only to a request that named one; missing means 4:2:0.
    public let chromaSubsampling: VideoChromaSubsampling?
    // False when the host updated its running encoder and capture interval in place without restarting the media epoch.
    public let restartsStream: Bool?
    public init(id: UUID, state: VideoStreamState, error: String? = nil, codec: VideoCodec? = nil,
                chromaSubsampling: VideoChromaSubsampling? = nil, restartsStream: Bool? = nil) {
        self.id = id
        self.state = state
        self.error = error
        self.codec = codec
        self.chromaSubsampling = chromaSubsampling
        self.restartsStream = restartsStream
    }
}

// One request in flight; edits made while waiting coalesce into the latest choice.
public struct VideoTuningSession {
    public private(set) var applied: VideoStreamState
    public private(set) var desired: StreamSettings
    public private(set) var pending: StreamSettingsRequest?
    public private(set) var appliedCodec: VideoCodec = .h264
    public private(set) var desiredCodec: VideoCodec = .h264
    public private(set) var appliedChroma: VideoChromaSubsampling = .yuv420
    public private(set) var desiredChroma: VideoChromaSubsampling = .yuv420
    public init(applied: VideoStreamState, preferred: StreamSettings? = nil) throws {
        try applied.validate()
        if let preferred { try preferred.validateControlValues() }
        self.applied = applied
        self.desired = preferred ?? applied.settings
    }
    public mutating func choose(_ settings: StreamSettings) throws {
        try settings.validateControlValues()
        desired = settings
    }
    /// Asks for this codec from the next request on; only for a host that advertised it.
    public mutating func chooseCodec(_ codec: VideoCodec) {
        desiredCodec = codec
        if codec == .h264 { desiredChroma = .yuv420 }
    }
    /// Asks for 4:4:4 or 4:2:0 chroma subsampling from the next request on; 4:4:4 implies HEVC.
    public mutating func chooseChromaSubsampling(_ chroma: VideoChromaSubsampling) {
        desiredChroma = chroma
        if chroma == .yuv444 { desiredCodec = .hevc }
    }
    public mutating func nextRequest() -> StreamSettingsRequest? {
        guard pending == nil,
              desired != applied.settings || desiredCodec != appliedCodec || desiredChroma != appliedChroma else {
            return nil
        }
        return makeRequest()
    }
    /// Confirms initial settings to a host awaiting single-start negotiation even when desired matches hello.
    public mutating func initialConfirmationRequest() -> StreamSettingsRequest? {
        guard pending == nil else { return nil }
        if let request = nextRequest() { return request }
        return makeRequest()
    }
    private mutating func makeRequest() -> StreamSettingsRequest {
        // H.264 / 4:2:0 on both sides keeps the request exactly as older hosts know it.
        let effectiveChroma: VideoChromaSubsampling = desiredCodec == .hevc ? desiredChroma : .yuv420
        let request = StreamSettingsRequest(
            settings: desired,
            codec: desiredCodec == .h264 && appliedCodec == .h264 ? nil : desiredCodec,
            chromaSubsampling: effectiveChroma == .yuv420 && appliedChroma == .yuv420 ? nil : effectiveChroma
        )
        pending = request
        return request
    }
    public mutating func receive(_ result: StreamSettingsResult, maximumFrameRate: Int = StreamSettings.frameRates.last!) throws -> Bool {
        guard let pending, pending.id == result.id else { return false }
        try result.state.validate()
        guard result.state.settings.framesPerSecond <= maximumFrameRate else { throw DeskError.invalid("画质回复超过已协商的帧率上限") }
        applied = result.state
        if desired == pending.settings { desired = result.state.settings }
        // A host that kept H.264 or 4:2:0 (no hardware support at this size, or a failed change) is not asked again.
        appliedCodec = result.codec ?? .h264
        if desiredCodec == (pending.codec ?? .h264) { desiredCodec = appliedCodec }
        appliedChroma = appliedCodec == .hevc ? (result.chromaSubsampling ?? .yuv420) : .yuv420
        if desiredChroma == (pending.chromaSubsampling ?? .yuv420) { desiredChroma = appliedChroma }
        if desiredCodec == .h264 { desiredChroma = .yuv420 }
        self.pending = nil
        return true
    }

    /// Updates the confirmed host stream state when a display switch or screen mode hot-update changes dimensions.
    public mutating func synchronizeHostState(_ state: VideoStreamState) throws {
        try state.validate()
        applied = state
    }
}
