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
    @State private var wakeConfigurationRecord: ConnectionRecord?

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
            preFlight: preFlightSummary,
            lanScanning: model.lanScanning,
            discoveredLANHosts: model.discoveredLANHosts,
            lanScanStatus: model.lanScanStatus,
            toggleLANScan: { model.toggleLANScan() },
            dismissLANScan: { model.stopLANScan(clearResults: true) },
            hasSavedCredentialForDiscovered: { model.hasSavedCredential(for: $0) },
            selectDiscoveredHost: { model.connectOrFillDiscoveredHost($0) },
            wakeRecord: { model.sendWakeOnLAN(for: $0) },
            configureWakeRecord: { wakeConfigurationRecord = $0 },
            wakeNotice: model.wakeStatusNotice,
            dismissWakeNotice: { model.wakeStatusNotice = nil }
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
                                if let wake = record.wakeOnLAN {
                                    Text("WOL: \(wake.macAddress.formatted)")
                                        .font(.caption).monospaced().foregroundStyle(.secondary)
                                }
                                Text(record.lastConnected == .distantPast ? "已保存 · 尚未远控" : record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if record.wakeOnLAN != nil {
                                Button("唤醒") { showRecords = false; model.sendWakeOnLAN(for: record) }
                            }
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
            showRecords = false; showRelaySettings = false; wakeConfigurationRecord = nil
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
            Text("配置网络唤醒（Wake-on-LAN）")
                .font(.title3.weight(.semibold))
            Text("目标设备：\(ConnectionEntryPresentation.title(record))（\(ConnectionEntryPresentation.endpoint(record))）")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("向局域网发送标准 IEEE 802.3 魔术包以唤醒睡眠中的台式 Mac。通常需要目标 Mac 使用有线以太网，并在「系统设置 → 节能」开启「唤醒以供网络访问」。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("有线网卡物理 MAC 地址")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("例如 AA:BB:CC:DD:EE:FF", text: $macAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("广播地址（可选，留空自动匹配子网）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("默认自动发送至活跃子网广播与 255.255.255.255", text: $broadcastAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UDP 端口")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("9", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 86)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
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
                }
                Spacer()
                Button("取消") { dismiss() }
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
                Button("保存") {
                    do {
                        let config = try parsedConfiguration()
                        try save(config)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
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
