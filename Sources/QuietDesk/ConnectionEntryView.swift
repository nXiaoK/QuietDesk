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

    static let placeholder = ConnectionPreFlightSummary(
        capsLockTitle: "按需启用",
        capsLockReady: false,
        shortcutsTitle: "全屏焦点时转发",
        shortcutsReady: false,
        clipboardTitle: "⌘V 按需同步",
        clipboardReady: true
    )
}

enum ConnectionEntryPresentation {
    enum Field: Hashable { case address, port, code, deviceID }
    static let recentLimit = 3

    static func matching(_ records: [ConnectionRecord], query: String) -> [ConnectionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { record in
            var fields = [record.name, record.address, String(record.port)]
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

struct RecentConnectionsView: View {
    let records: [ConnectionRecord]
    let locked: Bool
    @Binding var query: String
    @Binding var expanded: Bool
    let connect: (ConnectionRecord) -> Void
    let remove: (ConnectionRecord) -> Void
    let manage: () -> Void
    var benchmark: (ConnectionRecord) -> Void = { _ in }
    var openMapping: (ConnectionRecord) -> Void = { _ in }
    var qualityBadge: (ConnectionRecord) -> ConnectionRecordCardBadge? = { _ in nil }
    var runningMappingsCount: (ConnectionRecord) -> Int = { _ in 0 }
    var preFlight: ConnectionPreFlightSummary? = nil
    var openPreferences: (() -> Void)? = nil

    private var matches: [ConnectionRecord] { ConnectionEntryPresentation.matching(records, query: query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleRecords: [ConnectionRecord] {
        ConnectionEntryPresentation.visible(records, query: query, expanded: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text("我的设备书桌")
                    .font(.system(size: 15.5, weight: .bold))
                Text("\(records.count) 台已保存 · 本机记录不代表当前在线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                searchField
                Button("管理…", action: manage)
                    .controlSize(.small)
                    .disabled(locked)
            }

            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有匹配的连接记录")
                        .font(.callout.weight(.semibold))
                    Text("试试设备名称、域名、IP 或完整设备标识，也可以清除搜索条件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 340, maximum: 640), spacing: 14, alignment: .top)
                    ],
                    spacing: 14
                ) {
                    ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                        ConnectionDeskCard(
                            record: record,
                            highlighted: index == 0 && !searching,
                            badge: qualityBadge(record),
                            activeMappings: runningMappingsCount(record),
                            connect: { connect(record) },
                            remove: { remove(record) },
                            benchmark: { benchmark(record) },
                            openMapping: { openMapping(record) }
                        )
                        .disabled(locked)
                    }

                    if let preFlight, !searching {
                        PreFlightReadinessCard(summary: preFlight, openPreferences: openPreferences)
                    }
                }
            }

            HStack(spacing: 12) {
                if searching {
                    Text("找到 \(matches.count) 条，共 \(records.count) 条记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if records.count > ConnectionEntryPresentation.recentLimit {
                    Button(expanded ? "收起为最近 \(ConnectionEntryPresentation.recentLimit) 台设备" : "展开全部 \(records.count) 台已保存设备") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                }
                Spacer(minLength: 0)
                Text("点按「连接」使用已存配对码；凭据缺失时会提示补录，不读取钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("搜索名称、地址或设备 ID…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("搜索最近连接")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清除搜索")
                .accessibilityLabel("清除最近连接搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 216)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        }
    }
}

private struct ConnectionDeskCard: View {
    let record: ConnectionRecord
    let highlighted: Bool
    let badge: ConnectionRecordCardBadge?
    let activeMappings: Int
    let connect: () -> Void
    let remove: () -> Void
    let benchmark: () -> Void
    let openMapping: () -> Void

    private var badgeColor: Color {
        switch badge?.tone {
        case .good?: return Color(red: 0.07, green: 0.64, blue: 0.44)
        case .info?: return Color.accentColor
        case .caution?: return Color(red: 0.88, green: 0.52, blue: 0.08)
        case .neutral?, nil: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(highlighted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        .frame(width: 40, height: 40)
                    Image(systemName: ConnectionEntryPresentation.deviceSymbol(record))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(highlighted ? Color.accentColor : Color.primary.opacity(0.78))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(ConnectionEntryPresentation.title(record))
                            .font(.system(size: 14.5, weight: .bold))
                            .lineLimit(1)
                            .help(record.name)
                        Spacer(minLength: 4)
                        if let badge {
                            Text(badge.text)
                                .font(.system(size: 10.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(badgeColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(badgeColor.opacity(0.12), in: Capsule())
                        } else {
                            Text(ConnectionEntryPresentation.route(record))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }

                    HStack(spacing: 5) {
                        if badge != nil {
                            Text(ConnectionEntryPresentation.route(record))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.secondary)
                        }
                        Text(ConnectionEntryPresentation.endpoint(record))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(ConnectionEntryPresentation.endpoint(record))
                    }

                    if let relay = record.relay {
                        Text("设备 ID: \(relay.deviceID.uuidString.lowercased())")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(relay.deviceID.uuidString.lowercased())
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(ConnectionEntryPresentation.savedQualityLabel(record))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if activeMappings > 0 {
                    Text("\(activeMappings) 条映射启用中")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(alignment: .center, spacing: 8) {
                Text(record.lastConnected == .distantPast
                     ? "已保存 · 尚未远控"
                     : "上次连接 \(record.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button("测速", action: benchmark)
                    .controlSize(.small)
                    .help("实测此记录可用的直连与各中继线路质量及丢包情况")
                    .accessibilityLabel("测试 \(ConnectionEntryPresentation.title(record)) 的线路质量")

                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("连接 \(ConnectionEntryPresentation.title(record))")

                Menu {
                    Button("测试线路质量…", action: benchmark)
                    Button("配置 TCP 端口映射…", action: openMapping)
                    Divider()
                    Button("移除此记录", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多设备操作")
                .accessibilityLabel("\(ConnectionEntryPresentation.title(record)) 的记录操作")
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    highlighted ? Color.accentColor.opacity(0.38) : Color(nsColor: .separatorColor).opacity(0.65),
                    lineWidth: highlighted ? 1.3 : 0.8
                )
        }
        .contextMenu {
            Button("连接", action: connect)
            Button("测试线路质量…", action: benchmark)
            Button("配置 TCP 端口映射…", action: openMapping)
            Divider()
            Button("移除", role: .destructive, action: remove)
        }
    }
}

private struct PreFlightReadinessCard: View {
    let summary: ConnectionPreFlightSummary
    let openPreferences: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Color.accentColor)
                Text("本机连接前就绪状态")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                if let openPreferences {
                    Button("偏好设置 →", action: openPreferences)
                        .buttonStyle(.link)
                        .font(.caption.weight(.medium))
                }
            }

            readinessRow(title: "Caps Lock 远端中英切换", value: summary.capsLockTitle, ok: summary.capsLockReady)
            readinessRow(title: "全屏系统快捷键 (⌘Tab / ⌘Space)", value: summary.shortcutsTitle, ok: summary.shortcutsReady)
            readinessRow(title: "剪贴板与文件按需拉取", value: summary.clipboardTitle, ok: summary.clipboardReady)

            Spacer(minLength: 0)

            Text("快捷键：⌃⌥Esc 释放控制 · ⌃⌘F 全屏 · ⌃⌘S 远端截图")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        }
    }

    private func readinessRow(title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11.5))
                .foregroundStyle(ok ? Color(red: 0.07, green: 0.64, blue: 0.44) : Color.secondary)
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ok ? Color(red: 0.07, green: 0.64, blue: 0.44) : Color.secondary)
                .lineLimit(1)
        }
    }
}

struct ConnectionEntryView<NodePicker: View, Options: View>: View {
    let records: [ConnectionRecord]
    let locked: Bool
    let failure: String?
    let status: String
    let relayEnabled: Bool
    @Binding var address: String
    @Binding var port: String
    @Binding var code: String
    @Binding var strategy: RelayConnectionStrategy
    @Binding var deviceID: String
    let nodePicker: NodePicker
    @Binding var showOptions: Bool
    let options: Options
    let connect: () -> Void
    let cancel: () -> Void
    let quickConnect: (ConnectionRecord) -> Void
    let remove: (ConnectionRecord) -> Void
    let manage: () -> Void
    let openOptions: () -> Void
    let openCaps: () -> Void
    let openRelay: () -> Void
    let openTraffic: () -> Void
    var openBenchmark: () -> Void = {}
    var benchmarkRecord: (ConnectionRecord) -> Void = { _ in }
    var openPortMappingRecord: (ConnectionRecord) -> Void = { _ in }
    var qualityBadge: (ConnectionRecord) -> ConnectionRecordCardBadge? = { _ in nil }
    var runningMappingsCount: (ConnectionRecord) -> Int = { _ in 0 }
    var preFlight: ConnectionPreFlightSummary? = nil
    @State private var query = ""
    @State private var expandedRecords = false
    @FocusState private var focusedField: ConnectionEntryPresentation.Field?

    private var usesRelay: Bool { relayEnabled && strategy != .direct }
    private var showsAddress: Bool { !relayEnabled || strategy != .relay }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if locked {
                    connectingBanner
                }
                quickConnectCard
                    .id("new-connection")

                if records.isEmpty {
                    firstUseGuideCard
                } else {
                    RecentConnectionsView(
                        records: records,
                        locked: locked,
                        query: $query,
                        expanded: $expandedRecords,
                        connect: quickConnect,
                        remove: remove,
                        manage: manage,
                        benchmark: benchmarkRecord,
                        openMapping: openPortMappingRecord,
                        qualityBadge: qualityBadge,
                        runningMappingsCount: runningMappingsCount,
                        preFlight: preFlight,
                        openPreferences: openCaps
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if records.isEmpty || failure != nil {
                focusIncompleteField()
            }
        }
        .onChange(of: failure) { _, newFailure in
            if newFailure != nil {
                focusIncompleteField()
            }
        }
    }

    private var connectingBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在建立加密连接…")
                    .font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("取消连接", action: cancel)
                .controlSize(.regular)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
    }

    private var quickConnectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Label("快速发起新连接", systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 8)
                if relayEnabled {
                    Picker("连接策略", selection: $strategy) {
                        ForEach(RelayConnectionStrategy.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(locked)
                } else {
                    Button(action: openRelay) {
                        Label("直连 IP/域名 · 配置自托管中继…", systemImage: "network")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .disabled(locked)
                }
            }

            if let failure {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(failure)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试", action: connect)
                        .controlSize(.small)
                        .disabled(locked)
                }
                .padding(11)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            ViewThatFits(in: .horizontal) {
                horizontalInputRow
                verticalInputStack
            }
            .textFieldStyle(.roundedBorder)
            .disabled(locked)

            HStack(spacing: 14) {
                if usesRelay {
                    HStack(spacing: 6) {
                        Text("中继节点：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        nodePicker
                            .controlSize(.small)
                    }
                }
                Button(action: openOptions) {
                    Label("本次连接选项…", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showOptions, arrowEdge: .bottom) { options }

                Button(action: openCaps) {
                    Label("键盘与防窥偏好", systemImage: "keyboard")
                }

                if relayEnabled {
                    Button(action: openRelay) {
                        Label("管理节点", systemImage: "server.rack")
                    }
                }

                Spacer(minLength: 0)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        }
    }

    private var horizontalInputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if usesRelay {
                labeledField("目标设备标识", minWidth: 190) {
                    TextField("被控 Mac 显示的完整 UUID", text: $deviceID)
                        .font(.system(size: 12.5, design: .monospaced))
                        .accessibilityLabel("目标中继设备标识")
                        .focused($focusedField, equals: .deviceID)
                        .onSubmit { focusedField = showsAddress ? .address : .code }
                }
            }
            if showsAddress {
                labeledField(usesRelay ? "可选直连地址" : "目标地址（域名或 IP）", minWidth: 170) {
                    TextField(usesRelay ? "可选：已知域名或 IP" : "例如 studio.local 或 10.0.0.8", text: $address)
                        .font(.system(size: 12.5))
                        .accessibilityLabel("家里 Mac 的地址")
                        .focused($focusedField, equals: .address)
                        .onSubmit { focusedField = .code }
                }
                labeledField("端口", fixedWidth: 82) {
                    TextField("5908", text: $port)
                        .font(.system(size: 12.5, design: .monospaced))
                        .accessibilityLabel("映射后的端口")
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .code }
                }
            }
            labeledField("配对码", minWidth: 175) {
                SecureField("粘贴完整配对码", text: $code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .accessibilityLabel("家里 Mac 显示的配对码")
                    .focused($focusedField, equals: .code)
                    .onSubmit { if !locked { connect() } }
            }

            HStack(spacing: 8) {
                Button("测速", action: openBenchmark)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(locked)
                    .help("实测直连与各中继方式的实际帧率、延迟及 UDP 丢包情况")

                Button(action: connect) {
                    Label("连接", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(locked)
                .help("配对码输入完成后也可按 Return 连接")
            }
        }
    }

    private var verticalInputStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesRelay {
                labeledField("目标设备标识") {
                    TextField("被控 Mac 显示的完整 UUID", text: $deviceID)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($focusedField, equals: .deviceID)
                        .onSubmit { focusedField = showsAddress ? .address : .code }
                }
            }
            if showsAddress {
                HStack(spacing: 10) {
                    labeledField(usesRelay ? "可选直连地址" : "目标地址（域名或 IP）") {
                        TextField(usesRelay ? "可选：已知域名或 IP" : "域名或 IP", text: $address)
                            .focused($focusedField, equals: .address)
                            .onSubmit { focusedField = .code }
                    }
                    labeledField("端口", fixedWidth: 90) {
                        TextField("5908", text: $port)
                            .font(.system(size: 12.5, design: .monospaced))
                            .focused($focusedField, equals: .port)
                            .onSubmit { focusedField = .code }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                labeledField("配对码") {
                    SecureField("粘贴完整配对码", text: $code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .focused($focusedField, equals: .code)
                        .onSubmit { if !locked { connect() } }
                }
                Button("测速", action: openBenchmark)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private func labeledField<FieldContent: View>(
        _ label: String,
        minWidth: CGFloat? = nil,
        fixedWidth: CGFloat? = nil,
        @ViewBuilder content: () -> FieldContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
        }
        .frame(minWidth: minWidth)
        .frame(width: fixedWidth)
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil, alignment: .leading)
    }

    private func focusIncompleteField() {
        guard !locked else { return }
        focusedField = ConnectionEntryPresentation.firstIncompleteField(
            relayEnabled: relayEnabled,
            strategy: strategy,
            address: address,
            port: port,
            deviceID: deviceID,
            code: code
        )
    }

    private var firstUseGuideCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("第一次使用 QuietDesk")
                    .font(.headline)
                Text("在另一台 Mac 打开 QuietDesk → 左侧选择「本机共享」→ 开启共享并复制配对码，然后在上方粘贴连接。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("同一局域网直接填写内网 IP（默认端口 5908）；异地跨网可配置路由器 TCP/UDP 同端口转发，或启用左侧「端口映射与中继」中的自托管中继。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        }
    }
}
