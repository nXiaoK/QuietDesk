import Foundation

public enum PerformanceUnit: String, Codable, Sendable {
    case microseconds, bytes, count
}

public enum PerformanceMetric: String, Codable, CaseIterable, Sendable {
    case sendQueue, sendCompletion, receiveHeaderWait, receiveBody, messageHandler, roundTrip
    case tcpSmoothedRTT, tcpMinimumRTT, tcpRTTVariance, tcpReportDuration
    case tcpRetransmittedBytes, tcpOutOfOrderBytes, tcpSentBytes, tcpReceivedBytes
    case captureAge, captureInterval, encodeSubmit, encode, encodeCallbackQueue, videoAck, decodeQueue, decodePrepare, decode, decodeToDisplay, displayEnqueue
    case encodedBytes, keyframeBytes, pendingSendBytes
    case captureReplaced, displayReplaced, encoderHardware, decoderHardware, encoderDropped, videoOutstanding
    case mediaRoundTrip, mediaReassembly, mediaSwitch, mediaDecodeInterval
    case mediaDatagramSentBytes, mediaDatagramReceivedBytes, mediaRepairBytes
    case mediaExpired, mediaRecovery, mediaTransport

    public var unit: PerformanceUnit {
        switch self {
        case .encodedBytes, .keyframeBytes, .pendingSendBytes, .tcpRetransmittedBytes, .tcpOutOfOrderBytes,
             .tcpSentBytes, .tcpReceivedBytes, .mediaDatagramSentBytes, .mediaDatagramReceivedBytes,
             .mediaRepairBytes: return .bytes
        case .captureReplaced, .displayReplaced, .encoderHardware, .decoderHardware, .encoderDropped, .videoOutstanding,
             .mediaExpired, .mediaRecovery, .mediaTransport: return .count
        default: return .microseconds
        }
    }
}

public struct PerformanceSummary: Codable, Sendable {
    public let metric: PerformanceMetric
    public let messageKind: UInt8?
    public let unit: PerformanceUnit
    public let count: Int
    public let minimum: Int
    public let maximum: Int
    public let mean: Int
    public let p95UpperBound: Int
    public let worstIdentifier: UInt64?
    public let windowMilliseconds: Int

    public init(metric: PerformanceMetric, messageKind: UInt8? = nil, unit: PerformanceUnit,
                count: Int, minimum: Int, maximum: Int, mean: Int, p95UpperBound: Int,
                worstIdentifier: UInt64? = nil, windowMilliseconds: Int) {
        self.metric = metric; self.messageKind = messageKind; self.unit = unit
        self.count = count; self.minimum = minimum; self.maximum = maximum; self.mean = mean
        self.p95UpperBound = p95UpperBound; self.worstIdentifier = worstIdentifier
        self.windowMilliseconds = windowMilliseconds
    }
}

// Each connection has fixed metric/kind keys and fixed histograms, never a per-frame log or buffer.
public final class PerformanceDiagnostics: @unchecked Sendable {
    public struct Token: Sendable {
        public let startedAt: TimeInterval
        fileprivate let owner: ObjectIdentifier
        fileprivate let generation: UInt64
    }

    private struct Key: Hashable {
        let metric: PerformanceMetric
        let kind: UInt8?
    }

    private struct Statistics {
        var count = 0
        var minimum = Int.max
        var maximum = 0
        var mean: Double = 0
        var worstIdentifier: UInt64?
        var buckets = [Int](repeating: 0, count: Int.bitWidth)

        mutating func add(_ value: Int, identifier: UInt64?) {
            guard count < Int.max else { return }
            count += 1
            minimum = min(minimum, value)
            if count == 1 || value > maximum { maximum = value; worstIdentifier = identifier }
            mean += (Double(value) - mean) / Double(count)
            let bucket = value == 0 ? 0 : Int.bitWidth - value.leadingZeroBitCount
            buckets[bucket] += 1
        }

        var p95UpperBound: Int {
            let target = count - count / 20
            var seen = 0
            for (index, count) in buckets.enumerated() {
                seen += count
                if seen >= target {
                    let ceiling = index == Int.bitWidth - 1 ? Int.max : (1 << index) - 1
                    return min(maximum, ceiling)
                }
            }
            return maximum
        }
    }

    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private var enabled: Bool
    private var generation: UInt64 = 0
    private var windowStartedAt: TimeInterval
    private var statistics: [Key: Statistics] = [:]
    private var enableObservers: [UUID: () -> Void] = [:]

    public init(enabled: Bool = false, clock: @escaping () -> TimeInterval = { SessionClock.now }) {
        self.enabled = enabled
        self.clock = clock
        windowStartedAt = clock()
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    public func setEnabled(_ value: Bool) {
        let observers: [() -> Void] = lock.withLock {
            guard enabled != value else { return [] }
            enabled = value
            generation &+= 1
            statistics.removeAll(keepingCapacity: true)
            windowStartedAt = clock()
            return Array(enableObservers.values)
        }
        for observer in observers { observer() }
    }

    func observeEnableChanges(_ observer: @escaping () -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            enableObservers[id] = observer
            return id
        }
    }

    func removeEnableObserver(_ id: UUID) { _ = lock.withLock { enableObservers.removeValue(forKey: id) } }

    func accepts(_ token: Token) -> Bool {
        lock.withLock { enabled && token.owner == ObjectIdentifier(self) && token.generation == generation }
    }

    public func start() -> Token? {
        lock.withLock {
            guard enabled else { return nil }
            let time = clock()
            guard time.isFinite else { return nil }
            return Token(startedAt: time, owner: ObjectIdentifier(self), generation: generation)
        }
    }

    public func record(_ metric: PerformanceMetric, since token: Token?, kind: MessageKind? = nil, identifier: UInt64? = nil) {
        guard let token, metric.unit == .microseconds, token.owner == ObjectIdentifier(self) else { return }
        let elapsed = clock() - token.startedAt
        guard elapsed.isFinite, elapsed >= 0, let value = Int(exactly: (elapsed * 1_000_000).rounded()) else { return }
        lock.withLock {
            guard enabled, token.generation == generation else { return }
            statistics[Key(metric: metric, kind: kind?.rawValue), default: Statistics()].add(value, identifier: identifier)
        }
    }

    public func recordValue(_ metric: PerformanceMetric, _ value: Int, kind: MessageKind? = nil, identifier: UInt64? = nil, token: Token? = nil) {
        guard value >= 0 else { return }
        lock.withLock {
            guard enabled else { return }
            if let token { guard token.owner == ObjectIdentifier(self), token.generation == generation else { return } }
            statistics[Key(metric: metric, kind: kind?.rawValue), default: Statistics()].add(value, identifier: identifier)
        }
    }

    public func drain() -> [PerformanceSummary] {
        lock.withLock {
            guard enabled else { return [] }
            let now = clock()
            let elapsed = now - windowStartedAt
            let window = elapsed.isFinite && elapsed >= 0 ? Int(exactly: (elapsed * 1_000).rounded()) ?? 0 : 0
            windowStartedAt = now
            defer { statistics.removeAll(keepingCapacity: true) }
            return statistics.map { key, value in
                PerformanceSummary(metric: key.metric, messageKind: key.kind, unit: key.metric.unit,
                    count: value.count, minimum: value.minimum, maximum: value.maximum,
                    mean: Int(exactly: value.mean.rounded()) ?? value.maximum,
                    p95UpperBound: value.p95UpperBound, worstIdentifier: value.worstIdentifier,
                    windowMilliseconds: window)
            }.sorted {
                $0.metric.rawValue == $1.metric.rawValue ? ($0.messageKind.map(Int.init) ?? -1) < ($1.messageKind.map(Int.init) ?? -1)
                    : $0.metric.rawValue < $1.metric.rawValue
            }
        }
    }
}
