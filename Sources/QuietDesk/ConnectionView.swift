import SwiftUI
import QuietDeskCore

struct ConnectionView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject private var benchmarkStore: RouteQualityBenchmarkStore
    @ObservedObject private var portMappings: PortMappingManager
    @Binding var showOptions: Bool
    let openCaps: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    let openBenchmark: (ConnectionRecord?) -> Void
    var openRelayWorkspace: (() -> Void)? = nil
    var openPortMappingWorkspace: ((ConnectionRecord) -> Void)? = nil
    @State private var showRecords = false
    @State private var showRelaySettings = false

    init(
        model: DeskModel,
        showOptions: Binding<Bool>,
        openCaps: @escaping () -> Void,
        openTraffic: @escaping () -> Void,
        openEffects: @escaping () -> Void,
        openBenchmark: @escaping (ConnectionRecord?) -> Void,
        openRelayWorkspace: (() -> Void)? = nil,
        openPortMappingWorkspace: ((ConnectionRecord) -> Void)? = nil
    ) {
        self.model = model
        self._benchmarkStore = ObservedObject(wrappedValue: model.routeBenchmarkStore)
        self._portMappings = ObservedObject(wrappedValue: model.portMappings)
        self._showOptions = showOptions
        self.openCaps = openCaps
        self.openTraffic = openTraffic
        self.openEffects = openEffects
        self.openBenchmark = openBenchmark
        self.openRelayWorkspace = openRelayWorkspace
        self.openPortMappingWorkspace = openPortMappingWorkspace
    }

    private var locked: Bool { model.active || model.working }

    private var preFlightSummary: ConnectionPreFlightSummary {
        let capsTitle = !model.capsLockEnabled
            ? "未启用"
            : (model.capsLockRunning ? "本机监听已就绪" : "待权限或重检")
        let shortcutsTitle = model.localAccessibility && model.localInputMonitoring
            ? "权限已生效"
            : "待授予本机权限"
        let clipboardTitle = model.clipboardEnabled
            ? "⌘V 按需拉取 · 零空闲流量"
            : "已关闭自动同步"
        return ConnectionPreFlightSummary(
            capsLockTitle: capsTitle,
            capsLockReady: model.capsLockEnabled && model.capsLockRunning,
            shortcutsTitle: shortcutsTitle,
            shortcutsReady: model.localAccessibility && model.localInputMonitoring,
            clipboardTitle: clipboardTitle,
            clipboardReady: model.clipboardEnabled
        )
    }

    var body: some View {
        ConnectionEntryView(
            records: model.connections,
            locked: locked,
            failure: model.connectionFailure,
            status: model.status,
            relayEnabled: model.relayEnabled,
            address: $model.address,
            port: $model.port,
            code: $model.viewerCode,
            strategy: $model.relayStrategy,
            deviceID: $model.targetRelayDeviceID,
            nodePicker: RelayNodePicker(model: model),
            showOptions: $showOptions,
            options: ConnectionSettingsView(
                model: model,
                openCaps: { showOptions = false; openCaps() },
                openTraffic: openTraffic,
                openEffects: openEffects,
                openBenchmark: { showOptions = false; openBenchmark(nil) }
            ),
            connect: model.connect,
            cancel: { model.stop() },
            quickConnect: model.quickConnect,
            remove: model.removeConnection,
            manage: { showRecords = true },
            openOptions: { model.canvas.releaseControl(); showOptions = true },
            openCaps: openCaps,
            openRelay: {
                model.canvas.releaseControl()
                if let openRelayWorkspace {
                    openRelayWorkspace()
                } else {
                    showRelaySettings = true
                }
            },
            openTraffic: openTraffic,
            openBenchmark: { openBenchmark(nil) },
            benchmarkRecord: { openBenchmark($0) },
            openPortMappingRecord: { record in
                openPortMappingWorkspace?(record)
            },
            qualityBadge: historicalQualityBadge(for:),
            runningMappingsCount: { record in
                portMappings.rules.filter { $0.deviceID == record.id && portMappings.isEnabled($0.id) }.count
            },
            preFlight: preFlightSummary
        )
        .sheet(isPresented: $showRecords) {
            VStack(alignment: .leading, spacing: 16) {
                Text("管理连接记录").font(.title3.weight(.semibold))
                Text("配对码保存在本机私有文件，由当前账户的文件权限保护，未单独加密。移除记录会删除本机文件中对应的配对码；旧钥匙串条目保持不动。")
                    .font(.callout).foregroundStyle(.secondary)
                if model.connections.isEmpty {
                    ContentUnavailableView("没有连接记录", systemImage: "desktopcomputer")
                } else {
                    List(model.connections) { record in
                        HStack(spacing: 12) {
                            Image(systemName: ConnectionEntryPresentation.deviceSymbol(record))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ConnectionEntryPresentation.title(record)).font(.headline)
                                Text(ConnectionEntryPresentation.endpoint(record)).font(.caption).monospaced()
                                    .foregroundStyle(.secondary).lineLimit(2)
                                if let relay = record.relay {
                                    Text("\(ConnectionEntryPresentation.route(record)) · \(relay.deviceID.uuidString.lowercased())")
                                        .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text(record.lastConnected == .distantPast ? "已保存 · 尚未远控" : record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("测速…") { showRecords = false; openBenchmark(record) }
                            Button("连接") { showRecords = false; model.quickConnect(record) }
                            Button("移除") { model.removeConnection(record) }
                        }.padding(.vertical, 6)
                    }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack { Spacer(); Button("完成") { showRecords = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 560, height: 440)
        }
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(enabled: model.relayEnabled, nodes: model.relayNodes, deviceID: model.relayDeviceID,
                              locked: model.relaySettingsLocked, measurements: model.relayNodeMeasurements,
                              loadTrust: model.relayCertificate, saveNode: model.saveRelayNode, save: model.saveRelayConfiguration)
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRecords = false; showRelaySettings = false
        }
    }

    private func historicalQualityBadge(for record: ConnectionRecord) -> ConnectionRecordCardBadge? {
        let descriptor = model.buildRouteBenchmarkTargetDescriptor(for: record)
        guard descriptor.hasIdentity else { return nil }
        let runs = benchmarkStore.archive.runs(matching: descriptor)
        guard let assessment = RouteBenchmarkHistoryEvaluator.assess(runs: runs, targetOverride: descriptor) else {
            return nil
        }
        let rttSuffix: String
        if let rtt = assessment.recommendedRoute?.meanRTTMilliseconds, rtt.isFinite {
            let formatted = rtt < 10 ? String(format: "%.1f ms", rtt) : String(format: "%.0f ms", rtt)
            rttSuffix = " · \(formatted)"
        } else {
            rttSuffix = ""
        }
        let tone: ConnectionRecordCardBadge.Tone
        switch assessment.overallGrade {
        case .excellent: tone = .good
        case .good: tone = .info
        case .fair: tone = .caution
        case .poor, .unreachable: tone = .neutral
        }
        return ConnectionRecordCardBadge(
            text: "历史 \(assessment.overallScore) \(assessment.overallGrade.title)\(rttSuffix)",
            tone: tone
        )
    }
}
