import Foundation

// Own this value on one queue and use one monotonic clock for every call. A caller
// schedules takeDue with nextDelay, including after the final mouse event in a burst.
public struct PointerMovePacer: Sendable {
    public static let interval: TimeInterval = 1.0 / 60
    public static let minimumInterval: TimeInterval = 1.0 / 240
    public static let maximumInterval: TimeInterval = 1.0 / 30

    public static func interval(forFramesPerSecond framesPerSecond: Int) -> TimeInterval {
        1.0 / Double(min(120, max(60, framesPerSecond)))
    }

    public private(set) var currentInterval: TimeInterval
    public let allowsDrag: Bool
    private var pending: RemoteInput?
    private var lastObservedAt: TimeInterval?
    private var lastSentAt: TimeInterval?
    private var nextDueAt: TimeInterval?

    public var pendingButton: Int? { pending?.button }

    public init(interval: TimeInterval = Self.interval, allowsDrag: Bool = false) {
        self.allowsDrag = allowsDrag
        if interval.isFinite, interval > 0 {
            self.currentInterval = min(Self.maximumInterval, max(Self.minimumInterval, interval))
        } else {
            self.currentInterval = Self.interval
        }
    }

    public mutating func setInterval(_ value: TimeInterval) {
        guard value.isFinite, value > 0 else { return }
        let previousInterval = currentInterval
        let clamped = min(Self.maximumInterval, max(Self.minimumInterval, value))
        currentInterval = clamped
        if let due = nextDueAt {
            let base = lastSentAt ?? (due - previousInterval)
            nextDueAt = min(due, base + clamped)
        }
    }

    // Later events replace the payload, never postpone an already pending deadline.
    public mutating func offer(_ input: RemoteInput, now: TimeInterval) -> RemoteInput? {
        let supported = input.kind == .move || (allowsDrag && input.kind == .drag)
        guard supported, (try? input.validate()) != nil, validTime(now) else { return nil }
        if let existing = pending, existing.kind == input.kind,
           existing.relativeMouse == input.relativeMouse,
           (input.kind != .drag || existing.button == input.button) {
            pending = input.accumulatingPointerDelta(from: existing)
        } else {
            pending = input
        }
        return takeDue(now: now)
    }

    public func nextDelay(now: TimeInterval) -> TimeInterval? {
        guard pending != nil, validTime(now) else { return nil }
        return max(0, (nextDueAt ?? now) - now)
    }

    // A late timer emits at most one latest position; missed slots never create a burst.
    public mutating func takeDue(now: TimeInterval) -> RemoteInput? {
        guard validTime(now) else { return nil }
        lastObservedAt = now
        guard let pending, nextDueAt.map({ now >= $0 }) ?? true else { return nil }
        self.pending = nil
        lastSentAt = now
        nextDueAt = now + currentInterval
        return pending
    }

    // Flush before a reliable pointer event, then send that event. Invalid time drops
    // pending movement as well, so an old move cannot cross the event boundary later.
    public mutating func flush(now: TimeInterval) -> RemoteInput? {
        let input = pending
        pending = nil
        guard validTime(now) else { return nil }
        lastObservedAt = now
        if input != nil {
            lastSentAt = now
            nextDueAt = now + currentInterval
        }
        return input
    }

    // Cancel the caller's scheduled timer too, or fence it before reusing this value.
    public mutating func cancel() {
        pending = nil
        lastObservedAt = nil
        lastSentAt = nil
        nextDueAt = nil
    }

    private func validTime(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, lastObservedAt.map({ now >= $0 }) ?? true else { return false }
        let next = now + currentInterval
        return next.isFinite && next > now
    }
}
