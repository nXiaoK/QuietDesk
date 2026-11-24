import SwiftUI
import QuietDeskCore

struct PortMappingHostView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    var embedded: Bool = false
    @State private var pendingRevocation: Revocation?

    private enum Revocation {
        case device(TrustedRemoteMappingDevice)
        case target(PortMappingTarget)

        var title: String {
            switch self {
            case .device: return "撤回设备授权？"
            case .target: return "撤回目标服务？"
            }
        }

        var actionTitle: String {
            switch self {
            case .device: return "撤回授权"
            case .target: return "撤回"
            }
        }

        var detail: String {
            switch self {
            case .device: return "立即断开该设备当前映射，后续映射需重新满足授权条件。"
            case .target: return "立即断开访问该目标的对应映射。以后首次请求将再次确认。"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if embedded {
                authorizationGroups
            } else {
                HStack(alignment: .top) {
                    DeskSectionHeading(title: "本机映射授权", symbol: nil, detail: nil)
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                }
                ScrollView { authorizationGroups }
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 580, height: embedded ? nil : 500)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onAppear { model.prepareHostCode() }
        .confirmationDialog(
            pendingRevocation?.title ?? "撤回授权？",
            isPresented: Binding(get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }),
            titleVisibility: .visible,
            presenting: pendingRevocation
        ) { revocation in
            Button(revocation.actionTitle, role: .destructive) {
                switch revocation {
                case .device(let device): manager.revokeRemoteDevice(device.id)
                case .target(let target): manager.revoke(target)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { revocation in
            Text(revocation.detail)
        }
    }

    private var authorizationGroups: some View {
        VStack(alignment: .leading, spacing: 20) {
            DeskSettingsGroup(title: "独立服务") {
                DeskSettingsRow(
                    title: "关闭桌面共享时仍接受端口映射",
                    detail: model.mappingHostingStatus
                ) {
                    Toggle(
                        "关闭桌面共享时也接受映射",
                        isOn: Binding(get: { model.mappingHosting }, set: { model.setMappingHosting($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                DeskSettingsRow(
                    title: "待确认请求",
                    detail: manager.hostApprovalPending ? "\(manager.pendingTargets.count) 个目标正在等待确认" : nil
                ) {
                    if manager.hostApprovalPending {
                        Button("查看并处理") { manager.presentPendingRequest() }
                            .buttonStyle(DeskButtonStyle(.secondary))
                    } else {
                        Text("当前无待确认请求")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                DeskSettingsGroup(title: "已授权来源") {
                    sourceRows
                }
                Text("撤回会立即断开对应映射。曾用当前配对码成功远控本机的设备可自动免确认。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.storageError {
                DeskCalloutBox(message: error, symbol: "exclamationmark.triangle", tone: .danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sourceRows: some View {
        let devices = manager.trustedRemoteDevices
        let targets = manager.allowedTargets.sorted { $0.mappingAddress < $1.mappingAddress }

        if devices.isEmpty && targets.isEmpty {
            DeskSettingsRow(title: "尚无已授权设备或手动允许的目标地址") {
                EmptyView()
            }
        } else {
            ForEach(devices) { device in
                if device.id != devices.first?.id { Divider() }
                DeskSettingsRow(
                    title: "\(device.name) · 曾成功远控本机",
                    detail: "上次远控 \(device.lastConnected.formatted(date: .abbreviated, time: .shortened))"
                ) {
                    Button("撤回授权", role: .destructive) { pendingRevocation = .device(device) }
                        .buttonStyle(DeskButtonStyle(.danger))
                        .accessibilityLabel("撤回 \(device.name) 的授权")
                }
            }
            ForEach(targets, id: \.self) { target in
                if !devices.isEmpty || target != targets.first { Divider() }
                DeskSettingsRow(title: "\(target.mappingAddress) · 手动允许目标") {
                    Button("撤回", role: .destructive) { pendingRevocation = .target(target) }
                        .buttonStyle(DeskButtonStyle(.danger))
                        .accessibilityLabel("撤回 \(target.mappingAddress) 的授权")
                }
            }
        }
    }
}
