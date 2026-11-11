import Foundation
import QuietDeskCore

@MainActor
final class RouteQualityBenchmarkRunner: ObservableObject, Identifiable {
    let id = UUID()
    let model: DeskModel
    let sourceRecord: ConnectionRecord?

    @Published var duration: RouteBenchmarkDuration = .seconds30
    @Published var results: [RouteBenchmarkResult]
    @Published private(set) var notes: [String]
    @Published private(set) var isRunning = false
    @Published private(set) var activeCandidateID: String?
    @Published private(set) var liveTelemetrySummary = ""
    @Published private(set) var errorMessage: String?

    private var runTask: Task<Void, Never>?
    private var skipCurrentRequested = false
    private var stopAllRequested = false

    init(model: DeskModel, record: ConnectionRecord? = nil) {
        self.model = model
        self.sourceRecord = record
        let plan = model.buildRouteBenchmarkPlan(for: record)
        self.results = plan.candidates.map { RouteBenchmarkResult(candidate: $0) }
        self.notes = plan.notes
    }

    var targetSummary: String {
        if let record = sourceRecord {
            let endpoint = ConnectionEntryPresentation.endpoint(record)
            let trimmed = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed)（\(endpoint)）"
            }
            return endpoint
        }
        let cleanAddress = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDevice = model.targetRelayDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAddress.isEmpty && model.relayEnabled && !cleanDevice.isEmpty {
            return "\(cleanAddress):\(model.port) ＋ 中继设备 \(cleanDevice.prefix(8))…"
        }
        if !cleanAddress.isEmpty {
            return "\(cleanAddress):\(model.port)"
        }
        if !cleanDevice.isEmpty {
            return "中继设备 \(cleanDevice)"
        }
        return "当前未填写连接目标"
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
        skipCurrentRequested = false
        stopAllRequested = false
        liveTelemetrySummary = ""
        let targetDuration = Double(duration.rawValue)
        let probeSeconds = min(QualityProbeControl.maximumDurationSeconds, duration.rawValue + 12)
        let preference = resolvedRecordPreference()

        runTask = Task { [weak self] in
            guard let self else { return }
            self.model.setRouteBenchmarkMode(true)
            var hadPriorConnectedSession = false

            for index in selectedIndices {
                if Task.isCancelled || self.stopAllRequested {
                    if case .pending = self.results[index].status {
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
        activeCandidateID = nil
        liveTelemetrySummary = ""
        isRunning = false
        model.setRouteBenchmarkMode(false)
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
