import Foundation

public struct SessionIdlePolicy: Sendable {
    public private(set) var isPaused = false
    private var lastActivity: TimeInterval
    private let timeout: TimeInterval
    private var wasFocused = false

    public init(now: TimeInterval, timeout: TimeInterval = 600) {
        lastActivity = now; self.timeout = timeout
    }

    public mutating func tick(now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastActivity, !isPaused, now - lastActivity >= timeout else { return false }
        isPaused = true
        return true
    }

    public mutating func activity(now: TimeInterval, focused: Bool) -> Bool {
        guard focused, now.isFinite else { return false }
        lastActivity = max(lastActivity, now)
        let resume = isPaused
        isPaused = false
        return resume
    }

    public mutating func focusChanged(now: TimeInterval, focused: Bool, suppressWake: Bool = false) -> Bool {
        let entered = focused && !wasFocused
        wasFocused = focused
        return entered && !suppressWake ? activity(now: now, focused: true) : false
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
