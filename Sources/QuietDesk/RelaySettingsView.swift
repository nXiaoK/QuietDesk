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

    init(enabled: Bool, nodes: [String], deviceID: String, locked: Bool,
         measurements: [String: RelayNodeProbe.Measurement] = [:],
         loadTrust: @escaping @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?,
         saveNode: @escaping @MainActor (String, String, RelayNodeCertificate?) throws -> String,
         save: @escaping @MainActor (Bool, [String], String) throws -> Void) {
        _enabled = State(initialValue: enabled)
        _nodes = State(initialValue: nodes)
        _deviceID = State(initialValue: deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
        // A first-time setup opens straight into the editor for its first node.
        _editing = State(initialValue: nodes.isEmpty && enabled ? "" : nil)
        self.locked = locked; self.measurements = measurements
        self.loadTrust = loadTrust; self.saveNode = saveNode; self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.system(size: 24)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("自托管中继").font(.system(size: 17, weight: .semibold))
                    Text("两台 Mac 主动连接同一服务，无需为各自设置端口映射。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用中继功能", isOn: $enabled).toggleStyle(.switch)
                    if enabled {
                        nodeList
                        if editing != nil { nodeEditor }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本机设备标识（保存后生效）").font(.subheadline.weight(.medium))
                            Text(deviceID).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Text("开启共享后，可用此标识和 Mac 配对码经任一节点连接本机。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("更换标识") { deviceID = UUID().uuidString.lowercased() }
                                    .buttonStyle(.link).font(.caption)
                            }
                            Text("更换后需更新另一台 Mac 保存的目标标识；不会更换 Mac 配对码。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.frame(height: enabled ? 460 : 44)
            .textFieldStyle(.roundedBorder).disabled(locked)
            if locked { Text("请先停止共享并断开连接，再修改配置。").font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("新配置在下次开启共享或连接时生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(enabled, nodes, deviceID); dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(locked || (enabled && editing != nil))
                .help(editing != nil ? "请先保存或取消正在编辑的节点" : "")
            }
        }
        .padding(22).frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
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
        VStack(alignment: .leading, spacing: 8) {
            Text("中继节点").font(.subheadline.weight(.medium))
            Text("可添加多个节点。共享时在所有节点登记；连接时测量各节点的连接延迟，优先使用最快的节点，接不通时依次改用下一个。也可在连接页指定节点。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if nodes.isEmpty, editing == nil {
                Text("还没有节点。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(nodes, id: \.self) { node in
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Text(node).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if let label = RelayNodeLabel.latency(measurements[node]) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") { beginEditing(node) }.buttonStyle(.link).font(.caption)
                    Button("移除") { nodes.removeAll { $0 == node } }.buttonStyle(.link).font(.caption)
                }
                .disabled(editing != nil)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if editing == nil {
                Button { beginEditing("") } label: { Label("添加节点…", systemImage: "plus") }.buttonStyle(.link)
            }
        }
    }

    private var nodeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing?.isEmpty == true ? "添加节点" : "编辑节点").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("中继服务地址").font(.subheadline.weight(.medium))
                TextField("tls://服务器IP:7443 或 tls://域名:7443", text: $address)
                    .accessibilityLabel("中继服务地址")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("中继接入码").font(.subheadline.weight(.medium))
                SecureField("首次填写；留空保留此节点已保存的接入码", text: $accessCode)
                    .accessibilityLabel("中继接入码，与 Mac 配对码不同")
                Text("由节点部署者提供，与控制 Mac 使用的配对码不同；每个节点使用各自的接入码。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            certificateSettings
            HStack {
                Spacer()
                Button("取消") { cancelEditing() }
                Button("保存节点") { saveEditedNode() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || probe != nil || !trustLoaded || candidate != nil)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
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
            Text("节点证书").font(.subheadline.weight(.medium))
            if let certificate {
                Text("已选择此节点证书（点保存节点后生效）").font(.caption)
                fingerprint(certificate)
            } else { Text("使用 macOS 系统信任的证书").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("导入节点证书…") { importCertificate() }
                Button(probe == nil ? "获取并核对指纹…" : "正在获取…") { fetchCertificate() }.disabled(probe != nil)
                if probe != nil { Button("取消获取") { requestID = UUID(); probe?.cancel(); probe = nil } }
            }
            Button("使用系统信任") {
                requestID = UUID(); probe?.cancel(); probe = nil
                candidate = nil; certificate = nil; fingerprintChecked = false; trustLoaded = true; failure = nil
            }.buttonStyle(.link).font(.caption)
            Text("自签节点无需域名。请与服务器终端显示的 SHA-256 指纹核对；信任只适用于此地址和端口，不修改系统信任。证书更换后需重新核对。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let candidate {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待核对：\((try? RelayEndpoint(address: address))?.address ?? address)").font(.caption.weight(.medium))
                    fingerprint(candidate)
                    if let expires = candidate.expires { Text("有效期至 \(expires.formatted())").font(.caption) }
                    Toggle("已通过服务器终端或可信渠道核对上述指纹", isOn: $fingerprintChecked).font(.caption)
                    HStack {
                        Button("信任此证书") {
                            certificate = candidate; self.candidate = nil; trustLoaded = true; failure = nil
                        }.disabled(!fingerprintChecked)
                        Button("放弃") { self.candidate = nil; fingerprintChecked = false }
                    }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func fingerprint(_ value: RelayNodeCertificate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
            Text(String(value.fingerprint.prefix(47)) + "\n" + value.fingerprint.suffix(47))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
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
