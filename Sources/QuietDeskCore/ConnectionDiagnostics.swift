import Foundation

/// The control connection and the path carrying the video can use different transports.
public struct DiagnosticRoute: Hashable, Sendable {
    public enum Control: Hashable, Sendable { case unavailable, direct, relay }

    public enum Media: Hashable, Sendable {
        case negotiating, reconnecting, paused, udpTrial
        case directCompatibleTCP, relayCompatibleTCP, directTCP, relayTCP, directUDP, relayUDP, punchedUDP

        public var isUDP: Bool { self == .directUDP || self == .relayUDP || self == .punchedUDP }
    }

    public let control: Control
    public let media: Media
    public let node: String?

    public init(control: Control, media: Media, node: String? = nil) {
        self.control = control
        self.media = media
        self.node = node
    }
}

public struct DiagnosticObservations: Sendable {
    public fileprivate(set) var count = 0
    public fileprivate(set) var maximum: Double?
    fileprivate var sum = 0.0
    public var mean: Double? { count > 0 ? sum / Double(count) : nil }

    fileprivate mutating func add(_ value: Double) {
        count += 1
        sum += value
        maximum = max(maximum ?? 0, value)
    }

    fileprivate mutating func merge(_ other: Self) {
        count += other.count
        sum += other.sum
        if let peak = other.maximum { maximum = max(maximum ?? 0, peak) }
    }
}

public struct DiagnosticLoss: Sendable {
    public fileprivate(set) var count = 0
    public fileprivate(set) var maximum: Double?
    public fileprivate(set) var settledFragments = 0
    public fileprivate(set) var lostFragments = 0
    public var mean: Double? { settledFragments > 0 ? Double(lostFragments) / Double(settledFragments) : nil }

    fileprivate mutating func add(settled: Int, lost: Int) {
        count += 1
        settledFragments += settled
        lostFragments += lost
        maximum = max(maximum ?? 0, Double(lost) / Double(settled))
    }

    fileprivate mutating func merge(_ other: Self) {
        count += other.count
        settledFragments += other.settledFragments
        lostFragments += other.lostFragments
        if let peak = other.maximum { maximum = max(maximum ?? 0, peak) }
    }
}

public struct DiagnosticQuality: Sendable {
    public fileprivate(set) var roundTrip = DiagnosticObservations()
    public fileprivate(set) var udpRoundTrip = DiagnosticObservations()
    public fileprivate(set) var loss = DiagnosticLoss()
    public fileprivate(set) var bytes = 0
    public fileprivate(set) var frames = 0
    public fileprivate(set) var measuredSeconds: TimeInterval = 0

    public var megabitsPerSecond: Double? {
        measuredSeconds > 0 ? Double(bytes) * 8 / 1_000_000 / measuredSeconds : nil
    }
    public var framesPerSecond: Double? { measuredSeconds > 0 ? Double(frames) / measuredSeconds : nil }

    fileprivate mutating func merge(_ other: Self) {
        roundTrip.merge(other.roundTrip)
        udpRoundTrip.merge(other.udpRoundTrip)
        loss.merge(other.loss)
        bytes += other.bytes
        frames += other.frames
        measuredSeconds += other.measuredSeconds
    }
}

public struct DiagnosticRouteSummary: Sendable {
    public let route: DiagnosticRoute
    public fileprivate(set) var visits = 0
    public fileprivate(set) var duration: TimeInterval = 0
    public fileprivate(set) var quality = DiagnosticQuality()
}

public struct DiagnosticTimeBucket: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let routes: [DiagnosticRoute: TimeInterval]
    public let quality: DiagnosticQuality
}

public struct ConnectionDiagnosticReport: Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let duration: TimeInterval
    public let remoteName: String
    public let reason: String
    public let totals: DiagnosticQuality
    public let routes: [DiagnosticRouteSummary]
    public let timeline: [DiagnosticTimeBucket]
}

/// A single owner feeds local, monotonic timestamps. Traffic counters are drained before route changes.
public final class ConnectionDiagnosticRecorder {
    private struct Bucket {
        var routes: [DiagnosticRoute: TimeInterval] = [:]
        var quality = DiagnosticQuality()

        mutating func merge(_ other: Self) {
            for (route, seconds) in other.routes { routes[route, default: 0] += seconds }
            quality.merge(other.quality)
        }
    }

    private let id = UUID()
    private let startedAt: Date
    private let origin: TimeInterval
    private var routeStart: TimeInterval = 0
    private var currentRouteIndex = 0
    private var lastCreditedRouteIndex: Int?
    private var indices: [DiagnosticRoute: Int]
    private var summaries: [DiagnosticRouteSummary]
    public var route: DiagnosticRoute { summaries[currentRouteIndex].route }
    private var bucketWidth: TimeInterval = 1
    private var buckets: [Bucket] = []
    private static let bucketLimit = 256

    public init(startedAt: Date, now: TimeInterval, route: DiagnosticRoute) {
        self.startedAt = startedAt
        origin = now
        indices = [route: 0]
        summaries = [DiagnosticRouteSummary(route: route)]
    }

    public func changeRoute(_ next: DiagnosticRoute, at time: TimeInterval) {
        accountDuration(through: time - origin)
        if let index = indices[next] {
            currentRouteIndex = index
        } else {
            currentRouteIndex = summaries.count
            indices[next] = currentRouteIndex
            summaries.append(DiagnosticRouteSummary(route: next))
        }
    }

    public func recordTraffic(bytes: Int, frames: Int, seconds: TimeInterval, at time: TimeInterval) {
        guard seconds.isFinite, seconds > 0, bytes >= 0, frames >= 0 else { return }
        // A rate is one observation over the drained interval. Pin it at the midpoint of that interval.
        record(elapsed: max(routeStart, time - origin - seconds / 2)) { quality in
            quality.bytes += bytes
            quality.frames += frames
            quality.measuredSeconds += seconds
        }
    }

    public func recordRoundTrip(milliseconds: Double, at time: TimeInterval) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        record(elapsed: time - origin) { $0.roundTrip.add(milliseconds) }
    }

    public func recordUDPRoundTrip(milliseconds: Double, at time: TimeInterval) {
        guard route.media.isUDP, milliseconds.isFinite, milliseconds >= 0 else { return }
        record(elapsed: time - origin) { $0.udpRoundTrip.add(milliseconds) }
    }

    public func recordLoss(settled: Int, lost: Int, at time: TimeInterval) {
        guard route.media.isUDP || route.media == .udpTrial, settled > 0, lost >= 0, lost <= settled else { return }
        record(elapsed: time - origin) { $0.loss.add(settled: settled, lost: lost) }
    }

    public func finish(remoteName: String, reason: String, at time: TimeInterval) -> ConnectionDiagnosticReport {
        let duration = time - origin
        accountDuration(through: duration)
        let totals = summaries.reduce(into: DiagnosticQuality()) { $0.merge($1.quality) }
        let timeline = buckets.enumerated().map { index, bucket in
            DiagnosticTimeBucket(start: Double(index) * bucketWidth, end: min(duration, Double(index + 1) * bucketWidth),
                                 routes: bucket.routes, quality: bucket.quality)
        }
        return ConnectionDiagnosticReport(id: id, startedAt: startedAt, duration: duration, remoteName: remoteName,
                                          reason: reason, totals: totals, routes: summaries, timeline: timeline)
    }

    private func record(elapsed: TimeInterval, _ update: (inout DiagnosticQuality) -> Void) {
        let index = prepareBuckets(through: elapsed)
        update(&buckets[index].quality)
        update(&summaries[currentRouteIndex].quality)
    }

    private func accountDuration(through elapsed: TimeInterval) {
        guard elapsed > routeStart else { return }
        let last = prepareBuckets(through: elapsed)
        for index in Int(routeStart / bucketWidth)...last {
            let start = max(routeStart, Double(index) * bucketWidth)
            let end = min(elapsed, Double(index + 1) * bucketWidth)
            buckets[index].routes[route, default: 0] += end - start
        }
        if lastCreditedRouteIndex != currentRouteIndex {
            summaries[currentRouteIndex].visits += 1
            lastCreditedRouteIndex = currentRouteIndex
        }
        summaries[currentRouteIndex].duration += elapsed - routeStart
        routeStart = elapsed
    }

    // Double the time span of every bucket together, preserving earlier routes and observations.
    private func prepareBuckets(through elapsed: TimeInterval) -> Int {
        while elapsed > Double(Self.bucketLimit) * bucketWidth {
            var merged: [Bucket] = []
            for index in stride(from: 0, to: buckets.count, by: 2) {
                var pair = buckets[index]
                if index + 1 < buckets.count { pair.merge(buckets[index + 1]) }
                merged.append(pair)
            }
            buckets = merged
            bucketWidth *= 2
        }
        let index = max(0, Int(ceil(elapsed / bucketWidth)) - 1)
        if index >= buckets.count { buckets += Array(repeating: Bucket(), count: index + 1 - buckets.count) }
        return index
    }
}
