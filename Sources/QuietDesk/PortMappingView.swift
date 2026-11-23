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
    var embedded: Bool = false
    var preferredDeviceID: UUID? = nil
    @State private var deviceID: UUID?
    @State private var editor: MappingEditorSelection?
    @State private var deleting: PortMappingRule?
    @State private var error: String?

    private var selected: ConnectionRecord? { model.connections.first { $0.id == deviceID } }
    private var rules: [PortMappingRule] { manager.rules.filter { $0.deviceID == deviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack {
                    Text("TCP 端口映射").font(.title2.bold())
                    Spacer()
                    Button("完成", action: done).keyboardShortcut(.cancelAction)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("目标设备")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("设备", selection: $deviceID) {
                        if model.connections.isEmpty { Text("尚无已存设备").tag(nil as UUID?) }
                        ForEach(model.connections) { record in
                            Text("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record))")
                                .tag(Optional(record.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                if !model.connected && !model.working {
                    Button("导入连接页当前配置") {
                        do { deviceID = try model.savePortMappingDevice(); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    .controlSize(.small)
                    .help("将连接页填写的地址、端口和配对码保存并用于端口映射")
                }

                if let id = deviceID, model.hasConnectedDesktopSession(for: id) {
                    DeskPillBadge(text: "远控已连接", symbol: "display", tint: DeskPalette.emerald)
                }

                Spacer(minLength: 8)

                Button {
                    if let selected { editor = MappingEditorSelection(device: selected) }
                } label: {
                    Label("新建映射", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(selected == nil)
            }

            if selected == nil || rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(selected == nil ? "请先添加或选择目标 Mac" : "尚无 TCP 端口映射规则")
                        .font(.headline)
                    Text(selected == nil
                         ? "可在「远程桌面」连接一次目标 Mac，或填写地址与配对码后点击上方「导入连接页当前配置」。"
                         : "添加规则后可通过本机端口安全访问远端服务。曾远控过该 Mac 时免确认直通；未曾远控的设备首次启用需被控端确认。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                }
            } else {
                if embedded {
                    VStack(spacing: 10) {
                        ForEach(rules) { rule in
                            tunnelCard(rule)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(rules) { rule in
                                tunnelCard(rule)
                            }
                        }
                    }
                }
            }

            if let message = error ?? manager.storageError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DeskPalette.amber)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Text("被控 Mac 需开启桌面共享或「本机映射授权」中的独立映射服务。远控画面活动期间映射流量自动退让限速，优先保障键鼠与帧率。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 680, height: embedded ? nil : 480)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .onAppear {
            let preferred = preferredDeviceID.flatMap { id in model.connections.first { $0.id == id } }
            let selectedRecord = model.connections.first { $0.id == model.selectedConnectionID }
            deviceID = preferred?.id ?? model.preferredMappingRecordID ?? selectedRecord?.id ?? model.connections.first?.id
        }
        .onChange(of: preferredDeviceID) { _, newID in
            if let newID, model.connections.contains(where: { $0.id == newID }) {
                deviceID = newID
            }
        }
        .sheet(item: $editor) { item in
            PortMappingEditor(item: item, sessionAvailable: model.hasConnectedDesktopSession(for: item.device.id)) { rule, enable in
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
        } message: { _ in Text("当前规则的本地监听和加密转发会同时停止。") }
    }

    private func tunnelCard(_ rule: PortMappingRule) -> some View {
        let isEnabled = manager.isEnabled(rule.id)
        let state = manager.states[rule.id]
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(rule.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .lineLimit(1)
                    DeskPillBadge(text: rule.scope.title, tint: .secondary)
                }
                statusView(state)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 190, maxWidth: 260, alignment: .leading)

            HStack(spacing: 8) {
                endpointChip(role: "本机", address: "127.0.0.1:\(rule.localPort)")
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(isEnabled ? Color.accentColor.opacity(0.45) : DeskPalette.hairline)
                        .frame(width: 20, height: 2)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                }
                endpointChip(role: "远端", address: rule.target.mappingAddress)
            }

            Spacer(minLength: 6)

            Toggle("启用 \(rule.name)", isOn: Binding(get: { isEnabled }, set: { enabled in
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
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(rule.name)的更多操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isEnabled ? Color.accentColor.opacity(0.28) : DeskPalette.hairline, lineWidth: 0.9)
        }
    }

    private func endpointChip(role: String, address: String) -> some View {
        HStack(spacing: 5) {
            Text(role)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: address)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            Text(item.rule == nil ? "添加映射规则" : "编辑映射规则").font(.title3.bold())
            Form {
                TextField("名称", text: $name, prompt: Text("例如：Web 开发服务"))
                TextField("本地端口", text: $localPort, prompt: Text("3000"))
                TextField("目标地址", text: $host, prompt: Text("回环 127.0.0.1 或私有局域网 IP"))
                TextField("目标端口", text: $remotePort, prompt: Text(localPort.isEmpty ? "留空默认同本地端口" : localPort))
                Picker("运行方式", selection: $scope) {
                    ForEach(PortMappingScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .textFieldStyle(.roundedBorder)
            Text("目标地址从「\(ConnectionEntryPresentation.title(item.device))」发起访问，127.0.0.1 表示该 Mac 自身。")
                .font(.caption).foregroundStyle(.secondary)
            Text(scope == .independent
                 ? "独立规则在断开桌面远控后继续保持转发；系统睡眠或退出 QuietDesk 会停止映射。"
                 : "会话规则仅在此设备的远控会话期间工作，断开远控自动停止。")
                .font(.caption).foregroundStyle(.secondary)
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
        .padding(22)
        .frame(width: 460)
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
