import Foundation

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
    public var displayName: String {
        let singleLine = name.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : String($0) }.joined()
        let normalized = singleLine.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return normalized.isEmpty ? "未命名 Mac" : normalized
    }
}

public struct TrafficTotals: Codable, Equatable, Sendable {
    public var sentBytes: UInt64
    public var receivedBytes: UInt64
    public init(sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0) {
        self.sentBytes = sentBytes; self.receivedBytes = receivedBytes
    }
    public var totalBytes: Decimal { Decimal(sentBytes) + Decimal(receivedBytes) }
    public mutating func add(_ other: TrafficTotals) throws {
        let sent = sentBytes.addingReportingOverflow(other.sentBytes)
        let received = receivedBytes.addingReportingOverflow(other.receivedBytes)
        guard !sent.overflow, !received.overflow else { throw DeskError.invalid("流量计数超出可保存的整数范围") }
        sentBytes = sent.partialValue; receivedBytes = received.partialValue
    }
}

public struct TrafficSnapshot: Equatable, Sendable {
    public let connectionID: UUID
    public let totals: TrafficTotals
    public let error: String?
    public init(connectionID: UUID, totals: TrafficTotals, error: String? = nil) {
        self.connectionID = connectionID; self.totals = totals; self.error = error
    }
}

// The meter outlives Peer when Network.framework completes an already submitted send after close.
public final class TrafficMeter: @unchecked Sendable {
    public let connectionID = UUID()
    private let lock = NSLock()
    private var totals = TrafficTotals()
    private var failure: String?
    private var observer: ((TrafficSnapshot) -> Void)?
    public init() {}

    public var onUpdate: ((TrafficSnapshot) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }

    public func record(sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0) {
        let (snapshot, callback) = lock.withLock { () -> (TrafficSnapshot, ((TrafficSnapshot) -> Void)?) in
            do { try totals.add(TrafficTotals(sentBytes: sentBytes, receivedBytes: receivedBytes)) }
            catch { failure = error.localizedDescription }
            return (TrafficSnapshot(connectionID: connectionID, totals: totals, error: failure), observer)
        }
        callback?(snapshot)
    }

    public func snapshot() -> TrafficSnapshot {
        lock.withLock { TrafficSnapshot(connectionID: connectionID, totals: totals, error: failure) }
    }
}

public final class TrafficSession: @unchecked Sendable {
    public let connectionID: UUID
    private let lock = NSLock()
    private var identity: DeviceIdentity?
    private var latest = TrafficTotals()
    private var applied = TrafficTotals()
    private let onDelta: (DeviceIdentity, TrafficTotals) -> Void
    private let onError: (String) -> Void

    // onDelta enqueues persistence while this session is locked; it must not reenter the session.
    public init(connectionID: UUID, onDelta: @escaping (DeviceIdentity, TrafficTotals) -> Void,
                onError: @escaping (String) -> Void = { _ in }) {
        self.connectionID = connectionID; self.onDelta = onDelta; self.onError = onError
    }

    public func bind(_ value: DeviceIdentity) throws {
        try lock.withLock {
            if let identity {
                guard identity.id == value.id else { throw DeskError.invalid("连接中的设备标识发生变化") }
                return
            }
            identity = value
            applied = latest
            onDelta(value, latest)
        }
    }

    public func receive(_ snapshot: TrafficSnapshot) {
        guard snapshot.connectionID == connectionID else { return }
        lock.withLock {
            latest.sentBytes = max(latest.sentBytes, snapshot.totals.sentBytes)
            latest.receivedBytes = max(latest.receivedBytes, snapshot.totals.receivedBytes)
            guard let identity else { return }
            let delta = TrafficTotals(sentBytes: latest.sentBytes - applied.sentBytes,
                                      receivedBytes: latest.receivedBytes - applied.receivedBytes)
            guard delta.sentBytes != 0 || delta.receivedBytes != 0 else { return }
            applied = latest
            onDelta(identity, delta)
        }
        if let error = snapshot.error { onError(error) }
    }
}

public struct DeviceTrafficRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var totals: TrafficTotals
    public var firstSeen: Date
    public var lastSeen: Date
    public var sentBytes: UInt64 { totals.sentBytes }
    public var receivedBytes: UInt64 { totals.receivedBytes }
    public var totalBytes: Decimal { totals.totalBytes }
    public init(id: UUID, name: String, totals: TrafficTotals = .init(), firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = id; self.name = name; self.totals = totals; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
}
