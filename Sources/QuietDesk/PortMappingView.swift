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
            if !embedded {
                HStack(alignment: .top) {
                    DeskSectionHeading(title: "TCP 端口映射", symbol: nil, detail: "管理到目标设备的加密 TCP 转发。")
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                }
            }

            deviceSelector

            if embedded {
                mappingTable
            } else {
                ScrollView { mappingTable }
            }

            if let message = error ?? manager.storageError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DeskPalette.amber)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Label(
                "被控 Mac 需开启桌面共享或「本机映射授权」中的独立映射服务。远控画面活动期间映射流量自动退让限速，优先保障键鼠与帧率。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(DeskPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let selected { deviceProfile(selected) }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 740, height: embedded ? nil : 500)
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
        } message: { _ in Text("当前规则的本地监听和加密转发会同时停止。") }
    }

    private var deviceSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let selected {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)
                    Text(ConnectionEntryPresentation.title(selected))
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    if model.hasConnectedDesktopSession(for: selected.id) {
                        DeskPillBadge(text: "远控已连接", symbol: "circle.fill", tint: DeskPalette.emerald)
                    }
                }
            }

            HStack(spacing: 10) {
                Picker("目标设备", selection: Binding(get: { selected?.id }, set: selectDevice)) {
                    if model.connections.isEmpty { Text("尚无已存设备").tag(nil as UUID?) }
                    ForEach(model.connections) { record in
                        Text("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))")
                            .tag(Optional(record.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("目标设备")
                .frame(maxWidth: 350)
                if !model.connected && !model.working {
                    Button("导入连接草稿") {
                        do { selectDevice(try model.savePortMappingDevice()) }
                        catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .help("在「新建连接」填写连接信息，并选择「用于端口映射…」后导入")
                }
                Spacer(minLength: 0)
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
                .frame(minWidth: 600)
            mappingTable(compact: true)
        }
    }

    private func mappingTable(compact: Bool) -> some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 9) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("映射列表").font(.headline)
                    Text(rules.count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DeskPalette.muted)
                        .accessibilityLabel("\(rules.count) 条规则")
                    Spacer()
                    Button {
                        if let selected { editor = MappingEditorSelection(device: selected) }
                    } label: {
                        Label("添加映射", systemImage: "plus")
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(selected == nil)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
                if rules.isEmpty {
                    mappingEmptyState
                } else {
                    mappingColumns(compact: compact)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(DeskPalette.insetBackground)
                    ForEach(rules) { rule in
                        Divider().padding(.horizontal, 14)
                        mappingRow(rule, compact: compact)
                    }
                }

                Divider()
                HStack {
                    Text("\(rules.count) 条规则 · \(rules.filter { manager.isEnabled($0.id) }.count) 条已启用")
                    Spacer()
                    Text("本地仅监听 127.0.0.1")
                }
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var mappingEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24))
                .foregroundStyle(DeskPalette.muted)
                .accessibilityHidden(true)
            Text(selected == nil ? "请先添加或选择目标 Mac" : "尚无 TCP 端口映射规则")
                .font(.headline)
            Text(selected == nil
                 ? "先连接一次目标设备，或在「新建连接」填写连接信息后选择「用于端口映射…」，再导入草稿。"
                 : "添加规则后可通过本机端口安全访问远端服务。曾远控过该 Mac 时免确认直通；未曾远控的设备首次启用需被控端确认。")
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
    }

    private func mappingColumns(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            portColumn(Text("本地端口"))
            addressColumn(Text(compact ? "目标地址与端口" : "目标地址"))
            if !compact { portColumn(Text("目标端口")) }
            statusColumn(Text("映射状态"), compact: compact)
            Text("操作").frame(width: 72, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func mappingRow(_ rule: PortMappingRule, compact: Bool) -> some View {
        let targetAddress = compact ? rule.target.mappingAddress : rule.target.host
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).fontWeight(.medium).lineLimit(1).help(rule.name)
                Text(rule.scope.title).font(.caption).foregroundStyle(DeskPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            portColumn(Text(rule.localPort.formatted(.number.grouping(.never))).monospacedDigit())
                .accessibilityLabel("本地端口 \(rule.localPort)")
            addressColumn(Text(verbatim: targetAddress).lineLimit(1).truncationMode(.middle))
                .help(targetAddress)
                .textSelection(.enabled)
                .accessibilityLabel("目标地址 \(targetAddress)")
            if !compact {
                portColumn(Text(rule.target.port.formatted(.number.grouping(.never))).monospacedDigit())
                    .accessibilityLabel("目标端口 \(rule.target.port)")
            }
            statusColumn(statusView(manager.states[rule.id]), compact: compact)
                .font(.caption)
            HStack(spacing: 6) {
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
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func portColumn(_ content: some View) -> some View {
        content.frame(width: 54, alignment: .leading)
    }

    private func addressColumn(_ content: some View) -> some View {
        content.frame(width: 96, alignment: .leading)
    }

    private func statusColumn(_ content: some View, compact: Bool) -> some View {
        content.frame(width: compact ? 102 : 132, alignment: .leading)
    }

    @ViewBuilder
    private func statusView(_ state: PortMappingState?) -> some View {
        switch state {
        case .authorizing:
            Label("正在握手或等待被控端确认…", systemImage: "clock.fill")
                .foregroundStyle(DeskPalette.amber)
        case let .listening(_, connections):
            Label(
                connections > 0 ? "正在转发 · \(connections) 个活跃连接" : "监听就绪 · 等待本地连接",
                systemImage: "circle.fill"
            )
            .foregroundStyle(DeskPalette.emerald)
        case let .targetFailed(_, reason):
            Label("本地仍在监听 · \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DeskPalette.amber)
        case let .failed(reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(DeskPalette.coral)
        case .stopped, nil:
            Label("已停用", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PortMappingEditor: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeskSectionHeading(title: item.rule == nil ? "添加 TCP 映射规则" : "编辑 TCP 映射规则", symbol: nil, detail: nil)
            VStack(alignment: .leading, spacing: 11) {
                editorField("名称") {
                    TextField("名称", text: $name, prompt: Text("例如：Web 开发服务"))
                        .accessibilityLabel("映射名称")
                }
                editorField("本地端口") {
                    TextField("本地端口", text: $localPort, prompt: Text("3000"))
                        .accessibilityLabel("本地端口")
                }
                editorField("目标地址") {
                    TextField("目标地址", text: $host, prompt: Text("回环 127.0.0.1 或私有局域网 IP"))
                        .accessibilityLabel("目标地址")
                }
                editorField("目标端口") {
                    TextField("目标端口", text: $remotePort, prompt: Text(localPort.isEmpty ? "留空默认同本地端口" : localPort))
                        .accessibilityLabel("目标端口")
                }
                editorField("运行方式") {
                    Picker("运行方式", selection: $scope) {
                        ForEach(PortMappingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text("目标地址从「\(ConnectionEntryPresentation.title(item.device))」发起访问，127.0.0.1 表示该 Mac 自身。")
                Text(scope == .independent
                     ? "独立规则在断开桌面远控后继续保持转发；系统睡眠或退出 QuietDesk 会停止映射。"
                     : "会话规则仅在此设备的远控会话期间工作，断开远控自动停止。")
            }
            .font(.caption)
            .foregroundStyle(DeskPalette.secondary)
            if let enableError {
                Label("规则已保存，但未启用。\(enableError)", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(DeskPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mapping.savedWithoutEnabling")
            }
            if let error { Text(error).foregroundStyle(DeskPalette.coral).font(.callout) }
            HStack(spacing: 10) {
                Button(enableError == nil ? "取消" : "关闭") { dismiss() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(item.rule == nil ? "仅保存" : "保存并停用") { submit(enable: false) }
                    .buttonStyle(DeskButtonStyle(.secondary))
                Button(enableError == nil ? "保存并启用" : "保存并重试启用") { submit(enable: true) }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(scope == .session && !sessionAvailable)
            }
            .padding(.top, 10)
        }
        .padding(24)
        .frame(width: 500)
        .deskSurface()
    }

    private func editorField(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(DeskPalette.secondary).accessibilityHidden(true)
            content().labelsHidden()
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
