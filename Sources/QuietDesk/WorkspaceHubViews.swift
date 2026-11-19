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
}

struct NetworkWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel
    @ObservedObject var portMappings: PortMappingManager
    @Binding var subTab: NetworkWorkspaceSubTab
    let openBenchmarkForRecord: (ConnectionRecord?) -> Void

    private var runningCount: Int {
        portMappings.rules.filter { portMappings.isEnabled($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DeskSegmentedTabs(
                    tabs: [
                        (.viewerMappings, runningCount > 0 ? "TCP 端口映射 (\(runningCount))" : "TCP 端口映射"),
                        (.relayNodes, viewer.relayEnabled ? "自托管中继 (\(viewer.relayNodes.count))" : "自托管中继"),
                        (.hostApprovals, portMappings.hostApprovalPending ? "本机映射授权 (\(portMappings.pendingTargets.count) 待确认)" : "本机映射授权")
                    ],
                    selection: $subTab
                )
                Spacer()
                if subTab == .viewerMappings {
                    Button {
                        let selected = viewer.connections.first { $0.id == viewer.selectedConnectionID } ?? viewer.connections.first
                        openBenchmarkForRecord(selected)
                    } label: {
                        Label("测试目标线路质量…", systemImage: "speedometer")
                    }
                    .controlSize(.small)
                    .disabled(viewer.active || viewer.working)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch subTab {
                    case .viewerMappings:
                        DeskSurfaceCard(padding: 0) {
                            PortMappingView(model: viewer, manager: portMappings, done: {})
                                .frame(maxWidth: .infinity)
                        }
                    case .relayNodes:
                        DeskSurfaceCard(padding: 0) {
                            RelaySettingsView(
                                enabled: viewer.relayEnabled,
                                nodes: viewer.relayNodes,
                                deviceID: viewer.relayDeviceID,
                                locked: viewer.relaySettingsLocked,
                                measurements: viewer.relayNodeMeasurements,
                                loadTrust: viewer.relayCertificate,
                                saveNode: viewer.saveRelayNode,
                                save: viewer.saveRelayConfiguration
                            )
                            .frame(maxWidth: .infinity)
                        }
                    case .hostApprovals:
                        DeskSurfaceCard(padding: 0) {
                            PortMappingHostView(model: host, manager: host.portMappings, done: {})
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
            }
        }
        .background(DeskPalette.canvasBackground)
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
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .traffic:
                    TrafficStatisticsView(model: viewer, history: history, done: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        (.connectionDefaults, "连接、画质与诊断默认项")
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
                        DeskSurfaceCard(padding: 0) {
                            CapsLockSettingsView(model: viewer, done: {})
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .privacy:
                        DeskSurfaceCard(padding: 0) {
                            SessionEffectsView(model: viewer, done: {})
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .connectionDefaults:
                        DeskSurfaceCard(padding: 0) {
                            ConnectionSettingsView(
                                model: viewer,
                                openCaps: { subTab = .keyboard },
                                openTraffic: openTraffic,
                                openEffects: { subTab = .privacy },
                                openBenchmark: openBenchmark
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
            }
        }
        .background(DeskPalette.canvasBackground)
    }
}
