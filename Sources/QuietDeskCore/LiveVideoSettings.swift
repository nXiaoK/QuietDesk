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
    public init(id: UUID = UUID(), settings: StreamSettings) { self.id = id; self.settings = settings }
}

public struct StreamSettingsResult: Codable, Sendable {
    public let id: UUID
    public let state: VideoStreamState
    public let error: String?
    public init(id: UUID, state: VideoStreamState, error: String? = nil) {
        self.id = id; self.state = state; self.error = error
    }
}

// One request in flight; edits made while waiting coalesce into the latest choice.
public struct VideoTuningSession {
    public private(set) var applied: VideoStreamState
    public private(set) var desired: StreamSettings
    public private(set) var pending: StreamSettingsRequest?
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
    public mutating func nextRequest() -> StreamSettingsRequest? {
        guard pending == nil, desired != applied.settings else { return nil }
        let request = StreamSettingsRequest(settings: desired)
        pending = request
        return request
    }
    public mutating func receive(_ result: StreamSettingsResult, maximumFrameRate: Int = StreamSettings.frameRates.last!) throws -> Bool {
        guard let pending, pending.id == result.id else { return false }
        try result.state.validate()
        guard result.state.settings.framesPerSecond <= maximumFrameRate else { throw DeskError.invalid("画质回复超过已协商的帧率上限") }
        applied = result.state
        if desired == pending.settings { desired = result.state.settings }
        self.pending = nil
        return true
    }
}
