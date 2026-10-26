import Foundation
import Network

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

public struct TrafficEndpoint: Codable, Hashable, Sendable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) throws {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { throw DeskError.invalid("流量统计的 IPv6 地址无效") }
        }
        guard !host.isEmpty, port > 0, !host.contains("/"), !host.contains("["), !host.contains("]"),
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw DeskError.invalid("流量统计的地址或端口无效")
        }
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2, let ip = IPv6Address(String(parts[0])),
                  parts.count == 1 || !parts[1].isEmpty else { throw DeskError.invalid("流量统计的 IPv6 地址无效") }
            host = ip.debugDescription.lowercased() + (parts.count == 2 ? "%" + parts[1] : "")
        } else if let ip = IPv4Address(host) { host = ip.debugDescription }
        else { host = host.lowercased() }
        self.address = host
        self.port = port
    }

    public init(remoteEndpoint: NWEndpoint, listeningPort: UInt16) throws {
        guard case .hostPort(let host, _) = remoteEndpoint else { throw DeskError.invalid("无法识别连接的来源地址") }
        try self.init(address: host.debugDescription, port: listeningPort)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: values.decode(String.self, forKey: .address), port: values.decode(UInt16.self, forKey: .port))
    }

    public var label: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }
}

public struct EndpointTrafficRecord: Codable, Identifiable, Equatable, Sendable {
    public let endpoint: TrafficEndpoint
    public var totals: TrafficTotals
    public var firstSeen: Date
    public var lastSeen: Date
    public var id: TrafficEndpoint { endpoint }
    public var sentBytes: UInt64 { totals.sentBytes }
    public var receivedBytes: UInt64 { totals.receivedBytes }
    public var totalBytes: Decimal { totals.totalBytes }

    public init(endpoint: TrafficEndpoint, totals: TrafficTotals = .init(), firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.endpoint = endpoint; self.totals = totals; self.firstSeen = firstSeen; self.lastSeen = lastSeen
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

    /// Sent plus received for a count that keeps growing on screen: 1 KB = 1000 bytes as in the history sheet,
    /// with fixed decimals per unit (none for B, one for KB and MB, two from GB) so the text keeps its width.
    public var runningTotalLabel: String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        func decimals(_ unit: Int) -> Int { unit == 0 ? 0 : unit < 3 ? 1 : 2 }
        var amount = Double(sentBytes) + Double(receivedBytes), unit = 0
        // Step up before rounding would print 1000 of the smaller unit.
        while unit < units.count - 1, amount >= 1000 - 0.5 / pow(10, Double(decimals(unit))) {
            amount /= 1000
            unit += 1
        }
        return String(format: "%.\(decimals(unit))f %@", amount, units[unit])
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
    private var endpoint: TrafficEndpoint?
    private var latest = TrafficTotals()
    private var applied = TrafficTotals()
    private let onDelta: (TrafficEndpoint, TrafficTotals) -> Void
    private let onError: (String) -> Void

    // onDelta enqueues persistence while this session is locked; it must not reenter the session.
    public init(connectionID: UUID, endpoint: TrafficEndpoint? = nil, onDelta: @escaping (TrafficEndpoint, TrafficTotals) -> Void,
                onError: @escaping (String) -> Void = { _ in }) {
        self.connectionID = connectionID; self.endpoint = endpoint; self.onDelta = onDelta; self.onError = onError
    }

    public func bind(_ value: TrafficEndpoint) throws {
        try lock.withLock {
            if let endpoint {
                guard endpoint == value else { throw DeskError.invalid("连接中的流量统计地址发生变化") }
                return
            }
            endpoint = value
            applied = latest
            onDelta(value, latest)
        }
    }

    public func receive(_ snapshot: TrafficSnapshot) {
        guard snapshot.connectionID == connectionID else { return }
        lock.withLock {
            latest.sentBytes = max(latest.sentBytes, snapshot.totals.sentBytes)
            latest.receivedBytes = max(latest.receivedBytes, snapshot.totals.receivedBytes)
            guard let endpoint else { return }
            let delta = TrafficTotals(sentBytes: latest.sentBytes - applied.sentBytes,
                                      receivedBytes: latest.receivedBytes - applied.receivedBytes)
            guard delta.sentBytes != 0 || delta.receivedBytes != 0 else { return }
            applied = latest
            onDelta(endpoint, delta)
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
