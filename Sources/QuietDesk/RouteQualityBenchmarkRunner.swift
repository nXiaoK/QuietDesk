import Combine
import Foundation
import QuietDeskCore

@MainActor
final class RouteQualityBenchmarkRunner: ObservableObject, Identifiable {
    enum ViewTab: String, CaseIterable, Identifiable {
        case currentRun
        case history

        var id: String { rawValue }
    }

    enum HistoryScope: Hashable {
        case currentTarget
        case historicalTarget(RouteBenchmarkTargetDescriptor)
        case allRecords
    }

    private struct ActiveRunContext {
        let id: UUID
        let startedAt: Date
        let durationSeconds: Int
        let target: RouteBenchmarkTargetDescriptor
    }

    let id = UUID()
    let model: DeskModel
    let store: RouteQualityBenchmarkStore
    let sourceRecord: ConnectionRecord?

    @Published var selectedTab: ViewTab
    @Published var historyScope: HistoryScope
    @Published var duration: RouteBenchmarkDuration = .seconds30
    @Published var results: [RouteBenchmarkResult]
    @Published private(set) var notes: [String]
    @Published private(set) var isRunning = false
    @Published private(set) var activeCandidateID: String?
    @Published private(set) var liveTelemetrySummary = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSavedRunID: UUID?

    private var runTask: Task<Void, Never>?
    private var activeRunContext: ActiveRunContext?
    private var skipCurrentRequested = false
    private var stopAllRequested = false
    private var storeCancellable: AnyCancellable?

    init(model: DeskModel, record: ConnectionRecord? = nil) {
        self.model = model
        self.store = model.routeBenchmarkStore
        self.sourceRecord = record
        let plan = model.buildRouteBenchmarkPlan(for: record)
        let candidateResults = plan.candidates.map { RouteBenchmarkResult(candidate: $0) }
        self.results = candidateResults
        self.notes = plan.notes

        let descriptor = model.buildRouteBenchmarkTargetDescriptor(for: record)
        let archive = model.routeBenchmarkStore.archive
        if descriptor.hasIdentity {
            self.historyScope = .currentTarget
        } else if let latest = archive.distinctTargets().first {
            self.historyScope = .historicalTarget(latest)
        } else {
            self.historyScope = .allRecords
        }

        if candidateResults.isEmpty && !archive.runs.isEmpty {
            self.selectedTab = .history
        } else {
            self.selectedTab = .currentRun
        }

        self.storeCancellable = model.routeBenchmarkStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var currentTargetDescriptor: RouteBenchmarkTargetDescriptor {
        model.buildRouteBenchmarkTargetDescriptor(for: sourceRecord)
    }

    var targetSummary: String {
        currentTargetDescriptor.displayName
    }

    var selectedCount: Int {
        results.filter(\.isSelected).count
    }

    var hasDirectCandidates: Bool {
        results.contains { !$0.candidate.kind.usesRelay }
    }

    var hasRelayCandidates: Bool {
        results.contains { $0.candidate.kind.usesRelay }
    }

    var recommendation: (winner: RouteBenchmarkResult, reason: String)? {
        RouteBenchmarkScorer.recommendBest(from: results)
    }

    var completedOrFailedCount: Int {
        results.filter {
            switch $0.status {
            case .completed, .failed: return true
            case .pending, .connecting, .measuring, .skipped: return false
            }
        }.count
    }

    // MARK: - Historical Records & Cumulative Assessment

    var storageWarningMessage: String? {
        store.warningMessage
    }

    var allHistoryRuns: [RouteBenchmarkRunRecord] {
        store.archive.runs
    }

    var currentTargetHistoryRuns: [RouteBenchmarkRunRecord] {
        let descriptor = currentTargetDescriptor
        guard descriptor.hasIdentity else { return [] }
        return store.archive.runs(matching: descriptor)
    }

    var currentTargetAssessment: RouteBenchmarkOverallAssessment? {
        let descriptor = currentTargetDescriptor
        guard descriptor.hasIdentity else { return nil }
        let matching = store.archive.runs(matching: descriptor)
        return RouteBenchmarkHistoryEvaluator.assess(runs: matching, targetOverride: descriptor)
    }

    var distinctHistoricalTargets: [RouteBenchmarkTargetDescriptor] {
        store.archive.distinctTargets()
    }

    var otherHistoricalTargets: [RouteBenchmarkTargetDescriptor] {
        let current = store.archive.unifiedTarget(for: currentTargetDescriptor)
        return distinctHistoricalTargets.filter { target in
            guard current.hasIdentity else { return true }
            return !current.matches(target)
        }
    }

    var badgeHistoryCount: Int {
        if currentTargetDescriptor.hasIdentity {
            let count = currentTargetHistoryRuns.count
            return count > 0 ? count : allHistoryRuns.count
        }
        return allHistoryRuns.count
    }

    var displayedHistoryRuns: [RouteBenchmarkRunRecord] {
        switch historyScope {
        case .currentTarget:
            if currentTargetDescriptor.hasIdentity {
                return currentTargetHistoryRuns
            }
            return allHistoryRuns
        case let .historicalTarget(target):
            return store.archive.runs(matching: target)
        case .allRecords:
            return allHistoryRuns
        }
    }

    var displayedAssessment: RouteBenchmarkOverallAssessment? {
        switch historyScope {
        case .currentTarget:
            if currentTargetDescriptor.hasIdentity {
                return currentTargetAssessment
            }
            if distinctHistoricalTargets.count <= 1 {
                return RouteBenchmarkHistoryEvaluator.assess(runs: allHistoryRuns)
            }
            return nil
        case let .historicalTarget(target):
            let runs = store.archive.runs(matching: target)
            return RouteBenchmarkHistoryEvaluator.assess(runs: runs, targetOverride: target)
        case .allRecords:
            if distinctHistoricalTargets.count <= 1 {
                return RouteBenchmarkHistoryEvaluator.assess(runs: allHistoryRuns)
            }
            return nil
        }
    }

    func deleteHistoryRun(_ id: UUID) {
        store.removeRun(id: id)
        if lastSavedRunID == id {
            lastSavedRunID = nil
        }
        reconcileHistoryScopeAfterDeletion()
    }

    func clearDisplayedHistory() {
        switch historyScope {
        case .currentTarget:
            if currentTargetDescriptor.hasIdentity {
                store.removeRuns(matching: currentTargetDescriptor)
            } else {
                store.removeAll()
            }
        case let .historicalTarget(target):
            store.removeRuns(matching: target)
        case .allRecords:
            store.removeAll()
        }
        lastSavedRunID = nil
        reconcileHistoryScopeAfterDeletion()
    }

    func clearAllHistory() {
        store.removeAll()
        lastSavedRunID = nil
        reconcileHistoryScopeAfterDeletion()
    }

    private func reconcileHistoryScopeAfterDeletion() {
        if case let .historicalTarget(selected) = historyScope,
           store.archive.runs(matching: selected).isEmpty {
            if currentTargetDescriptor.hasIdentity {
                historyScope = .currentTarget
            } else if let next = distinctHistoricalTargets.first {
                historyScope = .historicalTarget(next)
            } else {
                historyScope = .allRecords
            }
        }
    }

    func resolveConnectionRecord(
        for candidate: RouteBenchmarkCandidate,
        preferredTargetRecordID: UUID? = nil
    ) -> ConnectionRecord? {
        model.resolveConnectionRecordForBenchmarkCandidate(
            candidate,
            preferredRecord: sourceRecord,
            preferredRecordID: preferredTargetRecordID
        )
    }

    // MARK: - Benchmark Execution

    func reloadPlan() {
        guard !isRunning else { return }
        let previousSelection = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.isSelected) })
        let plan = model.buildRouteBenchmarkPlan(for: sourceRecord)
        results = plan.candidates.map { candidate in
            RouteBenchmarkResult(
                candidate: candidate,
                isSelected: previousSelection[candidate.id] ?? true
            )
        }
        notes = plan.notes
        errorMessage = nil
    }

    func toggleSelection(_ id: String) {
        guard !isRunning, let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].isSelected.toggle()
    }

    func selectAll() {
        guard !isRunning else { return }
        for index in results.indices { results[index].isSelected = true }
    }

    func selectDirectOnly() {
        guard !isRunning else { return }
        for index in results.indices {
            results[index].isSelected = !results[index].candidate.kind.usesRelay
        }
    }

    func selectRelayOnly() {
        guard !isRunning else { return }
        for index in results.indices {
            results[index].isSelected = results[index].candidate.kind.usesRelay
        }
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        selectedTab = .currentRun
        let selectedIndices = results.indices.filter { results[$0].isSelected }
        guard !selectedIndices.isEmpty else {
            errorMessage = "请至少勾选一条要测试的直连或中继线路"
            return
        }
        if model.active || model.working || model.connected || model.reconnecting {
            errorMessage = "当前已有活动连接，请先断开后再执行多线路测速"
            return
        }
        let key: PairingKey
        do {
            key = try model.resolveRouteBenchmarkPairingKey(for: sourceRecord)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        for index in results.indices {
            results[index].metrics = nil
            results[index].evaluation = nil
            results[index].status = results[index].isSelected ? .pending : .skipped
        }

        isRunning = true
        lastSavedRunID = nil
        skipCurrentRequested = false
        stopAllRequested = false
        liveTelemetrySummary = ""
        let targetDuration = Double(duration.rawValue)
        let probeSeconds = min(QualityProbeControl.maximumDurationSeconds, duration.rawValue + 12)
        let preference = resolvedRecordPreference()
        let snapshotTarget = currentTargetDescriptor
        activeRunContext = ActiveRunContext(
            id: UUID(),
            startedAt: Date(),
            durationSeconds: duration.rawValue,
            target: snapshotTarget
        )
        if snapshotTarget.hasIdentity {
            historyScope = .currentTarget
        }

        runTask = Task { [weak self] in
            guard let self else { return }
            self.model.setRouteBenchmarkMode(true)
            var hadPriorConnectedSession = false

            for index in selectedIndices {
                if Task.isCancelled || self.stopAllRequested {
                    if !self.results[index].status.isTerminal {
                        self.results[index].status = .skipped
                    }
                    continue
                }

                let candidate = self.results[index].candidate
                self.activeCandidateID = candidate.id
                self.skipCurrentRequested = false

                await self.measureRoute(
                    at: index,
                    candidate: candidate,
                    key: key,
                    preference: preference,
                    measureSeconds: targetDuration,
                    probeSeconds: probeSeconds,
                    hadPriorConnectedSession: &hadPriorConnectedSession
                )

                let remainingSelected = selectedIndices.contains { $0 > index && !self.stopAllRequested && !Task.isCancelled }
                if remainingSelected && hadPriorConnectedSession {
                    self.liveTelemetrySummary = "正在等待被控端释放上一条测速会话…"
                    try? await Task.sleep(for: .milliseconds(850))
                }
            }

            let stoppedEarly = self.stopAllRequested || Task.isCancelled
            self.persistActiveRunIfNeeded(stoppedEarly: stoppedEarly)
            self.activeCandidateID = nil
            self.liveTelemetrySummary = ""
            self.isRunning = false
            self.runTask = nil
            self.model.setRouteBenchmarkMode(false)
        }
    }

    func skipCurrentRoute() {
        guard isRunning else { return }
        skipCurrentRequested = true
    }

    func stopAll() {
        guard isRunning else { return }
        stopAllRequested = true
    }

    func shutdown() {
        stopAllRequested = true
        runTask?.cancel()
        runTask = nil
        persistActiveRunIfNeeded(stoppedEarly: true)
        activeCandidateID = nil
        liveTelemetrySummary = ""
        isRunning = false
        model.setRouteBenchmarkMode(false)
    }

    private func persistActiveRunIfNeeded(stoppedEarly: Bool) {
        guard let context = activeRunContext else { return }
        activeRunContext = nil

        for index in results.indices where !results[index].status.isTerminal {
            results[index].status = .skipped
        }

        guard let runRecord = RouteBenchmarkRunRecord.from(
            id: context.id,
            startedAt: context.startedAt,
            finishedAt: Date(),
            perRouteDurationSeconds: context.durationSeconds,
            stoppedEarly: stoppedEarly,
            target: context.target,
            results: results
        ) else {
            return
        }

        store.record(runRecord)
        lastSavedRunID = runRecord.id
    }

    private func resolvedRecordPreference() -> ConnectionRecord? {
        if let sourceRecord { return sourceRecord }
        let cleanAddress = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = UInt16(model.port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5908
        if !cleanAddress.isEmpty,
           let match = ConnectionStore.matching(model.connections, address: cleanAddress, port: parsedPort) {
            return match
        }
        return nil
    }

    private func measureRoute(
        at index: Int,
        candidate: RouteBenchmarkCandidate,
        key: PairingKey,
        preference: ConnectionRecord?,
        measureSeconds: Double,
        probeSeconds: Int,
        hadPriorConnectedSession: inout Bool
    ) async {
        let maxTransientBusyRetries = hadPriorConnectedSession ? 2 : 0
        var attempt = 0

        while true {
            attempt += 1
            results[index].status = .connecting
            liveTelemetrySummary = attempt > 1
                ? "正在重试握手（等待上一条会话释放）…"
                : "正在建立加密连接并协商媒体通道…"

            let attemptStartedAt = SessionClock.now
            do {
                try model.beginRouteBenchmarkAttempt(
                    candidate: candidate,
                    key: key,
                    recordPreference: preference,
                    probeDurationSeconds: probeSeconds
                )
            } catch {
                results[index].status = .failed(error.localizedDescription)
                return
            }

            let connectTimeout: TimeInterval = candidate.kind.usesRelay ? 15.0 : 12.0
            var connectTimedOut = false
            while !model.connected {
                if Task.isCancelled || stopAllRequested || skipCurrentRequested {
                    _ = model.finishRouteBenchmarkAttempt(reason: "已跳过当前线路")
                    results[index].status = .skipped
                    return
                }
                if !model.active && !model.working && !model.connected {
                    break
                }
                if SessionClock.now - attemptStartedAt >= connectTimeout {
                    connectTimedOut = true
                    break
                }
                liveTelemetrySummary = model.status
                try? await Task.sleep(for: .milliseconds(100))
            }

            if !model.connected {
                let reasonFallback = connectTimedOut
                    ? String(format: "超过 %.0f 秒未能建立连接", connectTimeout)
                    : "连接未建立"
                let snapshot = model.finishRouteBenchmarkAttempt(reason: reasonFallback)
                let failure = snapshot.failureReason ?? reasonFallback
                if attempt <= maxTransientBusyRetries,
                   SessionClock.now - attemptStartedAt < 4.5,
                   failure.contains("已有控制连接") {
                    try? await Task.sleep(for: .milliseconds(1_000))
                    continue
                }
                results[index].status = .failed(failure)
                return
            }

            // Connected! Begin timed quality & packet-loss measurement.
            hadPriorConnectedSession = true
            let measureStartedAt = SessionClock.now
            var droppedMidRun = false

            while true {
                let elapsed = max(0, SessionClock.now - measureStartedAt)
                results[index].status = .measuring(elapsed: min(elapsed, measureSeconds), duration: measureSeconds)
                let telemetry = model.liveRouteBenchmarkTelemetry
                if !telemetry.isEmpty {
                    liveTelemetrySummary = telemetry
                }
                if elapsed >= measureSeconds {
                    break
                }
                if skipCurrentRequested {
                    _ = model.finishRouteBenchmarkAttempt(reason: "已跳过当前线路")
                    results[index].status = .skipped
                    return
                }
                if stopAllRequested || Task.isCancelled {
                    if elapsed >= 3.0 {
                        break
                    } else {
                        _ = model.finishRouteBenchmarkAttempt(reason: "已停止线路测速")
                        results[index].status = .skipped
                        return
                    }
                }
                if !model.connected && !model.active && !model.working {
                    droppedMidRun = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }

            let snapshot = model.finishRouteBenchmarkAttempt(reason: "线路质量实测完成")
            if droppedMidRun {
                let failure = snapshot.failureReason ?? "测速过程中连接中断"
                results[index].status = .failed(failure)
                return
            }

            guard let report = snapshot.report else {
                results[index].status = .failed(snapshot.failureReason ?? "未采集到有效线路诊断数据")
                return
            }

            let metrics = RouteBenchmarkMetrics.from(
                report: report,
                candidate: candidate,
                connectMilliseconds: snapshot.connectMilliseconds,
                firstFrameMilliseconds: snapshot.firstFrameMilliseconds,
                finalRouteLabel: snapshot.finalRouteLabel,
                appliedQualitySummary: snapshot.appliedQualitySummary,
                hostSupportsQualityProbe: snapshot.hostSupportsQualityProbe
            )
            let evaluation = RouteBenchmarkScorer.evaluate(candidate: candidate, metrics: metrics)
            results[index].metrics = metrics
            results[index].evaluation = evaluation
            if evaluation.grade == .unreachable {
                results[index].status = .failed(evaluation.summary)
            } else {
                results[index].status = .completed
            }
            return
        }
    }
}
