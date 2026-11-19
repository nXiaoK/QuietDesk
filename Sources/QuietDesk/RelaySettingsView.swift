import SwiftUI
import AppKit
import QuietDeskCore

@MainActor
struct RelaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var nodes: [String]
    @State private var deviceID: String
    @State private var failure: String?
    @State private var savedFeedback = false
    // The node being edited: nil when none, empty for a new node, otherwise its saved address.
    @State private var editing: String?
    @State private var address = ""
    @State private var accessCode = ""
    @State private var certificate: RelayNodeCertificate?
    @State private var candidate: RelayNodeCertificate?
    @State private var fingerprintChecked = false
    @State private var trustLoaded = false
    @State private var probe: RelayCertificateProbe?
    @State private var requestID = UUID()
    let locked: Bool
    let measurements: [String: RelayNodeProbe.Measurement]
    let loadTrust: @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?
    let saveNode: @MainActor (String, String, RelayNodeCertificate?) throws -> String
    let save: @MainActor (Bool, [String], String) throws -> Void
    var embedded: Bool = false

    init(enabled: Bool, nodes: [String], deviceID: String, locked: Bool,
         measurements: [String: RelayNodeProbe.Measurement] = [:],
         embedded: Bool = false,
         loadTrust: @escaping @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?,
         saveNode: @escaping @MainActor (String, String, RelayNodeCertificate?) throws -> String,
         save: @escaping @MainActor (Bool, [String], String) throws -> Void) {
        _enabled = State(initialValue: enabled)
        _nodes = State(initialValue: nodes)
        _deviceID = State(initialValue: deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
        _editing = State(initialValue: nodes.isEmpty && enabled ? "" : nil)
        self.locked = locked
        self.measurements = measurements
        self.embedded = embedded
        self.loadTrust = loadTrust
        self.saveNode = saveNode
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自托管中继").font(.system(size: 17, weight: .bold))
                        Text("两台 Mac 主动连接同一自建节点，无需路由器公网端口映射。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            let inner = VStack(alignment: .leading, spacing: 14) {
                DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("启用自托管中继功能")
                                .font(.system(size: 13.5, weight: .bold))
                            Text("共享时在全部已添加节点登记；连接时自动探测延迟并优先选最快节点，接不通自动回退下一节点。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("启用中继功能", isOn: $enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }

                if enabled {
                    DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                        VStack(alignment: .leading, spacing: 12) {
                            nodeList
                            if editing != nil { nodeEditor }
                        }
                    }

                    DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("本机中继设备标识（保存后生效）", systemImage: "person.text.rectangle")
                                    .font(.system(size: 13.5, weight: .bold))
                                Spacer()
                                Button("更换标识") {
                                    deviceID = UUID().uuidString.lowercased()
                                }
                                .controlSize(.small)
                            }

                            Text(deviceID)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Text("开启共享后，控制端凭此设备标识和本机配对码即可经任一节点连入。更换标识后需同步更新另一台 Mac 保存的目标标识，不影响配对码。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(locked)

            if embedded {
                inner
            } else {
                ScrollView { inner }
                    .frame(height: enabled ? 440 : 100)
            }

            if locked {
                Label("请先停止本机共享并断开远控连接，再修改中继节点配置。", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(savedFeedback ? "✓ 中继配置已保存（下次连接或共享生效）" : "新配置在下次开启共享或发起连接时生效。")
                    .font(.caption)
                    .foregroundStyle(savedFeedback ? DeskPalette.emerald : .secondary)
                Spacer()
                if !embedded {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button(embedded ? "保存中继配置" : "保存") {
                    do {
                        try save(enabled, nodes, deviceID)
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(embedded ? nil : .defaultAction)
                .disabled(locked || (enabled && editing != nil))
                .help(editing != nil ? "请先保存或取消正在编辑的节点" : "")
            }
        }
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
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
    }

    private var nodeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("已配置中继节点", systemImage: "server.rack")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                if editing == nil {
                    Button {
                        beginEditing("")
                    } label: {
                        Label("添加节点…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            }

            if nodes.isEmpty, editing == nil {
                Text("尚未添加中继节点，点击右上角「添加节点…」配置首个服务地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(nodes, id: \.self) { node in
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.accentColor)
                    Text(node)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let label = RelayNodeLabel.latency(measurements[node]) {
                        DeskPillBadge(text: label, tint: label == "不可达" ? DeskPalette.coral : DeskPalette.emerald, monospaced: true)
                    }
                    Spacer()
                    Button("编辑") { beginEditing(node) }
                        .controlSize(.small)
                    Button("移除", role: .destructive) { nodes.removeAll { $0 == node } }
                        .controlSize(.small)
                }
                .disabled(editing != nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private var nodeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing?.isEmpty == true ? "添加新中继节点" : "编辑中继节点")
                .font(.subheadline.weight(.bold))
            VStack(alignment: .leading, spacing: 5) {
                Text("中继服务地址").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("tls://服务器IP:7443 或 tls://域名:7443", text: $address)
                    .font(.system(size: 12.5, design: .monospaced))
                    .accessibilityLabel("中继服务地址")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("节点接入码（与 Mac 配对码不同）").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                SecureField("首次必填；编辑时留空保留已保存接入码", text: $accessCode)
                    .accessibilityLabel("中继接入码，与 Mac 配对码不同")
            }
            certificateSettings
            HStack {
                Spacer()
                Button("取消") { cancelEditing() }
                Button("保存节点") { saveEditedNode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || probe != nil || !trustLoaded || candidate != nil)
            }
        }
        .padding(14)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        }
    }

    private func beginEditing(_ node: String) {
        editing = node
        address = node.isEmpty ? "" : node
        accessCode = ""
        failure = nil
        reloadTrust()
    }

    private func cancelEditing() {
        requestID = UUID(); probe?.cancel(); probe = nil
        editing = nil; address = ""; accessCode = ""; candidate = nil; certificate = nil; fingerprintChecked = false
    }

    private func saveEditedNode() {
        do {
            let saved = try saveNode(address, accessCode, certificate)
            if let original = editing, !original.isEmpty, let index = nodes.firstIndex(of: original) { nodes[index] = saved }
            else { nodes.append(saved) }
            var seen = Set<String>()
            nodes = nodes.filter { seen.insert($0).inserted }
            failure = nil
            cancelEditing()
        } catch { failure = error.localizedDescription }
    }

    private var certificateSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TLS 节点证书信任").font(.caption.weight(.semibold))
                Spacer()
                DeskInfoPopoverButton(
                    title: "自签证书 SHA-256 指纹信任说明",
                    lines: [
                        "自签 IP 节点无需申请公共域名证书；请核对部署脚本输出的 SHA-256 指纹。",
                        "信任仅绑定当前节点地址与端口，不会写入或修改 macOS 系统钥匙串根证书。"
                    ]
                )
            }
            if let certificate {
                Text("已绑定此节点专属证书（保存节点后生效）").font(.caption).foregroundStyle(DeskPalette.emerald)
                fingerprint(certificate)
            } else {
                Text("当前使用 macOS 系统受信任 CA 证书").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("导入证书文件…") { importCertificate() }
                    .controlSize(.small)
                Button(probe == nil ? "在线获取并核对指纹…" : "正在获取…") { fetchCertificate() }
                    .controlSize(.small)
                    .disabled(probe != nil)
                if probe != nil {
                    Button("取消获取") { requestID = UUID(); probe?.cancel(); probe = nil }
                        .controlSize(.small)
                }
                if certificate != nil || candidate != nil {
                    Button("改用系统信任") {
                        requestID = UUID(); probe?.cancel(); probe = nil
                        candidate = nil; certificate = nil; fingerprintChecked = false; trustLoaded = true; failure = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if let candidate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待核对节点：\((try? RelayEndpoint(address: address))?.address ?? address)")
                        .font(.caption.weight(.semibold))
                    fingerprint(candidate)
                    if let expires = candidate.expires { Text("有效期至 \(expires.formatted())").font(.caption) }
                    Toggle("我已与服务器终端输出的 SHA-256 指纹核对一致", isOn: $fingerprintChecked)
                        .font(.caption)
                    HStack {
                        Button("信任此证书") {
                            certificate = candidate; self.candidate = nil; trustLoaded = true; failure = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!fingerprintChecked)
                        Button("放弃") { self.candidate = nil; fingerprintChecked = false }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func fingerprint(_ value: RelayNodeCertificate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SHA-256 指纹").font(.caption2).foregroundStyle(.secondary)
            Text(String(value.fingerprint.prefix(47)) + "\n" + value.fingerprint.suffix(47))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
