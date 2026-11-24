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
}

struct ConnectionEntryView<NodePicker: View, Options: View>: View {
    let records: [ConnectionRecord]
    let selectedRecord: ConnectionRecord?
    @Binding var showNewConnection: Bool
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
                    notice(wakeNotice, symbol: "bolt.horizontal") {
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
                        .padding(.top, 38)
                } else {
                    allDevices
                }

                if !activeSessions.isEmpty, selectedRecord == nil {
                    activeSessionsSection
                }
            }
            .padding(26)
            .frame(maxWidth: 1040, alignment: .leading)
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
        .onDisappear(perform: dismissSheet)
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            afterSheetDismissal = nil
            dismissSheet()
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if let selectedRecord {
                    let session = sessionForRecord(selectedRecord)
                    if let session {
                        DeskPillBadge(
                            text: session.connected ? "已连接" : session.reconnecting ? "重连中" : "连接中",
                            symbol: "circle.fill",
                            tint: session.connected ? DeskPalette.emerald : DeskPalette.amber
                        )
                    }
                    Text(ConnectionEntryPresentation.title(selectedRecord))
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    recordMenu(selectedRecord, session: session, inManagementSheet: false)
                } else {
                    Text(records.isEmpty ? "第一次使用 QuietDesk" : "全部设备")
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                if !activeSessions.isEmpty {
                    Button {
                        sheet = .sessions
                    } label: {
                        Label("活动会话", systemImage: "macwindow.on.rectangle")
                    }
                    .buttonStyle(DeskButtonStyle(.quiet))
                }
                if selectedRecord != nil {
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
            .frame(minHeight: 33)

            if let selectedRecord {
                Text("\(ConnectionEntryPresentation.endpoint(selectedRecord)) · \(ConnectionEntryPresentation.route(selectedRecord))")
                    .font(.callout)
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var firstUse: some View {
        VStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(DeskPalette.muted.opacity(0.72))
                .accessibilityHidden(true)
            Text("从另一台 Mac 开启共享")
                .font(.system(size: 23, weight: .semibold))
            Text("在「本机共享」复制配对码，然后填写地址连接。")
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
            Button(action: openNewConnection) {
                Text("新建连接").frame(minWidth: 112)
            }
            .buttonStyle(DeskButtonStyle(.primary))
            .disabled(locked)
            .padding(.top, 12)
            Text("同一局域网可扫描开启发现广播的设备。")
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .padding(.top, 6)
            Button(action: openDiscovery) {
                Text("扫描局域网").frame(minWidth: 112)
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(locked)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 290)
    }

    private var allDevices: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(records.count) 台已保存")
                    .font(.callout)
                    .foregroundStyle(DeskPalette.secondary)
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

            TextField("搜索名称、地址或设备 ID…", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索连接记录")

            if matches.isEmpty {
                VStack(spacing: 10) {
                    Text("没有匹配的连接记录")
                        .font(.system(size: 18, weight: .semibold))
                    Text("尝试设备名称、域名、IP、MAC 或完整设备标识。")
                        .font(.callout)
                        .foregroundStyle(DeskPalette.secondary)
                    Button("清除搜索") { query = "" }
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, minHeight: 168)
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

    private func deviceDetail(_ record: ConnectionRecord) -> some View {
        let session = sessionForRecord(record)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(DeskPalette.muted)
                    .accessibilityHidden(true)
                Text(session == nil ? "尚未连接" : "远程桌面在独立窗口运行")
                    .font(.system(size: 19, weight: .semibold))
                Text(session?.statusLabel ?? "连接后可在独立窗口查看远程桌面。")
                    .font(.callout)
                    .foregroundStyle(DeskPalette.secondary)
                Button {
                    connectSavedDevice(record)
                } label: {
                    Text(session == nil ? "连接到设备" : "打开会话窗口")
                        .frame(minWidth: 98)
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .disabled(locked)
                .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)

            HStack(spacing: 9) {
                Button { openPortMappingRecord(record) } label: {
                    Label("端口映射", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Divider().frame(height: 14)
                Button(action: openOptions) {
                    Label("连接选项", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: optionsPresentation(inComposer: false), arrowEdge: .bottom) {
                    options { benchmarkRecord(record) }
                }
                Divider().frame(height: 14)
                Button { benchmarkRecord(record) } label: {
                    Label("测试线路", systemImage: "speedometer")
                }
                if record.wakeOnLAN != nil {
                    Divider().frame(height: 14)
                    Button { wakeRecord(record) } label: {
                        Label("网络唤醒", systemImage: "bolt.horizontal")
                    }
                }
            }
            .buttonStyle(DeskButtonStyle(.quiet))
            .disabled(locked)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(DeskPalette.insetBackground, in: .rect(cornerRadius: 8))

            HStack(spacing: 10) {
                Text(ConnectionEntryPresentation.savedQualityLabel(record))
                    .lineLimit(1)
                if let badge = qualityBadge(record) {
                    DeskPillBadge(text: badge.text, tint: qualityTint(badge.tone), monospaced: true)
                }
                let mappings = runningMappingsCount(record)
                if mappings > 0 {
                    Text("\(mappings) 条映射启用中")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(DeskPalette.secondary)
        }
    }

    private func recordTable(_ records: [ConnectionRecord], inManagementSheet: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                tableCell("设备", width: 146)
                tableCell("连接端点")
                tableCell("最近连接", width: 112)
                tableCell("操作", width: 104)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(DeskPalette.secondary)
            .padding(.horizontal, 14)
            .frame(height: 33)
            .background(DeskPalette.insetBackground)

            ForEach(records) { record in
                let session = sessionForRecord(record)
                Divider()
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: ConnectionEntryPresentation.deviceSymbol(record))
                            .foregroundStyle(DeskPalette.muted)
                            .accessibilityHidden(true)
                        tableCell(ConnectionEntryPresentation.title(record))
                    }
                    .frame(width: 146, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        tableCell(ConnectionEntryPresentation.endpoint(record))
                            .font(.system(.caption, design: .monospaced))
                        if let relay = record.relay {
                            tableCell(relay.deviceID.uuidString.lowercased())
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                        if let wake = record.wakeOnLAN, inManagementSheet {
                            Text("WOL · \(wake.macAddress.formatted)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    tableCell(
                        record.lastConnected == .distantPast
                            ? "尚未远控"
                            : record.lastConnected.formatted(date: .abbreviated, time: .shortened),
                        width: 112
                    )
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)

                    HStack(spacing: 2) {
                        Button(session == nil ? "连接" : "切到窗口") { connectSavedDevice(record) }
                            .buttonStyle(DeskButtonStyle(.quiet))
                        recordMenu(record, session: session, inManagementSheet: inManagementSheet)
                    }
                    .frame(width: 104, alignment: .leading)
                    .disabled(locked)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 42)
                .contextMenu {
                    Button(session == nil ? "连接" : "切到窗口") { connectSavedDevice(record) }
                        .disabled(locked)
                    recordMenuActions(record, session: session, inManagementSheet: inManagementSheet)
                }
            }
        }
        .background(DeskPalette.cardBackground)
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DeskPalette.hairline) }
    }

    private func recordMenu(_ record: ConnectionRecord, session: ActiveRemoteSessionSummary?, inManagementSheet: Bool) -> some View {
        Menu {
            recordMenuActions(record, session: session, inManagementSheet: inManagementSheet)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 24, minHeight: 24)
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

    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("当前活动会话")
                    .font(.headline)
                Spacer()
                Button("查看会话") { sheet = .sessions }
                    .buttonStyle(DeskButtonStyle(.secondary))
            }
            activeSessionRows
        }
    }

    private var activeSessionRows: some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 8) {
            VStack(spacing: 0) {
                ForEach(activeSessions) { session in
                    if session.id != activeSessions.first?.id { Divider() }
                    HStack(spacing: 10) {
                        Circle()
                            .fill(session.connected ? DeskPalette.emerald : (session.reconnecting || session.working ? DeskPalette.amber : DeskPalette.muted))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            tableCell(session.title)
                                .font(.callout.weight(.semibold))
                            tableCell(session.endpointLabel)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                        tableCell(session.statusLabel, width: 136)
                            .foregroundStyle(DeskPalette.secondary)
                        Button("切到窗口") {
                            if sheet == .sessions { dismissSheet() }
                            focusSession(session.id)
                        }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        Button("断开", role: .destructive) { disconnectSession(session.id) }
                            .buttonStyle(DeskButtonStyle(.danger))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
    }

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
        VStack(alignment: .leading, spacing: 15) {
            sheetHeading(
                draftTitle == nil ? (usesRelay ? "通过设备标识连接" : "新建连接") : "编辑连接",
                detail: draftTitle
            )

            ViewThatFits(in: .vertical) {
                connectionFields
                ScrollView { connectionFields }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 368, alignment: .topLeading)

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
        .padding(24)
        .frame(width: 548)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .onAppear(perform: focusIncompleteField)
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 15) {
            if relayEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接方式").font(.callout).foregroundStyle(DeskPalette.secondary)
                    DeskSegmentedTabs(
                        tabs: [(.direct, "地址直连"), (.automatic, "自动（直连优先）"), (.relay, "中继设备标识")],
                        selection: $draft.strategy
                    )
                }
            } else {
                HStack {
                    Text("地址直连")
                        .font(.callout)
                        .foregroundStyle(DeskPalette.secondary)
                    Spacer()
                    Button("配置自托管中继…") { dismissSheet(then: openRelay) }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .disabled(locked)
                }
            }

            if usesRelay {
                labeledField("自托管中继") { nodePicker }
                labeledField("目标设备标识") {
                    TextField("被控 Mac 显示的完整 UUID", text: $draft.deviceID)
                        .font(.system(.callout, design: .monospaced))
                        .accessibilityLabel("目标中继设备标识")
                        .focused($focusedField, equals: .deviceID)
                        .onSubmit { focusedField = showsAddress ? .address : .code }
                }
            }
            if showsAddress {
                labeledField(usesRelay ? "可选直连地址" : "地址") {
                    TextField("域名或 IP", text: $draft.address)
                        .accessibilityLabel("被控 Mac 的地址")
                        .focused($focusedField, equals: .address)
                        .onSubmit { focusedField = .code }
                }
                labeledField("端口") {
                    TextField("5908", text: $draft.port)
                        .font(.system(.callout, design: .monospaced))
                        .accessibilityLabel("目标端口")
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .code }
                }
            }
            labeledField("配对码") { pairingField }

            if let draftFailure {
                notice(draftFailure, symbol: "exclamationmark.circle", tint: DeskPalette.coral) { EmptyView() }
            } else if usesRelay {
                notice("使用被控 Mac 的完整 UUID 与配对码。两端需接入同一组自托管中继。", symbol: "info.circle") {
                    Button("管理节点…") { dismissSheet(then: openRelay) }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .disabled(locked)
                }
            }

            Button(action: openOptions) {
                HStack {
                    Text("连接选项")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.medium))
                }
            }
            .buttonStyle(DeskButtonStyle(.quiet))
            .popover(isPresented: optionsPresentation(inComposer: true), arrowEdge: .bottom) {
                options(benchmarkDraft)
            }

        }
    }

    private func credentialsSheet(title: String, endpoint: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeading("补录连接凭据", detail: "\(title) · \(endpoint)")
            labeledField("粘贴被控 Mac 显示的完整配对码") { pairingField }
            Text("配对码保存在本机私有文件，由当前账户的文件权限保护，未单独加密。连接记录不会读取钥匙串。")
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let draftFailure {
                notice(draftFailure, symbol: "exclamationmark.circle", tint: DeskPalette.coral) {
                    Button("编辑连接") { sheet = .connection }
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }
            HStack(spacing: 8) {
                Spacer()
                cancelButton
                Button("继续连接", action: submitConnection)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(locked)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 520)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .onAppear { focusedField = .code }
    }

    private var pairingField: some View {
        SecureField("粘贴完整配对码", text: $draft.code)
            .font(.system(.callout, design: .monospaced))
            .accessibilityLabel("被控 Mac 显示的配对码")
            .focused($focusedField, equals: .code)
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

    private var discoverySheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                sheetHeading("局域网设备", detail: "发现开启 Bonjour 广播的共享端。扫描结果反映本次发现情况。")
                Spacer()
                Button(lanScanning ? "停止扫描" : "重新扫描", action: toggleLANScan)
                    .buttonStyle(DeskButtonStyle(.secondary))
            }

            if !discoveredLANHosts.isEmpty {
                ScrollView {
                    DeskSurfaceCard(padding: 0, cornerRadius: 8) {
                        VStack(spacing: 0) {
                            ForEach(discoveredLANHosts) { host in
                                if host.id != discoveredLANHosts.first?.id { Divider() }
                                let hasCredential = hasSavedCredentialForDiscovered(host)
                                HStack(spacing: 12) {
                                    tableCell(host.serviceName, width: 144)
                                    tableCell(host.endpointLabel)
                                        .font(.system(.caption, design: .monospaced))
                                    Text(hasCredential ? "已配对" : "未配对")
                                        .foregroundStyle(DeskPalette.secondary)
                                    Button(hasCredential ? "连接" : "填写配对码") {
                                        let attempt = selectDiscoveredHost(host)
                                        if attempt != nil { dismissLANScan() }
                                        discoveryFromComposer = false
                                        finishSavedAttempt(attempt, title: host.serviceName, endpoint: host.endpointLabel)
                                    }
                                    .buttonStyle(DeskButtonStyle(.quiet))
                                }
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(minHeight: 42)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(discoveredLANHosts.count) * 43 + 1, 250))
            }

            if lanScanning || !lanScanStatus.isEmpty {
                notice(lanScanStatus, symbol: lanScanning ? nil : "info.circle") {
                    if lanScanning { ProgressView().controlSize(.small) }
                }
            }
            HStack {
                Spacer()
                Button("完成", action: dismissDiscovery)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 634)
    }

    private var managementSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeading("管理连接记录", detail: "配对码由本机账户文件权限保护，未单独加密。移除连接记录也会删除本机文件中的对应配对码。")
            if records.isEmpty {
                ContentUnavailableView("没有连接记录", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView { recordTable(records, inManagementSheet: true) }
                    .frame(height: min(CGFloat(records.count) * 62 + 35, 300))
            }
            HStack {
                Spacer()
                Button("完成", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 700)
    }

    private var sessionsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                sheetHeading("当前活动会话", detail: "每个远程桌面在独立窗口运行。")
                Spacer()
                Button("新建连接", action: openNewConnection)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(locked)
            }
            if activeSessions.isEmpty {
                ContentUnavailableView("没有活动会话", systemImage: "macwindow.on.rectangle")
            } else {
                ScrollView { activeSessionRows }
                    .frame(height: min(CGFloat(activeSessions.count) * 53 + 1, 260))
            }
            HStack {
                if activeSessions.count > 1 {
                    Button("全部断开", role: .destructive, action: disconnectAllSessions)
                        .buttonStyle(DeskButtonStyle(.danger))
                }
                Spacer()
                Button("完成", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 650)
    }

    private var readinessSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            sheetHeading("连接前就绪状态", detail: "控制与快捷键按本机实际权限生效。")
            DeskSurfaceCard(padding: 0, cornerRadius: 8) {
                VStack(spacing: 0) {
                    readinessRow("Caps Lock 远端中英切换", value: preFlight.capsLockTitle, ready: preFlight.capsLockReady)
                    Divider()
                    readinessRow("全屏系统快捷键", value: preFlight.shortcutsTitle, ready: preFlight.shortcutsReady)
                    Divider()
                    readinessRow("剪贴板与文件按需拉取", value: preFlight.clipboardTitle, ready: preFlight.clipboardReady)
                }
            }
            Text("⌃⌥Esc 释放控制  ·  ⌃⌘F 全屏  ·  ⌃⌘S 远端截图")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
            HStack {
                Button("偏好设置…") { dismissSheet(then: openCaps) }
                    .buttonStyle(DeskButtonStyle(.secondary))
                Spacer()
                Button("关闭", action: dismissSheet)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 578)
    }

    private func readinessRow(_ title: String, value: String, ready: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(ready ? DeskPalette.emerald : DeskPalette.amber)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
    }

    private var connectingBanner: some View {
        DeskSurfaceCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在建立加密连接…").font(.headline)
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(DeskPalette.secondary)
                    }
                }
                Spacer()
                Button("取消连接", action: cancel)
                    .buttonStyle(DeskButtonStyle(.secondary))
            }
        }
    }

    private func failureNotice(_ message: String) -> some View {
        notice(message, symbol: "exclamationmark.circle", tint: DeskPalette.coral) {
            Button("编辑连接") {
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

    private func notice<Actions: View>(
        _ message: String, symbol: String?, tint: Color = DeskPalette.secondary,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .foregroundStyle(tint)
        .padding(12)
        .background(DeskPalette.insetBackground, in: .rect(cornerRadius: 7))
    }

    private func sheetHeading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeledField<FieldContent: View>(_ title: String, @ViewBuilder field: () -> FieldContent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout)
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

private struct RecordRemovalAlert: ViewModifier {
    @Binding var record: ConnectionRecord?
    let active: Bool
    let remove: (ConnectionRecord) -> Void

    func body(content: Content) -> some View {
        let presented = Binding(
            get: { active && record != nil },
            set: { if active && !$0 { record = nil } }
        )
        content.alert("移除连接记录？", isPresented: presented, presenting: record) { target in
            Button("取消", role: .cancel) {}
            Button("移除记录", role: .destructive) { remove(target) }
        } message: { target in
            Text("将删除「\(ConnectionEntryPresentation.title(target))」的本机连接记录、配对码、已保存的远端锁屏密码和端口映射规则。")
        }
    }
}
