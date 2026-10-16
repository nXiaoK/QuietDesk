import Foundation

public struct RoundTripProbe {
    private var sequence: UInt64 = 0
    private var pending: (id: UInt64, time: TimeInterval)?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        precondition(timeout.isFinite && timeout > 0)
        self.timeout = timeout
    }

    public mutating func begin(at time: TimeInterval) -> Data? {
        guard time.isFinite, time >= 0 else { return nil }
        if let pending, time - pending.time < timeout { return nil }
        sequence &+= 1
        pending = (sequence, time)
        var payload = Data()
        payload.put(sequence)
        return payload
    }

    public mutating func complete(_ payload: Data, at time: TimeInterval) -> Double? {
        guard payload.count == 8, let pending, time.isFinite else { return nil }
        var reader = ByteReader(payload)
        guard let id: UInt64 = try? reader.take(), id == pending.id else { return nil }
        let elapsed = time - pending.time
        guard elapsed >= 0 else { return nil }
        self.pending = nil
        return elapsed <= timeout ? elapsed * 1000 : nil
    }
}
