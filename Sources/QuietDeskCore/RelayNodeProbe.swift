import Foundation
import Network

/// Measures how quickly a relay node accepts a TCP connection, which takes about one network round
/// trip. No TLS handshake or relay credential is involved. Nodes are ranked by the fastest attempt,
/// and every attempt that did not connect adds a penalty, so a fast but lossy node ranks lower.
public enum RelayNodeProbe {
    public static let failurePenaltyMilliseconds = 200.0

    public struct Measurement: Equatable, Sendable {
        /// Fastest connect time in milliseconds, or nil when no attempt connected.
        public let milliseconds: Double?
        public let attempts: Int
        public let failures: Int
        public init(milliseconds: Double?, attempts: Int, failures: Int) {
            self.milliseconds = milliseconds; self.attempts = attempts; self.failures = failures
        }
        /// Lower is better; nil for a node that never connected.
        public var score: Double? { milliseconds.map { $0 + Double(failures) * RelayNodeProbe.failurePenaltyMilliseconds } }
    }

    public static func measure(_ endpoint: RelayEndpoint, attempts: Int = 3, timeout: TimeInterval = 3) async -> Measurement {
        var best: Double?
        var failures = 0
        var made = 0
        for _ in 0..<max(1, attempts) where !Task.isCancelled {
            made += 1
            if let value = await connectTime(endpoint, timeout: timeout) { best = min(best ?? value, value) }
            else { failures += 1 }
        }
        return Measurement(milliseconds: best, attempts: made, failures: failures)
    }

    /// Orders nodes best first. Nodes that never connected follow, then unmeasured ones; ties keep the given order.
    public static func ordered(_ nodes: [RelayEndpoint], by measurements: [RelayEndpoint: Measurement]) -> [RelayEndpoint] {
        func rank(_ node: RelayEndpoint) -> (Int, Double) {
            guard let measurement = measurements[node] else { return (2, 0) }
            guard let score = measurement.score else { return (1, 0) }
            return (0, score)
        }
        return nodes.enumerated().sorted { first, second in
            let a = rank(first.element), b = rank(second.element)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return first.offset < second.offset
        }.map(\.element)
    }

    private final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Double?, Never>?
        let connection: NWConnection
        init(_ connection: NWConnection, _ continuation: CheckedContinuation<Double?, Never>) {
            self.connection = connection; self.continuation = continuation
        }
        func finish(_ value: Double?) {
            let pending: CheckedContinuation<Double?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            connection.cancel()
            pending.resume(returning: value)
        }
    }

    static func connectTime(_ endpoint: RelayEndpoint, timeout: TimeInterval) async -> Double? {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
        let queue = DispatchQueue(label: "quietdesk.relay-probe")
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        return await withCheckedContinuation { continuation in
            let attempt = Attempt(connection, continuation)
            let started = DispatchTime.now().uptimeNanoseconds
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: attempt.finish(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                // Waiting means refused or no route; a probe does not wait for the path to improve.
                case .waiting, .failed, .cancelled: attempt.finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { attempt.finish(nil) }
        }
    }
}
