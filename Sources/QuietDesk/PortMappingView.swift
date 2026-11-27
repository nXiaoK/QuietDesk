import SwiftUI
import QuietDeskCore

private struct MappingEditorSelection: Identifiable {
    let id: UUID
    let device: ConnectionRecord
    let rule: PortMappingRule?
    init(device: ConnectionRecord, rule: PortMappingRule? = nil) {
        self.id = rule?.id ?? UUID()
        self.device = device
        self.rule = rule
    }
}

struct PortMappingView<DeviceProfile: View>: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    let embedded: Bool
    @Binding private var workspaceDeviceID: UUID?
    @ViewBuilder let deviceProfile: (ConnectionRecord) -> DeviceProfile
    @State private var sheetDeviceID: UUID?
    @State private var editor: MappingEditorSelection?
    @State private var deleting: PortMappingRule?
    @State private var error: String?

    init(
        model: DeskModel,
        manager: PortMappingManager,
        done: @escaping () -> Void,
        embedded: Bool = false,
        workspaceDeviceID: Binding<UUID?> = .constant(nil),
        @ViewBuilder deviceProfile: @escaping (ConnectionRecord) -> DeviceProfile = { _ in EmptyView() }
    ) {
        self.model = model
        self.manager = manager
        self.done = done
        self.embedded = embedded
        self._workspaceDeviceID = workspaceDeviceID
        self.deviceProfile = deviceProfile
    }

    private var selected: ConnectionRecord? {
        let candidates = [embedded ? workspaceDeviceID : sheetDeviceID,
                          model.preferredMappingRecordID, model.selectedConnectionID]
        for case let id? in candidates {
            if let record = model.connections.first(where: { $0.id == id }) { return record }
        }
        return model.connections.first
    }

    private var rules: [PortMappingRule] {
        let id = selected?.id
        return manager.rules.filter { $0.deviceID == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            deviceSelector

            if embedded {
                mappingTable
            } else {
                ScrollView { mappingTable }
            }

            if let message = error ?? manager.storageError {
                DeskCalloutBox(message: message, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }

            DeskCalloutBox(
                title: "被控端授权",
                message: "仅支持 TCP。访问目标需经过被控端授权。远控活动时映射流量自动退让，TLS 与证书信任沿用连接配置。",
                symbol: "info.circle",
                tone: .info
            )

            if let selected { deviceProfile(selected) }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 520)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onChange(of: selected?.id) { _, _ in error = nil }
        .sheet(item: $editor) { item in
            PortMappingEditor(
                item: item,
                sessionAvailable: model.hasConnectedDesktopSession(for: item.device.id),
                save: { rule in try manager.saveRule(rule); error = nil },
                enable: { rule in
                    try model.startPortMapping(rule)
                    if case let .failed(reason) = manager.states[rule.id] {
                        throw DeskError.invalid(reason)
                    }
                }
            )
        }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting) { rule in
            Button("删除规则", role: .destructive) {
                do { try manager.deleteRule(rule.id); error = nil }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("删除后停止对应映射；其他连接记录和规则保持不变。") }
    }

    private var deviceSelector: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                mappingHeading
                Spacer(minLength: 8)
                mappingActions
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                mappingHeading
                mappingActions
            }
        }
    }

    private var mappingHeading: some View {
        DeskSettingsPageHeading(
            title: "TCP 端口映射",
            detail: selected.map {
                "\(ConnectionEntryPresentation.title($0)) · \(ConnectionEntryPresentation.endpoint($0))"
            } ?? "先连接目标设备，或从新建连接导入草稿。",
            badgeText: selected.flatMap { model.hasConnectedDesktopSession(for: $0.id) ? "已连接" : nil }
        )
    }

    private var mappingActions: some View {
        HStack(spacing: 8) {
            if model.connections.count > 1 {
                Menu {
                    ForEach(model.connections) { record in
                        Button {
                            selectDevice(record.id)
                        } label: {
                            if record.id == selected?.id {
                                Label("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))", systemImage: "checkmark")
                            } else {
                                Text("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))")
                            }
                        }
                    }
                } label: {
                    Label("切换设备", systemImage: "chevron.up.chevron.down")
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .accessibilityLabel("切换目标设备")
            }

            if !model.connected && !model.working && !model.address.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("导入连接草稿") {
                    do { selectDevice(try model.savePortMappingDevice()) }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .help("将新建连接中填写的目标信息导入为端口映射目标")
            }
            if !embedded {
                Button("完成", action: done)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func selectDevice(_ id: UUID?) {
        if embedded { workspaceDeviceID = id } else { sheetDeviceID = id }
        error = nil
    }

    private var mappingTable: some View {
        ViewThatFits(in: .horizontal) {
            mappingTable(compact: false)
                .frame(minWidth: 580)
            mappingTable(compact: true)
        }
    }

    private func mappingTable(compact: Bool) -> some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("映射列表")
                        .font(.system(size: 15, weight: .semibold))
                    DeskPillBadge(text: "\(rules.count) 条规则", tint: DeskPalette.secondary, monospaced: true)
                    Spacer()
                    Button {
                        if let selected { editor = MappingEditorSelection(device: selected) }
                    } label: {
                        Label("添加映射", systemImage: "plus")
                    }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(selected == nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                Divider()

                mappingColumns(compact: compact)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(DeskPalette.insetBackground)

                if rules.isEmpty {
                    Divider()
                    VStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(DeskPalette.accent)
                            .accessibilityHidden(true)
                        Text("暂无映射规则")
                            .font(.system(size: 14, weight: .semibold))
                        Text(selected == nil
                             ? "先连接目标设备，或从「新建连接 → 用于端口映射…」导入草稿。"
                             : "点按「添加映射」配置一条 TCP 转发。")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskPalette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(rules) { rule in
                        Divider()
                        mappingRow(rule, compact: compact)
                    }
                }

                Divider()
                HStack {
                    Text("本地仅监听 127.0.0.1")
                        .monospacedDigit()
                    Spacer()
                    if !rules.isEmpty {
                        Text("\(rules.filter { manager.isEnabled($0.id) }.count) 条已启用")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(DeskPalette.insetBackground.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func mappingColumns(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            portColumn(Text("本地端口"), compact: compact)
            addressColumn(Text(compact ? "目标地址与端口" : "目标地址"), compact: compact)
            if !compact { portColumn(Text("目标端口"), compact: false) }
            statusColumn(Text("映射状态"), compact: compact)
            Text("操作").frame(width: 72, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func mappingRow(_ rule: PortMappingRule, compact: Bool) -> some View {
        let targetAddress = compact ? rule.target.mappingAddress : rule.target.host
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .help(rule.name)
                if rule.scope == .independent {
                    Text("独立映射")
                        .font(.system(size: 11))
                        .foregroundStyle(DeskPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            portColumn(
                Text(rule.localPort.formatted(.number.grouping(.never)))
                    .font(.system(size: 13, design: .monospaced)),
                compact: compact
            )
            .accessibilityLabel("本地端口 \(rule.localPort)")

            addressColumn(
                Text(verbatim: targetAddress)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle),
                compact: compact
            )
            .help(targetAddress)
            .textSelection(.enabled)
            .accessibilityLabel("目标地址 \(targetAddress)")

            if !compact {
                portColumn(
                    Text(rule.target.port.formatted(.number.grouping(.never)))
                        .font(.system(size: 13, design: .monospaced)),
                    compact: false
                )
                .accessibilityLabel("目标端口 \(rule.target.port)")
            }

            statusColumn(statusView(manager.states[rule.id]), compact: compact)

            HStack(spacing: 8) {
                Toggle("启用 \(rule.name)", isOn: Binding(get: { manager.isEnabled(rule.id) }, set: { enabled in
                    do {
                        if enabled { try model.startPortMapping(rule) } else { manager.stop(rule.id) }
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                Menu {
                    Button("编辑规则…") { if let selected { editor = MappingEditorSelection(device: selected, rule: rule) } }
                    Divider()
                    Button("删除规则…", role: .destructive) { deleting = rule }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DeskPalette.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(rule.name)的更多操作")
            }
            .frame(width: 72, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }

    private func portColumn(_ content: some View, compact: Bool) -> some View {
        content.frame(width: compact ? 62 : 68, alignment: .leading)
    }

    private func addressColumn(_ content: some View, compact: Bool) -> some View {
        content.frame(width: compact ? 140 : 114, alignment: .leading)
    }

    private func statusColumn(_ content: some View, compact: Bool) -> some View {
        content.frame(width: compact ? 104 : 156, alignment: .leading)
    }

    @ViewBuilder
    private func statusView(_ state: PortMappingState?) -> some View {
        switch state {
        case .authorizing:
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11.5))
                Text("正在握手或等待被控端确认…")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.amber)
            .help("正在握手或等待被控端确认…")
        case let .listening(_, connections):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text(connections > 0 ? "正在转发 · \(connections) 个连接" : "监听就绪")
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DeskPalette.emerald)
        case let .targetFailed(_, reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                Text("本地仍在监听 · \(reason)")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.amber)
            .help("本地仍在监听 · \(reason)")
        case let .failed(reason):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11.5))
                Text(reason)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.coral)
            .help(reason)
        case .stopped, nil:
            HStack(spacing: 6) {
                Circle()
                    .fill(DeskPalette.muted.opacity(0.65))
                    .frame(width: 6, height: 6)
                Text("已停用")
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.muted)
        }
    }
}

private struct PortMappingEditor: View {
    private enum Field: Hashable { case name, localPort, host, remotePort }
    let item: MappingEditorSelection
    let sessionAvailable: Bool
    let save: (PortMappingRule) throws -> Void
    let enable: (PortMappingRule) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var localPort: String
    @State private var host: String
    @State private var remotePort: String
    @State private var scope: PortMappingScope
    @State private var error: String?
    @State private var enableError: String?
    @FocusState private var focusedField: Field?

    init(item: MappingEditorSelection, sessionAvailable: Bool, save: @escaping (PortMappingRule) throws -> Void,
         enable: @escaping (PortMappingRule) throws -> Void) {
        self.item = item
        self.sessionAvailable = sessionAvailable
        self.save = save
        self.enable = enable
        _name = State(initialValue: item.rule?.name ?? "")
        _localPort = State(initialValue: item.rule.map { String($0.localPort) } ?? "")
        _host = State(initialValue: item.rule?.target.host ?? "127.0.0.1")
        _remotePort = State(initialValue: item.rule.map { String($0.target.port) } ?? "")
        _scope = State(initialValue: item.rule?.scope ?? (sessionAvailable ? .session : .independent))
    }

    private var headingTitle: String {
        if item.rule == nil { return "添加 TCP 映射规则" }
        return scope == .independent ? "编辑独立 TCP 映射" : "编辑 TCP 映射规则"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            DeskSectionHeading(
                title: headingTitle,
                symbol: "point.3.connected.trianglepath.dotted",
                detail: "配置从本机端口到被控端目标的 TCP 转发。"
            )

            editorField("名称") {
                TextField("例如：开发预览", text: $name)
                    .font(.system(size: 13))
                    .focused($focusedField, equals: .name)
                    .deskInputBox(focused: focusedField == .name)
                    .accessibilityLabel("映射名称")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    localEndpoint
                        .frame(width: 190)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)
                    remoteEndpoint
                        .frame(minWidth: 320)
                }
                VStack(spacing: 8) {
                    localEndpoint
                    Image(systemName: "arrow.down")
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)
                    remoteEndpoint
                }
            }

            DeskSettingsGroup(title: "") {
                DeskSettingsRow(title: "运行方式") {
                    Picker("运行方式", selection: $scope) {
                        ForEach(PortMappingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text(scope == .independent
                 ? "无需远控画面；被控端需开启共享或允许独立映射服务。编辑保存会先停止已有运行规则。"
                 : "目标地址从被控 Mac「\(ConnectionEntryPresentation.title(item.device))」访问；127.0.0.1 表示它自身。")
                .font(.system(size: 12.5))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let enableError {
                DeskCalloutBox(
                    message: "规则已保存，但未启用。\(enableError)",
                    symbol: "exclamationmark.circle",
                    tone: .warning
                )
                .accessibilityIdentifier("mapping.savedWithoutEnabling")
            }
            if let error {
                DeskCalloutBox(message: error, symbol: "exclamationmark.circle", tone: .danger)
            }

            Divider()

            HStack(spacing: 10) {
                Button(enableError == nil ? "取消" : "关闭") { dismiss() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(item.rule == nil ? "仅保存" : "保存并停用") { submit(enable: false) }
                    .buttonStyle(DeskButtonStyle(.secondary))
                Button(enableError == nil ? "保存并启用" : "保存并重试启用") { submit(enable: true) }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope == .session && !sessionAvailable)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(minWidth: 468, idealWidth: 680)
        .background(DeskPalette.cardBackground)
        .foregroundStyle(DeskPalette.ink)
        .tint(DeskPalette.accent)
        .onAppear { focusedField = item.rule == nil ? .name : .localPort }
    }

    private var localEndpoint: some View {
        endpointPanel("本机监听") {
            editorField("本地端口") {
                TextField("13000", text: $localPort)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focusedField, equals: .localPort)
                    .deskInputBox(focused: focusedField == .localPort)
                    .accessibilityLabel("本地端口")
            }
            Text("仅监听 127.0.0.1")
                .font(.caption.monospacedDigit())
                .foregroundStyle(DeskPalette.secondary)
        }
    }

    private var remoteEndpoint: some View {
        endpointPanel("被控端目标") {
            HStack(alignment: .top, spacing: 8) {
                editorField("目标地址") {
                    TextField("127.0.0.1 或局域网 IP", text: $host)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .host)
                        .deskInputBox(focused: focusedField == .host)
                        .accessibilityLabel("目标地址")
                }
                editorField("目标端口") {
                    TextField("留空使用本地端口", text: $remotePort)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focusedField, equals: .remotePort)
                        .deskInputBox(focused: focusedField == .remotePort)
                        .accessibilityLabel("目标端口")
                }
                .frame(width: 138)
            }
        }
    }

    private func endpointPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DeskPalette.hairline) }
    }

    private func editorField(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)
                .accessibilityHidden(true)
            content()
        }
    }

    private func submit(enable: Bool) {
        do {
            guard let port = UInt16(localPort.trimmingCharacters(in: .whitespaces)), port > 0 else {
                throw DeskError.invalid("本地端口须为 1 至 65535 之间的整数。")
            }
            let remote = remotePort.trimmingCharacters(in: .whitespaces)
            guard let targetPort = remote.isEmpty ? port : UInt16(remote) else { throw DeskError.invalid("目标端口无效。") }
            let target = try PortMappingTarget(host: host.trimmingCharacters(in: .whitespaces), port: targetPort)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rule = PortMappingRule(id: item.id, deviceID: item.device.id, name: label.isEmpty ? target.mappingAddress : label,
                                       localPort: port, target: target, scope: scope)
            try save(rule)
            error = nil
            if enable {
                do { try self.enable(rule) }
                catch { enableError = error.localizedDescription; return }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
