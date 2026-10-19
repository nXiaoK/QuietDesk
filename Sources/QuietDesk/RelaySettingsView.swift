import SwiftUI
import AppKit
import QuietDeskCore

@MainActor
struct RelaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var address: String
    @State private var accessCode = ""
    @State private var deviceID: String
    @State private var failure: String?
    @State private var certificate: RelayNodeCertificate?
    @State private var candidate: RelayNodeCertificate?
    @State private var fingerprintChecked = false
    @State private var trustLoaded = false
    @State private var probe: RelayCertificateProbe?
    @State private var requestID = UUID()
    let locked: Bool
    let loadTrust: @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?
    let save: @MainActor (Bool, String, String, String, RelayNodeCertificate?) throws -> Void

    init(enabled: Bool, address: String, deviceID: String, locked: Bool,
         loadTrust: @escaping @MainActor (RelayEndpoint) throws -> RelayNodeCertificate?,
         save: @escaping @MainActor (Bool, String, String, String, RelayNodeCertificate?) throws -> Void) {
        _enabled = State(initialValue: enabled)
        _address = State(initialValue: address)
        _deviceID = State(initialValue: deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
        self.locked = locked; self.loadTrust = loadTrust; self.save = save
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
                        VStack(alignment: .leading, spacing: 5) {
                            Text("中继服务地址").font(.subheadline.weight(.medium))
                            TextField("tls://服务器IP:7443 或 tls://域名:7443", text: $address)
                                .accessibilityLabel("中继服务地址")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("中继接入码").font(.subheadline.weight(.medium))
                            SecureField("首次填写；留空保留已保存的接入码", text: $accessCode)
                                .accessibilityLabel("中继接入码，与 Mac 配对码不同")
                            Text("由节点部署者提供，与控制 Mac 使用的配对码不同。更换节点需填写该节点的接入码。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        certificateSettings
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本机设备标识（保存后生效）").font(.subheadline.weight(.medium))
                            Text(deviceID).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Text("开启共享后，可用此标识和 Mac 配对码连接本机。")
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
            }.frame(height: enabled ? 440 : 44)
            .textFieldStyle(.roundedBorder).disabled(locked)
            if locked { Text("请先停止共享或断开连接，再修改配置。").font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("新配置在下次开启共享或连接时生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(enabled, address, accessCode, deviceID, certificate); accessCode = ""; dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(locked || (enabled && (probe != nil || !trustLoaded || candidate != nil)))
            }
        }
        .padding(22).frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reloadTrust() }
        .onChange(of: address) { _, _ in reloadTrust() }
        .onChange(of: enabled) { _, value in
            if !value { requestID = UUID(); probe?.cancel(); probe = nil; candidate = nil; fingerprintChecked = false }
        }
        .onChange(of: locked) { _, value in
            if value { requestID = UUID(); probe?.cancel(); probe = nil; candidate = nil }
        }
        .onDisappear { requestID = UUID(); probe?.cancel(); probe = nil }
    }

    private var certificateSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("节点证书").font(.subheadline.weight(.medium))
            if let certificate {
                Text("已选择此节点证书（点保存后生效）").font(.caption)
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
