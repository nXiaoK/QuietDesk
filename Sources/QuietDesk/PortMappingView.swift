import SwiftUI
import QuietDeskCore

private struct MappingEditorSelection: Identifiable {
    let id: UUID
    let machineID: String
    let recordID: UUID
    let allowsMachineSelection: Bool
    let rule: PortMappingRule?

    init(machine: RemoteMachineGroup, recordID: UUID, allowsMachineSelection: Bool, rule: PortMappingRule? = nil) {
        id = rule?.id ?? UUID()
        machineID = machine.id
        self.recordID = recordID
        self.allowsMachineSelection = allowsMachineSelection
        self.rule = rule
    }
}

struct PortMappingView<DeviceProfile: View>: View {
    private enum ScopeFilter: Hashable { case allMachines, machine(String) }

    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    let embedded: Bool
    @Binding private var workspaceDeviceID: UUID?
    @ViewBuilder let deviceProfile: (ConnectionRecord) -> DeviceProfile
    @State private var sheetFilter: ScopeFilter?
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

    var body: some View {
        let groups = model.portMappingMachineGroups()
        let selection = selectedScope(in: groups)
        let selected = groups.first { selection == .machine($0.id) }
        let rulesByMachine = Dictionary(grouping: manager.rules) { rule in
            model.machineGroup(for: rule, in: groups)?.id
        }

        VStack(alignment: .leading, spacing: 16) {
            mappingHeading(groups: groups, selected: selected, filter: selection)
            if let message = error ?? manager.storageError {
                DeskCalloutBox(message: message, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
            if embedded {
                mappingContent(groups: groups, selected: selected, rules: rulesByMachine)
            } else {
                ScrollView { mappingContent(groups: groups, selected: selected, rules: rulesByMachine) }
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 520)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onChange(of: selection) { _, _ in error = nil }
        .sheet(item: $editor) { item in
            PortMappingEditor(
                item: item,
                groups: item.allowsMachineSelection ? groups : groups.filter { $0.id == item.machineID },
                relayNodeNames: model.relayNodeNames,
                sessionAvailable: { model.hasConnectedDesktopSession(forMachine: $0) },
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
            Button("删除规则", role: .destructive) { perform { try manager.deleteRule(rule.id) } }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("删除后会停止这条映射。") }
    }

    private func selectedScope(in groups: [RemoteMachineGroup]) -> ScopeFilter {
        if !embedded, let sheetFilter {
            return groups.contains { sheetFilter == .machine($0.id) } ? sheetFilter : .allMachines
        }
        let id = embedded ? workspaceDeviceID : (workspaceDeviceID ?? model.preferredMappingRecordID ?? model.selectedConnectionID)
        guard let id, let group = groups.first(where: { $0.contains(recordID: id) }) else { return .allMachines }
        return .machine(group.id)
    }

    private func select(_ group: RemoteMachineGroup?, recordID: UUID? = nil) {
        if embedded { workspaceDeviceID = recordID ?? group?.primaryRecord.id }
        else { sheetFilter = group.map { .machine($0.id) } ?? .allMachines }
        error = nil
    }

    private func mappingHeading(groups: [RemoteMachineGroup], selected: RemoteMachineGroup?, filter: ScopeFilter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    pageHeading
                    Spacer(minLength: 8)
                    mappingActions(groups: groups, selected: selected, filter: filter)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    pageHeading
                    mappingActions(groups: groups, selected: selected, filter: filter)
                }
            }
            HStack(spacing: 7) {
                DeskPillBadge(text: "\(manager.rules.count) 条规则", tint: DeskPalette.secondary, monospaced: true)
                DeskPillBadge(text: "\(manager.rules.filter { manager.isEnabled($0.id) }.count) 条运行中",
                              tint: DeskPalette.accent, monospaced: true)
            }
        }
    }

    private var pageHeading: some View {
        DeskSettingsPageHeading(title: "TCP 端口映射")
    }

    private func mappingActions(groups: [RemoteMachineGroup], selected: RemoteMachineGroup?, filter: ScopeFilter) -> some View {
        HStack(spacing: 8) {
            if !groups.isEmpty {
                Menu {
                    Button { select(nil) } label: { filterLabel("全部机器（集中管理）", selected: filter == .allMachines) }
                    Divider()
                    ForEach(groups, id: \.id) { group in
                        Button { select(group) } label: { filterLabel(group.title, selected: filter == .machine(group.id)) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(selected?.title ?? "全部机器")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: 164)
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .accessibilityLabel("筛选被控电脑")
                .accessibilityValue(selected?.title ?? "全部机器")
            }

            if !model.connected && !model.working && !model.address.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("导入连接草稿") {
                    perform {
                        let recordID = try model.savePortMappingDevice()
                        let group = model.portMappingMachineGroups().first { $0.contains(recordID: recordID) }
                        select(group, recordID: recordID)
                    }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .help("将新建连接中填写的目标信息导入为端口映射目标")
            }

            Button {
                if let group = selected ?? groups.first {
                    beginEditor(for: group, allowsMachineSelection: selected == nil)
                }
            } label: {
                Label("添加映射", systemImage: "plus")
            }
            .buttonStyle(DeskButtonStyle(.primary))
            .disabled(groups.isEmpty)

            if !embedded {
                Button("完成", action: done)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private func filterLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private func mappingContent(groups: [RemoteMachineGroup], selected: RemoteMachineGroup?,
                                rules: [String?: [PortMappingRule]]) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if groups.isEmpty, rules[nil, default: []].isEmpty {
                DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                    emptyRules("先连接目标设备，或从「新建连接 → 用于端口映射…」导入草稿。")
                }
            }
            ForEach(selected.map { [$0] } ?? groups, id: \.id) { group in
                machineCard(group, rules: rules[group.id, default: []], allowsMachineSelection: selected == nil)
            }
            if selected == nil, let unmatched = rules[nil], !unmatched.isEmpty {
                DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("原连接记录不可用")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(16)
                        ForEach(unmatched) { rule in
                            Divider()
                            compactRow(rule, group: nil, allowsMachineSelection: false)
                        }
                    }
                }
            }
            DeskCalloutBox(
                title: "被控端授权",
                message: "本机仅监听 127.0.0.1。访问目标需经过被控端授权，TLS 与证书信任沿用连接配置。远控活动时映射流量自动退让。",
                symbol: "info.circle",
                tone: .info
            )
            if let selected {
                let record = selected.routes.first { $0.id == workspaceDeviceID } ?? selected.primaryRecord
                deviceProfile(record)
            }
        }
    }

    private func machineCard(_ group: RemoteMachineGroup, rules: [PortMappingRule],
                             allowsMachineSelection: Bool) -> some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 0) {
                machineHeading(group, showsBatchMenu: !rules.isEmpty && group.routes.count > 1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                Divider()
                if rules.isEmpty {
                    emptyRules("点按「添加映射」配置一条 TCP 转发。")
                } else {
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            mappingColumns
                            ForEach(rules) { rule in
                                Divider()
                                wideRow(rule, group: group, allowsMachineSelection: allowsMachineSelection)
                            }
                        }
                        .frame(minWidth: 672)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rules) { rule in
                                if rule.id != rules.first?.id { Divider() }
                                compactRow(rule, group: group, allowsMachineSelection: allowsMachineSelection)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func machineHeading(_ group: RemoteMachineGroup, showsBatchMenu: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DeskPalette.accent)
                .frame(width: 30, height: 30)
                .background(DeskPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .help(group.title)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    if model.hasConnectedDesktopSession(forMachine: group) {
                        DeskPillBadge(text: "远控已连接", symbol: "circle.fill", tint: DeskPalette.emerald)
                    }
                    DeskPillBadge(text: "\(group.routes.count) 条同机线路", tint: DeskPalette.secondary, monospaced: true)
                }
            }
            Spacer(minLength: 0)
            if showsBatchMenu {
                Menu {
                    routeOptions(group, rule: nil)
                } label: {
                    Label("切换全部线路", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .fixedSize()
                .help("切换这台电脑的所有映射，并重新连接已启用的映射")
            }
        }
    }

    private func emptyRules(_ hint: String) -> some View {
        VStack(spacing: 6) {
            Text("暂无映射规则")
                .font(.system(size: 14, weight: .semibold))
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(19)
        .frame(maxWidth: .infinity)
    }

    private func beginEditor(for group: RemoteMachineGroup, allowsMachineSelection: Bool, rule: PortMappingRule? = nil) {
        let preferredID = rule?.deviceID ?? workspaceDeviceID ?? model.preferredMappingRecordID
        let record = group.routes.first { $0.id == preferredID } ?? group.primaryRecord
        editor = MappingEditorSelection(machine: group, recordID: record.id, allowsMachineSelection: allowsMachineSelection, rule: rule)
    }

    private var mappingColumns: some View {
        HStack(spacing: 10) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("本地端口 → 远端目标").frame(width: 184, alignment: .leading)
            Text("线路").frame(width: 142, alignment: .leading)
            Text("映射状态").frame(width: 126, alignment: .leading)
            Text("操作").frame(width: 72, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DeskPalette.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(DeskPalette.insetBackground)
        .accessibilityHidden(true)
    }

    private func wideRow(_ rule: PortMappingRule, group: RemoteMachineGroup, allowsMachineSelection: Bool) -> some View {
        HStack(spacing: 10) {
            ruleName(rule).frame(maxWidth: .infinity, alignment: .leading)
            ruleEndpoints(rule).frame(width: 184, alignment: .leading)
            routeControl(rule, group: group).frame(width: 142, alignment: .leading)
            statusView(manager.states[rule.id]).frame(width: 126, alignment: .leading)
            ruleActions(rule, editorGroup: group, allowsMachineSelection: allowsMachineSelection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 49)
    }

    private func compactRow(_ rule: PortMappingRule, group: RemoteMachineGroup?, allowsMachineSelection: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                ruleName(rule)
                Spacer(minLength: 0)
                ruleActions(rule, editorGroup: group, allowsMachineSelection: allowsMachineSelection)
            }
            ruleEndpoints(rule)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    routeControl(rule, group: group).fixedSize()
                    statusView(manager.states[rule.id]).fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    routeControl(rule, group: group)
                    statusView(manager.states[rule.id])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func ruleName(_ rule: PortMappingRule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rule.name)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
                .help(rule.name)
            Text(rule.scope.title)
                .font(.system(size: 11))
                .foregroundStyle(DeskPalette.muted)
        }
    }

    private func ruleEndpoints(_ rule: PortMappingRule) -> some View {
        let localPort = rule.localPort.formatted(.number.grouping(.never))
        return HStack(spacing: 5) {
            Text(localPort).fixedSize()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(DeskPalette.muted)
                .accessibilityHidden(true)
            Text(verbatim: rule.target.mappingAddress)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .help("\(localPort) → \(rule.target.mappingAddress)")
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("本地端口 \(localPort)，目标 \(rule.target.mappingAddress)")
    }

    @ViewBuilder
    private func routeControl(_ rule: PortMappingRule, group: RemoteMachineGroup?) -> some View {
        if let group {
            let bound = group.routes.first { $0.id == rule.deviceID } ?? group.primaryRecord
            let actual = manager.activeRouteLabels[rule.id]
            let configured = RemoteMachineGroup.routeShortLabel(for: bound, relayNodeNames: model.relayNodeNames)
            let boundAddress = bound.relay?.endpoint.address
            if group.routes.count > 1 {
                let actualKind = actual?.components(separatedBy: " · ").first
                let actualTitle = actualKind == "中继" ? actual : actualKind
                let label = rule.routeMode == .automatic ? (actualTitle.map { "自动 · \($0)" } ?? "自动") : configured
                Menu {
                    routeOptions(group, rule: rule)
                } label: {
                    HStack(spacing: 4) {
                        if rule.routeMode == .automatic {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(DeskPalette.accent)
                                .accessibilityHidden(true)
                        }
                        Text(label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(DeskButtonStyle(.quiet))
                .help(actual.map { "当前线路 · \($0)" } ?? boundAddress ?? label)
                .accessibilityLabel("\(rule.name)的连接线路")
                .accessibilityValue(label)
            } else {
                Text(actual ?? configured)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help([boundAddress, "为同一台电脑保存其他线路（如 Tailscale 或中继）后，系统会自动识别并允许在此直接切换。"]
                        .compactMap { $0 }.joined(separator: "\n"))
            }
        } else {
            Text("原线路不可用")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
        }
    }

    @ViewBuilder
    private func routeOptions(_ group: RemoteMachineGroup, rule: PortMappingRule?) -> some View {
        Button {
            let recordID = rule.flatMap { group.contains(recordID: $0.deviceID) ? $0.deviceID : nil } ?? group.primaryRecord.id
            switchRoute(group, rule: rule, to: recordID, mode: .automatic)
        } label: {
            Label("同机自动选路（推荐）", systemImage: rule?.routeMode == .automatic ? "checkmark" : "bolt.fill")
        }
        Divider()
        ForEach(group.routes) { record in
            let active = model.hasConnectedDesktopSession(for: record.id)
            let title = RemoteMachineGroup.routeShortLabel(for: record, relayNodeNames: model.relayNodeNames)
                + (active ? "（当前远控）" : "")
            Button { switchRoute(group, rule: rule, to: record.id, mode: .pinned) } label: {
                filterLabel(title, selected: rule?.routeMode == .pinned && rule?.deviceID == record.id)
            }
            .help(record.relay?.endpoint.address ?? title)
        }
    }

    private func switchRoute(_ group: RemoteMachineGroup, rule: PortMappingRule?, to recordID: UUID, mode: PortMappingRouteMode) {
        perform {
            if let rule { try model.switchPortMappingRoute(rule, to: recordID, mode: mode) }
            else { try model.switchMachinePortMappingsRoute(in: group, to: recordID, mode: mode) }
        }
    }

    private func ruleActions(_ rule: PortMappingRule, editorGroup: RemoteMachineGroup?, allowsMachineSelection: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("启用 \(rule.name)", isOn: Binding(get: { manager.isEnabled(rule.id) }, set: { enabled in
                perform {
                    if enabled { try model.startPortMapping(rule) }
                    else { manager.stop(rule.id) }
                }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Menu {
                if let editorGroup {
                    Button("编辑规则…") { beginEditor(for: editorGroup, allowsMachineSelection: allowsMachineSelection, rule: rule) }
                    Divider()
                }
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

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    @ViewBuilder
    private func statusView(_ state: PortMappingState?) -> some View {
        switch state {
        case .authorizing:
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 11.5))
                Text("握手或等待授权")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.amber)
            .help("正在握手或等待被控端确认…")
        case let .listening(_, connections):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                Text(connections > 0 ? "转发中 · \(connections) 个连接" : "监听就绪")
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
    private enum RouteChoice: Hashable { case automatic, pinned(UUID) }

    let item: MappingEditorSelection
    let groups: [RemoteMachineGroup]
    let relayNodeNames: [String: String]
    let sessionAvailable: (RemoteMachineGroup) -> Bool
    let save: (PortMappingRule) throws -> Void
    let enable: (PortMappingRule) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var machineID: String
    @State private var routeChoice: RouteChoice
    @State private var name: String
    @State private var localPort: String
    @State private var host: String
    @State private var remotePort: String
    @State private var scope: PortMappingScope
    @State private var scopeWasEdited = false
    @State private var error: String?
    @State private var enableError: String?
    @FocusState private var focusedField: Field?

    init(item: MappingEditorSelection, groups: [RemoteMachineGroup], relayNodeNames: [String: String],
         sessionAvailable: @escaping (RemoteMachineGroup) -> Bool, save: @escaping (PortMappingRule) throws -> Void,
         enable: @escaping (PortMappingRule) throws -> Void) {
        self.item = item
        self.groups = groups
        self.relayNodeNames = relayNodeNames
        self.sessionAvailable = sessionAvailable
        self.save = save
        self.enable = enable
        let group = groups.first { $0.id == item.machineID }
        let defaultsToAutomatic = item.rule == nil && (group?.routes.count ?? 0) > 1
        _machineID = State(initialValue: item.machineID)
        _routeChoice = State(initialValue: item.rule?.routeMode == .automatic || defaultsToAutomatic
                             ? .automatic : .pinned(item.recordID))
        _name = State(initialValue: item.rule?.name ?? "")
        _localPort = State(initialValue: item.rule.map { String($0.localPort) } ?? "")
        _host = State(initialValue: item.rule?.target.host ?? "127.0.0.1")
        _remotePort = State(initialValue: item.rule.map { String($0.target.port) } ?? "")
        _scope = State(initialValue: item.rule?.scope ?? (group.map(sessionAvailable) == true ? .session : .independent))
    }

    private var machine: RemoteMachineGroup? { groups.first { $0.id == machineID } }

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

            if groups.count > 1 || (machine?.routes.count ?? 0) > 1 {
                routeSettings
            }

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
                    Picker("运行方式", selection: Binding(get: { scope }, set: { scope = $0; scopeWasEdited = true })) {
                        ForEach(PortMappingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text(scope == .independent
                 ? "被控端需开启共享或允许独立映射服务。编辑保存会先停止已有运行规则。"
                 : "目标地址从被控电脑「\(machine?.title ?? "—")」访问，127.0.0.1 表示它自身。")
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
                    .disabled(machine == nil)
                Button(enableError == nil ? "保存并启用" : "保存并重试启用") { submit(enable: true) }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(machine == nil || (scope == .session && machine.map(sessionAvailable) != true))
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(minWidth: 468, idealWidth: 680)
        .background(DeskPalette.cardBackground)
        .foregroundStyle(DeskPalette.ink)
        .tint(DeskPalette.accent)
        .onAppear { focusedField = item.rule == nil ? .name : .localPort }
        .onChange(of: machineID) { _, _ in
            guard let machine else { return }
            routeChoice = machine.routes.count > 1 ? .automatic : .pinned(machine.primaryRecord.id)
            if item.rule == nil, !scopeWasEdited {
                scope = sessionAvailable(machine) ? .session : .independent
            }
            error = nil
        }
    }

    private var routeSettings: some View {
        DeskSettingsGroup(title: "") {
            if groups.count > 1 {
                DeskSettingsRow(title: "目标被控电脑") {
                    Picker("目标被控电脑", selection: $machineID) {
                        ForEach(groups, id: \.id) { group in Text(group.title).tag(group.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 325)
                }
            }
            if let machine, machine.routes.count > 1 {
                if groups.count > 1 { Divider() }
                DeskSettingsRow(title: "连接线路") {
                    Picker("连接线路", selection: $routeChoice) {
                        Text("同机自动选路（跟随当前会话 / 失败自动切线）").tag(RouteChoice.automatic)
                        ForEach(machine.routes) { record in
                            Text(RemoteMachineGroup.routeShortLabel(for: record, relayNodeNames: relayNodeNames))
                                .tag(RouteChoice.pinned(record.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 325)
                }
            }
        }
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
            guard let machine else { throw DeskError.invalid("目标被控电脑已移除。") }
            guard let port = UInt16(localPort.trimmingCharacters(in: .whitespaces)), port > 0 else {
                throw DeskError.invalid("本地端口须为 1 至 65535 之间的整数。")
            }
            let remote = remotePort.trimmingCharacters(in: .whitespaces)
            guard let targetPort = remote.isEmpty ? port : UInt16(remote) else { throw DeskError.invalid("目标端口无效。") }
            let target = try PortMappingTarget(host: host.trimmingCharacters(in: .whitespaces), port: targetPort)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordID: UUID
            let mode: PortMappingRouteMode
            switch routeChoice {
            case .automatic:
                recordID = machine.contains(recordID: item.recordID) ? item.recordID : machine.primaryRecord.id
                mode = .automatic
            case .pinned(let id):
                guard machine.contains(recordID: id) else { throw DeskError.invalid("指定线路已移除，请重新选择。") }
                recordID = id
                mode = .pinned
            }
            let rule = PortMappingRule(id: item.id, deviceID: recordID, name: label.isEmpty ? target.mappingAddress : label,
                                       localPort: port, target: target, scope: scope,
                                       hostDeviceID: machine.hostDeviceID, routeMode: mode)
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
