import SwiftUI
import QuietDeskCore

struct PortMappingHostView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本机 TCP 端口映射").font(.title2.bold())
                Spacer()
                Button("完成", action: done).keyboardShortcut(.cancelAction)
            }
            Toggle("关闭桌面共享时也接受映射", isOn: Binding(get: { model.mappingHosting }, set: { model.setMappingHosting($0) }))
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.mappingHostingStatus).textSelection(.enabled)
                Text("桌面共享开启时可直接接受映射。独立映射使用相同的配对码和监听端口，无需开启远程桌面。")
            }
            .font(.callout).foregroundStyle(.secondary)
            if manager.hostApprovalPending {
                Button("查看待确认请求（\(manager.pendingTargets.count)）") { manager.presentPendingRequest() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("曾远控本机的设备（免确认）").font(.headline)
                        Text("曾使用当前配对码远控过这台 Mac 的设备可直接开启端口映射，无需在此 Mac 逐次确认。撤回会断开该设备当前的映射。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if manager.trustedRemoteDevices.isEmpty {
                            Text("尚无已记录的远控设备。升级两端后，控制端成功远控一次这台 Mac 即可自动记录。")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(manager.trustedRemoteDevices) { device in
                                    HStack(alignment: .center, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name).font(.body.weight(.medium))
                                            Text("上次远控 \(device.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("撤回", role: .destructive) { manager.revokeRemoteDevice(device.id) }
                                    }
                                    .padding(.vertical, 6)
                                    Divider()
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("手动允许的目标").font(.headline)
                        Text("未曾远控本机的设备或旧版控制端首次请求映射时，仍需在此 Mac 上确认。撤回会断开该目标现有的映射。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if manager.allowedTargets.isEmpty {
                            Text("尚无手动允许的目标")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(manager.allowedTargets.sorted { $0.mappingAddress < $1.mappingAddress }, id: \.self) { target in
                                    HStack {
                                        Text(target.mappingAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        Spacer()
                                        Button("撤回", role: .destructive) { manager.revoke(target) }
                                    }
                                    .padding(.vertical, 6)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            if let error = manager.storageError { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .padding(22).frame(width: 520, height: 480)
        .onAppear { model.prepareHostCode() }
    }
}
