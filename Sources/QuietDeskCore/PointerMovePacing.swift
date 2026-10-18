import Foundation

// Own this value on one queue and use one monotonic clock for every call. A caller
// schedules takeDue with nextDelay, including after the final mouse event in a burst.
public struct PointerMovePacer: Sendable {
    public static let interval: TimeInterval = 1.0 / 60
    private var pending: RemoteInput?
    private var lastObservedAt: TimeInterval?
    private var nextDueAt: TimeInterval?

    public init() {}

    // Later events replace the payload, never postpone an already pending deadline.
    public mutating func offer(_ input: RemoteInput, now: TimeInterval) -> RemoteInput? {
        guard input.kind == .move, (try? input.validate()) != nil, validTime(now) else { return nil }
        pending = input
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
        nextDueAt = now + Self.interval
        return pending
    }

    // Flush before a reliable pointer event, then send that event. Invalid time drops
    // pending movement as well, so an old move cannot cross the event boundary later.
    public mutating func flush(now: TimeInterval) -> RemoteInput? {
        let input = pending
        pending = nil
        guard validTime(now) else { return nil }
        lastObservedAt = now
        if input != nil { nextDueAt = now + Self.interval }
        return input
    }

    // Cancel the caller's scheduled timer too, or fence it before reusing this value.
    public mutating func cancel() {
        pending = nil
        lastObservedAt = nil
        nextDueAt = nil
    }

    private func validTime(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, lastObservedAt.map({ now >= $0 }) ?? true else { return false }
        let next = now + Self.interval
        return next.isFinite && next > now
    }
}
