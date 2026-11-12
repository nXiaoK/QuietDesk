import Darwin
import Foundation

public enum RouteBenchmarkSavedOutcome: Codable, Equatable, Sendable {
    case completed
    case failed(String)
    case skipped

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    public init(status: RouteBenchmarkStatus) {
        switch status {
        case .completed:
            self = .completed
        case let .failed(reason):
            self = .failed(reason)
        case .pending, .connecting, .measuring, .skipped:
            self = .skipped
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let state = try values.decode(String.self, forKey: .state)
        switch state {
        case "completed":
            self = .completed
        case "failed":
            let reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? "连接或测速失败"
            self = .failed(reason)
        default:
            self = .skipped
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed:
            try values.encode("completed", forKey: .state)
        case let .failed(reason):
            try values.encode("failed", forKey: .state)
            try values.encode(reason, forKey: .reason)
        case .skipped:
            try values.encode("skipped", forKey: .state)
        }
    }

    public var isEvaluatedAttempt: Bool {
        switch self {
        case .completed, .failed: return true
        case .skipped: return false
        }
    }
}

public struct RouteBenchmarkSavedEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { candidate.id }
    public let candidate: RouteBenchmarkCandidate
    public let outcome: RouteBenchmarkSavedOutcome
    public let metrics: RouteBenchmarkMetrics?
    public let evaluation: RouteBenchmarkEvaluation?

    public init(
        candidate: RouteBenchmarkCandidate,
        outcome: RouteBenchmarkSavedOutcome,
        metrics: RouteBenchmarkMetrics? = nil,
        evaluation: RouteBenchmarkEvaluation? = nil
    ) {
        self.candidate = candidate
        self.outcome = outcome
        self.metrics = metrics
        self.evaluation = evaluation
    }
}

public struct RouteBenchmarkTargetDescriptor: Codable, Hashable, Sendable {
    public let displayName: String
    public let recordID: UUID?
    public let directEndpoint: String?
    public let relayDeviceID: UUID?

    public init(
        displayName: String,
        recordID: UUID? = nil,
        directEndpoint: String? = nil,
        relayDeviceID: UUID? = nil
    ) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDirect = directEndpoint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.recordID = recordID
        self.directEndpoint = (normalizedDirect?.isEmpty == false) ? normalizedDirect : nil
        self.relayDeviceID = relayDeviceID
        if !trimmedName.isEmpty {
            self.displayName = trimmedName
        } else if let direct = self.directEndpoint {
            self.displayName = direct
        } else if let relayDeviceID {
            self.displayName = "中继设备 \(relayDeviceID.uuidString.lowercased())"
        } else {
            self.displayName = "未命名目标"
        }
    }

    public static func normalizedDirectEndpoint(address: String, port: UInt16) -> String? {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, port > 0, !host.contains("://"), !host.contains("/") else {
            return nil
        }
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
            host.removeFirst()
            host.removeLast()
        }
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    public var hasIdentity: Bool {
        recordID != nil || directEndpoint != nil || relayDeviceID != nil
    }

    public func matches(_ other: RouteBenchmarkTargetDescriptor) -> Bool {
        if let recordID, let otherRecordID = other.recordID, recordID == otherRecordID {
            return true
        }
        if let directEndpoint, let otherDirect = other.directEndpoint, directEndpoint == otherDirect {
            return true
        }
        if let relayDeviceID, let otherRelay = other.relayDeviceID, relayDeviceID == otherRelay {
            return true
        }
        if !hasIdentity && !other.hasIdentity {
            return displayName == other.displayName
        }
        return false
    }

    public func merged(with fallback: RouteBenchmarkTargetDescriptor) -> RouteBenchmarkTargetDescriptor {
        let chosenName = (!displayName.isEmpty && displayName != "未命名目标" && displayName != "当前未填写连接目标")
            ? displayName
            : fallback.displayName
        return RouteBenchmarkTargetDescriptor(
            displayName: chosenName,
            recordID: recordID ?? fallback.recordID,
            directEndpoint: directEndpoint ?? fallback.directEndpoint,
            relayDeviceID: relayDeviceID ?? fallback.relayDeviceID
        )
    }
}

public struct RouteBenchmarkRunRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let perRouteDurationSeconds: Int
    public let stoppedEarly: Bool
    public let target: RouteBenchmarkTargetDescriptor
    public let entries: [RouteBenchmarkSavedEntry]
    public let recommendedCandidateID: String?
    public let recommendationReason: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        perRouteDurationSeconds: Int,
        stoppedEarly: Bool = false,
        target: RouteBenchmarkTargetDescriptor,
        entries: [RouteBenchmarkSavedEntry],
        recommendedCandidateID: String? = nil,
        recommendationReason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = max(startedAt, finishedAt)
        self.perRouteDurationSeconds = max(1, perRouteDurationSeconds)
        self.stoppedEarly = stoppedEarly
        self.target = target
        self.entries = entries
        self.recommendedCandidateID = recommendedCandidateID
        self.recommendationReason = recommendationReason
    }

    public static func from(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date,
        perRouteDurationSeconds: Int,
        stoppedEarly: Bool,
        target: RouteBenchmarkTargetDescriptor,
        results: [RouteBenchmarkResult]
    ) -> RouteBenchmarkRunRecord? {
        let entries = results.map { item in
            RouteBenchmarkSavedEntry(
                candidate: item.candidate,
                outcome: RouteBenchmarkSavedOutcome(status: item.status),
                metrics: item.metrics,
                evaluation: item.evaluation
            )
        }
        guard entries.contains(where: \.outcome.isEvaluatedAttempt) else {
            return nil
        }
        let recommendation = RouteBenchmarkScorer.recommendBest(from: results)
        return RouteBenchmarkRunRecord(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            perRouteDurationSeconds: perRouteDurationSeconds,
            stoppedEarly: stoppedEarly,
            target: target,
            entries: entries,
            recommendedCandidateID: recommendation?.winner.id,
            recommendationReason: recommendation?.reason
        )
    }

    public var evaluatedEntries: [RouteBenchmarkSavedEntry] {
        entries.filter(\.outcome.isEvaluatedAttempt)
    }

    public var completedCount: Int {
        entries.filter {
            if case .completed = $0.outcome, let eval = $0.evaluation, eval.grade != .unreachable {
                return true
            }
            return false
        }.count
    }

    public var failedCount: Int {
        evaluatedEntries.count - completedCount
    }

    public var bestEntry: RouteBenchmarkSavedEntry? {
        if let recommendedCandidateID,
           let matched = entries.first(where: { $0.id == recommendedCandidateID && $0.outcome == .completed }) {
            return matched
        }
        return entries
            .filter { $0.outcome == .completed && ($0.evaluation?.grade ?? .unreachable) != .unreachable }
            .max { ($0.evaluation?.score ?? 0) < ($1.evaluation?.score ?? 0) }
    }
}

public struct RouteBenchmarkHistoryArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumRuns = 200

    public let version: Int
    public private(set) var runs: [RouteBenchmarkRunRecord]

    public init(runs: [RouteBenchmarkRunRecord] = []) {
        self.version = Self.currentVersion
        self.runs = Self.normalized(runs)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try values.decode(Int.self, forKey: .version)
        guard decodedVersion == Self.currentVersion else {
            throw DeskError.invalid("历史测速记录文件版本不受支持（v\(decodedVersion)）")
        }
        let decodedRuns = try values.decode([RouteBenchmarkRunRecord].self, forKey: .runs)
        self.version = Self.currentVersion
        self.runs = Self.normalized(decodedRuns)
    }

    public mutating func record(_ run: RouteBenchmarkRunRecord) {
        var updated = runs.filter { $0.id != run.id }
        updated.append(run)
        runs = Self.normalized(updated)
    }

    public mutating func removeRun(id: UUID) {
        runs.removeAll { $0.id == id }
    }

    public mutating func removeRuns(matching target: RouteBenchmarkTargetDescriptor) {
        let unified = unifiedTarget(for: target)
        runs.removeAll { unified.matches($0.target) }
    }

    public mutating func removeAll() {
        runs.removeAll()
    }

    public func unifiedTarget(for target: RouteBenchmarkTargetDescriptor) -> RouteBenchmarkTargetDescriptor {
        guard target.hasIdentity else { return target }
        var combined = target
        var changed = true
        while changed {
            changed = false
            for run in runs where combined.matches(run.target) {
                let next = combined.merged(with: run.target)
                if next != combined {
                    combined = next
                    changed = true
                }
            }
        }
        return combined
    }

    public func runs(matching target: RouteBenchmarkTargetDescriptor) -> [RouteBenchmarkRunRecord] {
        let unified = unifiedTarget(for: target)
        return runs.filter { unified.matches($0.target) }
    }

    /// Returns distinct historical targets ordered by most recently tested first.
    public func distinctTargets() -> [RouteBenchmarkTargetDescriptor] {
        var groups: [RouteBenchmarkTargetDescriptor] = []
        for run in runs {
            if let existingIndex = groups.firstIndex(where: { $0.matches(run.target) }) {
                groups[existingIndex] = groups[existingIndex].merged(with: run.target)
            } else {
                groups.append(unifiedTarget(for: run.target))
            }
        }
        return groups
    }

    private static func normalized(_ items: [RouteBenchmarkRunRecord]) -> [RouteBenchmarkRunRecord] {
        var seen = Set<UUID>()
        let sorted = items.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.finishedAt > $1.finishedAt
        }
        var unique: [RouteBenchmarkRunRecord] = []
        unique.reserveCapacity(min(sorted.count, Self.maximumRuns))
        for item in sorted where seen.insert(item.id).inserted {
            unique.append(item)
            if unique.count >= Self.maximumRuns { break }
        }
        return unique
    }
}

public enum RouteBenchmarkStability: String, Codable, Equatable, Sendable {
    case singleSample
    case rockSolid
    case stable
    case fluctuating
    case unstable
    case unreachable

    public var title: String {
        switch self {
        case .singleSample: return "单次样本"
        case .rockSolid: return "极稳定"
        case .stable: return "较稳定"
        case .fluctuating: return "偶有波动"
        case .unstable: return "波动较大"
        case .unreachable: return "不可用"
        }
    }
}

public struct RouteBenchmarkHistoricalRouteSummary: Identifiable, Equatable, Sendable {
    public var id: String { candidate.id }
    public let candidate: RouteBenchmarkCandidate
    public let attemptCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let availabilityPercent: Double
    public let overallScore: Int
    public let overallGrade: RouteBenchmarkEvaluation.Grade
    public let stability: RouteBenchmarkStability
    public let minScore: Int?
    public let maxScore: Int?
    public let latestScore: Int?
    public let meanCompletedScore: Double?
    public let meanConnectMilliseconds: Double?
    public let meanFirstFrameMilliseconds: Double?
    public let meanRTTMilliseconds: Double?
    public let worstRTTMilliseconds: Double?
    public let meanUDPLossPercent: Double?
    public let worstUDPLossPercent: Double?
    public let meanFPS: Double?
    public let meanMegabits: Double?
    public let punchedDirectCount: Int
    public let punchedDirectRatePercent: Double?
    public let tcpFallbackCount: Int
    public let totalMeasuredSeconds: Double
    public let lastFailureReason: String?
    public let summary: String
}

public struct RouteBenchmarkOverallAssessment: Equatable, Sendable {
    public let target: RouteBenchmarkTargetDescriptor
    public let runCount: Int
    public let reachableRunCount: Int
    public let totalMeasuredSeconds: Double
    public let earliestRunAt: Date
    public let latestRunAt: Date
    public let overallScore: Int
    public let overallGrade: RouteBenchmarkEvaluation.Grade
    public let overallStability: RouteBenchmarkStability
    public let recommendedRoute: RouteBenchmarkHistoricalRouteSummary?
    public let recommendationReason: String
    public let headline: String
    public let insights: [String]
    public let routeSummaries: [RouteBenchmarkHistoricalRouteSummary]
}

public enum RouteBenchmarkHistoryEvaluator {
    public static func assess(
        runs: [RouteBenchmarkRunRecord],
        targetOverride: RouteBenchmarkTargetDescriptor? = nil
    ) -> RouteBenchmarkOverallAssessment? {
        guard !runs.isEmpty else { return nil }
        let orderedRuns = runs.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.finishedAt > $1.finishedAt
        }

        var mergedTarget = targetOverride ?? orderedRuns[0].target
        for run in orderedRuns {
            mergedTarget = mergedTarget.merged(with: run.target)
        }

        // Group evaluated entries by candidate.id while keeping newest-first order.
        var candidateOrder: [String] = []
        var latestCandidateByID: [String: RouteBenchmarkCandidate] = [:]
        var entriesByID: [String: [RouteBenchmarkSavedEntry]] = [:]

        var totalMeasuredSeconds = 0.0
        var reachableRunCount = 0

        for run in orderedRuns {
            if run.completedCount > 0 {
                reachableRunCount += 1
            }
            for entry in run.entries where entry.outcome.isEvaluatedAttempt {
                if latestCandidateByID[entry.id] == nil {
                    candidateOrder.append(entry.id)
                    latestCandidateByID[entry.id] = entry.candidate
                }
                entriesByID[entry.id, default: []].append(entry)
                if entry.outcome == .completed, let measured = entry.metrics?.measuredSeconds {
                    totalMeasuredSeconds += max(0, measured)
                }
            }
        }

        guard !candidateOrder.isEmpty else { return nil }

        let summaries: [RouteBenchmarkHistoricalRouteSummary] = candidateOrder.compactMap { id in
            guard let candidate = latestCandidateByID[id],
                  let entries = entriesByID[id], !entries.isEmpty else {
                return nil
            }
            return summarizeRoute(candidate: candidate, newestFirstEntries: entries)
        }.sorted(by: routeSummaryPrecedes)

        guard !summaries.isEmpty else { return nil }

        let best = summaries.first { $0.overallGrade != .unreachable }
        let overallScore = best?.overallScore ?? 0
        let overallGrade = best?.overallGrade ?? .unreachable
        let overallStability = best?.stability ?? .unreachable

        let earliestAt = orderedRuns.map(\.startedAt).min() ?? orderedRuns.last!.startedAt
        let latestAt = orderedRuns.map(\.startedAt).max() ?? orderedRuns[0].startedAt

        let recommendationReason = buildRecommendationReason(best: best, all: summaries)
        let headline = buildHeadline(
            runCount: orderedRuns.count,
            reachableRunCount: reachableRunCount,
            best: best,
            overallGrade: overallGrade
        )
        let insights = buildInsights(
            runs: orderedRuns,
            reachableRunCount: reachableRunCount,
            best: best,
            summaries: summaries,
            entriesByID: entriesByID
        )

        return RouteBenchmarkOverallAssessment(
            target: mergedTarget,
            runCount: orderedRuns.count,
            reachableRunCount: reachableRunCount,
            totalMeasuredSeconds: totalMeasuredSeconds,
            earliestRunAt: earliestAt,
            latestRunAt: latestAt,
            overallScore: overallScore,
            overallGrade: overallGrade,
            overallStability: overallStability,
            recommendedRoute: best,
            recommendationReason: recommendationReason,
            headline: headline,
            insights: insights,
            routeSummaries: summaries
        )
    }

    private static func routeSummaryPrecedes(
        _ lhs: RouteBenchmarkHistoricalRouteSummary,
        _ rhs: RouteBenchmarkHistoricalRouteSummary
    ) -> Bool {
        let lhsReachable = lhs.overallGrade != .unreachable
        let rhsReachable = rhs.overallGrade != .unreachable
        if lhsReachable != rhsReachable { return lhsReachable }
        if lhs.overallScore != rhs.overallScore { return lhs.overallScore > rhs.overallScore }
        if abs(lhs.availabilityPercent - rhs.availabilityPercent) > 0.1 {
            return lhs.availabilityPercent > rhs.availabilityPercent
        }
        let lhsLoss = lhs.meanUDPLossPercent ?? (lhs.candidate.kind.mediaTCPOnly ? 1.0 : 0.0)
        let rhsLoss = rhs.meanUDPLossPercent ?? (rhs.candidate.kind.mediaTCPOnly ? 1.0 : 0.0)
        if abs(lhsLoss - rhsLoss) > 0.05 { return lhsLoss < rhsLoss }
        let lhsRTT = lhs.meanRTTMilliseconds ?? .infinity
        let rhsRTT = rhs.meanRTTMilliseconds ?? .infinity
        if lhsRTT != rhsRTT { return lhsRTT < rhsRTT }
        return lhs.id < rhs.id
    }

    private static func summarizeRoute(
        candidate: RouteBenchmarkCandidate,
        newestFirstEntries: [RouteBenchmarkSavedEntry]
    ) -> RouteBenchmarkHistoricalRouteSummary {
        let attemptCount = newestFirstEntries.count
        var completedEntries: [RouteBenchmarkSavedEntry] = []
        var lastFailureReason: String?

        for entry in newestFirstEntries {
            switch entry.outcome {
            case .completed:
                if let eval = entry.evaluation, eval.grade != .unreachable {
                    completedEntries.append(entry)
                } else if lastFailureReason == nil {
                    lastFailureReason = entry.evaluation?.summary ?? "未收到可解码画面帧"
                }
            case let .failed(reason):
                if lastFailureReason == nil {
                    lastFailureReason = reason
                }
            case .skipped:
                break
            }
        }

        let completedCount = completedEntries.count
        let failedCount = attemptCount - completedCount
        let availabilityRate = attemptCount > 0 ? Double(completedCount) / Double(attemptCount) : 0
        let availabilityPercent = availabilityRate * 100.0

        guard completedCount > 0 else {
            let reasonText = lastFailureReason ?? "连接超时或不可达"
            return RouteBenchmarkHistoricalRouteSummary(
                candidate: candidate,
                attemptCount: attemptCount,
                completedCount: 0,
                failedCount: failedCount,
                availabilityPercent: 0,
                overallScore: 0,
                overallGrade: .unreachable,
                stability: .unreachable,
                minScore: nil,
                maxScore: nil,
                latestScore: nil,
                meanCompletedScore: nil,
                meanConnectMilliseconds: nil,
                meanFirstFrameMilliseconds: nil,
                meanRTTMilliseconds: nil,
                worstRTTMilliseconds: nil,
                meanUDPLossPercent: nil,
                worstUDPLossPercent: nil,
                meanFPS: nil,
                meanMegabits: nil,
                punchedDirectCount: 0,
                punchedDirectRatePercent: candidate.kind == .relayAutoPunch ? 0 : nil,
                tcpFallbackCount: 0,
                totalMeasuredSeconds: 0,
                lastFailureReason: reasonText,
                summary: "共测试 \(attemptCount) 次均未接通（最近原因：\(reasonText)）"
            )
        }

        let scores = completedEntries.compactMap { $0.evaluation?.score }
        let minScore = scores.min()
        let maxScore = scores.max()
        let latestScore = scores.first
        let meanCompleted = Double(scores.reduce(0, +)) / Double(scores.count)

        // Recency-weighted completed score: recent runs carry slightly higher weight (0.85^k).
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (idx, score) in scores.enumerated() {
            let weight = pow(0.85, Double(idx))
            weightedSum += Double(score) * weight
            weightTotal += weight
        }
        let recencyScore = weightTotal > 0 ? weightedSum / weightTotal : meanCompleted

        let variance: Double = if scores.count >= 2 {
            scores.reduce(0.0) { acc, value in
                let diff = Double(value) - meanCompleted
                return acc + diff * diff
            } / Double(scores.count)
        } else {
            0
        }
        let stddev = sqrt(variance)
        let spread = (maxScore ?? 0) - (minScore ?? 0)

        let metricsList = completedEntries.compactMap(\.metrics)
        let meanConnect = average(metricsList.compactMap(\.connectMilliseconds))
        let meanFirstFrame = average(metricsList.compactMap(\.firstFrameMilliseconds))

        let rtts = metricsList.compactMap { $0.udpRTTMeanMilliseconds ?? $0.controlRTTMeanMilliseconds }
        let peakRTTs = metricsList.compactMap {
            $0.udpRTTMaxMilliseconds ?? $0.controlRTTMaxMilliseconds ?? $0.udpRTTMeanMilliseconds ?? $0.controlRTTMeanMilliseconds
        }
        let meanRTT = average(rtts)
        let worstRTT = peakRTTs.max()

        let totalSettled = metricsList.reduce(0) { $0 + max(0, $1.settledFragments) }
        let totalLost = metricsList.reduce(0) { $0 + max(0, $1.lostFragments) }
        let meanLoss: Double? = if !candidate.kind.mediaTCPOnly {
            if totalSettled > 0 {
                Double(totalLost) / Double(totalSettled) * 100.0
            } else {
                average(metricsList.compactMap(\.udpLossMeanPercent))
            }
        } else {
            nil
        }
        let worstLoss: Double? = if !candidate.kind.mediaTCPOnly {
            metricsList.compactMap { $0.udpLossMaxPercent ?? $0.udpLossMeanPercent }.max()
        } else {
            nil
        }

        let meanFPS = average(metricsList.compactMap(\.averageFPS))
        let meanMbps = average(metricsList.compactMap(\.averageMegabits))
        let punchedCount = metricsList.filter(\.punchedDirect).count
        let punchedRate: Double? = candidate.kind == .relayAutoPunch
            ? Double(punchedCount) / Double(completedCount) * 100.0
            : nil
        let tcpFallbackCount = metricsList.filter(\.fellBackToTCP).count
        let measuredTotal = metricsList.reduce(0.0) { $0 + max(0, $1.measuredSeconds) }

        // Penalize multi-run volatility and intermittent connection failures.
        let volatilityPenalty = scores.count >= 2 && stddev > 4.0
            ? min(12.0, (stddev - 4.0) * 0.75)
            : 0.0
        let tailLossPenalty: Double = if !candidate.kind.mediaTCPOnly, let worstLoss, worstLoss >= 5.0 {
            min(4.0, (worstLoss - 5.0) * 0.35)
        } else {
            0.0
        }
        let baseAdjusted = max(1.0, recencyScore - volatilityPenalty - tailLossPenalty)
        let availabilityAdjusted = baseAdjusted * (0.35 + 0.65 * availabilityRate) - (1.0 - availabilityRate) * 25.0
        let overallScore = min(100, max(1, Int(availabilityAdjusted.rounded())))

        let overallGrade: RouteBenchmarkEvaluation.Grade = switch overallScore {
        case 85...: .excellent
        case 70..<85: .good
        case 52..<70: .fair
        default: .poor
        }

        let stability: RouteBenchmarkStability = if attemptCount == 1 {
            .singleSample
        } else if availabilityRate < 0.75 || spread >= 22 || stddev >= 10.0 {
            .unstable
        } else if availabilityRate < 1.0 || spread >= 12 || stddev >= 5.5 || (worstLoss ?? 0) >= 5.0 {
            .fluctuating
        } else if spread <= 6 && stddev <= 3.0 {
            .rockSolid
        } else {
            .stable
        }

        let summary = buildPerRouteHistoricalSummary(
            candidate: candidate,
            attemptCount: attemptCount,
            completedCount: completedCount,
            availabilityPercent: availabilityPercent,
            stability: stability,
            meanRTT: meanRTT,
            meanLoss: meanLoss,
            worstLoss: worstLoss,
            punchedCount: punchedCount,
            tcpFallbackCount: tcpFallbackCount,
            lastFailureReason: lastFailureReason
        )

        return RouteBenchmarkHistoricalRouteSummary(
            candidate: candidate,
            attemptCount: attemptCount,
            completedCount: completedCount,
            failedCount: failedCount,
            availabilityPercent: availabilityPercent,
            overallScore: overallScore,
            overallGrade: overallGrade,
            stability: stability,
            minScore: minScore,
            maxScore: maxScore,
            latestScore: latestScore,
            meanCompletedScore: meanCompleted,
            meanConnectMilliseconds: meanConnect,
            meanFirstFrameMilliseconds: meanFirstFrame,
            meanRTTMilliseconds: meanRTT,
            worstRTTMilliseconds: worstRTT,
            meanUDPLossPercent: meanLoss,
            worstUDPLossPercent: worstLoss,
            meanFPS: meanFPS,
            meanMegabits: meanMbps,
            punchedDirectCount: punchedCount,
            punchedDirectRatePercent: punchedRate,
            tcpFallbackCount: tcpFallbackCount,
            totalMeasuredSeconds: measuredTotal,
            lastFailureReason: lastFailureReason,
            summary: summary
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func buildPerRouteHistoricalSummary(
        candidate: RouteBenchmarkCandidate,
        attemptCount: Int,
        completedCount: Int,
        availabilityPercent: Double,
        stability: RouteBenchmarkStability,
        meanRTT: Double?,
        meanLoss: Double?,
        worstLoss: Double?,
        punchedCount: Int,
        tcpFallbackCount: Int,
        lastFailureReason: String?
    ) -> String {
        var parts: [String] = []
        if completedCount < attemptCount {
            parts.append(String(format: "连通率 %.0f%%（%d/%d 次成功）", availabilityPercent, completedCount, attemptCount))
            if let lastFailureReason {
                parts.append("曾因「\(lastFailureReason)」中断")
            }
        } else if attemptCount >= 2 {
            parts.append("\(attemptCount) 次测试全部接通（\(stability.title)）")
        }

        if candidate.kind == .relayAutoPunch {
            parts.append("NAT 打洞成功 \(punchedCount)/\(completedCount) 次")
        }
        if tcpFallbackCount > 0 && !candidate.kind.mediaTCPOnly {
            parts.append("UDP 自动降级 TCP \(tcpFallbackCount) 次")
        }

        if !candidate.kind.mediaTCPOnly, let meanLoss {
            if let worstLoss, worstLoss >= 5.0 {
                parts.append(String(format: "UDP 平均丢包 %.2f%%，峰值达 %.1f%%", meanLoss, worstLoss))
            } else if meanLoss < 0.1 {
                parts.append("UDP 长期接近零丢包")
            } else {
                parts.append(String(format: "UDP 平均丢包 %.2f%%", meanLoss))
            }
        } else if candidate.kind.mediaTCPOnly {
            parts.append("可靠 TCP 传输无分片丢失")
        }

        if let meanRTT {
            parts.append(String(format: "平均往返 %.0f ms", meanRTT))
        }

        return parts.isEmpty ? "已纳入历史质量统计" : parts.joined(separator: "；")
    }

    private static func buildHeadline(
        runCount: Int,
        reachableRunCount: Int,
        best: RouteBenchmarkHistoricalRouteSummary?,
        overallGrade: RouteBenchmarkEvaluation.Grade
    ) -> String {
        guard let best else {
            return "累计 \(runCount) 次历史测试均未能建立可用远程画面，请检查网络防火墙、端口映射或中继服务状态。"
        }
        if runCount == 1 {
            return "已保存首次实测记录，当前推荐「\(best.candidate.title)」（\(best.overallScore) 分 · \(overallGrade.title)）。建议在不同时段多次测试以积累稳定性评估。"
        }
        return String(
            format: "综合 %d 次历史实测（目标接通 %d/%d 次），长期最优线路为「%@」，总评 %d 分（%@ · %@）。",
            runCount,
            reachableRunCount,
            runCount,
            best.candidate.title,
            best.overallScore,
            overallGrade.title,
            best.stability.title
        )
    }

    private static func buildRecommendationReason(
        best: RouteBenchmarkHistoricalRouteSummary?,
        all: [RouteBenchmarkHistoricalRouteSummary]
    ) -> String {
        guard let best else {
            return "所有已测试线路均不可用"
        }
        var clauses: [String] = []
        clauses.append(String(format: "连通可用率 %.0f%%（%d/%d）", best.availabilityPercent, best.completedCount, best.attemptCount))
        if best.attemptCount >= 2 {
            clauses.append(best.stability.title)
        }
        if let rtt = best.meanRTTMilliseconds {
            clauses.append(String(format: "平均延迟 %.0f ms", rtt))
        }
        if !best.candidate.kind.mediaTCPOnly, let loss = best.meanUDPLossPercent {
            clauses.append(loss < 0.05 ? "长期零丢包" : String(format: "平均丢包 %.2f%%", loss))
        } else if best.candidate.kind.mediaTCPOnly {
            let lossyUDPExists = all.contains {
                !$0.candidate.kind.mediaTCPOnly && (($0.worstUDPLossPercent ?? 0) >= 3.0 || $0.tcpFallbackCount > 0)
            }
            clauses.append(lossyUDPExists ? "规避了历史 UDP 丢包与波动" : "全程可靠 TCP 传输")
        }
        if best.candidate.kind == .relayAutoPunch, let rate = best.punchedDirectRatePercent, rate > 0 {
            clauses.append(String(format: "打洞直连率 %.0f%%", rate))
        }
        let others = all.filter { $0.id != best.id && $0.overallGrade != .unreachable }
        if let runnerUp = others.first {
            clauses.append("长期综合优于「\(runnerUp.candidate.title)」（\(best.overallScore) vs \(runnerUp.overallScore) 分）")
        }
        return clauses.joined(separator: "，")
    }

    private static func buildInsights(
        runs: [RouteBenchmarkRunRecord],
        reachableRunCount: Int,
        best: RouteBenchmarkHistoricalRouteSummary?,
        summaries: [RouteBenchmarkHistoricalRouteSummary],
        entriesByID: [String: [RouteBenchmarkSavedEntry]]
    ) -> [String] {
        var insights: [String] = []

        if runs.count == 1 {
            insights.append("当前仅有 1 次实测样本；在早晚高峰或不同网络环境下再测 2–3 次，可自动识别间歇性丢包与晚高峰拥塞。")
        } else if reachableRunCount < runs.count {
            insights.append("在 \(runs.count) 次测试中有 \(runs.count - reachableRunCount) 次未能接通任何线路，请留意被控端休眠、网络切换或共享未开启。")
        }

        // Direct vs Relay comparison
        let directSummaries = summaries.filter { !$0.candidate.kind.usesRelay }
        let relaySummaries = summaries.filter { $0.candidate.kind.usesRelay }
        if !directSummaries.isEmpty && !relaySummaries.isEmpty {
            let bestDirect = directSummaries.first!
            let bestRelay = relaySummaries.first!
            if bestDirect.completedCount == 0 && bestRelay.completedCount > 0 {
                insights.append("历次测试中直连线路均不可达，中继线路可正常连通；跨网连接时建议直接使用「仅中继」策略省去直连超时等待。")
            } else if bestDirect.availabilityPercent < 80 && bestRelay.availabilityPercent >= 95 {
                insights.append(String(
                    format: "直连线路可用率仅 %.0f%%，而「%@」达 %.0f%%；外出或跨运营商时中继线路更可靠。",
                    bestDirect.availabilityPercent, bestRelay.candidate.title, bestRelay.availabilityPercent
                ))
            } else if bestDirect.overallScore >= bestRelay.overallScore + 8 && bestDirect.availabilityPercent >= 95 {
                insights.append("直连线路在历史延迟、吞吐和稳定性上均显著优于中继转发，同网或公网直通环境下优先使用直连。")
            }
        }

        // UDP packet loss vs TCP comparison
        let udpWithSamples = summaries.filter { !$0.candidate.kind.mediaTCPOnly && $0.completedCount > 0 }
        if let worstUDPRoute = udpWithSamples.max(by: { ($0.worstUDPLossPercent ?? 0) < ($1.worstUDPLossPercent ?? 0) }),
           let peakLoss = worstUDPRoute.worstUDPLossPercent {
            if peakLoss >= 3.5 {
                let tcpAlternative = summaries.first { $0.candidate.kind.mediaTCPOnly && $0.completedCount > 0 }
                if let tcpAlternative, tcpAlternative.overallScore >= worstUDPRoute.overallScore {
                    insights.append(String(
                        format: "「%@」在历史记录中曾出现 %.1f%% 的 UDP 峰值丢包（易触发卡顿与降画质），「%@」表现更稳健。",
                        worstUDPRoute.candidate.title, peakLoss, tcpAlternative.candidate.title
                    ))
                } else {
                    insights.append(String(
                        format: "「%@」曾检出最高 %.1f%% 的 UDP 分片丢包，若远程画面偶发卡顿可尝试切换对应 TCP 线路。",
                        worstUDPRoute.candidate.title, peakLoss
                    ))
                }
            } else if runs.count >= 2 && udpWithSamples.allSatisfy({ ($0.worstUDPLossPercent ?? 0) < 0.25 && $0.tcpFallbackCount == 0 }) {
                insights.append("历次实测 UDP 通道分片丢包极低（峰值 < 0.25%），适合保持 UDP 低延迟高帧率传输。")
            }
        }

        // NAT Auto-Punch insight
        if let punchSummary = summaries.first(where: { $0.candidate.kind == .relayAutoPunch && $0.completedCount > 0 }),
           let punchRate = punchSummary.punchedDirectRatePercent {
            if punchRate >= 80 {
                insights.append(String(
                    format: "中继自动打洞成功率达 %.0f%%（%d/%d 次），既保留中继高连通率又能获得端到端直连低延迟。",
                    punchRate, punchSummary.punchedDirectCount, punchSummary.completedCount
                ))
            } else if punchRate == 0 {
                insights.append("中继自动打洞在历史测试中均未打通直连（0/\(punchSummary.completedCount) 次），双端可能位于对称型 NAT 后，实际流量由中继节点转发。")
            } else {
                insights.append(String(
                    format: "中继自动打洞呈部分成功（%d/%d 次，%.0f%%），可能随本机所处 Wi‑Fi / 热点 NAT 类型变化而波动。",
                    punchSummary.punchedDirectCount, punchSummary.completedCount, punchRate
                ))
            }
        }

        // Trend on recommended route when >= 3 completed samples exist
        if let best,
           let entries = entriesByID[best.id] {
            let completedScores = entries.compactMap { entry -> Int? in
                guard entry.outcome == .completed, let eval = entry.evaluation, eval.grade != .unreachable else { return nil }
                return eval.score
            }
            if completedScores.count >= 3 {
                let latest = Double(completedScores[0])
                let priorMean = Double(completedScores.dropFirst().reduce(0, +)) / Double(completedScores.count - 1)
                if latest - priorMean >= 8.0 {
                    insights.append(String(
                        format: "「%@」最近一次得分（%.0f 分）较此前历史均值（%.0f 分）明显提升，当前网络时段质量较佳。",
                        best.candidate.title, latest, priorMean
                    ))
                } else if priorMean - latest >= 8.0 {
                    insights.append(String(
                        format: "「%@」最近一次得分（%.0f 分）较此前历史均值（%.0f 分）有所下滑，当前时段可能存在网络拥塞。",
                        best.candidate.title, latest, priorMean
                    ))
                }
            }
        }

        return insights
    }
}

public enum RouteBenchmarkHistoryPersistence {
    public struct LoadResult: Sendable {
        public let archive: RouteBenchmarkHistoryArchive
        public let protectsUnreadFile: Bool
        public let warningMessage: String?

        public init(
            archive: RouteBenchmarkHistoryArchive,
            protectsUnreadFile: Bool = false,
            warningMessage: String? = nil
        ) {
            self.archive = archive
            self.protectsUnreadFile = protectsUnreadFile
            self.warningMessage = warningMessage
        }
    }

    public static func load(from fileURL: URL) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return LoadResult(archive: RouteBenchmarkHistoryArchive())
            }
            return LoadResult(
                archive: RouteBenchmarkHistoryArchive(),
                protectsUnreadFile: true,
                warningMessage: "历史测速记录读取失败：\(error.localizedDescription)。已保留磁盘原文件，新增测速仅暂存内存。"
            )
        }

        do {
            let archive = try JSONDecoder().decode(RouteBenchmarkHistoryArchive.self, from: data)
            return LoadResult(archive: archive)
        } catch {
            return LoadResult(
                archive: RouteBenchmarkHistoryArchive(),
                protectsUnreadFile: true,
                warningMessage: "历史测速记录解析失败：\(error.localizedDescription)。已保留磁盘原文件，新增测速仅暂存内存。"
            )
        }
    }

    public static func save(_ archive: RouteBenchmarkHistoryArchive, to fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(archive)
        try data.write(to: fileURL, options: .atomic)
        _ = fileURL.path.withCString { chmod($0, S_IRUSR | S_IWUSR) }
    }
}
