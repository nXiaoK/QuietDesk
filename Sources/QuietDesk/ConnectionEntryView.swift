import SwiftUI
import QuietDeskCore

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

    private var matches: [ConnectionRecord] { ConnectionEntryPresentation.matching(records, query: query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近连接").font(.headline)
                Text("\(records.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("管理记录…", action: manage).buttonStyle(.link).disabled(locked)
            }
            Text("按上次连接排序；本机记录不代表设备当前在线。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、地址或设备标识", text: $query)
                    .textFieldStyle(.plain).accessibilityLabel("搜索最近连接")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("清除搜索").accessibilityLabel("清除最近连接搜索")
                }
            }
            .padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有匹配的连接").font(.callout.weight(.medium))
                    Text("试试设备名称、域名、IP 或完整设备标识，也可以清除搜索。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            } else {
                VStack(spacing: 8) {
                    ForEach(ConnectionEntryPresentation.visible(records, query: query, expanded: expanded)) { record in
                        RecentConnectionRow(record: record, connect: { connect(record) }, remove: { remove(record) })
                            .disabled(locked)
                    }
                }
            }
            if searching {
                Text("找到 \(matches.count) 条，共 \(records.count) 条记录")
                    .font(.caption).foregroundStyle(.secondary)
            } else if records.count > ConnectionEntryPresentation.recentLimit {
                Button(expanded ? "收起为最近 \(ConnectionEntryPresentation.recentLimit) 条" : "显示全部 \(records.count) 条记录") {
                    expanded.toggle()
                }.buttonStyle(.link)
            }
            Text("点按「连接」尝试使用本机保存的配对码；旧记录或凭据缺失时会请你补录，不会读取钥匙串。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecentConnectionRow: View {
    let record: ConnectionRecord
    let connect: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 18)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ConnectionEntryPresentation.title(record)).font(.headline).lineLimit(1).help(record.name)
                    Text(ConnectionEntryPresentation.route(record)).font(.caption).foregroundStyle(.secondary)
                }
                Text(ConnectionEntryPresentation.endpoint(record)).font(.caption).monospaced()
                    .lineLimit(1).truncationMode(.middle).help(ConnectionEntryPresentation.endpoint(record))
                if let relay = record.relay {
                    Text("设备 \(relay.deviceID.uuidString.lowercased())").font(.caption).monospaced()
                        .lineLimit(1).truncationMode(.middle).help(relay.deviceID.uuidString.lowercased())
                }
                Text("上次连接 \(record.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("连接", action: connect).controlSize(.small)
                .accessibilityLabel("连接 \(ConnectionEntryPresentation.title(record))")
            Menu {
                Button("移除此记录", action: remove)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("记录操作").accessibilityLabel("\(ConnectionEntryPresentation.title(record)) 的记录操作")
        }
        .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { Button("移除", action: remove) }
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
    @State private var query = ""
    @State private var expandedRecords = false
    @State private var expandedForm = false
    @State private var expandedNetwork = false
    @FocusState private var focusedField: ConnectionEntryPresentation.Field?

    private var showForm: Binding<Bool> {
        Binding(get: { ConnectionEntryPresentation.showsForm(hasRecords: !records.isEmpty, expanded: expandedForm, failure: failure) },
                set: { expandedForm = $0 })
    }
    private var usesRelay: Bool { relayEnabled && strategy != .direct }
    private var showsAddress: Bool { !relayEnabled || strategy != .relay }
    private var networkSummary: String {
        let route = relayEnabled ? strategy.title : RelayConnectionStrategy.direct.title
        return showsAddress ? "\(route) · 端口 \(port)" : route
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 14) {
                            Image(systemName: "desktopcomputer").font(.system(size: 28)).foregroundStyle(.tint)
                                .frame(width: 52, height: 52)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("你的另一张书桌").font(.system(size: 22, weight: .bold))
                                Text(records.isEmpty ? "输入地址和配对码，连接另一台 Mac" : "从最近连接继续，或填写一个新连接")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button(action: openTraffic) { Label("流量统计…", systemImage: "chart.bar.xaxis") }
                                .buttonStyle(.link).font(.callout)
                        }
                        if locked {
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small)
                                Text(status).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button("取消", action: cancel).controlSize(.large)
                            }
                            .padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                        DisclosureGroup(isExpanded: showForm) {
                            connectionForm.padding(.top, 12)
                        } label: {
                            HStack {
                                Label("新连接", systemImage: "plus.circle").font(.headline)
                                Spacer()
                                if !showForm.wrappedValue { Text("地址与配对码").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .id("new-connection")
                        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        if records.isEmpty { firstUse }
                        else {
                            RecentConnectionsView(records: records, locked: locked, query: $query, expanded: $expandedRecords,
                                                  connect: quickConnect, remove: remove, manage: manage)
                        }
                    }
                    .frame(width: min(geometry.size.width - 48, geometry.size.width < 960 ? 560 : 640))
                    .padding(.top, max(28, min(48, geometry.size.height * 0.07))).padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: expandedForm) { _, expanded in
                    if expanded { scroll.scrollTo("new-connection", anchor: .top); focusIncompleteField() }
                }
                .onChange(of: failure) { _, failure in
                    guard failure != nil else { return }
                    expandedForm = true; expandedNetwork = true
                    scroll.scrollTo("new-connection", anchor: .top)
                    focusIncompleteField()
                }
            }
        }
        .onAppear {
            expandedNetwork = port != "5908" || usesRelay
            if failure != nil { expandedForm = true; expandedNetwork = true }
            if records.isEmpty || failure != nil { focusIncompleteField() }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(failure).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试", action: connect).disabled(locked)
                }
                .padding(12).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 12) {
                if usesRelay {
                    formRow("目标设备标识") {
                        TextField("被控 Mac 显示的完整设备标识", text: $deviceID)
                            .accessibilityLabel("目标中继设备标识").focused($focusedField, equals: .deviceID)
                            .onSubmit { focusedField = showsAddress ? .address : .code }
                    }
                }
                if showsAddress {
                    formRow("Mac 地址") {
                        TextField(usesRelay ? "可选：已知域名或 IP" : "域名或 IP", text: $address)
                            .accessibilityLabel("家里 Mac 的地址").focused($focusedField, equals: .address)
                            .onSubmit { focusedField = .code }
                    }
                }
                formRow("配对码") {
                    SecureField("粘贴完整配对码", text: $code)
                        .accessibilityLabel("家里 Mac 显示的配对码").focused($focusedField, equals: .code)
                        .onSubmit { if !locked { connect() } }
                }
                DisclosureGroup(isExpanded: $expandedNetwork) {
                    VStack(spacing: 12) {
                        if relayEnabled {
                            formRow("连接策略") {
                                Picker("连接策略", selection: $strategy) {
                                    ForEach(RelayConnectionStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }
                        if usesRelay { formRow("中继节点") { nodePicker } }
                        if showsAddress {
                            formRow("端口") {
                                HStack(spacing: 10) {
                                    TextField("5908", text: $port).frame(width: 80)
                                        .accessibilityLabel("映射后的端口").focused($focusedField, equals: .port)
                                        .onSubmit { focusedField = .code }
                                    Text("默认 5908；使用端口映射时填映射后的端口")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.padding(.top, 12)
                } label: {
                    HStack {
                        Text("端口与连接策略").font(.callout)
                        Spacer()
                        Text(networkSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder).controlSize(.large).disabled(locked)
            HStack(spacing: 16) {
                Button(action: openOptions) { Label("连接选项…", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { options }
                Button(action: openCaps) { Label("键盘设置…", systemImage: "keyboard") }
                Button(action: openRelay) { Label("中继设置…", systemImage: "network") }
                Spacer(minLength: 0)
                Button("连接", action: connect).buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(locked).help("配对码输入完成后也可按 Return 连接")
            }.buttonStyle(.link).font(.callout)
        }
    }

    private func focusIncompleteField() {
        guard !locked else { return }
        focusedField = ConnectionEntryPresentation.firstIncompleteField(relayEnabled: relayEnabled, strategy: strategy,
            address: address, port: port, deviceID: deviceID, code: code)
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.body).frame(width: 100, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 32)
    }

    private var firstUse: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第一次使用").font(.headline)
            Text("在另一台 Mac 打开 QuietDesk →「共享这台 Mac」→ 开启共享，再填写它的地址和完整配对码。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("同一局域网可使用局域网 IP；跨网络连接需要端口映射或已配置的自托管中继。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
