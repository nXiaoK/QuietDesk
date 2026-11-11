import Foundation

/// Bounded request asking an updated host (`qualityProbeV1 == true`) to keep producing test frames
/// during a manual route quality benchmark even if the shared desktop is completely motionless.
public struct QualityProbeControl: Codable, Equatable, Sendable {
    public static let minimumDurationSeconds = 5
    public static let maximumDurationSeconds = 120

    public let id: UUID
    public let enabled: Bool
    public let durationSeconds: Int

    public init(id: UUID = UUID(), enabled: Bool, durationSeconds: Int) {
        self.id = id
        self.enabled = enabled
        self.durationSeconds = durationSeconds
    }

    public func validate() throws {
        if enabled {
            guard (Self.minimumDurationSeconds...Self.maximumDurationSeconds).contains(durationSeconds) else {
                throw DeskError.invalid("线路质量压测时长超出范围（\(Self.minimumDurationSeconds)–\(Self.maximumDurationSeconds) 秒）")
            }
        } else {
            guard (0...Self.maximumDurationSeconds).contains(durationSeconds) else {
                throw DeskError.invalid("线路质量压测控制参数无效")
            }
        }
    }

    public func message() throws -> Message {
        try validate()
        return try Wire.json(.qualityProbeControl, self)
    }

    public static func read(_ data: Data) throws -> Self {
        let control = try Wire.readJSON(Self.self, data)
        try control.validate()
        return control
    }
}

/// Selectable per-route measurement durations for manual connection & relay route testing.
public enum RouteBenchmarkDuration: Int, CaseIterable, Identifiable, Sendable {
    case seconds15 = 15
    case seconds30 = 30
    case seconds60 = 60

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .seconds15: return "15 秒"
        case .seconds30: return "30 秒（默认）"
        case .seconds60: return "1 分钟"
        }
    }

    public var shortTitle: String {
        switch self {
        case .seconds15: return "15 秒"
        case .seconds30: return "30 秒"
        case .seconds60: return "1 分钟"
        }
    }
}

public enum RouteBenchmarkKind: String, Codable, CaseIterable, Hashable, Sendable {
    case directUDP
    case directTCP
    case relayAutoPunch
    case relayPureUDP
    case relayPureTCP

    public var usesRelay: Bool {
        switch self {
        case .directUDP, .directTCP: return false
        case .relayAutoPunch, .relayPureUDP, .relayPureTCP: return true
        }
    }

    public var mediaTCPOnly: Bool {
        switch self {
        case .directTCP, .relayPureTCP: return true
        case .directUDP, .relayAutoPunch, .relayPureUDP: return false
        }
    }

    public var relayPeerAssist: RelayPeerAssistMode {
        switch self {
        case .relayAutoPunch: return .automatic
        case .directUDP, .directTCP, .relayPureUDP, .relayPureTCP: return .off
        }
    }

    public var modeTitle: String {
        switch self {
        case .directUDP: return "直连 · UDP 优先"
        case .directTCP: return "直连 · 仅 TCP"
        case .relayAutoPunch: return "中继 · 自动打洞优先"
        case .relayPureUDP: return "中继 · 纯中继 UDP"
        case .relayPureTCP: return "中继 · 纯中继 TCP"
        }
    }

    public var modeExplanation: String {
        switch self {
        case .directUDP:
            return "端到端直连控制，视频优先走低延迟 UDP（不通时自动降级 TCP）"
        case .directTCP:
            return "端到端直连控制，视频强制走可靠 TCP（排查运营商对 UDP 的限速/丢包）"
        case .relayAutoPunch:
            return "经中继握手并尝试 NAT 打洞，打通后视频直连，不通则保留中继 UDP"
        case .relayPureUDP:
            return "控制与视频全程经中继服务器转发（UDP），不交换双端公网/内网地址"
        case .relayPureTCP:
            return "控制与视频全程经中继 TCP 转发（适合校园网/企业网封禁 UDP 或严重 UDP 丢包场景）"
        }
    }
}

public struct RouteBenchmarkCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: RouteBenchmarkKind
    public let address: String
    public let port: UInt16
    public let relayEndpoint: RelayEndpoint?
    public let relayDeviceID: UUID?
    public let nodeCount: Int

    public init(kind: RouteBenchmarkKind, address: String = "", port: UInt16 = 5908,
                relayEndpoint: RelayEndpoint? = nil, relayDeviceID: UUID? = nil, nodeCount: Int = 1) {
        self.kind = kind
        self.address = address
        self.port = port
        self.relayEndpoint = relayEndpoint
        self.relayDeviceID = relayDeviceID
        self.nodeCount = max(1, nodeCount)
        if let relayEndpoint {
            self.id = "\(kind.rawValue):\(relayEndpoint.address)"
        } else {
            self.id = "\(kind.rawValue):\(address):\(port)"
        }
    }

    public var title: String {
        guard kind.usesRelay, let relayEndpoint else {
            return kind.modeTitle
        }
        if nodeCount > 1 {
            return "中继（\(relayEndpoint.host)）· \(shortRelayMode)"
        }
        return kind.modeTitle
    }

    private var shortRelayMode: String {
        switch kind {
        case .relayAutoPunch: return "自动打洞优先"
        case .relayPureUDP: return "纯中继 UDP"
        case .relayPureTCP: return "纯中继 TCP"
        case .directUDP, .directTCP: return kind.modeTitle
        }
    }

    public var subtitle: String {
        if let relayEndpoint {
            return "\(relayEndpoint.address) · \(kind.modeExplanation)"
        }
        let formattedHost = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return "\(formattedHost):\(port) · \(kind.modeExplanation)"
    }
}

public struct RouteBenchmarkPlan: Equatable, Sendable {
    public let candidates: [RouteBenchmarkCandidate]
    public let notes: [String]

    public init(candidates: [RouteBenchmarkCandidate], notes: [String]) {
        self.candidates = candidates
        self.notes = notes
    }
}

public enum RouteBenchmarkPlanner {
    public static func plan(
        address: String,
        portString: String,
        relayEnabled: Bool,
        relayDeviceIDString: String,
        preferredNodeAddress: String = "",
        configuredNodes: [RelayEndpoint],
        nodesWithCredentials: Set<String>
    ) -> RouteBenchmarkPlan {
        var candidates: [RouteBenchmarkCandidate] = []
        var notes: [String] = []

        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAddress.isEmpty {
            if cleanAddress.contains("://") || cleanAddress.contains("/") {
                notes.append("直连地址格式无效（请填域名或 IP，不含协议前缀），已跳过直连线路。")
            } else if let port = UInt16(portString.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
                candidates.append(RouteBenchmarkCandidate(kind: .directUDP, address: cleanAddress, port: port))
                candidates.append(RouteBenchmarkCandidate(kind: .directTCP, address: cleanAddress, port: port))
            } else {
                notes.append("直连端口无效（需为 1–65535），已跳过直连线路。")
            }
        } else {
            notes.append("未填写直连域名或 IP，仅测试中继线路（填写 IP/域名后可同时对比直连）。")
        }

        if relayEnabled {
            let cleanDevice = relayDeviceIDString.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanDevice.isEmpty {
                notes.append("尚未填写目标中继设备标识，无法测试中继线路。")
            } else if let deviceID = UUID(uuidString: cleanDevice) {
                var orderedNodes = configuredNodes
                if !preferredNodeAddress.isEmpty,
                   let index = orderedNodes.firstIndex(where: { $0.address == preferredNodeAddress }),
                   index > 0 {
                    let chosen = orderedNodes.remove(at: index)
                    orderedNodes.insert(chosen, at: 0)
                }
                let readyNodes = orderedNodes.filter { nodesWithCredentials.contains($0.address) }
                let missingNodes = orderedNodes.filter { !nodesWithCredentials.contains($0.address) }
                if !missingNodes.isEmpty {
                    let names = missingNodes.map(\.host).joined(separator: "、")
                    notes.append("中继节点 \(names) 尚未保存节点接入码，已在测速列表中跳过。")
                }
                if readyNodes.isEmpty {
                    notes.append("已开启中继，但当前没有已保存接入码的可用中继节点。")
                } else {
                    let count = readyNodes.count
                    for endpoint in readyNodes {
                        candidates.append(RouteBenchmarkCandidate(kind: .relayAutoPunch, relayEndpoint: endpoint, relayDeviceID: deviceID, nodeCount: count))
                        candidates.append(RouteBenchmarkCandidate(kind: .relayPureUDP, relayEndpoint: endpoint, relayDeviceID: deviceID, nodeCount: count))
                        candidates.append(RouteBenchmarkCandidate(kind: .relayPureTCP, relayEndpoint: endpoint, relayDeviceID: deviceID, nodeCount: count))
                    }
                }
            } else {
                notes.append("目标中继设备标识格式不正确（需为完整 UUID），无法测试中继线路。")
            }
        } else if !configuredNodes.isEmpty {
            notes.append("当前未启用中继服务；在「中继设置…」中启用后可一并对比中继打洞与纯中继线路。")
        }

        return RouteBenchmarkPlan(candidates: candidates, notes: notes)
    }
}

public enum RouteBenchmarkStatus: Equatable, Sendable {
    case pending
    case connecting
    case measuring(elapsed: TimeInterval, duration: TimeInterval)
    case completed
    case failed(String)
    case skipped

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped: return true
        case .pending, .connecting, .measuring: return false
        }
    }
}

public struct RouteBenchmarkMetrics: Equatable, Sendable {
    public var connectMilliseconds: Double?
    public var firstFrameMilliseconds: Double?
    public var measuredSeconds: Double
    public var finalRoute: DiagnosticRoute.Media
    public var finalRouteLabel: String
    public var punchedDirect: Bool
    public var fellBackToTCP: Bool
    public var controlRTTMeanMilliseconds: Double?
    public var controlRTTMaxMilliseconds: Double?
    public var udpRTTMeanMilliseconds: Double?
    public var udpRTTMaxMilliseconds: Double?
    public var udpLossMeanPercent: Double?
    public var udpLossMaxPercent: Double?
    public var settledFragments: Int
    public var lostFragments: Int
    public var averageMegabits: Double?
    public var peakMegabits: Double?
    public var averageFPS: Double?
    public var peakFPS: Double?
    public var decodedFrames: Int
    public var appliedQualitySummary: String
    public var hostSupportsQualityProbe: Bool

    public init(
        connectMilliseconds: Double? = nil,
        firstFrameMilliseconds: Double? = nil,
        measuredSeconds: Double = 0,
        finalRoute: DiagnosticRoute.Media = .negotiating,
        finalRouteLabel: String = "未就绪",
        punchedDirect: Bool = false,
        fellBackToTCP: Bool = false,
        controlRTTMeanMilliseconds: Double? = nil,
        controlRTTMaxMilliseconds: Double? = nil,
        udpRTTMeanMilliseconds: Double? = nil,
        udpRTTMaxMilliseconds: Double? = nil,
        udpLossMeanPercent: Double? = nil,
        udpLossMaxPercent: Double? = nil,
        settledFragments: Int = 0,
        lostFragments: Int = 0,
        averageMegabits: Double? = nil,
        peakMegabits: Double? = nil,
        averageFPS: Double? = nil,
        peakFPS: Double? = nil,
        decodedFrames: Int = 0,
        appliedQualitySummary: String = "",
        hostSupportsQualityProbe: Bool = false
    ) {
        self.connectMilliseconds = connectMilliseconds
        self.firstFrameMilliseconds = firstFrameMilliseconds
        self.measuredSeconds = measuredSeconds
        self.finalRoute = finalRoute
        self.finalRouteLabel = finalRouteLabel
        self.punchedDirect = punchedDirect
        self.fellBackToTCP = fellBackToTCP
        self.controlRTTMeanMilliseconds = controlRTTMeanMilliseconds
        self.controlRTTMaxMilliseconds = controlRTTMaxMilliseconds
        self.udpRTTMeanMilliseconds = udpRTTMeanMilliseconds
        self.udpRTTMaxMilliseconds = udpRTTMaxMilliseconds
        self.udpLossMeanPercent = udpLossMeanPercent
        self.udpLossMaxPercent = udpLossMaxPercent
        self.settledFragments = settledFragments
        self.lostFragments = lostFragments
        self.averageMegabits = averageMegabits
        self.peakMegabits = peakMegabits
        self.averageFPS = averageFPS
        self.peakFPS = peakFPS
        self.decodedFrames = decodedFrames
        self.appliedQualitySummary = appliedQualitySummary
        self.hostSupportsQualityProbe = hostSupportsQualityProbe
    }

    /// Builds benchmark metrics from a finished `ConnectionDiagnosticReport` and session metadata.
    public static func from(
        report: ConnectionDiagnosticReport,
        candidate: RouteBenchmarkCandidate,
        connectMilliseconds: Double?,
        firstFrameMilliseconds: Double?,
        finalRouteLabel: String,
        appliedQualitySummary: String,
        hostSupportsQualityProbe: Bool
    ) -> RouteBenchmarkMetrics {
        let activeRoutes = report.routes.filter {
            $0.route.media != .negotiating && $0.route.media != .reconnecting && $0.route.media != .paused
        }
        let dominant = activeRoutes.max(by: { $0.duration < $1.duration })?.route.media
            ?? report.routes.last?.route.media
            ?? .negotiating
        let punched = report.routes.contains { $0.route.media == .punchedUDP && $0.duration >= 0.5 }
        let isTCPFinal = dominant == .directTCP || dominant == .relayTCP
            || dominant == .directCompatibleTCP || dominant == .relayCompatibleTCP
        let fellBack = !candidate.kind.mediaTCPOnly && isTCPFinal

        let peakMbps = report.timeline.compactMap(\.quality.megabitsPerSecond).max()
        let peakFPS = report.timeline.compactMap(\.quality.framesPerSecond).max()

        return RouteBenchmarkMetrics(
            connectMilliseconds: connectMilliseconds,
            firstFrameMilliseconds: firstFrameMilliseconds,
            measuredSeconds: report.totals.measuredSeconds > 0 ? report.totals.measuredSeconds : report.duration,
            finalRoute: punched ? .punchedUDP : dominant,
            finalRouteLabel: finalRouteLabel,
            punchedDirect: punched,
            fellBackToTCP: fellBack,
            controlRTTMeanMilliseconds: report.totals.roundTrip.mean,
            controlRTTMaxMilliseconds: report.totals.roundTrip.maximum,
            udpRTTMeanMilliseconds: report.totals.udpRoundTrip.mean,
            udpRTTMaxMilliseconds: report.totals.udpRoundTrip.maximum,
            udpLossMeanPercent: report.totals.loss.mean.map { $0 * 100 },
            udpLossMaxPercent: report.totals.loss.maximum.map { $0 * 100 },
            settledFragments: report.totals.loss.settledFragments,
            lostFragments: report.totals.loss.lostFragments,
            averageMegabits: report.totals.megabitsPerSecond,
            peakMegabits: peakMbps,
            averageFPS: report.totals.framesPerSecond,
            peakFPS: peakFPS,
            decodedFrames: report.totals.frames,
            appliedQualitySummary: appliedQualitySummary,
            hostSupportsQualityProbe: hostSupportsQualityProbe
        )
    }
}

public struct RouteBenchmarkEvaluation: Equatable, Sendable {
    public enum Grade: String, Equatable, Sendable {
        case excellent
        case good
        case fair
        case poor
        case unreachable

        public var title: String {
            switch self {
            case .excellent: return "优秀"
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "较差"
            case .unreachable: return "不可达"
            }
        }
    }

    public let score: Int
    public let grade: Grade
    public let summary: String

    public init(score: Int, grade: Grade, summary: String) {
        self.score = score
        self.grade = grade
        self.summary = summary
    }
}

public struct RouteBenchmarkResult: Identifiable, Equatable, Sendable {
    public var id: String { candidate.id }
    public let candidate: RouteBenchmarkCandidate
    public var isSelected: Bool
    public var status: RouteBenchmarkStatus
    public var metrics: RouteBenchmarkMetrics?
    public var evaluation: RouteBenchmarkEvaluation?

    public init(
        candidate: RouteBenchmarkCandidate,
        isSelected: Bool = true,
        status: RouteBenchmarkStatus = .pending,
        metrics: RouteBenchmarkMetrics? = nil,
        evaluation: RouteBenchmarkEvaluation? = nil
    ) {
        self.candidate = candidate
        self.isSelected = isSelected
        self.status = status
        self.metrics = metrics
        self.evaluation = evaluation
    }
}

public enum RouteBenchmarkScorer {
    public static func evaluate(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> RouteBenchmarkEvaluation {
        guard metrics.decodedFrames > 0 || metrics.firstFrameMilliseconds != nil else {
            return RouteBenchmarkEvaluation(score: 0, grade: .unreachable, summary: "连接已建立但未收到可解码的远端画面帧")
        }

        // 1. Latency score (0...32)
        let primaryRTT = metrics.udpRTTMeanMilliseconds ?? metrics.controlRTTMeanMilliseconds
        let peakRTT = metrics.udpRTTMaxMilliseconds ?? metrics.controlRTTMaxMilliseconds
        var latencyPoints = 20.0
        if let rtt = primaryRTT {
            switch rtt {
            case ..<15: latencyPoints = 32
            case 15..<35: latencyPoints = 32 - (rtt - 15) * 0.25          // 27...32
            case 35..<80: latencyPoints = 27 - (rtt - 35) * 0.18          // 18.9...27
            case 80..<160: latencyPoints = 18.9 - (rtt - 80) * 0.12       // 9.3...18.9
            default: latencyPoints = max(2, 9.3 - (rtt - 160) * 0.05)
            }
            if let peak = peakRTT, peak > max(rtt * 2.5, rtt + 35) {
                let spikePenalty = min(6.0, (peak - rtt) / 30.0)
                latencyPoints = max(1, latencyPoints - spikePenalty)
            }
        }

        // 2. Packet loss & transport fidelity score (0...30)
        var lossPoints: Double
        if candidate.kind.mediaTCPOnly || metrics.fellBackToTCP {
            // Reliable TCP avoids fragment loss, capped below clean UDP due to head-of-line retransmission stalls.
            lossPoints = metrics.fellBackToTCP ? 16.0 : 24.0
        } else if let meanLoss = metrics.udpLossMeanPercent {
            switch meanLoss {
            case ..<0.1: lossPoints = 30
            case 0.1..<0.5: lossPoints = 29 - (meanLoss - 0.1) * 5.0      // 27...29
            case 0.5..<2.0: lossPoints = 27 - (meanLoss - 0.5) * 4.5      // 20.25...27
            case 2.0..<5.0: lossPoints = 20.25 - (meanLoss - 2.0) * 3.2   // 10.65...20.25
            case 5.0..<12.0: lossPoints = 10.65 - (meanLoss - 5.0) * 1.1  // 2.95...10.65
            default: lossPoints = max(0, 3.0 - (meanLoss - 12.0) * 0.25)
            }
            if let maxLoss = metrics.udpLossMaxPercent, maxLoss >= 8.0 {
                lossPoints = max(0, lossPoints - min(5.0, (maxLoss - 5.0) * 0.35))
            }
        } else {
            lossPoints = 25.0
        }

        // 3. Frame rate & bitrate smoothness score (0...26)
        var smoothnessPoints = 0.0
        if let fps = metrics.averageFPS, metrics.hostSupportsQualityProbe || fps >= 5 {
            switch fps {
            case 50...: smoothnessPoints += 16
            case 28..<50: smoothnessPoints += 12.5 + (fps - 28) / 22.0 * 3.5
            case 15..<28: smoothnessPoints += 7.0 + (fps - 15) / 13.0 * 5.5
            case 5..<15: smoothnessPoints += 2.5 + (fps - 5) / 10.0 * 4.5
            default: smoothnessPoints += max(1.0, fps * 0.4)
            }
        } else {
            // Older host with static desktop: don't over-penalize static 0 fps after initial keyframe + refinements.
            smoothnessPoints += 11.0
        }

        if let mbps = metrics.averageMegabits, metrics.hostSupportsQualityProbe || mbps >= 1.5 {
            switch mbps {
            case 16...: smoothnessPoints += 10
            case 8..<16: smoothnessPoints += 7.0 + (mbps - 8) / 8.0 * 3.0
            case 3..<8: smoothnessPoints += 3.5 + (mbps - 3) / 5.0 * 3.5
            default: smoothnessPoints += max(1.0, mbps)
            }
        } else {
            smoothnessPoints += 6.0
        }

        // 4. First-frame responsiveness score (0...12)
        var startupPoints = 8.0
        if let ttff = metrics.firstFrameMilliseconds {
            switch ttff {
            case ..<600: startupPoints = 12
            case 600..<1400: startupPoints = 12 - (ttff - 600) / 800 * 3.5
            case 1400..<3000: startupPoints = 8.5 - (ttff - 1400) / 1600 * 4.5
            default: startupPoints = max(1.0, 4.0 - (ttff - 3000) / 2500 * 3.0)
            }
        }

        let rawScore = Int((latencyPoints + lossPoints + smoothnessPoints + startupPoints).rounded())
        let clampedScore = min(100, max(1, rawScore))
        let grade: RouteBenchmarkEvaluation.Grade = switch clampedScore {
        case 85...: .excellent
        case 70..<85: .good
        case 52..<70: .fair
        default: .poor
        }

        let summary = buildSummary(candidate: candidate, metrics: metrics, rtt: primaryRTT)
        return RouteBenchmarkEvaluation(score: clampedScore, grade: grade, summary: summary)
    }

    public static func recommendBest(from results: [RouteBenchmarkResult]) -> (winner: RouteBenchmarkResult, reason: String)? {
        let completed = results.filter {
            if case .completed = $0.status, let eval = $0.evaluation, eval.grade != .unreachable {
                return true
            }
            return false
        }
        guard let best = completed.max(by: { lhs, rhs in
            let ls = lhs.evaluation?.score ?? 0
            let rs = rhs.evaluation?.score ?? 0
            if ls != rs { return ls < rs }
            let ll = lhs.metrics?.udpLossMeanPercent ?? (lhs.candidate.kind.mediaTCPOnly ? 1.0 : 0)
            let rl = rhs.metrics?.udpLossMeanPercent ?? (rhs.candidate.kind.mediaTCPOnly ? 1.0 : 0)
            if abs(ll - rl) > 0.05 { return ll > rl }
            let lr = lhs.metrics?.udpRTTMeanMilliseconds ?? lhs.metrics?.controlRTTMeanMilliseconds ?? .infinity
            let rr = rhs.metrics?.udpRTTMeanMilliseconds ?? rhs.metrics?.controlRTTMeanMilliseconds ?? .infinity
            return lr > rr
        }) else {
            return nil
        }

        let others = completed.filter { $0.id != best.id }
        var clauses: [String] = []
        if let m = best.metrics {
            if let rtt = m.udpRTTMeanMilliseconds ?? m.controlRTTMeanMilliseconds {
                clauses.append(String(format: "平均往返 %.0f ms", rtt))
            }
            if !best.candidate.kind.mediaTCPOnly && !m.fellBackToTCP, let loss = m.udpLossMeanPercent {
                clauses.append(loss < 0.05 ? "UDP 零丢包" : String(format: "UDP 丢包 %.2f%%", loss))
            } else if best.candidate.kind.mediaTCPOnly {
                if others.contains(where: { ($0.metrics?.udpLossMeanPercent ?? 0) >= 2.5 }) {
                    clauses.append("规避了 UDP 线路的高丢包")
                } else {
                    clauses.append("TCP 传输稳定无分片丢失")
                }
            }
            if m.punchedDirect {
                clauses.append("NAT 打洞成功直连")
            }
            if let fps = m.averageFPS, fps >= 1 {
                clauses.append(String(format: "实测 %.0f fps", fps))
            }
        }
        if let runnerUp = others.max(by: { ($0.evaluation?.score ?? 0) < ($1.evaluation?.score ?? 0) }),
           let bScore = best.evaluation?.score, let rScore = runnerUp.evaluation?.score {
            clauses.append("综合优于「\(runnerUp.candidate.title)」（\(bScore) vs \(rScore) 分）")
        }
        let reason = clauses.isEmpty ? (best.evaluation?.summary ?? "实测综合质量最佳") : clauses.joined(separator: "，")
        return (best, reason)
    }

    private static func buildSummary(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics, rtt: Double?) -> String {
        var parts: [String] = []
        if metrics.fellBackToTCP {
            parts.append("UDP 试传未通过或中途劣化，已自动回退到 TCP")
        } else if candidate.kind == .relayAutoPunch {
            if metrics.punchedDirect {
                parts.append("中继打洞成功，视频已切换为端到端直连 UDP")
            } else {
                parts.append("当前 NAT 环境未能打通直连，保持中继转发")
            }
        }

        if !candidate.kind.mediaTCPOnly && !metrics.fellBackToTCP {
            if let loss = metrics.udpLossMeanPercent {
                if loss >= 5.0 {
                    parts.append(String(format: "UDP 分片丢包偏高（%.1f%%），易导致卡顿或降画质，建议对比 TCP 线路", loss))
                } else if loss >= 1.5 {
                    parts.append(String(format: "存在轻微 UDP 丢包（%.2f%%）", loss))
                } else {
                    parts.append("UDP 传输干净低损")
                }
            }
        } else if candidate.kind.mediaTCPOnly {
            parts.append("全程可靠 TCP 传输，适合 UDP 受限或丢包严重网络")
        }

        if let rtt {
            if rtt < 25 { parts.append(String(format: "延迟极低（%.0f ms）", rtt)) }
            else if rtt > 100 { parts.append(String(format: "往返延迟较高（%.0f ms）", rtt)) }
        }

        if !metrics.hostSupportsQualityProbe && metrics.decodedFrames <= 8 {
            parts.append("被控端版本较旧且桌面静止，建议升级被控端以持续压测帧率")
        }

        return parts.isEmpty ? "线路测速完成" : parts.joined(separator: "；")
    }
}
