import Foundation

/// The viewer pauses after `timeout` seconds away from the session. Attended means the session window is
/// focused and visible on this Mac; while it is, the session never pauses, with or without input.
public struct SessionIdlePolicy: Sendable {
    public private(set) var isPaused = false
    private var lastActivity: TimeInterval
    private let timeout: TimeInterval
    private var wasAttended = false

    public init(now: TimeInterval, timeout: TimeInterval = 600) {
        lastActivity = now; self.timeout = timeout
    }

    /// Attention holds the clock at `now`; it never resumes a pause by itself, only a return or input does.
    public mutating func tick(now: TimeInterval, attended: Bool) -> Bool {
        guard now.isFinite, !isPaused else { return false }
        if attended { lastActivity = max(lastActivity, now); return false }
        guard now >= lastActivity, now - lastActivity >= timeout else { return false }
        isPaused = true
        return true
    }

    public mutating func activity(now: TimeInterval, attended: Bool) -> Bool {
        guard attended, now.isFinite else { return false }
        lastActivity = max(lastActivity, now)
        let resume = isPaused
        isPaused = false
        return resume
    }

    /// A return (focused and visible again) resumes; leaving starts the away interval now.
    public mutating func attentionChanged(now: TimeInterval, attended: Bool, suppressWake: Bool = false) -> Bool {
        let entered = attended && !wasAttended
        if !attended, wasAttended, !isPaused, now.isFinite { lastActivity = max(lastActivity, now) }
        wasAttended = attended
        return entered && !suppressWake ? activity(now: now, attended: true) : false
    }

    public mutating func synchronize(paused: Bool, now: TimeInterval) {
        isPaused = paused
        if !paused, now.isFinite { lastActivity = max(lastActivity, now) }
    }
}

public struct SessionPauseTransmission: Sendable {
    public private(set) var desiredPaused: Bool
    public private(set) var appliedPaused = false
    public private(set) var pending: SessionPauseRequest?
    public private(set) var freshFrameToken: UUID?
    public var inputSuspended: Bool { desiredPaused || appliedPaused || pending != nil || freshFrameToken != nil }

    public init(paused: Bool = false) { desiredPaused = paused }

    public mutating func choose(paused: Bool) {
        desiredPaused = paused
        if paused { freshFrameToken = nil }
    }

    public mutating func requireFreshFrame() { freshFrameToken = UUID() }

    public mutating func nextRequest() -> SessionPauseRequest? {
        guard pending == nil, desiredPaused != appliedPaused else { return nil }
        let request = SessionPauseRequest(paused: desiredPaused)
        pending = request
        return request
    }

    public mutating func receive(_ result: SessionPauseResult) -> Bool {
        guard let pending, pending.id == result.id else { return false }
        appliedPaused = result.paused
        if result.error != nil, desiredPaused == pending.paused { desiredPaused = result.paused }
        freshFrameToken = !desiredPaused && !result.paused && !pending.paused && result.error == nil ? UUID() : nil
        self.pending = nil
        return true
    }

    public mutating func decodedFreshFrame(token: UUID) -> Bool {
        guard freshFrameToken == token else { return false }
        freshFrameToken = nil
        return true
    }
}

public struct SessionWakeInputGate: Sendable {
    private var keys = Set<UInt16>()
    private var buttons = Set<Int>()
    private var modifiers: UInt64 = 0
    public init() {}

    public mutating func allows(_ input: RemoteInput, suspended: Bool) -> Bool {
        let mask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
        let previousModifiers = modifiers
        modifiers &= input.flags & mask
        let blocked = suspended || modifiers != 0
        if blocked { modifiers |= input.flags & mask }
        switch input.kind {
        case .keyDown:
            if blocked { keys.insert(input.keyCode); return false }
            return !keys.contains(input.keyCode)
        case .keyUp:
            if keys.remove(input.keyCode) != nil { return false }
        case .down:
            if blocked { buttons.insert(input.button); return false }
            return !buttons.contains(input.button)
        case .up:
            if buttons.remove(input.button) != nil { return false }
        case .drag:
            if buttons.contains(input.button) { return false }
        case .flags:
            if previousModifiers != 0 { return false }
        default: break
        }
        return !blocked
    }
}

public struct SessionPauseRequest: Codable, Sendable {
    public let id: UUID
    public let paused: Bool
    public init(id: UUID = UUID(), paused: Bool) { self.id = id; self.paused = paused }
}

public struct SessionPauseResult: Codable, Sendable {
    public let id: UUID
    public let paused: Bool
    public let error: String?
    public init(id: UUID, paused: Bool, error: String? = nil) {
        self.id = id; self.paused = paused; self.error = error
    }
}
