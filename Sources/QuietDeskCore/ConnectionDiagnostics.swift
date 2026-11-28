import Foundation

/// The control connection and the path carrying the video can use different transports.
public struct DiagnosticRoute: Codable, Hashable, Sendable {
    public enum Control: String, Codable, Hashable, Sendable { case unavailable, direct, relay, tailnet }

    public enum Media: String, Codable, Hashable, Sendable {
        case negotiating, reconnecting, paused, udpTrial
        case directCompatibleTCP, relayCompatibleTCP, directTCP, relayTCP, directUDP, relayUDP, punchedUDP
        case tailnetCompatibleTCP, tailnetTCP, tailnetUDP

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Self(rawValue: raw) ?? .negotiating
        }

        public var isUDP: Bool { self == .directUDP || self == .relayUDP || self == .punchedUDP || self == .tailnetUDP }
    }

    public let control: Control
    public let media: Media
    public let node: String?
    public let tailnetPath: String?

    public init(control: Control, media: Media, node: String? = nil, tailnetPath: String? = nil) {
        self.control = control
        self.media = media
        self.node = node.map { DiagnosticReportText.clean($0, allowsRelayAddress: true) }
        self.tailnetPath = ["direct", "derp"].first { $0 == tailnetPath }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(control: values.decode(Control.self, forKey: .control),
                      media: values.decode(Media.self, forKey: .media),
                      node: values.decodeIfPresent(String.self, forKey: .node),
                      tailnetPath: values.decodeIfPresent(String.self, forKey: .tailnetPath))
    }

    fileprivate var samplesFrames: Bool {
        control != .unavailable && media != .paused && media != .reconnecting && media != .negotiating
    }
}

private func diagnosticSum<T: FixedWidthInteger>(_ left: T, _ right: T) -> T {
    let result = left.addingReportingOverflow(right)
    return result.overflow ? .max : result.partialValue
}

public struct DiagnosticTrafficBucket: Codable, Equatable, Sendable {
    public private(set) var sentBytes: UInt64
    public private(set) var receivedBytes: UInt64
    public var totalBytes: UInt64 { diagnosticSum(sentBytes, receivedBytes) }

    public init(sentBytes: UInt64 = 0, receivedBytes: UInt64 = 0) {
        self.sentBytes = sentBytes
        self.receivedBytes = receivedBytes
    }

    public mutating func add(sent: UInt64, received: UInt64) {
        sentBytes = diagnosticSum(sentBytes, sent)
        receivedBytes = diagnosticSum(receivedBytes, received)
    }

    public mutating func merge(_ other: Self) {
        add(sent: other.sentBytes, received: other.receivedBytes)
    }
}

public struct DiagnosticTrafficBreakdown: Codable, Equatable, Sendable {
    public var directTCP = DiagnosticTrafficBucket()
    public var directUDP = DiagnosticTrafficBucket()
    public var relayTCP = DiagnosticTrafficBucket()
    public var relayUDP = DiagnosticTrafficBucket()
    public var punchedUDP = DiagnosticTrafficBucket()
    public var tailnetDirectTCP = DiagnosticTrafficBucket()
    public var tailnetDirectUDP = DiagnosticTrafficBucket()
    public var tailnetDERPTCP = DiagnosticTrafficBucket()
    public var tailnetDERPUDP = DiagnosticTrafficBucket()
    public var tailnetUnknownTCP = DiagnosticTrafficBucket()
    public var tailnetUnknownUDP = DiagnosticTrafficBucket()
    public var controlChannel = DiagnosticTrafficBucket()
    public var videoChannel = DiagnosticTrafficBucket()
    public var bulkChannel = DiagnosticTrafficBucket()

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func bucket(_ key: CodingKeys) throws -> DiagnosticTrafficBucket {
            try values.decodeIfPresent(DiagnosticTrafficBucket.self, forKey: key) ?? .init()
        }
        directTCP = try bucket(.directTCP)
        directUDP = try bucket(.directUDP)
        relayTCP = try bucket(.relayTCP)
        relayUDP = try bucket(.relayUDP)
        punchedUDP = try bucket(.punchedUDP)
        tailnetDirectTCP = try bucket(.tailnetDirectTCP)
        tailnetDirectUDP = try bucket(.tailnetDirectUDP)
        tailnetDERPTCP = try bucket(.tailnetDERPTCP)
        tailnetDERPUDP = try bucket(.tailnetDERPUDP)
        tailnetUnknownTCP = try bucket(.tailnetUnknownTCP)
        tailnetUnknownUDP = try bucket(.tailnetUnknownUDP)
        controlChannel = try bucket(.controlChannel)
        videoChannel = try bucket(.videoChannel)
        bulkChannel = try bucket(.bulkChannel)
    }

    public var tcp: DiagnosticTrafficBucket {
        Self.combined([directTCP, relayTCP, tailnetDirectTCP, tailnetDERPTCP, tailnetUnknownTCP])
    }
    public var udp: DiagnosticTrafficBucket {
        Self.combined([directUDP, relayUDP, punchedUDP, tailnetDirectUDP, tailnetDERPUDP, tailnetUnknownUDP])
    }

    private var total: DiagnosticTrafficBucket { Self.combined([tcp, udp]) }
    public var totalSentBytes: UInt64 { total.sentBytes }
    public var totalReceivedBytes: UInt64 { total.receivedBytes }
    public var totalBytes: UInt64 { total.totalBytes }
    public var tcpBytes: UInt64 { tcp.totalBytes }
    public var udpBytes: UInt64 { udp.totalBytes }
    public var directBytes: UInt64 { Self.combined([directTCP, directUDP]).totalBytes }
    public var punchedBytes: UInt64 { Self.combined([punchedUDP, tailnetDirectTCP, tailnetDirectUDP]).totalBytes }
    public var relayedBytes: UInt64 { Self.combined([relayTCP, relayUDP, tailnetDERPTCP, tailnetDERPUDP]).totalBytes }
    public var tailnetUnknownBytes: UInt64 { Self.combined([tailnetUnknownTCP, tailnetUnknownUDP]).totalBytes }
    public var relayShareFraction: Double? { totalBytes > 0 ? Double(relayedBytes) / Double(totalBytes) : nil }
    public var punchedShareFraction: Double? { totalBytes > 0 ? Double(punchedBytes) / Double(totalBytes) : nil }
    public var punchedSavedRelayFraction: Double? {
        let shared = Double(relayedBytes) + Double(punchedBytes)
        return shared > 0 ? Double(punchedBytes) / shared : nil
    }

    public mutating func merge(_ other: Self) {
        directTCP.merge(other.directTCP)
        directUDP.merge(other.directUDP)
        relayTCP.merge(other.relayTCP)
        relayUDP.merge(other.relayUDP)
        punchedUDP.merge(other.punchedUDP)
        tailnetDirectTCP.merge(other.tailnetDirectTCP)
        tailnetDirectUDP.merge(other.tailnetDirectUDP)
        tailnetDERPTCP.merge(other.tailnetDERPTCP)
        tailnetDERPUDP.merge(other.tailnetDERPUDP)
        tailnetUnknownTCP.merge(other.tailnetUnknownTCP)
        tailnetUnknownUDP.merge(other.tailnetUnknownUDP)
        controlChannel.merge(other.controlChannel)
        videoChannel.merge(other.videoChannel)
        bulkChannel.merge(other.bulkChannel)
    }

    private static func combined(_ buckets: [DiagnosticTrafficBucket]) -> DiagnosticTrafficBucket {
        buckets.reduce(into: DiagnosticTrafficBucket()) { $0.merge($1) }
    }
}

public struct DiagnosticFrameRateStats: Codable, Equatable, Sendable {
    private static let bucketBounds: [Double] = [0, 5, 10, 15, 20, 25, 30, 45, 60, 90, 120, 180]

    public private(set) var activeSamples = 0
    public fileprivate(set) var activeSeconds: TimeInterval = 0
    public private(set) var idleSeconds: TimeInterval = 0
    public private(set) var sumFPS = 0.0
    public private(set) var sumSquaredFPS = 0.0
    public private(set) var minimumActiveFPS: Double?
    public private(set) var maximumFPS: Double?
    public private(set) var dropEvents = 0
    public private(set) var histogram = Array(repeating: 0, count: DiagnosticFrameRateStats.bucketBounds.count)

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeSamples = try values.decodeIfPresent(Int.self, forKey: .activeSamples) ?? 0
        activeSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .activeSeconds) ?? 0
        idleSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .idleSeconds) ?? 0
        sumFPS = try values.decodeIfPresent(Double.self, forKey: .sumFPS) ?? 0
        sumSquaredFPS = try values.decodeIfPresent(Double.self, forKey: .sumSquaredFPS) ?? 0
        minimumActiveFPS = try values.decodeIfPresent(Double.self, forKey: .minimumActiveFPS)
        maximumFPS = try values.decodeIfPresent(Double.self, forKey: .maximumFPS)
        dropEvents = try values.decodeIfPresent(Int.self, forKey: .dropEvents) ?? 0
        if let counts = try values.decodeIfPresent([Int].self, forKey: .histogram) {
            guard counts.count == Self.bucketBounds.count, counts.allSatisfy({ $0 >= 0 }) else {
                throw DecodingError.dataCorruptedError(forKey: .histogram, in: values, debugDescription: "Invalid frame-rate histogram")
            }
            histogram = counts
        }
    }

    public var activeMeanFPS: Double? { activeSamples > 0 ? sumFPS / Double(activeSamples) : nil }
    public var standardDeviationFPS: Double? {
        guard activeSamples >= 2, let mean = activeMeanFPS else { return nil }
        return sqrt(max(0, sumSquaredFPS / Double(activeSamples) - mean * mean))
    }
    public var coefficientOfVariation: Double? {
        guard let mean = activeMeanFPS, mean > 0, let deviation = standardDeviationFPS else { return nil }
        return deviation / mean
    }
    public var p10LowFPS: Double? {
        guard activeSamples > 0 else { return nil }
        let rank = Int((Double(activeSamples) * 0.10).rounded(.up))
        var counted = 0
        for (index, count) in histogram.enumerated() {
            counted = diagnosticSum(counted, count)
            if counted >= rank {
                let lower = Self.bucketBounds[index]
                guard index + 1 < Self.bucketBounds.count else { return lower }
                return (lower + Self.bucketBounds[index + 1]) / 2
            }
        }
        return nil
    }
    public var lowFrameRateShare: Double? {
        guard activeSamples > 0 else { return nil }
        let lowSamples = zip(Self.bucketBounds, histogram).prefix { $0.0 < 20 }
            .reduce(0) { diagnosticSum($0, $1.1) }
        return Double(lowSamples) / Double(activeSamples)
    }
    public var stabilityLabel: String {
        guard activeSamples >= 3, let cv = coefficientOfVariation, let low = lowFrameRateShare else { return "样本不足" }
        if cv <= 0.10, low <= 0.10 { return "稳定" }
        if cv <= 0.25, low <= 0.25 { return "轻微波动" }
        return "明显波动"
    }

    public mutating func recordSample(fps: Double, seconds: TimeInterval, previousActiveFPS: inout Double?) {
        guard fps.isFinite, fps >= 0, seconds.isFinite, seconds > 0 else { return }
        if fps == 0 {
            recordIdle(seconds: seconds)
            previousActiveFPS = nil
            return
        }
        let squared = fps * fps
        guard (sumSquaredFPS + squared).isFinite else { return }
        activeSamples = diagnosticSum(activeSamples, 1)
        activeSeconds += seconds
        sumFPS += fps
        sumSquaredFPS += squared
        minimumActiveFPS = min(minimumActiveFPS ?? fps, fps)
        maximumFPS = max(maximumFPS ?? fps, fps)
        if let previousActiveFPS, previousActiveFPS >= 20, fps < previousActiveFPS * 0.5, previousActiveFPS - fps >= 10 {
            dropEvents = diagnosticSum(dropEvents, 1)
        }
        let index = Self.bucketBounds.lastIndex(where: { $0 <= fps }) ?? 0
        histogram[index] = diagnosticSum(histogram[index], 1)
        previousActiveFPS = fps
    }

    public mutating func recordIdle(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        idleSeconds += seconds
    }

    public mutating func merge(_ other: Self) {
        activeSamples = diagnosticSum(activeSamples, other.activeSamples)
        activeSeconds += other.activeSeconds
        idleSeconds += other.idleSeconds
        sumFPS += other.sumFPS
        sumSquaredFPS += other.sumSquaredFPS
        if let minimum = other.minimumActiveFPS { minimumActiveFPS = min(minimumActiveFPS ?? minimum, minimum) }
        if let maximum = other.maximumFPS { maximumFPS = max(maximumFPS ?? maximum, maximum) }
        dropEvents = diagnosticSum(dropEvents, other.dropEvents)
        for index in histogram.indices {
            histogram[index] = diagnosticSum(histogram[index], other.histogram[index])
        }
    }
}

public struct DiagnosticObservations: Codable, Equatable, Sendable {
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

public struct DiagnosticLoss: Codable, Equatable, Sendable {
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

public struct DiagnosticQuality: Codable, Equatable, Sendable {
    public fileprivate(set) var roundTrip = DiagnosticObservations()
    public fileprivate(set) var udpRoundTrip = DiagnosticObservations()
    public fileprivate(set) var loss = DiagnosticLoss()
    public fileprivate(set) var bytes = 0
    public fileprivate(set) var frames = 0
    public fileprivate(set) var measuredSeconds: TimeInterval = 0
    public fileprivate(set) var traffic = DiagnosticTrafficBreakdown()
    public fileprivate(set) var frameRate = DiagnosticFrameRateStats()

    init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roundTrip = try values.decodeIfPresent(DiagnosticObservations.self, forKey: .roundTrip) ?? .init()
        udpRoundTrip = try values.decodeIfPresent(DiagnosticObservations.self, forKey: .udpRoundTrip) ?? .init()
        loss = try values.decodeIfPresent(DiagnosticLoss.self, forKey: .loss) ?? .init()
        bytes = try values.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        frames = try values.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        measuredSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .measuredSeconds) ?? 0
        traffic = try values.decodeIfPresent(DiagnosticTrafficBreakdown.self, forKey: .traffic) ?? .init()
        frameRate = try values.decodeIfPresent(DiagnosticFrameRateStats.self, forKey: .frameRate) ?? .init()
    }

    public var megabitsPerSecond: Double? {
        measuredSeconds > 0 ? Double(bytes) * 8 / 1_000_000 / measuredSeconds : nil
    }
    public var framesPerSecond: Double? { measuredSeconds > 0 ? Double(frames) / measuredSeconds : nil }

    fileprivate mutating func merge(_ other: Self) {
        roundTrip.merge(other.roundTrip)
        udpRoundTrip.merge(other.udpRoundTrip)
        loss.merge(other.loss)
        bytes = diagnosticSum(bytes, other.bytes)
        frames = diagnosticSum(frames, other.frames)
        measuredSeconds += other.measuredSeconds
        traffic.merge(other.traffic)
        frameRate.merge(other.frameRate)
    }
}

public struct DiagnosticRouteSummary: Codable, Equatable, Sendable {
    public let route: DiagnosticRoute
    public fileprivate(set) var visits = 0
    public fileprivate(set) var duration: TimeInterval = 0
    public fileprivate(set) var quality = DiagnosticQuality()
}

public struct DiagnosticTimeBucket: Codable, Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let routes: [DiagnosticRoute: TimeInterval]
    public let quality: DiagnosticQuality

    private enum CodingKeys: String, CodingKey { case start, end, routes, quality }

    private struct RouteDuration: Codable {
        let route: DiagnosticRoute
        let seconds: TimeInterval
    }

    init(start: TimeInterval, end: TimeInterval, routes: [DiagnosticRoute: TimeInterval], quality: DiagnosticQuality) {
        self.start = start
        self.end = end
        self.routes = routes
        self.quality = quality
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(TimeInterval.self, forKey: .start)
        end = try values.decode(TimeInterval.self, forKey: .end)
        let pairs = try values.decodeIfPresent([RouteDuration].self, forKey: .routes) ?? []
        routes = Dictionary(pairs.map { ($0.route, $0.seconds) }, uniquingKeysWith: +)
        quality = try values.decodeIfPresent(DiagnosticQuality.self, forKey: .quality) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        let pairs = routes.sorted { left, right in
            let l = left.key
            let r = right.key
            return (l.control.rawValue, l.media.rawValue, l.node ?? "", l.tailnetPath ?? "")
                < (r.control.rawValue, r.media.rawValue, r.node ?? "", r.tailnetPath ?? "")
        }
        try values.encode(pairs.map { RouteDuration(route: $0.key, seconds: $0.value) }, forKey: .routes)
        try values.encode(quality, forKey: .quality)
    }
}

public struct ConnectionDiagnosticReport: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let duration: TimeInterval
    public let remoteName: String
    public let endpointLabel: String
    public let endedAt: Date
    public let reason: String
    public let totals: DiagnosticQuality
    public let routes: [DiagnosticRouteSummary]
    public let timeline: [DiagnosticTimeBucket]

    public var traffic: DiagnosticTrafficBreakdown { totals.traffic }
    public var frameRate: DiagnosticFrameRateStats { totals.frameRate }

    init(id: UUID, startedAt: Date, duration: TimeInterval, remoteName: String, reason: String,
         totals: DiagnosticQuality, routes: [DiagnosticRouteSummary], timeline: [DiagnosticTimeBucket],
         endpointLabel: String = "", endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.remoteName = DiagnosticReportText.clean(remoteName)
        self.endpointLabel = DiagnosticReportText.clean(endpointLabel)
        self.endedAt = endedAt ?? startedAt.addingTimeInterval(max(0, duration))
        self.reason = DiagnosticReportText.clean(reason)
        self.totals = totals
        self.routes = routes
        self.timeline = timeline
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      startedAt: values.decode(Date.self, forKey: .startedAt),
                      duration: values.decode(TimeInterval.self, forKey: .duration),
                      remoteName: values.decode(String.self, forKey: .remoteName),
                      reason: values.decode(String.self, forKey: .reason),
                      totals: values.decode(DiagnosticQuality.self, forKey: .totals),
                      routes: values.decode([DiagnosticRouteSummary].self, forKey: .routes),
                      timeline: values.decode([DiagnosticTimeBucket].self, forKey: .timeline),
                      endpointLabel: values.decodeIfPresent(String.self, forKey: .endpointLabel) ?? "",
                      endedAt: values.decodeIfPresent(Date.self, forKey: .endedAt))
    }

    public func plainTextSummary() -> String {
        let date = ISO8601DateFormatter()
        func number(_ value: Double?, unit: String) -> String {
            guard let value else { return "—" }
            return String(format: "%.1f", value) + " " + unit
        }
        func percent(_ fraction: Double?) -> String {
            number(fraction.map { $0 * 100 }, unit: "%")
        }
        let target = remoteName.isEmpty ? "远程连接" : remoteName
        let path = endpointLabel.isEmpty || endpointLabel == target ? target : "\(target)（\(endpointLabel)）"
        return [
            "QuietDesk 连接诊断报告",
            "连接目标　\(path)",
            "连接时间　\(date.string(from: startedAt)) 至 \(date.string(from: endedAt))",
            "连接时长　\(number(duration, unit: "秒"))",
            "结束原因　\(reason)",
            "",
            "流量统计",
            "传输流量合计　\(traffic.totalBytes) B（发送 \(traffic.totalSentBytes) B，接收 \(traffic.totalReceivedBytes) B）",
            "传输协议　TCP \(traffic.tcpBytes) B，UDP \(traffic.udpBytes) B",
            "传输路径　原生直连 \(traffic.directBytes) B，中转 \(traffic.relayedBytes) B（\(percent(traffic.relayShareFraction))），打洞直连 \(traffic.punchedBytes) B，Tailscale 未知路径 \(traffic.tailnetUnknownBytes) B",
            "业务通道　控制 \(traffic.controlChannel.totalBytes) B，视频与媒体 \(traffic.videoChannel.totalBytes) B，文件与剪贴板 \(traffic.bulkChannel.totalBytes) B",
            "",
            "活跃帧率",
            "平均 \(number(frameRate.activeMeanFPS, unit: "fps"))，最低 \(number(frameRate.minimumActiveFPS, unit: "fps"))，最高 \(number(frameRate.maximumFPS, unit: "fps"))",
            "P10 \(number(frameRate.p10LowFPS, unit: "fps"))，标准差 \(number(frameRate.standardDeviationFPS, unit: "fps"))，明显掉帧 \(frameRate.dropEvents) 次，\(frameRate.stabilityLabel)",
            "活跃 \(number(frameRate.activeSeconds, unit: "秒"))，静止 \(number(frameRate.idleSeconds, unit: "秒"))",
            "",
            "链路质量",
            "控制 RTT \(number(totals.roundTrip.mean, unit: "ms"))，UDP 视频 RTT \(number(totals.udpRoundTrip.mean, unit: "ms"))，UDP 分片丢失率 \(percent(totals.loss.mean))"
        ].joined(separator: "\n")
    }
}

private enum DiagnosticReportText {
    private static let sensitive = try! NSRegularExpression(pattern: #"""
        (?ix)
        -----BEGIN[^\r\n]*PRIVATE\s+KEY
        |(?:password|passphrase|pairing[\s_-]*(?:code|key)|access[\s_-]*(?:code|key)|private[\s_-]*key
           |配对码|中继接入码|中继接入密钥|本机私钥|锁屏密码|密码)["']?(?:\s*[:：=]\s*|\s+is\s+)\S
        |(?<![A-F\d])(?:[A-F\d][-\s]*){63}[A-F\d](?![A-F\d])
        |(?:file:|~)[\\/]
        |(?:^|[\s('"`：=:])[\\/](?![\\/])[\p{L}\d._-]
        |/(?:Users|home|private|Volumes|var|tmp|Library|System|Applications|opt)/
        |\b[A-Z]:[\\/]
        |://
        """#)

    static func clean(_ text: String, allowsRelayAddress: Bool = false) -> String {
        let safeRelayPrefix = allowsRelayAddress && text.hasPrefix("tls://") && (try? RelayEndpoint(address: text)) != nil
        let value = safeRelayPrefix ? String(text.dropFirst("tls://".count)) : text
        let scanned = value.removingPercentEncoding ?? value
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        guard sensitive.firstMatch(in: scanned, range: range) == nil else { return "已隐藏敏感内容" }
        let singleLine = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(singleLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }
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
    private var previousActiveFPS: Double?
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
        if !route.samplesFrames || !next.samplesFrames { previousActiveFPS = nil }
        if let index = indices[next] {
            currentRouteIndex = index
        } else {
            currentRouteIndex = summaries.count
            indices[next] = currentRouteIndex
            summaries.append(DiagnosticRouteSummary(route: next))
        }
    }

    public func recordTraffic(bytes: Int, frames: Int, seconds: TimeInterval, at time: TimeInterval) {
        guard seconds > 0 else { return }
        recordTraffic(bytes: bytes, breakdown: .init(), frames: frames, seconds: seconds, at: time, countsFrameSample: true)
    }

    /// A caller can preserve its application throughput meter when path bytes are observed at a different layer.
    public func recordDetailedTraffic(_ breakdown: DiagnosticTrafficBreakdown, frames: Int, seconds: TimeInterval,
                                      at time: TimeInterval, applicationBytes: Int? = nil, countsFrameSample: Bool = true) {
        recordTraffic(bytes: applicationBytes ?? Int(clamping: breakdown.totalBytes), breakdown: breakdown,
                      frames: frames, seconds: seconds, at: time, countsFrameSample: countsFrameSample)
    }

    private func recordTraffic(bytes: Int, breakdown: DiagnosticTrafficBreakdown, frames: Int, seconds: TimeInterval,
                               at time: TimeInterval, countsFrameSample: Bool) {
        guard (time - origin).isFinite, seconds.isFinite, seconds >= 0, bytes >= 0, frames >= 0 else { return }
        guard seconds > 0 || bytes > 0 || frames > 0 || breakdown != .init() else { return }
        var frameRate = DiagnosticFrameRateStats()
        if seconds > 0 {
            if route.samplesFrames, countsFrameSample {
                frameRate.recordSample(fps: Double(frames) / seconds, seconds: seconds, previousActiveFPS: &previousActiveFPS)
            } else {
                previousActiveFPS = nil
                if route.samplesFrames {
                    if frames > 0 { frameRate.activeSeconds = seconds }
                    else { frameRate.recordIdle(seconds: seconds) }
                }
            }
        }
        // A rate is one observation over the drained interval. Pin it at the midpoint of that interval.
        record(elapsed: max(routeStart, time - origin - seconds / 2)) { quality in
            quality.bytes = diagnosticSum(quality.bytes, bytes)
            quality.frames = diagnosticSum(quality.frames, frames)
            quality.measuredSeconds += seconds
            quality.traffic.merge(breakdown)
            quality.frameRate.merge(frameRate)
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

    public func finish(remoteName: String, endpointLabel: String = "", reason: String, at time: TimeInterval) -> ConnectionDiagnosticReport {
        let elapsed = time - origin
        let duration = elapsed.isFinite ? max(routeStart, elapsed) : routeStart
        accountDuration(through: duration)
        let totals = summaries.reduce(into: DiagnosticQuality()) { $0.merge($1.quality) }
        let timeline = buckets.enumerated().map { index, bucket in
            DiagnosticTimeBucket(start: Double(index) * bucketWidth, end: min(duration, Double(index + 1) * bucketWidth),
                                 routes: bucket.routes, quality: bucket.quality)
        }
        return ConnectionDiagnosticReport(id: id, startedAt: startedAt, duration: duration, remoteName: remoteName,
                                          reason: reason, totals: totals, routes: summaries, timeline: timeline,
                                          endpointLabel: endpointLabel)
    }

    private func record(elapsed: TimeInterval, _ update: (inout DiagnosticQuality) -> Void) {
        guard elapsed.isFinite else { return }
        let index = prepareBuckets(through: elapsed)
        update(&buckets[index].quality)
        update(&summaries[currentRouteIndex].quality)
    }

    private func accountDuration(through elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > routeStart else { return }
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
