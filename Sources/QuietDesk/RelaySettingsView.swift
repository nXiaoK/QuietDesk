import SwiftUI
import AppKit
import QuietDeskCore

struct RelayNodeStatusBadge: View {
    let status: RelayNodeVersionStatus
    let capabilities: Set<String>

    var body: some View {
        Group {
            if status == .unknown {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .accessibilityLabel("版本未检测")
            } else {
                DeskPillBadge(text: status.badgeText, tint: tint)
                    .help(capabilityLabel)
                    .accessibilityHint(capabilityLabel)
            }
        }
    }

    private var tint: Color {
        switch status {
        case .upToDate: return DeskPalette.emerald
        case .updatable, .legacyUnversioned: return DeskPalette.amber
        case .unknown: return DeskPalette.secondary
        }
    }

    private var capabilityLabel: String {
        if capabilities.contains("tcp"), !capabilities.contains("udp") { return "仅 TCP" }
        return RelayNodeNaming.capabilityLabel(capabilities)
    }
}

@MainActor
struct RelaySettingsView: View {
    private enum EditorField: Hashable { case name, address, accessCode }
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var nodes: [String]
    @State private var nodeNames: [String: String]
    @State private var deviceID: String
    @State private var failure: String?
    @State private var savedFeedback = false
    @State private var copiedDeviceID = false
    // The node being edited: nil when none, empty for a new node, otherwise its saved address.
    @State private var editing: String?
    @State private var name = ""
    @State private var address = ""
    @State private var accessCode = ""
    @State private var certificate: RelayNodeCertificate?
    @State private var candidate: RelayNodeCertificate?
    @State private var fingerprintChecked = false
    @State private var trustLoaded = false
    @State private var probe: RelayCertificateProbe?
    @State private var requestID = UUID()
    @FocusState private var editorFocus: EditorField?

    let locked: Bool
    let measurements: [String: RelayNodeProbe.Measurement]
    let nodeInfos: [String: (versionStatus: RelayNodeVersionStatus, serverVersion: String?, capabilities: Set<String>)]
    let probing: Bool
    let measure: () -> Void
    let loadTrust: @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?
    let saveNode: @MainActor (String, String?, String, RelayNodeCertificate?) throws -> String
    let save: @MainActor (Bool, [String], [String: String], String) throws -> Void
    var embedded: Bool = false

    init(enabled: Bool, nodes: [String], deviceID: String, locked: Bool,
         nodeNames: [String: String] = [:],
         measurements: [String: RelayNodeProbe.Measurement] = [:],
         nodeInfos: [String: (versionStatus: RelayNodeVersionStatus, serverVersion: String?, capabilities: Set<String>)] = [:],
         probing: Bool = false, measure: @escaping () -> Void = {},
         embedded: Bool = false,
         loadTrust: @escaping @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?,
         saveNode: @escaping @MainActor (String, String?, String, RelayNodeCertificate?) throws -> String,
         save: @escaping @MainActor (Bool, [String], [String: String], String) throws -> Void) {
        _enabled = State(initialValue: enabled)
        _nodes = State(initialValue: nodes)
        _nodeNames = State(initialValue: nodeNames)
        _deviceID = State(initialValue: deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
        _editing = State(initialValue: nodes.isEmpty && enabled ? "" : nil)
        self.locked = locked
        self.measurements = measurements
        self.nodeInfos = nodeInfos
        self.probing = probing
        self.measure = measure
        self.embedded = embedded
        self.loadTrust = loadTrust
        self.saveNode = saveNode
        self.save = save
    }

    init(enabled: Bool, nodes: [String], deviceID: String, locked: Bool,
         measurements: [String: RelayNodeProbe.Measurement] = [:], embedded: Bool = false,
         loadTrust: @escaping @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?,
         saveNode: @escaping @MainActor (String, String, RelayNodeCertificate?) throws -> String,
         save: @escaping @MainActor (Bool, [String], String) throws -> Void) {
        self.init(enabled: enabled, nodes: nodes, deviceID: deviceID, locked: locked, measurements: measurements,
                  embedded: embedded, loadTrust: loadTrust,
                  saveNode: { address, _, accessCode, certificate in try saveNode(address, accessCode, certificate) },
                  save: { enabled, nodes, _, deviceID in try save(enabled, nodes, deviceID) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !embedded {
                DeskSectionHeading(
                    title: "自托管中继",
                    symbol: nil,
                    detail: "两端主动连接同一自建节点；配置在下次共享或连接时生效"
                )
            }

            if locked {
                DeskCalloutBox(
                    title: "中继配置已锁定",
                    message: "停止本机共享并断开远控后可编辑节点。",
                    symbol: "lock",
                    tone: .warning
                )
            }

            let inner = VStack(alignment: .leading, spacing: 18) {
                DeskSettingsGroup(title: "") {
                    DeskSettingsRow(
                        title: "启用自托管中继",
                        detail: "共享时在全部节点登记，连接时优先尝试延迟最低的节点"
                    ) {
                        Toggle("启用中继功能", isOn: $enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Divider()
                    DeskSettingsRow(title: "节点证书") {
                        Text("仅绑定当前地址与端口")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskPalette.secondary)
                            .help("节点证书绑定当前地址与端口，不写入系统根证书。")
                    }
                }
                .disabled(locked)

                if enabled {
                    nodeList
                    deviceIdentitySection
                        .disabled(locked)
                }
            }

            if embedded {
                inner
            } else {
                ScrollView { inner }
                    .frame(maxHeight: enabled ? 410 : 116)
            }

            if editing == nil, let failure {
                DeskCalloutBox(message: failure, symbol: "exclamationmark.triangle.fill", tone: .danger)
            }

            HStack {
                Text(savedFeedback ? "✓ 中继配置已保存（下次连接或共享生效）" : "新配置在下次开启共享或发起连接时生效。")
                    .font(.system(size: 12))
                    .foregroundStyle(savedFeedback ? DeskPalette.emerald : DeskPalette.secondary)
                Spacer()
                if !embedded {
                    Button("取消") { dismiss() }
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                }
                Button(embedded ? "保存中继配置" : "保存") {
                    do {
                        try save(enabled, nodes, nodeNames, deviceID)
                        failure = nil
                        if embedded {
                            savedFeedback = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                savedFeedback = false
                            }
                        } else {
                            dismiss()
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(embedded ? nil : .defaultAction)
                .disabled(locked || (enabled && editing != nil))
                .help(editing != nil ? "请先保存或取消正在编辑的节点" : "")
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 660)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onChange(of: address) { _, _ in if editing != nil { reloadTrust() } }
        .onChange(of: enabled) { _, value in
            if !value { cancelEditing() }
            else if nodes.isEmpty, editing == nil { beginEditing("") }
        }
        .onChange(of: locked) { _, value in
            if value { requestID = UUID(); probe?.cancel(); probe = nil; candidate = nil }
        }
        .onAppear { if editing != nil { reloadTrust() } }
        .onDisappear { requestID = UUID(); probe?.cancel(); probe = nil }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { cancelEditing() } }
        )) {
            nodeEditor
        }
    }

    private var nodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("中继节点")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                Spacer()
                Button {
                    measure()
                } label: {
                    Label(probing ? "检测中…" : "检测节点", systemImage: "waveform.path")
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .disabled(probing || nodes.isEmpty)
                .help("检测已保存节点的连接延迟、版本及能力")
                if editing == nil {
                    Button { beginEditing("") } label: {
                        Label("添加节点…", systemImage: "plus")
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(locked)
                }
            }

            DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    nodeColumns {
                        Text("节点").frame(maxWidth: .infinity, alignment: .leading)
                        Text("版本与能力").frame(width: 138, alignment: .leading)
                        Text("延迟探测").frame(width: 104, alignment: .leading)
                        Text("操作").frame(width: 112, alignment: .leading)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .background(DeskPalette.insetBackground)
                    .accessibilityHidden(true)

                    if nodes.isEmpty {
                        Divider()
                        Text("尚未添加中继节点。点按右上角「添加节点…」配置自建服务。")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(nodes, id: \.self) { node in
                            Divider()
                            nodeRow(node)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func nodeRow(_ node: String) -> some View {
        nodeColumns {
            VStack(alignment: .leading, spacing: 3) {
                Text((try? RelayEndpoint(address: node)).map {
                    RelayNodeNaming.shortTitle(for: $0, names: nodeNames)
                } ?? node)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                Text(node)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(node)
            .frame(maxWidth: .infinity, alignment: .leading)

            RelayNodeStatusBadge(status: nodeInfos[node]?.versionStatus ?? .unknown,
                                 capabilities: nodeInfos[node]?.capabilities ?? [])
                .frame(width: 138, alignment: .leading)

            let latency = RelayNodeLabel.latency(measurements[node])
            Text(latency ?? "—")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(latency == "不可达" ? DeskPalette.coral : DeskPalette.secondary)
                .frame(width: 104, alignment: .leading)

            HStack(spacing: 6) {
                Button("编辑") { beginEditing(node) }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .accessibilityLabel("编辑 \(node)")
                Button("移除", role: .destructive) {
                    nodes.removeAll { $0 == node }
                    nodeNames.removeValue(forKey: node)
                }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .foregroundStyle(DeskPalette.coral)
                    .accessibilityLabel("移除 \(node)")
            }
            .frame(width: 112, alignment: .leading)
            .disabled(locked || editing != nil)
        }
        .frame(minHeight: 44)
    }

    private func nodeColumns(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private var deviceIdentitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            DeskSettingsGroup(title: "本机设备标识") {
                DeskSettingsRow(title: "中继设备标识") {
                    Text(deviceID)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DeskPalette.ink)
                        .textSelection(.enabled)
                }
                Divider()
                DeskSettingsRow(title: "设备标识操作") {
                    HStack(spacing: 8) {
                        Button(copiedDeviceID ? "已复制" : "复制标识") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceID, forType: .string)
                            copiedDeviceID = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.2))
                                copiedDeviceID = false
                            }
                        }
                        .buttonStyle(DeskButtonStyle(.secondary))

                        Button("更换标识") {
                            deviceID = UUID().uuidString.lowercased()
                        }
                        .buttonStyle(DeskButtonStyle(.secondary))
                    }
                }
            }

            Text("开启共享后，控制端凭此标识与配对码连入。更换后需更新控制端保存的目标标识。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nodeEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(editing?.isEmpty == true ? "添加中继节点" : "编辑中继节点")
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("节点名称（选填）")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    TextField("例如：上海阿里云 / 广州电信，留空显示地址", text: $name)
                        .font(.system(size: 13))
                        .focused($editorFocus, equals: .name)
                        .deskInputBox(focused: editorFocus == .name)
                        .accessibilityLabel("中继节点名称")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("节点地址")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    TextField("tls://relay.example.com:443 或 IP:7443", text: $address)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($editorFocus, equals: .address)
                        .deskInputBox(focused: editorFocus == .address)
                        .accessibilityLabel("中继服务地址")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("服务器接入码（与 Mac 配对码不同）")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                    SecureField("首次必填；编辑时留空保留已保存接入码", text: $accessCode)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($editorFocus, equals: .accessCode)
                        .deskInputBox(focused: editorFocus == .accessCode)
                        .accessibilityLabel("中继接入码，与 Mac 配对码不同")
                }

                Divider()
                certificateSettings
            }
            .disabled(locked)

            if let failure {
                DeskCalloutBox(message: failure, symbol: "exclamationmark.triangle", tone: .danger)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { cancelEditing() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存节点") { saveEditedNode() }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(locked || address.trimmingCharacters(in: .whitespaces).isEmpty || probe != nil || !trustLoaded || candidate != nil)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 540)
        .deskSurface()
        .onAppear { editorFocus = editing?.isEmpty == true ? .address : .name }
    }

    private func beginEditing(_ node: String) {
        editing = node
        name = nodeNames[node] ?? ""
        address = node.isEmpty ? "" : node
        accessCode = ""
        failure = nil
        reloadTrust()
    }

    private func cancelEditing() {
        requestID = UUID(); probe?.cancel(); probe = nil
        editing = nil; address = ""; accessCode = ""; candidate = nil; certificate = nil; fingerprintChecked = false
        name = ""
    }

    private func saveEditedNode() {
        do {
            let alias = RelayNodeNaming.sanitize(name)
            let saved = try saveNode(address, alias, accessCode, certificate)
            if let original = editing, !original.isEmpty, let index = nodes.firstIndex(of: original) {
                nodes[index] = saved
                nodeNames.removeValue(forKey: original)
            } else {
                nodes.append(saved)
            }
            nodeNames[saved] = alias
            var seen = Set<String>()
            nodes = nodes.filter { seen.insert($0).inserted }
            failure = nil
            cancelEditing()
        } catch { failure = error.localizedDescription }
    }

    private var certificateSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TLS 证书信任")
                    .font(.system(size: 14, weight: .semibold))
                DeskInfoPopoverButton(
                    title: "自签证书 SHA-256 指纹信任说明",
                    lines: [
                        "自签 IP 节点无需申请公共域名证书；请核对部署脚本输出的 SHA-256 指纹。",
                        "信任仅绑定当前节点地址与端口，不会写入或修改 macOS 系统钥匙串根证书。"
                    ]
                )
                Spacer()
                Button("导入 PEM / DER 证书") { importCertificate() }
                    .buttonStyle(DeskButtonStyle(.secondary))
            }

            if let certificate {
                HStack {
                    Text("已绑定此节点专属证书（保存节点后生效）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskPalette.emerald)
                    Spacer()
                    Button("改用系统信任") {
                        requestID = UUID(); probe?.cancel(); probe = nil
                        candidate = nil; self.certificate = nil; fingerprintChecked = false; trustLoaded = true; failure = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.accent)
                }
                fingerprintBox(certificate)
            } else if candidate == nil {
                HStack {
                    Text("当前使用系统受信任 CA；自签节点可导入或在线读取指纹。")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.secondary)
                    Spacer(minLength: 8)
                    if probe != nil {
                        Button("取消获取") { requestID = UUID(); probe?.cancel(); probe = nil }
                            .buttonStyle(DeskButtonStyle(.secondary))
                    } else {
                        Button("在线获取指纹…") { fetchCertificate() }
                            .buttonStyle(DeskButtonStyle(.secondary))
                    }
                }
            }

            if let candidate {
                VStack(alignment: .leading, spacing: 10) {
                    fingerprintBox(candidate)
                    if let expires = candidate.expires {
                        Text("有效期至 \(expires.formatted())")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DeskPalette.secondary)
                    }
                    Toggle("已通过可信渠道核对证书 SHA-256 指纹", isOn: $fingerprintChecked)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))

                    DeskCalloutBox(
                        title: "尚未确认信任",
                        message: "仅看到服务器返回证书不能自动视为可信；端点变更需重新加载信任。",
                        symbol: "info.circle",
                        tone: .warning
                    )

                    HStack(spacing: 8) {
                        Button("信任此证书") {
                            certificate = candidate; self.candidate = nil; trustLoaded = true; failure = nil
                        }
                        .buttonStyle(DeskButtonStyle(.primary))
                        .disabled(!fingerprintChecked)

                        Button("放弃") {
                            self.candidate = nil; fingerprintChecked = false
                        }
                        .buttonStyle(DeskButtonStyle(.secondary))

                        Spacer()

                        Button("改用系统信任") {
                            requestID = UUID(); probe?.cancel(); probe = nil
                            self.candidate = nil; certificate = nil; fingerprintChecked = false; trustLoaded = true; failure = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.secondary)
                    }
                }
            }
        }
    }

    private func fingerprintBox(_ value: RelayNodeCertificate) -> some View {
        Text(String(value.fingerprint.prefix(47)) + "\n" + value.fingerprint.suffix(47))
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(DeskPalette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func reloadTrust() {
        requestID = UUID(); probe?.cancel(); probe = nil
        candidate = nil; certificate = nil; fingerprintChecked = false; failure = nil
        do {
            if let endpoint = try? RelayEndpoint(address: address) { certificate = try loadTrust(endpoint) }
            trustLoaded = true
        } catch { trustLoaded = false; failure = error.localizedDescription }
    }

    private func importCertificate() {
        do {
            let endpoint = try RelayEndpoint(address: address)
            requestID = UUID(); probe?.cancel(); probe = nil
            let token = requestID
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.title = "导入中继证书"
            panel.message = "选择服务器导出的节点证书（PEM 或 DER），不要选择私钥。"
            panel.begin { response in
                MainActor.assumeIsolated {
                    guard requestID == token, response == .OK, let url = panel.url else { return }
                    do {
                        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                            throw RelayTransportError.certificate
                        }
                        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                        let data = try file.read(upToCount: RelayNodeCertificate.maximumBytes + 1) ?? Data()
                        let imported = try RelayNodeCertificate(data: data)
                        try imported.validate(for: endpoint)
                        candidate = imported; fingerprintChecked = false; failure = nil
                    } catch { failure = "无法导入：请检查证书文件、IP/域名及有效期。" }
                }
            }
        } catch { failure = error.localizedDescription }
    }

    private func fetchCertificate() {
        do {
            let endpoint = try RelayEndpoint(address: address)
            requestID = UUID(); let token = requestID
            candidate = nil; fingerprintChecked = false; failure = nil
            let operation = RelayCertificateProbe(endpoint: endpoint) { result in
                DispatchQueue.main.async {
                    guard requestID == token else { return }; probe = nil
                    switch result {
                    case .success(let value): candidate = value
                    case .failure: failure = "无法获取有效的节点证书，请检查网络、地址匹配及证书有效期。"
                    }
                }
            }
            probe = operation; operation.start()
        } catch { failure = error.localizedDescription }
    }
}

/// How a node's measured connection is shown next to its address.
enum RelayNodeLabel {
    static func latency(_ measurement: RelayNodeProbe.Measurement?) -> String? {
        guard let measurement else { return nil }
        guard let milliseconds = measurement.milliseconds else { return "不可达" }
        let value = milliseconds < 10 ? String(format: "%.1f ms", milliseconds) : String(format: "%.0f ms", milliseconds)
        return measurement.failures > 0 ? "\(value) · \(measurement.failures)/\(measurement.attempts) 次未连上" : value
    }
}
