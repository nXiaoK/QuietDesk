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
            : (model.capsLockRunning ? "已就绪" : "尚未就绪")
        let shortcutsTitle = model.localAccessibility && model.localInputMonitoring
            ? "已就绪"
            : "尚未就绪"
        let clipboardTitle = model.clipboardEnabled
            ? "已开启"
            : "已关闭"
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
            hasSavedCredentialForRecord: { record in
                (try? KeyStore.load(account: "remote." + record.id.uuidString)) != nil
            },
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
            },
            liveSessionForRecord: { record in
                guard let existing = models.existingSession(for: record), existing.connected else { return nil }
                let badge: String
                if !existing.effectiveViewerCanControl {
                    badge = "仅观看"
                } else if existing.controlling {
                    badge = "控制中"
                } else {
                    badge = "已连接"
                }
                return LiveDeviceSessionOverview(
                    sessionID: existing.sessionID,
                    badgeTitle: badge,
                    connected: existing.connected,
                    controlling: existing.controlling,
                    viewOnlyLocked: existing.viewerViewOnlyLock,
                    effectiveCanControl: existing.effectiveViewerCanControl,
                    resolution: existing.resolution,
                    qualitySummary: existing.videoQualitySummary,
                    frameRate: existing.frameRate,
                    latency: existing.latency,
                    transportLabel: existing.mediaTransportStatus,
                    toggleViewOnly: {
                        existing.setViewerViewOnlyLock(!existing.viewerViewOnlyLock)
                    },
                    enterFullScreen: {
                        models.focusViewerSession(existing)
                        if !existing.isFullScreen {
                            existing.toggleFullScreen()
                        }
                    }
                )
            },
            openReceivedFiles: {
                model.canvas.releaseControl()
                model.openReceivedFiles()
            },
            viewerViewOnlyLocked: model.viewerViewOnlyLock,
            toggleViewerViewOnly: {
                model.setViewerViewOnlyLock(!model.viewerViewOnlyLock)
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
    private enum Field: Hashable { case mac, broadcast, port }
    let record: ConnectionRecord
    let save: (WakeOnLANConfiguration?) throws -> Void
    let sendWakeNow: (WakeOnLANConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var macAddress: String
    @State private var broadcastAddress: String
    @State private var port: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

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
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("配置网络唤醒")
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("目标设备 \(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
            }

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("有线网卡 MAC 地址")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    TextField("例如 AA:BB:CC:DD:EE:FF", text: $macAddress)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .mac)
                        .deskInputBox(focused: focusedField == .mac)
                        .accessibilityLabel("有线网卡物理 MAC 地址")
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("广播地址（可选）")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                        TextField("留空自动匹配活跃子网", text: $broadcastAddress)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusedField, equals: .broadcast)
                            .deskInputBox(focused: focusedField == .broadcast)
                            .accessibilityLabel("广播地址，可留空")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UDP 端口")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                        TextField("9", text: $port)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusedField, equals: .port)
                            .deskInputBox(focused: focusedField == .port)
                            .frame(width: 98)
                            .accessibilityLabel("网络唤醒 UDP 端口")
                    }
                }
            }

            Text("通常需要有线以太网，并在目标 Mac 开启「唤醒以供网络访问」。发送魔术包不保证实际唤醒。")
                .font(.system(size: 12.5))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                DeskCalloutBox(message: errorMessage, symbol: "exclamationmark.circle", tone: .danger)
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
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 520)
        .deskSurface()
        .onAppear { focusedField = .mac }
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
