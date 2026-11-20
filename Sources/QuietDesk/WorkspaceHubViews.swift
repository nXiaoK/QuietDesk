import AppKit
import QuietDeskCore
import SwiftUI

enum NetworkWorkspaceSubTab: String, CaseIterable, Hashable {
    case viewerMappings
    case relayNodes
    case hostApprovals
}

enum DiagnosticsWorkspaceSubTab: String, CaseIterable, Hashable {
    case benchmark
    case traffic
}

enum PreferencesWorkspaceSubTab: String, CaseIterable, Hashable {
    case keyboard
    case privacy
    case connectionDefaults
    case updates
}

struct NetworkWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel
    @ObservedObject var portMappings: PortMappingManager
    @ObservedObject private var benchmarkStore: RouteQualityBenchmarkStore
    @Binding var subTab: NetworkWorkspaceSubTab
    var preferredDeviceID: UUID? = nil
    let openBenchmarkForRecord: (ConnectionRecord?) -> Void

    init(
        viewer: DeskModel,
        host: DeskModel,
        portMappings: PortMappingManager,
        subTab: Binding<NetworkWorkspaceSubTab>,
        preferredDeviceID: UUID? = nil,
        openBenchmarkForRecord: @escaping (ConnectionRecord?) -> Void
    ) {
        self.viewer = viewer
        self.host = host
        self.portMappings = portMappings
        self._benchmarkStore = ObservedObject(wrappedValue: viewer.routeBenchmarkStore)
        self._subTab = subTab
        self.preferredDeviceID = preferredDeviceID
        self.openBenchmarkForRecord = openBenchmarkForRecord
    }

    private var runningCount: Int {
        portMappings.rules.filter { portMappings.isEnabled($0.id) }.count
    }

    private var activeDeviceRecord: ConnectionRecord? {
        if let preferredDeviceID, let match = viewer.connections.first(where: { $0.id == preferredDeviceID }) {
            return match
        }
        return viewer.connections.first { $0.id == viewer.selectedConnectionID } ?? viewer.connections.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DeskSegmentedTabs(
                    tabs: [
                        (.viewerMappings, runningCount > 0 ? "TCP 端口映射 (\(runningCount))" : "TCP 端口映射"),
                        (.relayNodes, viewer.relayEnabled ? "自托管中继节点 (\(viewer.relayNodes.count))" : "自托管中继节点"),
                        (.hostApprovals, portMappings.hostApprovalPending ? "本机被控映射授权 (\(portMappings.pendingTargets.count) 待确认)" : "本机被控映射授权")
                    ],
                    selection: $subTab
                )
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch subTab {
                    case .viewerMappings:
                        PortMappingView(
                            model: viewer,
                            manager: portMappings,
                            done: {},
                            embedded: true,
                            preferredDeviceID: preferredDeviceID
                        )

                        if let record = activeDeviceRecord {
                            deviceRouteSummaryCard(for: record)
                        }
                    case .relayNodes:
                        RelaySettingsView(
                            enabled: viewer.relayEnabled,
                            nodes: viewer.relayNodes,
                            deviceID: viewer.relayDeviceID,
                            locked: viewer.relaySettingsLocked,
                            measurements: viewer.relayNodeMeasurements,
                            embedded: true,
                            loadTrust: viewer.relayCertificate,
                            saveNode: viewer.saveRelayNode,
                            save: viewer.saveRelayConfiguration
                        )
                    case .hostApprovals:
                        PortMappingHostView(
                            model: host,
                            manager: host.portMappings,
                            done: {},
                            embedded: true
                        )
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(DeskPalette.canvasBackground)
    }

    @ViewBuilder
    private func deviceRouteSummaryCard(for record: ConnectionRecord) -> some View {
        let descriptor = viewer.buildRouteBenchmarkTargetDescriptor(for: record)
        let runs = descriptor.hasIdentity ? benchmarkStore.archive.runs(matching: descriptor) : []
        let assessment = RouteBenchmarkHistoryEvaluator.assess(runs: runs, targetOverride: descriptor)

        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    if let assessment {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DeskPalette.emerald.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Text("\(assessment.overallScore)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(DeskPalette.emerald)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DeskPalette.subtleFill)
                                .frame(width: 42, height: 42)
                            Image(systemName: "speedometer")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("「\(ConnectionEntryPresentation.title(record))」线路质量档案")
                                .font(.system(size: 13.5, weight: .bold))
                            if let assessment {
                                DeskPillBadge(
                                    text: "累计 \(assessment.runCount) 次实测 · \(assessment.overallGrade.title)",
                                    tint: DeskPalette.emerald
                                )
                            }
                        }
                        if let assessment, let best = assessment.recommendedRoute {
                            Text("长期推荐：\(best.candidate.title) — \(assessment.recommendationReason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("尚未执行过线路质量实测；实测可对比直连与各中继节点的真实帧率、延迟与 UDP 丢包。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Button("前往线路实测…") {
                        openBenchmarkForRecord(record)
                    }
                    .controlSize(.small)
                    .disabled(viewer.active || viewer.working)
                }

                if let assessment, !assessment.routeSummaries.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(assessment.routeSummaries.prefix(3).enumerated()), id: \.element.id) { idx, item in
                            let isBest = idx == 0 && item.overallGrade != .unreachable
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.candidate.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if isBest {
                                        Text("最佳")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(DeskPalette.emerald)
                                    }
                                }
                                HStack(spacing: 8) {
                                    if let rtt = item.meanRTTMilliseconds {
                                        Text(String(format: "延迟 %.1f ms", rtt))
                                    }
                                    if let loss = item.meanUDPLossPercent {
                                        Text(String(format: "丢包 %.1f%%", loss))
                                    }
                                    if let fps = item.meanFPS {
                                        Text(String(format: "%.0f fps", fps))
                                    }
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isBest ? DeskPalette.emerald.opacity(0.08) : DeskPalette.subtleFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isBest ? DeskPalette.emerald.opacity(0.35) : DeskPalette.hairline, lineWidth: 0.8)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DiagnosticsWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var history: TrafficHistoryFeed
    @Binding var subTab: DiagnosticsWorkspaceSubTab
    @Binding var benchmarkTargetRecord: ConnectionRecord?
    @State private var inlineRunner: RouteQualityBenchmarkRunner?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DeskSegmentedTabs(
                    tabs: [
                        (.benchmark, "连接与中继线路实测"),
                        (.traffic, "地址历史流量统计")
                    ],
                    selection: $subTab
                )
                Spacer()
                if subTab == .benchmark, !viewer.connections.isEmpty {
                    Menu {
                        Button("使用连接页当前填写目标") {
                            rebuildRunner(for: nil)
                        }
                        Divider()
                        ForEach(viewer.connections) { record in
                            Button("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))") {
                                rebuildRunner(for: record)
                            }
                        }
                    } label: {
                        Label(
                            benchmarkTargetRecord.map { "目标：\(ConnectionEntryPresentation.title($0))" } ?? "切换测速目标",
                            systemImage: "desktopcomputer"
                        )
                    }
                    .controlSize(.small)
                    .disabled(inlineRunner?.isRunning == true || viewer.active || viewer.working)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch subTab {
                case .benchmark:
                    if let runner = inlineRunner {
                        RouteQualityBenchmarkView(
                            runner: runner,
                            onConnectCandidate: { candidate, record in
                                runner.shutdown()
                                DispatchQueue.main.async {
                                    viewer.connectUsingBenchmarkCandidate(candidate, record: record)
                                }
                            },
                            onClose: {
                                runner.shutdown()
                            },
                            embedded: true
                        )
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .traffic:
                    TrafficStatisticsView(model: viewer, history: history, done: {}, embedded: true)
                }
            }
        }
        .background(DeskPalette.canvasBackground)
        .onAppear {
            if inlineRunner == nil {
                inlineRunner = RouteQualityBenchmarkRunner(model: viewer, record: benchmarkTargetRecord)
            }
        }
        .onChange(of: benchmarkTargetRecord?.id) { _, _ in
            rebuildRunner(for: benchmarkTargetRecord)
        }
        .onDisappear {
            inlineRunner?.shutdown()
        }
    }

    private func rebuildRunner(for record: ConnectionRecord?) {
        inlineRunner?.shutdown()
        benchmarkTargetRecord = record
        inlineRunner = RouteQualityBenchmarkRunner(model: viewer, record: record)
    }
}

struct PreferencesWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var updates: UpdateController
    @Binding var subTab: PreferencesWorkspaceSubTab
    let openBenchmark: () -> Void
    let openTraffic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                DeskSegmentedTabs(
                    tabs: [
                        (.keyboard, "键盘与系统快捷键"),
                        (.privacy, "被控端防窥与自动解锁"),
                        (.connectionDefaults, "连接、画质与诊断默认项"),
                        (.updates, updates.manifest != nil ? "软件更新 · 新版本" : "软件更新")
                    ],
                    selection: $subTab
                )
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch subTab {
                    case .keyboard:
                        DeskSurfaceCard(padding: 0, cornerRadius: 14) {
                            CapsLockSettingsView(model: viewer, done: {}, embedded: true)
                        }
                    case .privacy:
                        SessionEffectsView(model: viewer, done: {}, embedded: true)
                    case .connectionDefaults:
                        DeskSurfaceCard(padding: 0, cornerRadius: 14) {
                            ConnectionSettingsView(
                                model: viewer,
                                openCaps: { subTab = .keyboard },
                                openTraffic: openTraffic,
                                openEffects: { subTab = .privacy },
                                openBenchmark: openBenchmark,
                                embedded: true
                            )
                        }
                    case .updates:
                        UpdateSettingsPanel(controller: updates)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(DeskPalette.canvasBackground)
    }
}
