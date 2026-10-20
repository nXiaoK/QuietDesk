import SwiftUI

struct SessionEffectsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void

    private var switchesDisabled: Bool { !model.connected || !model.supportsSessionEffects || model.sessionEffectsWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("被控端隐私与安全").font(.title3.weight(.semibold))
            Text("开启成功后会记住，之后每次连接自动开启；关闭开关即不再自动开启。断开时被控端恢复原状。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("被控端静音", isOn: Binding(get: { model.sessionEffects.muted }, set: model.setRemoteMuted))
                .disabled(switchesDisabled)
            Toggle("防窥 · 本地显示黑屏遮罩", isOn: Binding(get: { model.sessionEffects.privacy }, set: model.setRemotePrivacy))
                .disabled(switchesDisabled)
            Text("黑屏期间远端仍可观看和操作。被控 Mac 可按 ⌃⌥Esc 退出遮罩；系统安全界面、Mission Control 等不在遮罩保证范围内。被控端的截图软件只能截到黑屏，截图请用“截取画面”或 ⌃⌘S。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("防窥会从远端画面排除 QuietDesk 自身窗口，处理被控端的文件确认或权限设置前请先关闭。静音恢复原输出设备状态；设备不支持系统静音时会说明原因。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("断开后立即锁定被控 Mac", isOn: Binding(get: { model.sessionEffects.lockOnDisconnect }, set: model.setRemoteLockOnDisconnect))
                .disabled(switchesDisabled || !model.supportsSessionLock)
            Text("任何断开都会立即锁屏，包括网络中断、控制端休眠和 QuietDesk 自身重建连接。被控 Mac 保持唤醒且 QuietDesk 在运行时，重新连接后可在锁屏界面输入密码解锁（断开锁屏后的重连尚待实机确认）；睡眠、注销、重启后无法远程解锁。被控端 QuietDesk 被强制结束或崩溃时无法锁屏。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let remembered = model.sessionEffectsMemory.connectionState {
                Text("新连接将自动开启：" + [remembered.muted ? "被控端静音" : nil, remembered.privacy ? "防窥" : nil,
                                       remembered.lockOnDisconnect ? "断开后锁屏" : nil].compactMap { $0 }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.connected {
                Text("连接后可使用。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsSessionEffects {
                Text("共享端需更新后才能使用这些开关。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsSessionLock {
                Text("共享端需更新后才能使用断开锁屏。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.sessionEffectsStatus.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if model.sessionEffectsWorking { ProgressView().controlSize(.small) }
                    Text(model.sessionEffectsStatus).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack { Spacer(); Button("完成", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .toggleStyle(.switch)
        .padding(22).frame(width: 450)
        .onExitCommand(perform: done)
    }
}
