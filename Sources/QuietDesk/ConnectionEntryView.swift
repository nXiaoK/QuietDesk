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

    static func matching(_ records: [ConnectionRecord], query: String) -> [ConnectionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { record in
            var fields = [record.name, record.address, String(record.port)]
            if let deviceID = record.deviceID {
                fields.append(deviceID.uuidString)
            }
            if let wake = record.wakeOnLAN {
                fields.append(wake.macAddress.formatted)
            }
            if let relay = record.relay {
                fields += [relay.deviceID.uuidString, relay.endpoint.host, String(relay.endpoint.port)]
            }
            return fields.contains { $0.localizedStandardContains(query) }
        }
    }

    static func visible(_ records: [ConnectionRecord], query: String, expanded: Bool) -> [ConnectionRecord] {
        let matches = matching(records, query: query)
        return expanded || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? matches : Array(matches.prefix(recentLimit))
    }

    static func title(_ record: ConnectionRecord) -> String {
        record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (record.address.isEmpty ? "已保存的 Mac" : record.address) : record.name
    }

    static func endpoint(_ record: ConnectionRecord) -> String {
        if let relay = record.relay { return relay.endpoint.address }
        let host = record.address.contains(":") && !record.address.hasPrefix("[") ? "[\(record.address)]" : record.address
        return "\(host):\(record.port)"
    }

    static func compactRelayIdentity(_ uuid: UUID) -> String {
        let raw = uuid.uuidString.lowercased()
        guard raw.count >= 12 else { return raw }
        return "\(raw.prefix(4))…\(raw.suffix(4))"
    }

    static func route(_ record: ConnectionRecord) -> String { (record.relay?.strategy ?? .direct).title }

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
    let options: (@escaping () -> Void) -> Options
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
    var openReceivedFiles: () -> Void = {}
    var viewerViewOnlyLocked: Bool = false
    var toggleViewerViewOnly: () -> Void = {}

    @State private var sheet: Sheet?
    @State private var query = ""
    @State private var expandedRecords = false
    @State private var draft = ConnectionEntryDraft()
    @State private var draftTitle: String?
    @State private var draftFailure: String?
    @State private var discoveryFromComposer = false
    @State private var recordToRemove: ConnectionRecord?
    @State private var afterSheetDismissal: (() -> Void)?
    @FocusState private var focusedField: ConnectionEntryPresentation.Field?

    private enum Sheet: Equatable {
        case connection, credentials(title: String, endpoint: String), discovery, records, sessions, readiness
    }

    private var usesRelay: Bool { relayEnabled && draft.strategy != .direct }
    private var showsAddress: Bool { !relayEnabled || draft.strategy != .relay }
    private var matches: [ConnectionRecord] { ConnectionEntryPresentation.matching(records, query: query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleRecords: [ConnectionRecord] {
        ConnectionEntryPresentation.visible(records, query: query, expanded: expandedRecords)
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
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1020, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(selectedRecord == nil ? DeskPalette.canvasBackground : DeskPalette.cardBackground)
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
        .onDisappear(perform: dismissSheet)
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            afterSheetDismissal = nil
            dismissSheet()
        }
    }

    // MARK: - Page Heading

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if let selectedRecord {
                    let session = sessionForRecord(selectedRecord)
                    let live = liveSessionForRecord(selectedRecord)
                    if let live {
                        DeskPillBadge(
                            text: live.badgeTitle,
                            symbol: "circle.fill",
                            tint: live.connected ? DeskPalette.emerald : DeskPalette.amber
                        )
                    } else if let session {
                        DeskPillBadge(
                            text: session.connected ? "已连接" : session.reconnecting ? "重连中" : "连接中",
                            symbol: "circle.fill",
                            tint: session.connected ? DeskPalette.emerald : DeskPalette.amber
                        )
                    }
                    Text(ConnectionEntryPresentation.title(selectedRecord))
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    recordMenu(selectedRecord, session: session, inManagementSheet: false)
                } else {
                    Text(records.isEmpty ? "第一次使用 QuietDesk" : "全部设备")
                        .font(.system(size: 23, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                }

                Spacer(minLength: 8)

                if !activeSessions.isEmpty {
                    Button {
                        sheet = .sessions
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(DeskPalette.emerald)
                                .frame(width: 6.5, height: 6.5)
                            Text("活动会话（\(activeSessions.count)）")
                        }
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                }

                if let selectedRecord {
                    let live = liveSessionForRecord(selectedRecord)
                    Button(action: openReceivedFiles) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .help("打开接收文件目录")
                    .accessibilityLabel("打开接收文件目录")

                    if let live {
                        Button(action: live.enterFullScreen) {
                            Image(systemName: "viewfinder")
                        }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .help("切到远控窗口并进入全屏")
                        .accessibilityLabel("进入全屏")
                    }

                    Button {
                        sheet = .readiness
                    } label: {
                        Image(systemName: "checkmark.shield")
                    }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .help("连接前就绪状态")
                    .accessibilityLabel("连接前就绪状态")
                }
            }
            .frame(minHeight: 34)
        }
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
            HStack(spacing: 8) {
                Text("\(records.count) 台已保存设备 · 本机保存的记录不代表设备当前在线")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(1)
                Spacer()
                Button("扫描局域网", action: openDiscovery)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(locked)
                Button("管理记录") { sheet = .records }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(locked)
                Button("新建连接", action: openNewConnection)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(locked)
            }

            DeskSearchField(
                placeholder: "搜索名称、地址或设备 ID…",
                text: $query,
                accessibilityTitle: "搜索连接记录"
            )

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
                if searching {
                    Text("找到 \(matches.count) 条，共 \(records.count) 条记录")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                } else if records.count > ConnectionEntryPresentation.recentLimit {
                    Button(expandedRecords ? "收起为最近 \(ConnectionEntryPresentation.recentLimit) 台设备" : "展开全部 \(records.count) 台设备") {
                        expandedRecords.toggle()
                    }
                    .buttonStyle(DeskButtonStyle(.quiet))
                }
                Spacer()
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

        return VStack(alignment: .leading, spacing: 14) {
            DeskSurfaceCard(padding: 0, cornerRadius: 12) {
                VStack(spacing: 0) {
                    if let live {
                        connectedDeviceStage(record: record, live: live)
                    } else if let session {
                        connectingDeviceStage(record: record, session: session)
                    } else {
                        idleDeviceStage(record: record)
                    }

                    Divider()

                    stageActionDock(record: record, live: live, viewOnlyActive: viewOnlyActive)
                }
            }

            deviceFooterMetadata(record: record, live: live, session: session)
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

    private func idleDeviceStage(record: ConnectionRecord) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(DeskPalette.muted.opacity(0.8))
                .accessibilityHidden(true)

            Text("连接后显示远程桌面")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DeskPalette.ink)

            Text("此设备尚未建立会话，没有实时画面。")
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)

            Button {
                connectSavedDevice(record)
            } label: {
                Text("连接到设备")
                    .padding(.horizontal, 8)
                    .frame(minWidth: 118, minHeight: 32)
            }
            .buttonStyle(DeskButtonStyle(.primary))
            .disabled(locked)
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.vertical, 52)
        .frame(maxWidth: .infinity, minHeight: 310)
        .background(DeskPalette.insetBackground.opacity(0.65))
    }

    private func stageActionDock(
        record: ConnectionRecord,
        live: LiveDeviceSessionOverview?,
        viewOnlyActive: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                dockButton("文件接收", symbol: "doc.on.doc", action: openReceivedFiles)
                dockDivider
                dockButton(
                    viewOnlyActive ? "仅观看已开" : "仅观看",
                    symbol: viewOnlyActive ? "eye.fill" : "eye",
                    highlighted: viewOnlyActive,
                    action: {
                        if let live {
                            live.toggleViewOnly()
                        } else {
                            toggleViewerViewOnly()
                        }
                    }
                )
                dockDivider
                dockButton("端口映射", symbol: "point.3.connected.trianglepath.dotted") {
                    openPortMappingRecord(record)
                }
                dockDivider
                dockOptionsButton(record: record)
                dockDivider
                dockMoreMenu(record: record, live: live, includePortMappingAndTest: false)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                dockButton("端口映射", symbol: "point.3.connected.trianglepath.dotted") {
                    openPortMappingRecord(record)
                }
                dockDivider
                dockOptionsButton(record: record)
                dockDivider
                dockMoreMenu(record: record, live: live, includePortMappingAndTest: true)
            }
        }
        .frame(minHeight: 46)
        .background(DeskPalette.cardBackground)
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
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dockOptionsButton(record: ConnectionRecord) -> some View {
        Button(action: openOptions) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.secondary)
                Text("连接选项")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: optionsPresentation(inComposer: false), arrowEdge: .bottom) {
            options { benchmarkRecord(record) }
        }
    }

    private func dockMoreMenu(
        record: ConnectionRecord,
        live: LiveDeviceSessionOverview?,
        includePortMappingAndTest: Bool
    ) -> some View {
        Menu {
            if includePortMappingAndTest {
                Button("打开接收文件目录", action: openReceivedFiles)
            }
            Button("测试线路质量…") { benchmarkRecord(record) }
                .disabled(live != nil)
            if record.wakeOnLAN != nil {
                Button("发送网络唤醒包") { wakeRecord(record) }
                Button("编辑网络唤醒…") { configureWakeRecord(record) }
            } else {
                Button("配置网络唤醒…") { configureWakeRecord(record) }
            }
            Button("连接前就绪状态…") { sheet = .readiness }
            if let live {
                Divider()
                Button("断开远程连接", role: .destructive) {
                    disconnectSession(live.sessionID)
                }
            }
            Divider()
            Button("移除此记录…", role: .destructive) { recordToRemove = record }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DeskPalette.secondary)
                Text("更多")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.ink)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func deviceFooterMetadata(
        record: ConnectionRecord,
        live: LiveDeviceSessionOverview?,
        session: ActiveRemoteSessionSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let live {
                    let parts = [
                        "当前会话",
                        live.resolution.isEmpty ? nil : live.resolution,
                        live.qualitySummary.isEmpty ? nil : live.qualitySummary
                    ].compactMap { $0 }
                    Text(parts.joined(separator: " · "))
                        .lineLimit(1)
                } else {
                    Text("\(ConnectionEntryPresentation.endpoint(record)) · \(ConnectionEntryPresentation.route(record)) · \(ConnectionEntryPresentation.savedQualityLabel(record))")
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                if let badge = qualityBadge(record) {
                    DeskPillBadge(text: badge.text, tint: qualityTint(badge.tone), monospaced: true)
                }

                let mappings = runningMappingsCount(record)
                if mappings > 0 {
                    DeskPillBadge(text: "\(mappings) 条映射启用中", tint: DeskPalette.emerald)
                }

                Spacer(minLength: 8)

                if let session {
                    Button("打开独立窗口") { focusSession(session.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                } else {
                    HStack(spacing: 10) {
                        Button("测试线路") { benchmarkRecord(record) }
                            .buttonStyle(.plain)
                            .foregroundStyle(DeskPalette.secondary)
                        if record.wakeOnLAN != nil {
                            Text("·").foregroundStyle(DeskPalette.muted)
                            Button("网络唤醒") { wakeRecord(record) }
                                .buttonStyle(.plain)
                                .foregroundStyle(DeskPalette.secondary)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(DeskPalette.secondary)

            if live == nil {
                Text("远程桌面将在建立加密连接后在独立窗口中运行。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.muted)
            }
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
                            tableCell(ConnectionEntryPresentation.title(record))
                                .fontWeight(.medium)
                        }
                        .frame(width: 152, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            if let relay = record.relay {
                                tableCell("设备标识 · \(ConnectionEntryPresentation.compactRelayIdentity(relay.deviceID))")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .help("\(relay.endpoint.address) · \(relay.deviceID.uuidString.lowercased())")
                                tableCell(relay.endpoint.address)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DeskPalette.muted)
                            } else {
                                tableCell(ConnectionEntryPresentation.endpoint(record))
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
        VStack(alignment: .leading, spacing: 16) {
            sheetHeading(
                draftTitle == nil ? (usesRelay ? "通过设备标识连接" : "新建连接") : "编辑连接",
                detail: draftTitle
            )

            ViewThatFits(in: .vertical) {
                connectionFields
                ScrollView { connectionFields }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 396, alignment: .topLeading)

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
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 540)
        .onAppear(perform: focusIncompleteField)
        .onChange(of: draft.address) { _, text in adoptInvitation(text) }
        .onChange(of: draft.code) { _, text in adoptInvitation(text) }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if relayEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接方式")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    DeskSegmentedTabs(
                        tabs: [(.direct, "地址直连"), (.automatic, "自动（直连优先）"), (.relay, "中继设备标识")],
                        selection: $draft.strategy
                    )
                }
            } else {
                HStack {
                    Text("连接方式 · 地址直连")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    Spacer()
                    Button("配置自托管中继…") { dismissSheet(then: openRelay) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                        .disabled(locked)
                }
            }

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
                labeledField(usesRelay ? "可选直连地址" : "地址") {
                    TextField("域名或 IP，或粘贴被控 Mac 复制的连接信息", text: $draft.address)
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
                    Button("管理节点…") { dismissSheet(then: openRelay) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                        .disabled(locked)
                }
            } else {
                Text("连接成功后沿用现有记录与凭据保存逻辑。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
            }

            VStack(spacing: 0) {
                Button(action: openOptions) {
                    HStack {
                        Text("连接选项")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DeskPalette.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(DeskPalette.muted)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: optionsPresentation(inComposer: true), arrowEdge: .bottom) {
                    options(benchmarkDraft)
                }
                Divider()
            }
        }
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

    private func optionsPresentation(inComposer: Bool) -> Binding<Bool> {
        Binding(
            get: { showOptions && (sheet == .connection) == inComposer },
            set: { if (sheet == .connection) == inComposer { showOptions = $0 } }
        )
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

            Text("释放控制 Ctrl+Option+Esc  ·  全屏 Ctrl+Cmd+F  ·  远端截图 Ctrl+Cmd+S")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)

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
            endpoint: ConnectionEntryPresentation.endpoint(record)
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
