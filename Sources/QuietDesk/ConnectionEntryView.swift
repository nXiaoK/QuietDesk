import SwiftUI
import QuietDeskCore

struct ConnectionRecordCardBadge: Equatable {
    enum Tone: Equatable {
        case good, info, caution, neutral
    }
    let text: String
    let tone: Tone
}

struct ConnectionPreFlightSummary: Equatable {
    let capsLockTitle: String
    let capsLockReady: Bool
    let shortcutsTitle: String
    let shortcutsReady: Bool
    let clipboardTitle: String
    let clipboardReady: Bool
}

struct LiveDeviceSessionOverview {
    let sessionID: UUID
    let badgeTitle: String
    let connected: Bool
    let controlling: Bool
    let viewOnlyLocked: Bool
    let effectiveCanControl: Bool
    let resolution: String
    let qualitySummary: String
    let frameRate: String
    let latency: String
    let transportLabel: String
    let toggleViewOnly: () -> Void
    let enterFullScreen: () -> Void
}

struct ConnectionEntryDraft {
    var address = ""
    var port = "5908"
    var code = ""
    var strategy: RelayConnectionStrategy = .direct
    var deviceID = ""
    var recordID: UUID?
}

struct ConnectionEntryAttemptFailure {
    let draft: ConnectionEntryDraft
    let message: String
}

enum ConnectionEntryPresentation {
    enum Field: Hashable { case address, port, code, deviceID }
    static let recentLimit = 3

    static func matching(_ records: [ConnectionRecord], query: String, relayNodeNames: [String: String] = [:]) -> [ConnectionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        let nodeDigests = Set(relayNodeNames.compactMap { address, name -> String? in
            guard name.localizedStandardContains(query),
                  let endpoint = try? RelayEndpoint(address: address) else { return nil }
            return RelayNodeNaming.endpointDigest(endpoint)
        })
        return records.filter { record in
            var fields = [record.name, record.address, String(record.port)]
            if let customName = record.customName {
                fields.append(customName)
            }
            if let deviceID = record.deviceID {
                fields.append(deviceID.uuidString)
            }
            if let wake = record.wakeOnLAN {
                fields.append(wake.macAddress.formatted)
            }
            if let relay = record.relay {
                fields += [relay.deviceID.uuidString, relay.endpoint.host, String(relay.endpoint.port)]
                if let name = relayNodeNames[relay.endpoint.address] { fields.append(name) }
            }
            if let deviceID = record.knownRelayDeviceID { fields.append(deviceID.uuidString) }
            if let digests = record.hostRelayNodeDigests, !nodeDigests.isDisjoint(with: digests) { return true }
            return fields.contains { $0.localizedStandardContains(query) }
        }
    }

    static func visible(
        _ records: [ConnectionRecord], query: String, expanded: Bool, relayNodeNames: [String: String] = [:]
    ) -> [ConnectionRecord] {
        let matches = matching(records, query: query, relayNodeNames: relayNodeNames)
        return expanded || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? matches : Array(matches.prefix(recentLimit))
    }

    static func title(_ record: ConnectionRecord) -> String {
        let name = record.displayName
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (record.address.isEmpty ? "已保存的 Mac" : record.address) : name
    }

    static func endpoint(_ record: ConnectionRecord, relayNodeNames: [String: String] = [:]) -> String {
        if let relay = record.relay {
            return RelayNodeNaming.fullTitle(for: relay.endpoint, names: relayNodeNames)
        }
        return directEndpoint(record)
    }

    static func directEndpoint(_ record: ConnectionRecord) -> String {
        if let host = try? TailnetAddress.host(in: record.address) { return "\(host):\(record.port)" }
        let host = record.address.contains(":") && !record.address.hasPrefix("[") ? "[\(record.address)]" : record.address
        return "\(host):\(record.port)"
    }

    static func compactRelayIdentity(_ uuid: UUID) -> String {
        let raw = uuid.uuidString.lowercased()
        guard raw.count >= 12 else { return raw }
        return "\(raw.prefix(4))…\(raw.suffix(4))"
    }

    static func route(_ record: ConnectionRecord) -> String {
        if (try? TailnetAddress.host(in: record.address)) != nil { return "Tailscale" }
        return (record.relay?.strategy ?? .direct).title
    }

    static func deviceSymbol(_ record: ConnectionRecord) -> String {
        let lower = record.name.lowercased()
        if lower.contains("studio") { return "macstudio" }
        if lower.contains("mini") { return "macmini" }
        if lower.contains("book") || lower.contains("笔记本") || lower.contains("mbp") || lower.contains("mba") {
            return "laptopcomputer"
        }
        return "desktopcomputer"
    }

    static func savedQualityLabel(_ record: ConnectionRecord) -> String {
        if let video = record.videoSettings {
            var summary = video.summary
            if record.chromaSubsampling == .yuv444 {
                summary += " · 4:4:4 真彩"
            }
            return "已记忆：\(summary)"
        }
        return "画质：自动适配上限"
    }

    static func showsForm(hasRecords: Bool, expanded: Bool, failure: String?) -> Bool {
        !hasRecords || expanded || failure != nil
    }

    static func firstIncompleteField(relayEnabled: Bool, strategy: RelayConnectionStrategy, address: String,
                                     port: String, deviceID: String, code: String) -> Field? {
        if relayEnabled && strategy != .direct,
           UUID(uuidString: deviceID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil { return .deviceID }
        if !relayEnabled || strategy != .relay {
            let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty {
                if !relayEnabled || strategy == .direct { return .address }
            } else {
                if host.contains("://") || host.contains("/") { return .address }
                if host.lowercased().hasPrefix(TailnetAddress.prefix), (try? TailnetAddress.host(in: host)) == nil { return .address }
                if UInt16(port).map({ $0 > 0 }) != true { return .port }
            }
        }
        return (try? PairingKey(code: code)) == nil ? .code : nil
    }

    /// The draft with a whole invitation, pasted into any of its fields, spread over address, port and code;
    /// nil when `text` is not one, so that ordinary input stays exactly as typed.
    static func adopting(_ text: String, into draft: ConnectionEntryDraft, relayEnabled: Bool) -> ConnectionEntryDraft? {
        guard let invitation = ConnectionInvitation(text: text) else { return nil }
        var filled = draft
        filled.address = invitation.address
        filled.port = String(invitation.port)
        filled.code = invitation.code
        // The invitation names an address, which a relay-only connection has no field for.
        if relayEnabled, filled.strategy == .relay { filled.strategy = .direct }
        return filled
    }
}

struct ConnectionEntryView<NodePicker: View, Options: View>: View {
    let records: [ConnectionRecord]
    let selectedRecord: ConnectionRecord?
    @Binding var showNewConnection: Bool
    /// A record the sidebar asked to connect to, by a double-click, Return or its menu; taken once.
    var openRecordRequest: Binding<UUID?> = .constant(nil)
    let locked: Bool
    let failure: String?
    let status: String
    let relayEnabled: Bool
    let defaultStrategy: RelayConnectionStrategy
    let retryDraft: () -> ConnectionEntryDraft
    let nodePicker: NodePicker
    @Binding var showOptions: Bool
    let options: (_ columns: Bool, _ benchmark: @escaping () -> Void) -> Options
    let connect: (ConnectionEntryDraft) -> ConnectionEntryAttemptFailure?
    let cancel: () -> Void
    let clearFailure: () -> Void
    let quickConnect: (ConnectionRecord) -> ConnectionEntryAttemptFailure?
    let remove: (ConnectionRecord) -> Void
    let openOptions: () -> Void
    let openCaps: () -> Void
    let openRelay: () -> Void
    let openBenchmarkDraft: (ConnectionEntryDraft) -> Void
    let benchmarkRecord: (ConnectionRecord) -> Void
    let openPortMappingRecord: (ConnectionRecord) -> Void
    let openPortMappingDraft: ((ConnectionEntryDraft) -> Void)?
    let qualityBadge: (ConnectionRecord) -> ConnectionRecordCardBadge?
    let runningMappingsCount: (ConnectionRecord) -> Int
    let preFlight: ConnectionPreFlightSummary
    let lanScanning: Bool
    let discoveredLANHosts: [DiscoveredLANHost]
    let lanScanStatus: String
    let toggleLANScan: () -> Void
    let dismissLANScan: () -> Void
    let hasSavedCredentialForDiscovered: (DiscoveredLANHost) -> Bool
    var hasSavedCredentialForRecord: (ConnectionRecord) -> Bool = { _ in true }
    let selectDiscoveredHost: (DiscoveredLANHost) -> ConnectionEntryAttemptFailure?
    let wakeRecord: (ConnectionRecord) -> Void
    let configureWakeRecord: (ConnectionRecord) -> Void
    let wakeNotice: String?
    let dismissWakeNotice: () -> Void
    let activeSessions: [ActiveRemoteSessionSummary]
    let focusSession: (UUID) -> Void
    let disconnectSession: (UUID) -> Void
    let disconnectAllSessions: () -> Void
    let sessionForRecord: (ConnectionRecord) -> ActiveRemoteSessionSummary?
    var liveSessionForRecord: (ConnectionRecord) -> LiveDeviceSessionOverview? = { _ in nil }
    var selectRecord: ((ConnectionRecord) -> Void)? = nil
    var openReceivedFiles: () -> Void = {}
    var viewerViewOnlyLocked: Bool = false
    var toggleViewerViewOnly: () -> Void = {}
    var relayNodeNames: [String: String] = [:]
    var relayOptions: (ConnectionRecord) -> [RelaySwitchableNodeOption] = { _ in [] }
    var probeRelayOptions: (ConnectionRecord) -> Void = { _ in }
    var connectViaRelayNode: (ConnectionRecord, String?) -> String? = { _, _ in nil }

    @State private var sheet: Sheet?
    @State private var query = ""
    @State private var expandedRecords = false
    @State private var draft = ConnectionEntryDraft()
    @State private var draftTitle: String?
    @State private var draftFailure: String?
    @State private var relaySwitchFailure: String?
    @State private var discoveryFromComposer = false
    @State private var recordToRemove: ConnectionRecord?
    @State private var afterSheetDismissal: (() -> Void)?
    @FocusState private var focusedField: ConnectionEntryPresentation.Field?

    private enum Sheet: Equatable {
        case connection, credentials(title: String, endpoint: String), discovery, records, sessions, readiness
    }

    private struct RelayProbeSelection: Equatable {
        let recordID: UUID?
        let deviceID: UUID?
        let enabled: Bool
    }

    private var relayProbeSelection: RelayProbeSelection {
        RelayProbeSelection(recordID: selectedRecord?.id, deviceID: selectedRecord?.effectiveRelayDeviceID,
                            enabled: relayEnabled)
    }

    private var usesTailnet: Bool {
        !usesRelay && draft.address.lowercased().hasPrefix(TailnetAddress.prefix)
    }

    private var addressField: Binding<String> {
        Binding(get: { usesTailnet ? String(draft.address.dropFirst(TailnetAddress.prefix.count)) : draft.address },
                set: { value in
                    draft.address = usesTailnet && !value.lowercased().hasPrefix(TailnetAddress.prefix)
                        ? TailnetAddress.prefix + value : value
                })
    }

    private var usesRelay: Bool { relayEnabled && draft.strategy != .direct }
    private var showsAddress: Bool { !relayEnabled || draft.strategy != .relay }
    private var matches: [ConnectionRecord] {
        ConnectionEntryPresentation.matching(records, query: query, relayNodeNames: relayNodeNames)
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleRecords: [ConnectionRecord] {
        ConnectionEntryPresentation.visible(records, query: query, expanded: expandedRecords, relayNodeNames: relayNodeNames)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading
                if locked {
                    connectingBanner
                }
                if let wakeNotice, !wakeNotice.isEmpty {
                    DeskCalloutBox(message: wakeNotice, symbol: "bolt.horizontal", tone: .info) {
                        Button("收起", action: dismissWakeNotice)
                            .buttonStyle(DeskButtonStyle(.quiet))
                    }
                }
                if let failure {
                    failureNotice(failure)
                }

                if let selectedRecord {
                    deviceDetail(selectedRecord)
                } else if records.isEmpty {
                    firstUse
                        .padding(.top, 36)
                } else {
                    allDevices
                }

                if !activeSessions.isEmpty, selectedRecord == nil {
                    activeSessionsSection
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(DeskPalette.canvasBackground)
        .sheet(isPresented: Binding(
            get: { sheet != nil },
            set: { presented in if !presented { dismissSheet() } }
        ), onDismiss: finishSheetDismissal) {
            sheetContent
                .fixedSize(horizontal: false, vertical: true)
                .deskSurface()
                .modifier(recordRemovalAlert(inManagementSheet: true))
        }
        .modifier(recordRemovalAlert(inManagementSheet: false))
        .onChange(of: selectedRecord?.id) { _, _ in
            if sheet == nil { showOptions = false }
            relaySwitchFailure = nil
        }
        .onChange(of: relayProbeSelection, initial: true) { _, selection in
            if selection.enabled, let selectedRecord { probeRelayOptions(selectedRecord) }
        }
        .onChange(of: showNewConnection, initial: true) { _, requested in
            if requested { openNewConnection() }
        }
        .onChange(of: openRecordRequest.wrappedValue, initial: true) { _, id in
            guard let id else { return }
            openRecordRequest.wrappedValue = nil
            // The same path as the page's own button: it switches to a running session, or asks for what is missing.
            guard !locked, sheet == nil, let record = records.first(where: { $0.id == id }) else { return }
            connectSavedDevice(record)
        }
        .onDisappear {
            showOptions = false
            dismissSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            afterSheetDismissal = nil
            dismissSheet()
        }
    }

    // MARK: - Page Heading

    private var pageHeading: some View {
        HStack(spacing: 10) {
            if let selectedRecord {
                let session = sessionForRecord(selectedRecord)
                let live = liveSessionForRecord(selectedRecord)
                Image(systemName: ConnectionEntryPresentation.deviceSymbol(selectedRecord))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(DeskPalette.accent)
                    .frame(width: 45, height: 45)
                    .background(DeskPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ConnectionEntryPresentation.title(selectedRecord))
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        Text(selectedRecord.relay.map { "中继设备标识 · " + ConnectionEntryPresentation.compactRelayIdentity($0.deviceID) }
                             ?? ConnectionEntryPresentation.endpoint(selectedRecord, relayNodeNames: relayNodeNames))
                            .font(.system(size: 11.5))
                            .foregroundStyle(DeskPalette.secondary)
                            .lineLimit(1)
                        DeskPillBadge(
                            text: live?.badgeTitle ?? session?.statusLabel ?? "未连接",
                            tint: live != nil ? DeskPalette.emerald : session != nil ? DeskPalette.amber : DeskPalette.secondary
                        )
                    }
                }
                Spacer(minLength: 4)
                if let live {
                    Button(action: live.enterFullScreen) {
                        Image(systemName: "viewfinder")
                    }
                    .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                    .help("进入全屏")
                    .accessibilityLabel("进入全屏")
                }
                Button(session == nil ? "连接设备" : "打开会话窗口") { connectSavedDevice(selectedRecord) }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(locked)
                deviceActions(selectedRecord, live: live)
                    .disabled(locked)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(records.isEmpty ? "第一次使用 QuietDesk" : "全部设备")
                        .font(.system(size: 26, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    if !records.isEmpty {
                        Text("\(records.count) 条本机连接记录")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskPalette.secondary)
                    }
                }
                Spacer(minLength: 6)
                if !records.isEmpty {
                    Button("扫描局域网", action: openDiscovery)
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .disabled(locked)
                    Button(action: openNewConnection) { Label("新建连接", systemImage: "plus") }
                        .buttonStyle(DeskButtonStyle(.primary))
                        .disabled(locked)
                }
            }
            if !activeSessions.isEmpty {
                Button {
                    sheet = .sessions
                } label: {
                    Label("活动会话（\(activeSessions.count)）", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(DeskButtonStyle(.secondary, compact: true))
            }
        }
        .frame(minHeight: 45)
    }

    // MARK: - First-Use Empty State (Page 9)

    private var firstUse: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(DeskPalette.muted.opacity(0.76))
                .accessibilityHidden(true)
            Text("从另一台 Mac 开启共享")
                .font(.system(size: 22, weight: .bold))
            Text("在被控 Mac 的「本机共享」里点“复制连接信息”，回到这里新建连接并粘贴。")
                .font(.system(size: 13.5))
                .foregroundStyle(DeskPalette.secondary)

            Button(action: openNewConnection) {
                Text("新建连接")
                    .frame(minWidth: 124)
            }
            .buttonStyle(DeskButtonStyle(.primary))
            .disabled(locked)
            .padding(.top, 10)

            Text("同一局域网可扫描开启发现广播的设备。")
                .font(.system(size: 12.5))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.top, 8)

            Button(action: openDiscovery) {
                Text("扫描局域网")
                    .frame(minWidth: 124)
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(locked)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - All Devices Table (Pages 6 & 61)

    private var allDevices: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                DeskSearchField(
                    placeholder: "搜索名称、地址或设备 ID…",
                    text: $query,
                    accessibilityTitle: "搜索连接记录"
                )
                if records.count > ConnectionEntryPresentation.recentLimit, !searching {
                    DeskSegmentedTabs(
                        tabs: [(false, "最近 \(ConnectionEntryPresentation.recentLimit) 台"),
                               (true, "全部 \(records.count) 台")],
                        selection: $expandedRecords
                    )
                    .frame(width: 174)
                }
            }

            if matches.isEmpty {
                DeskSurfaceCard(padding: 36, cornerRadius: 11) {
                    VStack(spacing: 10) {
                        Text("没有匹配的连接记录")
                            .font(.system(size: 18, weight: .semibold))
                        Text("尝试名称、域名、IP、MAC 或完整标识，或清除搜索。")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                        Button("清除搜索") { query = "" }
                            .buttonStyle(DeskButtonStyle(.secondary))
                            .padding(.top, 4)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
            } else {
                recordTable(visibleRecords, inManagementSheet: false)
            }

            HStack {
                Text(searching
                     ? "找到 \(matches.count) 条，共 \(records.count) 条记录"
                     : "已显示 \(visibleRecords.count) 条本机记录")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                Spacer()
                Button("管理记录") { sheet = .records }
                    .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                    .disabled(locked)
                Button("连接前就绪状态") { sheet = .readiness }
                    .buttonStyle(DeskButtonStyle(.quiet))
            }
        }
    }

    // MARK: - Selected Device Stage (Pages 1 & 8)

    private func deviceDetail(_ record: ConnectionRecord) -> some View {
        let session = sessionForRecord(record)
        let live = liveSessionForRecord(record)
        let viewOnlyActive = live?.viewOnlyLocked ?? viewerViewOnlyLocked

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                desktopPanel(record: record, live: live, session: session, viewOnlyActive: viewOnlyActive)
                    .frame(minWidth: 365)
                deviceInspector(record: record, live: live, session: session, alignedHeight: true)
                    .frame(width: showOptions ? 278 : 234)
            }
            VStack(alignment: .leading, spacing: 12) {
                desktopPanel(record: record, live: live, session: session, viewOnlyActive: viewOnlyActive, compact: true)
                deviceInspector(record: record, live: live, session: session)
            }
        }
    }

    private func desktopPanel(
        record: ConnectionRecord, live: LiveDeviceSessionOverview?, session: ActiveRemoteSessionSummary?,
        viewOnlyActive: Bool, compact: Bool = false
    ) -> some View {
        DeskSurfaceCard(padding: 12, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("远程桌面").font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let live {
                        connectedDeviceStage(record: record, live: live)
                    } else if let session {
                        connectingDeviceStage(record: record, session: session)
                    } else {
                        idleDeviceStage(compact: compact)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Divider()
                stageActionDock(record: record, live: live, viewOnlyActive: viewOnlyActive)
            }
        }
    }

    private func connectedDeviceStage(record: ConnectionRecord, live: LiveDeviceSessionOverview) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    DeskPalette.subtleFill,
                    DeskPalette.insetBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(DeskPalette.coral.opacity(0.75)).frame(width: 8, height: 8)
                        Circle().fill(DeskPalette.amber.opacity(0.75)).frame(width: 8, height: 8)
                        Circle().fill(DeskPalette.emerald.opacity(0.75)).frame(width: 8, height: 8)
                    }
                    .accessibilityHidden(true)

                    Text("\(ConnectionEntryPresentation.title(record)) · 实时远控会话")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        if !live.transportLabel.isEmpty {
                            Text(live.transportLabel)
                        }
                        if !live.latency.isEmpty {
                            Text(live.latency)
                        }
                        if !live.frameRate.isEmpty {
                            Text(live.frameRate)
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DeskPalette.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(DeskPalette.cardBackground.opacity(0.68))

                Divider()

                Spacer(minLength: 28)

                VStack(spacing: 14) {
                    Button {
                        focusSession(live.sessionID)
                    } label: {
                        HStack(spacing: 14) {
                            Text("进入桌面")
                                .font(.system(size: 15, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(DeskPalette.ink)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            DeskPalette.cardBackground,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("进入 \(ConnectionEntryPresentation.title(record)) 的远程桌面窗口")

                    Text(live.controlling ? "正在独立窗口中控制此设备" : "远控会话已在独立窗口运行，点按切到桌面")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                }

                Spacer(minLength: 28)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 310)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
    }

    private func connectingDeviceStage(record: ConnectionRecord, session: ActiveRemoteSessionSummary) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(session.reconnecting ? "连接中断，正在重连…" : "正在建立加密连接…")
                .font(.system(size: 19, weight: .semibold))
            Text(session.statusLabel)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
            HStack(spacing: 10) {
                Button("打开会话窗口") { focusSession(session.id) }
                    .buttonStyle(DeskButtonStyle(.primary))
                Button("取消连接", role: .destructive) { disconnectSession(session.id) }
                    .buttonStyle(DeskButtonStyle(.danger))
            }
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, minHeight: 310)
        .background(DeskPalette.insetBackground)
    }

    private func idleDeviceStage(compact: Bool) -> some View {
        ZStack {
            DeskPalette.insetBackground
            Canvas { context, size in
                for x in stride(from: CGFloat(14), to: size.width, by: 19) {
                    for y in stride(from: CGFloat(14), to: size.height, by: 19) {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)),
                            with: .color(DeskPalette.accent.opacity(0.20))
                        )
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 20) {
                ZStack {
                    previewWindow.offset(x: -32, y: -18)
                    previewWindow.offset(x: 32, y: 17)
                    Circle().fill(DeskPalette.accent).frame(width: 7, height: 7)
                        .offset(x: -13, y: 12)
                }
                .frame(width: 160, height: 105)
                .accessibilityHidden(true)
                Text("连接后显示远程桌面")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DeskPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 244 : 342)
    }

    private var previewWindow: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(DeskPalette.cardBackground.opacity(0.54))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DeskPalette.accent.opacity(0.46), lineWidth: 1.5) }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in
                        Circle().fill(DeskPalette.accent.opacity(0.45)).frame(width: 3.5, height: 3.5)
                    }
                }
                .padding(8)
            }
            .frame(width: 94, height: 61)
    }

    private func stageActionDock(
        record: ConnectionRecord,
        live: LiveDeviceSessionOverview?,
        viewOnlyActive: Bool
    ) -> some View {
        HStack(spacing: 0) {
            dockButton("文件接收", symbol: "folder", action: openReceivedFiles)
            dockDivider
            dockButton(
                viewOnlyActive ? "仅观看已开" : "仅观看",
                symbol: viewOnlyActive ? "eye.fill" : "eye",
                highlighted: viewOnlyActive,
                action: { if let live { live.toggleViewOnly() } else { toggleViewerViewOnly() } }
            )
            dockDivider
            dockButton("端口映射", symbol: "point.3.connected.trianglepath.dotted") {
                openPortMappingRecord(record)
            }
            dockDivider
            dockButton("连接选项", symbol: "slider.horizontal.3", highlighted: showOptions) {
                if showOptions { showOptions = false } else { openOptions() }
            }
        }
        .disabled(locked)
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(DeskPalette.hairline)
            .frame(width: 1, height: 18)
            .accessibilityHidden(true)
    }

    private func dockButton(
        _ title: String,
        symbol: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(highlighted ? DeskPalette.accent : DeskPalette.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: highlighted ? .semibold : .medium))
                    .foregroundStyle(highlighted ? DeskPalette.accent : DeskPalette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 33)
            .background(highlighted ? DeskPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deviceActions(_ record: ConnectionRecord, live: LiveDeviceSessionOverview?) -> some View {
        Menu {
            Button("打开接收文件目录", action: openReceivedFiles)
            Button("测试线路质量…") { benchmarkRecord(record) }
                .disabled(live != nil)
            if record.wakeOnLAN != nil {
                Button("发送网络唤醒包") { wakeRecord(record) }
                Button("编辑网络唤醒…") { configureWakeRecord(record) }
            } else {
                Button("配置网络唤醒…") { configureWakeRecord(record) }
            }
            Button("配置 TCP 端口映射…") { openPortMappingRecord(record) }
            Button("连接前就绪状态…") { sheet = .readiness }
            if let live {
                Divider()
                Button("断开远程连接", role: .destructive) { disconnectSession(live.sessionID) }
            }
            Divider()
            Button("移除此记录…", role: .destructive) { recordToRemove = record }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 29)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 31)
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DeskPalette.hairline) }
        .help("更多连接操作")
        .accessibilityLabel("更多连接操作")
    }

    private func deviceInspector(
        record: ConnectionRecord, live: LiveDeviceSessionOverview?, session: ActiveRemoteSessionSummary?,
        alignedHeight: Bool = false
    ) -> some View {
        DeskSurfaceCard(padding: 14, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(showOptions ? "连接选项" : "连接概况")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    if showOptions {
                        Button { showOptions = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                            .accessibilityLabel("关闭连接选项")
                    }
                }
                if showOptions {
                    Text("对所有连接生效").font(.caption).foregroundStyle(DeskPalette.secondary)
                    ScrollView {
                        options(false) { benchmarkRecord(record) }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 425)
                } else {
                    detailRow("连接方式", ConnectionEntryPresentation.route(record))
                    detailRow(record.relay == nil ? "连接地址" : "中继节点",
                              ConnectionEntryPresentation.endpoint(record, relayNodeNames: relayNodeNames))
                    let nodes = relayOptions(record)
                    if !nodes.isEmpty {
                        relaySwitching(record, nodes: nodes)
                    }
                    if let live {
                        let summary = [live.resolution, live.qualitySummary].filter { !$0.isEmpty }.joined(separator: " · ")
                        detailRow("当前画质", summary.isEmpty ? "正在等待画面" : summary)
                    } else {
                        detailRow("默认画质", ConnectionEntryPresentation.savedQualityLabel(record))
                    }
                    detailRow("配对记录", hasSavedCredentialForRecord(record) ? "已保存" : "缺少配对码")
                    if let badge = qualityBadge(record) {
                        DeskPillBadge(text: badge.text, tint: qualityTint(badge.tone), monospaced: true)
                    }
                    let mappings = runningMappingsCount(record)
                    if mappings > 0 {
                        DeskPillBadge(text: "\(mappings) 条映射启用中", tint: DeskPalette.emerald)
                    }
                    HStack(spacing: 5) {
                        if let session {
                            Button("打开独立窗口") { focusSession(session.id) }
                                .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                        } else {
                            Button("测试线路") { benchmarkRecord(record) }
                                .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                                .disabled(locked)
                        }
                        Button("就绪状态") { sheet = .readiness }
                            .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                    }
                }
            }
            .frame(minHeight: alignedHeight ? 420 : 0, alignment: .topLeading)
        }
    }

    private func relaySwitching(_ record: ConnectionRecord, nodes: [RelaySwitchableNodeOption]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("中继节点切换").font(.system(size: 11)).foregroundStyle(DeskPalette.secondary)
            Menu("选择线路并连接…") {
                if !record.address.isEmpty {
                    Button("使用原地址连接（\(ConnectionEntryPresentation.directEndpoint(record))）") {
                        relaySwitchFailure = connectViaRelayNode(record, nil)
                    }
                    Divider()
                }
                Button {
                    relaySwitchFailure = connectViaRelayNode(record, "")
                } label: {
                    Label("自动选择共有最快中继", systemImage: "bolt")
                }
                ForEach(nodes) { node in
                    Button {
                        relaySwitchFailure = connectViaRelayNode(record, node.id)
                    } label: {
                        Label(relaySwitchLabel(node), systemImage: relaySwitchSymbol(node.peerMatch))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(locked)
            if let relaySwitchFailure {
                Text(relaySwitchFailure)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func relaySwitchLabel(_ node: RelaySwitchableNodeOption) -> String {
        let name = RelayNodeNaming.shortTitle(
            for: node.endpoint, names: node.customName.map { [node.id: $0] } ?? [:])
        return [name, node.latencyLabel, node.peerMatch.badgeText].compactMap { $0 }.joined(separator: " · ")
    }

    private func relaySwitchSymbol(_ match: RelayPeerNodeMatch) -> String {
        switch match {
        case .onlineShared: return "checkmark.circle.fill"
        case .notConfiguredOnHost, .unreachable: return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(label).font(.system(size: 11)).foregroundStyle(DeskPalette.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .textSelection(.enabled)
        }
    }

    // MARK: - Record Table (Pages 6 & 61)

    private func recordTable(_ records: [ConnectionRecord], inManagementSheet: Bool) -> some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    tableCell("设备", width: 152)
                    tableCell("连接端点")
                    tableCell(inManagementSheet ? "凭据" : "最近连接", width: inManagementSheet ? 88 : 162)
                    tableCell("操作", width: 128)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(DeskPalette.insetBackground)

                ForEach(records) { record in
                    let session = sessionForRecord(record)
                    let credentialSaved = hasSavedCredentialForRecord(record)
                    Divider()
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            Image(systemName: ConnectionEntryPresentation.deviceSymbol(record))
                                .font(.system(size: 13))
                                .foregroundStyle(DeskPalette.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            if !inManagementSheet, let selectRecord {
                                Button { selectRecord(record) } label: {
                                    tableCell(ConnectionEntryPresentation.title(record)).fontWeight(.medium)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DeskPalette.accent)
                                .disabled(locked)
                            } else {
                                tableCell(ConnectionEntryPresentation.title(record)).fontWeight(.medium)
                            }
                        }
                        .frame(width: 152, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            if let relay = record.relay {
                                tableCell("设备标识 · \(ConnectionEntryPresentation.compactRelayIdentity(relay.deviceID))")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .help("\(relay.endpoint.address) · \(relay.deviceID.uuidString.lowercased())")
                                tableCell(RelayNodeNaming.fullTitle(for: relay.endpoint, names: relayNodeNames))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DeskPalette.muted)
                            } else {
                                tableCell(ConnectionEntryPresentation.endpoint(record, relayNodeNames: relayNodeNames))
                                    .font(.system(size: 12.5, design: .monospaced))
                            }
                            if let wake = record.wakeOnLAN, inManagementSheet {
                                Text("WOL · \(wake.macAddress.formatted)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(DeskPalette.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if inManagementSheet {
                            tableCell(credentialSaved ? "已保存" : "缺少配对码", width: 88)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(credentialSaved ? DeskPalette.secondary : DeskPalette.amber)
                        } else {
                            tableCell(
                                record.lastConnected == .distantPast
                                    ? (credentialSaved ? "尚未远控" : "缺少配对码")
                                    : record.lastConnected.formatted(date: .abbreviated, time: .shortened),
                                width: 162
                            )
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(!credentialSaved ? DeskPalette.amber : DeskPalette.secondary)
                        }

                        HStack(spacing: 6) {
                            Button(session != nil ? "切到窗口" : (credentialSaved ? "连接" : "输入配对码")) {
                                connectSavedDevice(record)
                            }
                            .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                            recordMenu(record, session: session, inManagementSheet: inManagementSheet)
                        }
                        // Wide enough for the longest action, "输入配对码", beside the menu.
                        .frame(width: 128, alignment: .leading)
                        .disabled(locked)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minHeight: 46)
                    .contextMenu {
                        Button(session != nil ? "切到窗口" : (credentialSaved ? "连接" : "输入配对码")) {
                            connectSavedDevice(record)
                        }
                        .disabled(locked)
                        recordMenuActions(record, session: session, inManagementSheet: inManagementSheet)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func recordMenu(_ record: ConnectionRecord, session: ActiveRemoteSessionSummary?, inManagementSheet: Bool) -> some View {
        Menu {
            recordMenuActions(record, session: session, inManagementSheet: inManagementSheet)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 26, minHeight: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(DeskPalette.secondary)
        .fixedSize()
        .disabled(locked)
        .help("设备操作")
        .accessibilityLabel("\(ConnectionEntryPresentation.title(record)) 的记录操作")
    }

    @ViewBuilder
    private func recordMenuActions(_ record: ConnectionRecord, session: ActiveRemoteSessionSummary?, inManagementSheet: Bool) -> some View {
        Button(record.wakeOnLAN == nil ? "配置网络唤醒…" : "编辑网络唤醒…") {
            performAfterManagement(inManagementSheet) { configureWakeRecord(record) }
        }
        .disabled(locked)
        if record.wakeOnLAN != nil {
            Button("发送唤醒包") { performAfterManagement(inManagementSheet) { wakeRecord(record) } }
                .disabled(locked)
        }
        Button("测试线路质量…") { performAfterManagement(inManagementSheet) { benchmarkRecord(record) } }
            .disabled(locked)
        Button("配置 TCP 端口映射…") { performAfterManagement(inManagementSheet) { openPortMappingRecord(record) } }
            .disabled(locked)
        if let session {
            Button("断开连接", role: .destructive) { disconnectSession(session.id) }
        }
        Divider()
        Button("移除此记录…", role: .destructive) { recordToRemove = record }
            .disabled(locked)
    }

    private func tableCell(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: - Active Sessions (Page 60)

    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前活动会话")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("管理会话") { sheet = .sessions }
                    .buttonStyle(DeskButtonStyle(.secondary))
            }
            activeSessionTable
        }
    }

    private var activeSessionTable: some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    tableCell("远端设备", width: 170)
                    tableCell("控制状态")
                    tableCell("窗口", width: 112)
                    tableCell("操作", width: 128)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 16)
                .frame(height: 35)
                .background(DeskPalette.insetBackground)

                ForEach(activeSessions) { session in
                    Divider()
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(session.connected ? DeskPalette.emerald : (session.reconnecting || session.working ? DeskPalette.amber : DeskPalette.muted))
                                .frame(width: 6.5, height: 6.5)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                tableCell(session.title)
                                    .font(.system(size: 13, weight: .medium))
                                tableCell(session.endpointLabel)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DeskPalette.muted)
                            }
                        }
                        .frame(width: 170, alignment: .leading)

                        tableCell(session.statusLabel)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DeskPalette.secondary)

                        tableCell("独立远控窗口", width: 112)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DeskPalette.secondary)

                        HStack(spacing: 8) {
                            Button("切到窗口") {
                                if sheet == .sessions { dismissSheet() }
                                focusSession(session.id)
                            }
                            .buttonStyle(DeskButtonStyle(.quiet))
                            Button("断开", role: .destructive) { disconnectSession(session.id) }
                                .buttonStyle(DeskButtonStyle(.quiet))
                                .foregroundStyle(DeskPalette.coral)
                        }
                        .frame(width: 128, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minHeight: 46)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Modal Sheets

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case .connection:
            connectionSheet
        case let .credentials(title, endpoint):
            credentialsSheet(title: title, endpoint: endpoint)
        case .discovery:
            discoverySheet
        case .records:
            managementSheet
        case .sessions:
            sessionsSheet
        case .readiness:
            readinessSheet
        case nil:
            EmptyView()
        }
    }

    private var connectionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeading(
                showOptions ? "连接选项" : draftTitle == nil ? "新建连接" : "编辑连接",
                detail: showOptions ? "新建连接 / 对所有连接生效" : draftTitle ?? "选择方式并填写被控设备的连接信息。"
            )

            if showOptions {
                ScrollView { options(true, benchmarkDraft) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 390)
                Divider()
                HStack {
                    Spacer()
                    Button {
                        showOptions = false
                    } label: {
                        Label("返回连接", systemImage: "arrow.left")
                    }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    connectionMethods
                        .frame(width: 172)
                    ScrollView {
                        connectionFields
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity)
                    .onAppear(perform: focusIncompleteField)
                }
                .frame(height: 383, alignment: .topLeading)
                HStack {
                    if usesRelay {
                        Button("管理节点…") { dismissSheet(then: openRelay) }
                            .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                            .disabled(locked)
                    }
                    Spacer(minLength: 0)
                    Button(action: openOptions) { Label("连接选项", systemImage: "slider.horizontal.3") }
                        .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                        .disabled(locked)
                }
                Divider()
                HStack(spacing: 8) {
                    Button("测试线路", action: benchmarkDraft)
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .help("测量直连与中继的实际帧率、延迟及 UDP 丢包")
                        .disabled(locked)
                    Button("扫描局域网", action: openDiscovery)
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .disabled(locked)
                    if let openPortMappingDraft {
                        Button("用于端口映射…") {
                            let input = draft
                            dismissSheet { openPortMappingDraft(input) }
                        }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .disabled(locked)
                    }
                    Spacer()
                    cancelButton
                    Button(draftFailure == nil ? "连接" : "重试", action: submitConnection)
                        .buttonStyle(DeskButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(locked)
                }
            }
        }
        .padding(23)
        .frame(width: 762)
        .onChange(of: draft.address) { _, text in adoptInvitation(text) }
        .onChange(of: draft.code) { _, text in adoptInvitation(text) }
    }

    private var connectionMethods: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("连接方式").font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 6)
            if relayEnabled {
                methodRow(.direct, detail: "使用域名或 IP", symbol: "link")
                methodRow(.automatic, detail: "优先尝试直连", symbol: "arrow.right")
                methodRow(.relay, detail: "使用自托管中继", symbol: "point.3.connected.trianglepath.dotted")
            } else {
                methodRow(.direct, detail: "使用域名或 IP", symbol: "link")
                Button("配置自托管中继…") { dismissSheet(then: openRelay) }
                    .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                    .disabled(locked)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func methodRow(_ strategy: RelayConnectionStrategy, detail: String, symbol: String) -> some View {
        let selected = !relayEnabled || draft.strategy == strategy
        return Button { draft.strategy = strategy } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 17)
                    .foregroundStyle(selected ? DeskPalette.accent : DeskPalette.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(strategy == .direct ? "地址直连" : strategy == .relay ? "中继设备标识" : strategy.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(DeskPalette.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DeskPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(usesRelay ? (showsAddress ? "自动选择线路" : "通过设备标识连接") : "通过地址连接")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if usesRelay {
                labeledField("自托管中继") {
                    nodePicker
                        .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
                        .padding(.horizontal, 11)
                        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                        }
                }
                labeledField("目标设备标识") {
                    TextField("被控 Mac 显示的完整 UUID", text: $draft.deviceID)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .deviceID)
                        .deskInputBox(focused: focusedField == .deviceID)
                        .accessibilityLabel("目标中继设备标识")
                        .onSubmit { focusedField = showsAddress ? .address : .code }
                }
            }

            if showsAddress {
                HStack(alignment: .top, spacing: 12) {
                    labeledField(usesTailnet ? "对端 Tailscale IPv4" : (usesRelay ? "可选直连地址" : "地址")) {
                        TextField(usesTailnet ? "100.x.y.z" : "域名、IP 或粘贴连接信息", text: addressField)
                            .font(.system(size: 13))
                            .focused($focusedField, equals: .address)
                            .deskInputBox(focused: focusedField == .address)
                            .accessibilityLabel("被控 Mac 的地址")
                            .onSubmit { focusedField = .code }
                    }
                    labeledField("端口") {
                        TextField("5908", text: $draft.port)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($focusedField, equals: .port)
                            .deskInputBox(focused: focusedField == .port)
                            .accessibilityLabel("目标端口")
                            .onSubmit { focusedField = .code }
                    }
                    .frame(width: 96)
                }
            }
            if !usesRelay {
                Toggle("通过内置 Tailscale 连接", isOn: Binding(get: { usesTailnet }, set: { enabled in
                    draft.address = enabled ? TailnetAddress.prefix + draft.address : String(draft.address.dropFirst(TailnetAddress.prefix.count))
                }))
                .toggleStyle(.checkbox)
                .disabled(locked)
            }

            labeledField("配对码") { pairingField }

            if let draftFailure {
                DeskCalloutBox(message: draftFailure, symbol: "exclamationmark.circle", tone: .danger)
            } else if usesRelay {
                VStack(alignment: .leading, spacing: 8) {
                    DeskCalloutBox(
                        title: "连接到同一组自托管节点",
                        message: "使用被控 Mac 的完整 UUID 与配对码，不是账号登录。",
                        symbol: "info.circle",
                        tone: .info
                    )
                }
            } else if usesTailnet {
                Text("两端先在「网络与线路 → Tailscale」登录同一网络，然后填入对端显示的地址和 QuietDesk 配对码。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func credentialsSheet(title: String, endpoint: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            sheetHeading("输入配对码", detail: "\(title) · \(endpoint)")
            labeledField("粘贴被控 Mac 显示的完整配对码") { pairingField }
            Text("这条记录还没有保存配对码，输入一次后会记住；QuietDesk 不读取钥匙串。配对码保存在本机私有文件中，未单独加密。")
                .font(.system(size: 12.5))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let draftFailure {
                DeskCalloutBox(message: draftFailure, symbol: "exclamationmark.circle", tone: .danger) {
                    Button("编辑连接") { sheet = .connection }
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }

            HStack(spacing: 10) {
                Spacer()
                cancelButton
                Button("继续连接", action: submitConnection)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(locked)
            }
            .padding(.top, 8)
        }
        .padding(26)
        .frame(width: 500)
        .onAppear { focusedField = .code }
        // This record keeps its own address; of a pasted invitation only the code is used.
        .onChange(of: draft.code) { _, text in
            if let invitation = ConnectionInvitation(text: text) { draft.code = invitation.code }
        }
    }

    private var pairingField: some View {
        SecureField("粘贴完整配对码", text: $draft.code)
            .font(.system(size: 13, design: .monospaced))
            .focused($focusedField, equals: .code)
            .deskInputBox(focused: focusedField == .code)
            .accessibilityLabel("被控 Mac 显示的配对码")
            .onSubmit(submitConnection)
    }

    private var cancelButton: some View {
        Button("取消", action: dismissSheet)
            .buttonStyle(DeskButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)
    }

    // MARK: - LAN Discovery Sheet (Page 10)

    private var discoverySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                sheetHeading("局域网设备", detail: "仅发现开启 Bonjour 广播的共享端；扫描结果不是持续在线监控")
                Spacer()
                Button(lanScanning ? "停止扫描" : "重新扫描", action: toggleLANScan)
                    .buttonStyle(DeskButtonStyle(.secondary))
            }

            DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        tableCell("设备", width: 150)
                        tableCell("地址")
                        tableCell("配对记录", width: 92)
                        tableCell("操作", width: 96)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 35)
                    .background(DeskPalette.insetBackground)

                    if discoveredLANHosts.isEmpty {
                        Divider()
                        HStack(spacing: 8) {
                            if lanScanning {
                                ProgressView().controlSize(.small)
                            }
                            Text(lanScanning ? "正在扫描同一局域网内的共享设备…" : "当前未发现开启广播的其他 Mac")
                                .font(.system(size: 13))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(discoveredLANHosts) { host in
                                    Divider()
                                    let hasCredential = hasSavedCredentialForDiscovered(host)
                                    HStack(spacing: 12) {
                                        tableCell(host.serviceName, width: 150)
                                            .fontWeight(.medium)
                                        tableCell(host.endpointLabel)
                                            .font(.system(size: 12.5, design: .monospaced))
                                        tableCell(hasCredential ? "已配对" : "未配对", width: 92)
                                            .foregroundStyle(hasCredential ? DeskPalette.emerald : DeskPalette.secondary)
                                        Button(hasCredential ? "连接" : "填写配对码") {
                                            let attempt = selectDiscoveredHost(host)
                                            if attempt != nil { dismissLANScan() }
                                            discoveryFromComposer = false
                                            finishSavedAttempt(attempt, title: host.serviceName, endpoint: host.endpointLabel)
                                        }
                                        .buttonStyle(DeskButtonStyle(.quiet))
                                        .frame(width: 96, alignment: .leading)
                                    }
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(discoveredLANHosts.count) * 45, 220))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            DeskCalloutBox(
                title: discoveredLANHosts.isEmpty && !lanScanning ? "没有找到其他设备" : nil,
                message: !lanScanStatus.isEmpty
                    ? lanScanStatus
                    : "检查两台 Mac 是否处于同一局域网，并在共享端允许 Bonjour 发现。",
                symbol: "info.circle",
                tone: .info
            )

            HStack {
                Spacer()
                Button("完成", action: dismissDiscovery)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 640)
    }

    // MARK: - Manage Records Sheet (Page 6)

    private var managementSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeading("管理连接记录", detail: "本机保存的记录不代表设备当前在线；移除记录会同时删除对应本机配对码与锁屏密码")
            if records.isEmpty {
                ContentUnavailableView("没有连接记录", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView { recordTable(records, inManagementSheet: true) }
                    .frame(height: min(CGFloat(records.count) * 56 + 38, 320))
            }
            HStack {
                Spacer()
                Button("完成", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 700)
    }

    // MARK: - Active Sessions Sheet (Page 60)

    private var sessionsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                sheetHeading("当前活动会话", detail: "每个远端桌面在独立窗口运行；可继续新建连接")
                Spacer()
                Button("新建连接", action: openNewConnection)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(locked)
            }
            if activeSessions.isEmpty {
                ContentUnavailableView("没有活动会话", systemImage: "macwindow.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView { activeSessionTable }
                    .frame(height: min(CGFloat(activeSessions.count) * 48 + 38, 280))
            }
            Text("不会把选中连接记录当作已连接会话；关闭管理列表也不会自动断开。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)

            HStack {
                if !activeSessions.isEmpty {
                    Button("全部断开", role: .destructive, action: disconnectAllSessions)
                        .buttonStyle(DeskButtonStyle(.danger))
                }
                Spacer()
                Button("完成", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 660)
    }

    // MARK: - Pre-flight Readiness Sheet (Page 66)

    private var readinessSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeading("连接前就绪状态", detail: "不阻止仅观看；控制与快捷键按实际权限生效。")

            DeskSettingsGroup(title: "本机连接前检测") {
                readinessRow("Caps Lock 远端中英切换", value: preFlight.capsLockTitle, ready: preFlight.capsLockReady)
                Divider()
                readinessRow("系统快捷键", value: preFlight.shortcutsTitle, ready: preFlight.shortcutsReady)
                Divider()
                readinessRow("剪贴板与文件按需拉取", value: preFlight.clipboardTitle, ready: preFlight.clipboardReady)
            }

            HStack(spacing: 12) {
                readinessShortcut("释放控制", "⌃⌥Esc")
                readinessShortcut("全屏", "⌃⌘F")
                readinessShortcut("远端截图", "⌃⌘S")
            }

            HStack {
                Button("偏好设置…") { dismissSheet(then: openCaps) }
                    .buttonStyle(DeskButtonStyle(.secondary))
                Spacer()
                Button("关闭", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 540)
    }

    private func readinessShortcut(_ action: String, _ shortcut: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(action).font(.caption).foregroundStyle(DeskPalette.secondary)
            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func readinessRow(_ title: String, value: String, ready: Bool) -> some View {
        DeskSettingsRow(title: title) {
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ready ? DeskPalette.emerald : DeskPalette.amber)
        }
    }

    // MARK: - Banners & Helpers

    private var connectingBanner: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 10) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在建立加密连接…")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text(status.isEmpty ? "握手期间保留取消入口，不展示远端画面或控制中状态。" : status)
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.secondary)
                }
                Spacer()
                Button("取消连接", action: cancel)
                    .buttonStyle(DeskButtonStyle(.secondary))
            }
        }
    }

    private func failureNotice(_ message: String) -> some View {
        DeskCalloutBox(
            title: "无法连接到设备",
            message: message,
            symbol: "exclamationmark.circle",
            tone: .danger
        ) {
            HStack(spacing: 8) {
                Button("重试 / 编辑") {
                    draft = retryDraft()
                    draftTitle = selectedRecord.map(ConnectionEntryPresentation.title) ?? "上次连接"
                    draftFailure = message
                    sheet = .connection
                    clearFailure()
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .disabled(locked)

                Button("收起", action: clearFailure)
                    .buttonStyle(DeskButtonStyle(.quiet))
            }
        }
    }

    private func sheetHeading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledField<FieldContent: View>(_ title: String, @ViewBuilder field: () -> FieldContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)
            field()
        }
    }

    private func qualityTint(_ tone: ConnectionRecordCardBadge.Tone) -> Color {
        switch tone {
        case .good: return DeskPalette.emerald
        case .info: return DeskPalette.accent
        case .caution: return DeskPalette.amber
        case .neutral: return DeskPalette.secondary
        }
    }

    private func connectSavedDevice(_ record: ConnectionRecord) {
        finishSavedAttempt(
            quickConnect(record),
            title: ConnectionEntryPresentation.title(record),
            endpoint: ConnectionEntryPresentation.endpoint(record, relayNodeNames: relayNodeNames)
        )
    }

    private func finishSavedAttempt(_ attempt: ConnectionEntryAttemptFailure?, title: String, endpoint: String) {
        guard let attempt else { dismissSheet(); return }
        draft = attempt.draft
        draftTitle = title
        if draft.code.isEmpty {
            draftFailure = nil
            sheet = .credentials(title: title, endpoint: endpoint)
        } else {
            draftFailure = attempt.message
            sheet = .connection
        }
    }

    private func openNewConnection() {
        draft = ConnectionEntryDraft(strategy: relayEnabled ? defaultStrategy : .direct)
        draftTitle = nil
        draftFailure = nil
        showOptions = false
        sheet = .connection
    }

    private func openDiscovery() {
        discoveryFromComposer = sheet == .connection
        showOptions = false
        if !lanScanning { toggleLANScan() }
        sheet = .discovery
    }

    private func dismissDiscovery() {
        if discoveryFromComposer {
            dismissLANScan()
            discoveryFromComposer = false
            sheet = .connection
        } else {
            dismissSheet()
        }
    }

    private func dismissSheet() {
        if sheet == .discovery { dismissLANScan() }
        if sheet != nil { showOptions = false }
        sheet = nil
        showNewConnection = false
        draft = ConnectionEntryDraft()
        draftTitle = nil
        draftFailure = nil
        discoveryFromComposer = false
        recordToRemove = nil
    }

    private func dismissSheet(then action: @escaping () -> Void) {
        afterSheetDismissal = action
        dismissSheet()
    }

    private func finishSheetDismissal() {
        let action = afterSheetDismissal
        afterSheetDismissal = nil
        action?()
    }

    private func performAfterManagement(_ inManagementSheet: Bool, _ action: @escaping () -> Void) {
        if inManagementSheet {
            dismissSheet(then: action)
        } else {
            action()
        }
    }

    private func submitConnection() {
        guard !locked, sheet != nil else { return }
        guard let attempt = connect(draft) else { dismissSheet(); return }
        draftFailure = attempt.message
        if sheet == .connection { focusIncompleteField() }
    }

    /// A whole invitation pasted into the address or the code field fills address, port and code at once.
    /// Anything else stays exactly as typed.
    private func adoptInvitation(_ text: String) {
        guard !locked, let filled = ConnectionEntryPresentation.adopting(text, into: draft, relayEnabled: relayEnabled) else { return }
        draft = filled
        draftFailure = nil
        focusIncompleteField()
    }

    private func focusIncompleteField() {
        guard !locked else { return }
        focusedField = ConnectionEntryPresentation.firstIncompleteField(
            relayEnabled: relayEnabled, strategy: draft.strategy, address: draft.address, port: draft.port,
            deviceID: draft.deviceID, code: draft.code
        )
    }

    private func benchmarkDraft() {
        let input = draft
        dismissSheet { openBenchmarkDraft(input) }
    }

    private func recordRemovalAlert(inManagementSheet: Bool) -> RecordRemovalAlert {
        RecordRemovalAlert(
            record: $recordToRemove,
            active: (sheet == .records) == inManagementSheet,
            remove: remove
        )
    }
}

struct RecordRemovalAlert: ViewModifier {
    @Binding var record: ConnectionRecord?
    let active: Bool
    let remove: (ConnectionRecord) -> Void

    func body(content: Content) -> some View {
        let presented = Binding(
            get: { active && record != nil },
            set: { if active && !$0 { record = nil } }
        )
        content.alert("移除此连接记录？", isPresented: presented, presenting: record) { target in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { remove(target) }
        } message: { target in
            Text("将移除「\(ConnectionEntryPresentation.title(target))」的本机连接记录、配对码、已保存的远端锁屏密码和端口映射规则。")
        }
    }
}
