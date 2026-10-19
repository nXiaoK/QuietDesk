import SwiftUI
import AppKit

@MainActor
struct RelaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var address: String
    @State private var accessCode = ""
    @State private var deviceID: String
    @State private var failure: String?
    let locked: Bool
    let save: @MainActor (Bool, String, String, String) throws -> Void

    init(enabled: Bool, address: String, deviceID: String, locked: Bool,
         save: @escaping @MainActor (Bool, String, String, String) throws -> Void) {
        _enabled = State(initialValue: enabled)
        _address = State(initialValue: address)
        _deviceID = State(initialValue: deviceID.isEmpty ? UUID().uuidString.lowercased() : deviceID)
        self.locked = locked; self.save = save
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
            VStack(alignment: .leading, spacing: 12) {
                Toggle("启用中继功能", isOn: $enabled).toggleStyle(.switch)
                if enabled {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("中继服务地址").font(.subheadline.weight(.medium))
                        TextField("tls://relay.example.com:7443", text: $address)
                            .accessibilityLabel("中继服务地址")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("中继接入码").font(.subheadline.weight(.medium))
                        SecureField("首次填写；留空保留已保存的接入码", text: $accessCode)
                            .accessibilityLabel("中继接入码，与 Mac 配对码不同")
                        Text("由节点部署者提供，与控制 Mac 使用的配对码不同。更换节点需填写该节点的接入码。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
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
            .textFieldStyle(.roundedBorder).disabled(locked)
            if locked { Text("请先停止共享或断开连接，再修改配置。").font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("新配置在下次开启共享或连接时生效。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try save(enabled, address, accessCode, deviceID); accessCode = ""; dismiss() }
                    catch { failure = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(locked)
            }
        }
        .padding(22).frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
