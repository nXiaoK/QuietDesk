import SwiftUI
import QuietDeskCore

struct PortMappingHostView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    var embedded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 500)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onAppear { model.prepareHostCode() }
    }

    private var authorizationGroups: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("独立服务").font(.caption).foregroundStyle(DeskPalette.secondary)
                serviceGroup
                Text("开启独立服务后，无需启动桌面共享即可使用同一配对码和监听端口提供映射服务。")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("已授权来源").font(.caption).foregroundStyle(DeskPalette.secondary)
                sourceGroup
                Text("撤回授权会立即断开对应映射。曾用当前配对码成功远控本机的设备可自动免确认。其他设备首次映射时须经本机确认。")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = manager.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(DeskPalette.coral)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceGroup: some View {
        DeskSurfaceCard(padding: 14, cornerRadius: 9) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("关闭桌面共享时仍接受端口映射").font(.callout.weight(.medium))
                        Text(model.mappingHostingStatus)
                            .font(.caption)
                            .foregroundStyle(DeskPalette.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Toggle(
                        "关闭桌面共享时也接受映射",
                        isOn: Binding(get: { model.mappingHosting }, set: { model.setMappingHosting($0) })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                if manager.hostApprovalPending {
                    Divider()
                    HStack {
                        DeskPillBadge(
                            text: "\(manager.pendingTargets.count) 个访问请求等待确认",
                            symbol: "clock",
                            tint: DeskPalette.amber
                        )
                        Spacer()
                        Button("查看并处理…") { manager.presentPendingRequest() }
                            .buttonStyle(DeskButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    private var sourceGroup: some View {
        let devices = manager.trustedRemoteDevices
        let targets = manager.allowedTargets.sorted { $0.mappingAddress < $1.mappingAddress }

        return DeskSurfaceCard(padding: 14, cornerRadius: 9) {
            VStack(alignment: .leading, spacing: 10) {
                if devices.isEmpty && targets.isEmpty {
                    Text("尚无已授权设备或手动允许的目标地址。")
                        .font(.callout)
                        .foregroundStyle(DeskPalette.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(devices) { device in
                    if device.id != devices.first?.id { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.callout.weight(.medium))
                            Text("上次远控 \(device.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(DeskPalette.secondary)
                        }
                        Spacer()
                        Button("撤回授权", role: .destructive) { manager.revokeRemoteDevice(device.id) }
                            .buttonStyle(DeskButtonStyle(.danger))
                            .accessibilityLabel("撤回 \(device.name) 的授权")
                    }
                }
                ForEach(targets, id: \.self) { target in
                    if !devices.isEmpty || target != targets.first { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.mappingAddress)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text("手动允许的目标").font(.caption).foregroundStyle(DeskPalette.secondary)
                        }
                        Spacer()
                        Button("撤回", role: .destructive) { manager.revoke(target) }
                            .buttonStyle(DeskButtonStyle(.danger))
                            .accessibilityLabel("撤回 \(target.mappingAddress) 的授权")
                    }
                }
            }
        }
    }
}
