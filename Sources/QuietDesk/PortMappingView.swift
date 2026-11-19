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

struct PortMappingView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    @State private var deviceID: UUID?
    @State private var editor: MappingEditorSelection?
    @State private var deleting: PortMappingRule?
    @State private var error: String?

    private var selected: ConnectionRecord? { model.connections.first { $0.id == deviceID } }
    private var rules: [PortMappingRule] { manager.rules.filter { $0.deviceID == deviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TCP 端口映射").font(.title2.bold())
                Spacer()
                Button("完成", action: done).keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("设备", selection: $deviceID) {
                    if model.connections.isEmpty { Text("尚无设备").tag(nil as UUID?) }
                    ForEach(model.connections) { record in
                        Text("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))").tag(Optional(record.id))
                    }
                }
                if !model.connected && !model.working {
                    Button("使用连接页配置") {
                        do { deviceID = try model.savePortMappingDevice() }
                        catch { self.error = error.localizedDescription }
                    }
                    .help("将连接页填写的地址、端口和配对码用于这台设备")
                }
                if let id = deviceID, id == model.currentMappingRecordID {
                    Label("远控已连接", systemImage: "display").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("映射规则").font(.headline)
                Spacer()
                Button {
                    if let selected { editor = MappingEditorSelection(device: selected) }
                } label: { Label("添加规则", systemImage: "plus") }
                .disabled(selected == nil)
            }
            if selected == nil || rules.isEmpty {
                ContentUnavailableView {
                    Label(selected == nil ? "先添加设备" : "尚无映射规则", systemImage: "network")
                } description: {
                    Text(selected == nil ? "在连接页填写目标 Mac 的地址与配对码，然后选择「使用连接页配置」。" :
                        "添加规则后，可通过本机端口访问目标服务。曾远控过该 Mac 时可直接启用；未曾远控的设备首次启用仍需被控端确认。")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                            Divider()
                        }
                    }
                }
            }
            if let message = error ?? manager.storageError {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .font(.callout).textSelection(.enabled)
            }
            Divider()
            Text("被控 Mac 需开启桌面共享或独立映射服务。远控期间映射传输会限速，优先保障画面与操作。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 650, height: 460)
        .onAppear {
            let selectedRecord = model.connections.first { $0.id == model.selectedConnectionID }
            deviceID = model.currentMappingRecordID ?? selectedRecord?.id ?? model.connections.first?.id
        }
        .sheet(item: $editor) { item in
            PortMappingEditor(item: item, sessionAvailable: item.device.id == model.currentMappingRecordID) { rule, enable in
                try manager.saveRule(rule)
                if enable { try model.startPortMapping(rule) }
                error = nil
                editor = nil
            }
        }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting) { rule in
            Button("删除规则", role: .destructive) {
                do { try manager.deleteRule(rule.id); error = nil }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("当前规则的监听和传输会同时停止。") }
    }

    private func ruleRow(_ rule: PortMappingRule) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(rule.name).font(.body.weight(.semibold))
                    Text(rule.scope.title).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: "127.0.0.1:\(rule.localPort)  →  \(rule.target.mappingAddress)")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                status(manager.states[rule.id])
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("启用 \(rule.name)", isOn: Binding(get: { manager.isEnabled(rule.id) }, set: { enabled in
                do {
                    if enabled { try model.startPortMapping(rule) } else { manager.stop(rule.id) }
                    error = nil
                } catch { self.error = error.localizedDescription }
            }))
            .labelsHidden().toggleStyle(.switch)
            Menu {
                Button("编辑…") { if let selected { editor = MappingEditorSelection(device: selected, rule: rule) } }
                Button("删除…", role: .destructive) { deleting = rule }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(rule.name)的更多操作")
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private func status(_ state: PortMappingState?) -> some View {
        switch state {
        case .authorizing: Label("正在连接或等待被控端确认…", systemImage: "clock").foregroundStyle(.secondary)
        case let .listening(_, connections):
            Label(connections > 0 ? "正在转发 · \(connections) 个连接" : "正在监听 · 等待本地连接",
                  systemImage: "checkmark.circle").foregroundStyle(.green)
        case let .targetFailed(_, reason):
            Label("本地仍在监听 · \(reason)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case let .failed(reason): Label(reason, systemImage: "xmark.circle").foregroundStyle(.red)
        case .stopped, nil: Text("已停用").foregroundStyle(.secondary)
        }
    }
}

private struct PortMappingEditor: View {
    let item: MappingEditorSelection
    let sessionAvailable: Bool
    let save: (PortMappingRule, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var localPort: String
    @State private var host: String
    @State private var remotePort: String
    @State private var scope: PortMappingScope
    @State private var error: String?

    init(item: MappingEditorSelection, sessionAvailable: Bool, save: @escaping (PortMappingRule, Bool) throws -> Void) {
        self.item = item
        self.sessionAvailable = sessionAvailable
        self.save = save
        _name = State(initialValue: item.rule?.name ?? "")
        _localPort = State(initialValue: item.rule.map { String($0.localPort) } ?? "")
        _host = State(initialValue: item.rule?.target.host ?? "127.0.0.1")
        _remotePort = State(initialValue: item.rule.map { String($0.target.port) } ?? "")
        _scope = State(initialValue: item.rule?.scope ?? (sessionAvailable ? .session : .independent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.rule == nil ? "添加映射规则" : "编辑映射规则").font(.title2.bold())
            Form {
                TextField("名称", text: $name, prompt: Text("例如：开发服务"))
                TextField("本地端口", text: $localPort, prompt: Text("3000"))
                TextField("目标地址", text: $host, prompt: Text("回环或私有局域网 IP"))
                TextField("目标端口", text: $remotePort, prompt: Text(localPort.isEmpty ? "与本地端口相同" : localPort))
                Picker("运行方式", selection: $scope) {
                    ForEach(PortMappingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            .textFieldStyle(.roundedBorder)
            Text("目标地址从「\(ConnectionEntryPresentation.title(item.device))」访问。127.0.0.1 表示该 Mac 自身。")
                .font(.callout).foregroundStyle(.secondary)
            Text(scope == .independent ? "独立规则在断开远控后继续工作。睡眠或退出 QuietDesk 会停止映射。" :
                    "规则需在此设备的远控会话中启用，断开时自动停止。")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(item.rule == nil ? "仅保存" : "保存并停用") { submit(enable: false) }
                Button("保存并启用") { submit(enable: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(scope == .session && !sessionAvailable)
            }
        }
        .padding(22).frame(width: 460)
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
            try save(rule, enable)
        } catch { self.error = error.localizedDescription }
    }
}
