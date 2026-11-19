import Foundation

public struct HandshakeAdmissionPolicy {
    private var attempts: [String: [TimeInterval]] = [:]
    private var cleanupAt: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    public init() {}

    fileprivate mutating func authenticated(address: String?, time: TimeInterval) {
        guard let address, var recent = attempts[address], let index = recent.firstIndex(of: time) else { return }
        recent.remove(at: index)
        attempts[address] = recent.isEmpty ? nil : recent
    }

    // The address must come from the accepted network endpoint, never a protocol message.
    public mutating func allows(address: String?, pendingCount: Int, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastTime, pendingCount >= 0, pendingCount < 4 else { return false }
        lastTime = now
        if now >= cleanupAt {
            attempts = attempts.compactMapValues { values in
                let recent = values.filter { now - $0 < 10 }
                return recent.isEmpty ? nil : recent
            }
            cleanupAt = now + 1
        }
        guard let address, !address.isEmpty else { return true }
        let recent = (attempts[address] ?? []).filter { now - $0 < 10 }
        guard recent.count < 3 else { return false }
        attempts[address] = recent + [now]
        return true
    }
}

public final class PendingHandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = HandshakeAdmissionPolicy()
    private var reservations: [UUID: (address: String?, time: TimeInterval)] = [:]
    public init() {}

    public func reserve(address: String?, now: TimeInterval) -> UUID? {
        lock.withLock {
            guard policy.allows(address: address, pendingCount: reservations.count, now: now) else { return nil }
            let id = UUID()
            reservations[id] = (address, now)
            return id
        }
    }

    /// Authenticated channels no longer consume the source's failed/pending attempt budget.
    public func authenticated(_ id: UUID) {
        lock.withLock {
            guard let entry = reservations.removeValue(forKey: id) else { return }
            policy.authenticated(address: entry.address, time: entry.time)
        }
    }

    public func release(_ id: UUID) { _ = lock.withLock { reservations.removeValue(forKey: id) } }
}
