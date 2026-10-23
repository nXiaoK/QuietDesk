import SwiftUI

struct SessionEffectsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    @State private var unlockPassword = ""

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
            Text("黑屏期间远端仍可操作。新版被控端配合“本地即时光标”可隐藏本机指针，关闭遮罩时恢复；未启用即时光标时保留原有遮罩。⌃⌥Esc 可在被控 Mac 退出；系统安全界面、Mission Control 等不保证遮住。截图请用“截取画面”或 ⌃⌘S。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("防窥只从远端画面排除黑屏遮罩本身；被控端的 QuietDesk 窗口、菜单、文件确认和权限提示在远端仍可见、可操作。静音恢复原输出设备状态；设备不支持系统静音时会说明原因。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("防窥 · 内建屏幕亮度归零", isOn: Binding(get: { model.sessionEffects.dimBuiltInDisplay }, set: model.setRemoteDisplayDim))
                .disabled(switchesDisabled || !(model.hostDisplayDimmable || model.sessionEffects.dimBuiltInDisplay))
            Text("仅用于笔记本的内建屏幕：亮度调到 0、背光关闭，锁屏界面和 Mission Control 也看不见，远端画面照常；外接显示器不会变暗，可同时开启黑屏遮罩。被控 Mac 本机调高亮度时开关自动关闭并在此提示；断开时恢复原亮度，开启断开锁屏时先锁屏再恢复。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("断开后立即锁定被控 Mac", isOn: Binding(get: { model.sessionEffects.lockOnDisconnect }, set: model.setRemoteLockOnDisconnect))
                .disabled(switchesDisabled || !model.supportsSessionLock)
            Text("任何断开都会立即锁屏，包括网络中断、控制端休眠和 QuietDesk 自身重建连接。被控 Mac 保持唤醒且 QuietDesk 在运行时，重新连接后可在锁屏界面输入密码解锁（断开锁屏后的重连尚待实机确认）；睡眠、注销、重启后无法远程解锁。被控端 QuietDesk 被强制结束或崩溃时无法锁屏。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            unlockSection
            if let remembered = model.sessionEffectsMemory.connectionState {
                Text("新连接将自动开启：" + [remembered.muted ? "被控端静音" : nil, remembered.privacy ? "防窥" : nil,
                                       remembered.dimBuiltInDisplay ? "亮度归零" : nil,
                                       remembered.lockOnDisconnect ? "断开后锁屏" : nil].compactMap { $0 }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.connected {
                Text("连接后可使用。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsSessionEffects {
                Text("共享端需更新后才能使用这些开关。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsSessionLock {
                Text("共享端需更新后才能使用断开锁屏和亮度归零。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsDisplayDimming {
                Text("共享端需更新后才能使用亮度归零。").font(.caption).foregroundStyle(.secondary)
            } else if !model.hostDisplayDimmable {
                Text("被控端不是笔记本，或内建屏幕当前无法调节亮度（如已合盖），亮度归零不可用。").font(.caption).foregroundStyle(.secondary)
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
        .toggleStyle(SessionEffectSwitchStyle())
        .padding(22).frame(width: 450)
        .onExitCommand(perform: done)
        .onAppear { model.refreshUnlockState() }
        .onDisappear { unlockPassword = "" }
    }

    @ViewBuilder private var unlockSection: some View {
        let record = model.currentRecordID != nil
        Toggle("连接时被控 Mac 若在锁屏，自动输入密码解锁", isOn: Binding(get: { model.autoUnlockEnabled }, set: model.setAutoUnlock))
            .disabled(!record || !model.unlockPasswordSaved)
        HStack(spacing: 8) {
            SecureField(model.unlockPasswordSaved ? "已保存；输入新密码可替换" : "被控 Mac 的登录密码", text: $unlockPassword)
                .textFieldStyle(.roundedBorder).disabled(!record)
            Button("保存") { if model.saveUnlockPassword(unlockPassword) { unlockPassword = "" } }
                .disabled(!record || unlockPassword.isEmpty)
            if model.unlockPasswordSaved { Button("删除") { model.removeUnlockPassword() } }
        }
        HStack(spacing: 8) {
            Button("立即输入密码解锁") { model.unlockNow() }
                .disabled(!model.connected || !model.supportsSessionUnlock || !model.unlockPasswordSaved || model.unlockWorking)
            if model.unlockWorking { ProgressView().controlSize(.small) }
        }
        Text("按连接记录保存。连接成功、画面出现约 1.5 秒后，若被控 Mac 处于锁屏，被控端会逐个输入密码再回车，你能看到解锁过程，完成后画面上方会提示“已自动解锁”；被控 Mac 没有锁屏时不输入任何字符，输入中途被本机解锁会立即停止。密码保存在这台 Mac 的私有文件（仅当前账户可读，未单独加密），只经端到端加密的控制通道发送，不写入日志；能读取这台 Mac 账户文件的人也能借此解锁被控 Mac。被控端需授权辅助功能。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !record {
            Text("连接成功后可为这条连接记录保存密码。").font(.caption).foregroundStyle(.secondary)
        } else if model.connected, !model.supportsSessionUnlock {
            Text("共享端需更新后才能自动解锁。").font(.caption).foregroundStyle(.secondary)
        }
        if !model.unlockStatus.isEmpty {
            Text(model.unlockStatus).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// The macOS 26 system switch draws its knob through a window portal; in this sheet the knob was seen
// missing after the remote round trip, leaving a bare track, so these switches are drawn here.
private struct SessionEffectSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SessionEffectSwitch(configuration: configuration) }
}

private struct SessionEffectSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                    .frame(width: 38, height: 22)
                    .opacity(isEnabled ? 1 : 0.5)
                    .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}
