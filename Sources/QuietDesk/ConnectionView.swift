import SwiftUI
import QuietDeskCore

struct ConnectionView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var model: DeskModel
    @ObservedObject private var benchmarkStore: RouteQualityBenchmarkStore
    @ObservedObject private var portMappings: PortMappingManager
    @Binding var showOptions: Bool
    let openCaps: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    let openBenchmark: (ConnectionRecord?) -> Void
    var openRelayWorkspace: (() -> Void)? = nil
    var openPortMappingWorkspace: ((ConnectionRecord?) -> Void)? = nil
    let selectedRecord: ConnectionRecord?
    @Binding var showNewConnection: Bool
    @State private var showRelaySettings = false
    @State private var wakeConfigurationRecord: ConnectionRecord?

    init(
        models: DeskModels,
        model: DeskModel,
        showOptions: Binding<Bool>,
        openCaps: @escaping () -> Void,
        openTraffic: @escaping () -> Void,
        openEffects: @escaping () -> Void,
        openBenchmark: @escaping (ConnectionRecord?) -> Void,
        openRelayWorkspace: (() -> Void)? = nil,
        openPortMappingWorkspace: ((ConnectionRecord?) -> Void)? = nil,
        selectedRecord: ConnectionRecord? = nil,
        showNewConnection: Binding<Bool> = .constant(false)
    ) {
        self.models = models
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
        self.selectedRecord = selectedRecord
        self._showNewConnection = showNewConnection
    }

    private var locked: Bool { model.active || model.working || model.isRunningRouteBenchmark }

    private var pageFailure: String? {
        guard selectedRecord == nil || selectedRecord?.id == model.selectedConnectionID else { return nil }
        return model.connectionFailure
    }

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
            selectedRecord: selectedRecord,
            showNewConnection: $showNewConnection,
            locked: locked,
            failure: pageFailure,
            status: model.status,
            relayEnabled: model.relayEnabled,
            defaultStrategy: model.relayStrategy,
            retryDraft: { model.hubConnectionDraft },
            nodePicker: RelayNodePicker(model: model),
            showOptions: $showOptions,
            options: { benchmark in
                ConnectionSettingsView(
                    model: model,
                    openCaps: { showOptions = false; openCaps() },
                    openTraffic: openTraffic,
                    openEffects: openEffects,
                    openBenchmark: { showOptions = false; benchmark() }
                )
            },
            connect: { draft in
                performAttempt(with: draft) { models.connectFromHub() != nil }
            },
            cancel: { model.stop() },
            clearFailure: model.clearConnectionError,
            quickConnect: { record in
                performAttempt { models.quickConnect(record) != nil }
            },
            remove: model.removeConnection,
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
            openBenchmarkDraft: { draft in
                model.hubConnectionDraft = draft
                model.clearConnectionError()
                openBenchmark(nil)
            },
            benchmarkRecord: { openBenchmark($0) },
            openPortMappingRecord: { record in
                openPortMappingWorkspace?(record)
            },
            openPortMappingDraft: openPortMappingWorkspace.map { open in
                { draft in
                    model.hubConnectionDraft = draft
                    model.clearConnectionError()
                    open(nil)
                }
            },
            qualityBadge: historicalQualityBadge(for:),
            runningMappingsCount: { record in
                portMappings.rules.filter { $0.deviceID == record.id && portMappings.isEnabled($0.id) }.count
            },
            preFlight: preFlightSummary,
            lanScanning: model.lanScanning,
            discoveredLANHosts: model.discoveredLANHosts,
            lanScanStatus: model.lanScanStatus,
            toggleLANScan: { model.toggleLANScan() },
            dismissLANScan: { model.stopLANScan(clearResults: true) },
            hasSavedCredentialForDiscovered: { model.hasSavedCredential(for: $0) },
            selectDiscoveredHost: { discovered in
                performAttempt {
                    model.viewerCode = ""
                    model.targetRelayDeviceID = ""
                    return models.connectOrFillDiscoveredHost(discovered) != nil
                }
            },
            wakeRecord: { model.sendWakeOnLAN(for: $0) },
            configureWakeRecord: { wakeConfigurationRecord = $0 },
            wakeNotice: model.wakeStatusNotice,
            dismissWakeNotice: { model.wakeStatusNotice = nil },
            activeSessions: models.activeSessionSummaries,
            focusSession: { models.focusViewerSession(id: $0) },
            disconnectSession: { models.disconnectViewerSession(id: $0) },
            disconnectAllSessions: { models.disconnectAllViewerSessions() },
            sessionForRecord: { record in
                guard let existing = models.existingSession(for: record),
                      existing.active || existing.working || existing.reconnecting else { return nil }
                return existing.activeSessionSummary
            }
        )
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(enabled: model.relayEnabled, nodes: model.relayNodes, deviceID: model.relayDeviceID,
                              locked: model.relaySettingsLocked, measurements: model.relayNodeMeasurements,
                              loadTrust: model.relayCertificate, saveNode: model.saveRelayNode, save: model.saveRelayConfiguration)
        }
        .sheet(item: $wakeConfigurationRecord) { record in
            WakeOnLANConfigurationSheet(
                record: record,
                save: { configuration in
                    try model.saveWakeOnLAN(configuration, for: record.id)
                },
                sendWakeNow: { configuration in
                    try model.saveWakeOnLAN(configuration, for: record.id)
                    if let updated = model.connections.first(where: { $0.id == record.id }) {
                        model.sendWakeOnLAN(for: updated)
                    }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRelaySettings = false
            wakeConfigurationRecord = nil
        }
    }

    private func performAttempt(with draft: ConnectionEntryDraft? = nil, _ start: () -> Bool) -> ConnectionEntryAttemptFailure? {
        let previous = model.hubConnectionDraft
        if let draft { model.hubConnectionDraft = draft }
        model.clearConnectionError()
        guard !start() else { return nil }
        // Failed inputs stay in this sheet. The hub's last accepted inputs still serve mapping and diagnostics.
        let failure = ConnectionEntryAttemptFailure(
            draft: model.hubConnectionDraft,
            message: model.connectionFailure ?? "暂时无法发起连接，请稍后重试。"
        )
        model.hubConnectionDraft = previous
        model.clearConnectionError()
        return failure
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

private struct WakeOnLANConfigurationSheet: View {
    let record: ConnectionRecord
    let save: (WakeOnLANConfiguration?) throws -> Void
    let sendWakeNow: (WakeOnLANConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var macAddress: String
    @State private var broadcastAddress: String
    @State private var port: String
    @State private var errorMessage: String?

    init(
        record: ConnectionRecord,
        save: @escaping (WakeOnLANConfiguration?) throws -> Void,
        sendWakeNow: @escaping (WakeOnLANConfiguration) throws -> Void
    ) {
        self.record = record
        self.save = save
        self.sendWakeNow = sendWakeNow
        _macAddress = State(initialValue: record.wakeOnLAN?.macAddress.formatted ?? "")
        _broadcastAddress = State(initialValue: record.wakeOnLAN?.broadcastAddress ?? "")
        _port = State(initialValue: String(record.wakeOnLAN?.port ?? WakeOnLANConfiguration.defaultPort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配置网络唤醒")
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("目标设备：\(ConnectionEntryPresentation.title(record))（\(ConnectionEntryPresentation.endpoint(record))）")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("有线网卡物理 MAC 地址")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DeskPalette.secondary)
                    TextField("例如 AA:BB:CC:DD:EE:FF", text: $macAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("有线网卡物理 MAC 地址")
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("广播地址（可选，留空自动匹配子网）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DeskPalette.secondary)
                        TextField("默认自动发送至活跃子网广播与 255.255.255.255", text: $broadcastAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("广播地址，可留空")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UDP 端口")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DeskPalette.secondary)
                        TextField("9", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 86)
                            .accessibilityLabel("网络唤醒 UDP 端口")
                    }
                }
            }

            Text("通常需要目标 Mac 使用有线以太网，并在「系统设置 → 节能」开启「唤醒以供网络访问」。")
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if record.wakeOnLAN != nil {
                    Button("清除配置", role: .destructive) {
                        do {
                            try save(nil)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(DeskButtonStyle(.danger))
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存并立即唤醒") {
                    do {
                        let config = try parsedConfiguration()
                        try sendWakeNow(config)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                Button("保存") {
                    do {
                        let config = try parsedConfiguration()
                        try save(config)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .controlSize(.large)
        .deskSurface()
    }

    private func parsedConfiguration() throws -> WakeOnLANConfiguration {
        let mac = try MACAddress(parsing: macAddress)
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portNumber = UInt16(cleanPort), portNumber > 0 else {
            throw DeskError.invalid("网络唤醒 UDP 端口需为 1 到 65535 的整数")
        }
        return try WakeOnLANConfiguration(
            macAddress: mac,
            broadcastAddress: broadcastAddress,
            port: portNumber
        )
    }
}
