import SwiftUI
import QuietDeskCore

struct PortMappingHostView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void
    var embedded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack {
                    Text("本机 TCP 端口映射授权").font(.title2.bold())
                    Spacer()
                    Button("完成", action: done).keyboardShortcut(.cancelAction)
                }
            }

            DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("关闭桌面共享时仍接受端口映射")
                                .font(.system(size: 13.5, weight: .bold))
                            Text(model.mappingHostingStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                    Text("桌面共享开启时自动接受已授权映射；开启上方开关后，无需启动画面共享即可复用同一配对码与监听端口提供独立映射服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if manager.hostApprovalPending {
                        HStack {
                            DeskPillBadge(
                                text: "\(manager.pendingTargets.count) 个访问请求等待确认",
                                symbol: "bell.badge.fill",
                                tint: DeskPalette.amber
                            )
                            Spacer()
                            Button("查看并处理待确认请求…") {
                                manager.presentPendingRequest()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }

            let content = VStack(alignment: .leading, spacing: 16) {
                DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("曾远控本机的设备（自动免确认）", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 13.5, weight: .bold))
                            Spacer()
                            Text("\(manager.trustedRemoteDevices.count) 台")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("曾使用当前配对码成功远控本机的控制端可直接开启端口映射，无需逐次弹窗确认。撤回会立即断开该设备现有的映射。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if manager.trustedRemoteDevices.isEmpty {
                            Text("尚无已记录的免确认设备。两端升级后成功远控本机一次即可自动登记。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(manager.trustedRemoteDevices) { device in
                                    HStack(spacing: 12) {
                                        Image(systemName: "desktopcomputer")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name).font(.body.weight(.semibold))
                                            Text("上次远控 \(device.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("撤回授权", role: .destructive) {
                                            manager.revokeRemoteDevice(device.id)
                                        }
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }

                DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("手动允许的目标服务地址", systemImage: "network.badge.shield.half.filled")
                                .font(.system(size: 13.5, weight: .bold))
                            Spacer()
                            Text("\(manager.allowedTargets.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("未曾远控本机的设备或旧版控制端首次请求映射时，经本机弹窗允许后记录在此。撤回会立即断开对应映射。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if manager.allowedTargets.isEmpty {
                            Text("尚无手动允许的目标地址")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(manager.allowedTargets.sorted { $0.mappingAddress < $1.mappingAddress }, id: \.self) { target in
                                    HStack {
                                        Text(target.mappingAddress)
                                            .font(.system(.callout, design: .monospaced))
                                            .textSelection(.enabled)
                                        Spacer()
                                        Button("撤回", role: .destructive) {
                                            manager.revoke(target)
                                        }
                                        .controlSize(.small)
                                    }
                                    .padding(10)
                                    .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }

            if embedded {
                content
            } else {
                ScrollView { content }
            }

            if let error = manager.storageError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 560, height: embedded ? nil : 500)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .onAppear { model.prepareHostCode() }
    }
}
