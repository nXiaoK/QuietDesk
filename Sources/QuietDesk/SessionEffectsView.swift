import SwiftUI

struct SessionEffectsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    var embedded: Bool = false
    @State private var unlockPassword = ""

    private var switchesDisabled: Bool { !model.connected || !model.supportsSessionEffects || model.sessionEffectsWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("被控端隐私与安全").font(.title3.weight(.bold))
                        Text("开启成功后自动记忆，后续连接自动生效；断开连接时恢复被控端原状。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("会话期间防窥与静音策略", systemImage: "eye.slash.circle.fill")
                            .font(.system(size: 13.5, weight: .bold))
                        Spacer()
                        DeskInfoPopoverButton(
                            title: "防窥遮罩与亮度归零边界说明",
                            lines: [
                                "软件黑屏防窥只从远端画面排除黑屏遮罩本身；被控端的 QuietDesk 窗口、文件确认和权限弹窗在远端仍可见可操作，系统安全界面与 Mission Control 不保证遮住。可在被控端按 ⌃⌥Esc 退出。",
                                "内建屏幕亮度归零仅支持笔记本内建屏（背光关闭，锁屏与调度中心亦不可见），外接显示器不变暗；若被控 Mac 本机调高亮度会自动关闭此项。",
                                "断开立即锁屏涵盖网络中断、休眠与重连；被控进程被强制终止或崩溃时无法执行。"
                            ],
                            label: "边界说明"
                        )
                    }

                    effectRow(
                        title: "被控端本机静音",
                        subtitle: "关闭被控 Mac 扬声器外放（不影响远端音频回传到本机）",
                        isOn: Binding(get: { model.sessionEffects.muted }, set: model.setRemoteMuted),
                        disabled: switchesDisabled
                    )
                    Divider()
                    effectRow(
                        title: "软件黑屏防窥遮罩",
                        subtitle: "被控屏幕覆盖全黑遮罩并配合即时光标隐藏物理指针，远端照常操作",
                        isOn: Binding(get: { model.sessionEffects.privacy }, set: model.setRemotePrivacy),
                        disabled: switchesDisabled
                    )
                    Divider()
                    effectRow(
                        title: "笔记本内建屏幕亮度归零",
                        subtitle: "关闭 MacBook 内建屏幕背光，锁屏与调度中心同样防窥",
                        isOn: Binding(get: { model.sessionEffects.dimBuiltInDisplay }, set: model.setRemoteDisplayDim),
                        disabled: switchesDisabled || !(model.hostDisplayDimmable || model.sessionEffects.dimBuiltInDisplay)
                    )
                    Divider()
                    effectRow(
                        title: "断开连接后立即锁定被控 Mac",
                        subtitle: "任意断线、控制端休眠或重建连接时立即触发系统锁屏",
                        isOn: Binding(get: { model.sessionEffects.lockOnDisconnect }, set: model.setRemoteLockOnDisconnect),
                        disabled: switchesDisabled || !model.supportsSessionLock
                    )

                    if let remembered = model.sessionEffectsMemory.connectionState {
                        let items = [
                            remembered.muted ? "被控端静音" : nil,
                            remembered.privacy ? "黑屏防窥" : nil,
                            remembered.dimBuiltInDisplay ? "亮度归零" : nil,
                            remembered.lockOnDisconnect ? "断开后锁屏" : nil
                        ].compactMap { $0 }
                        if !items.isEmpty {
                            Text("已记忆（新连接自动开启）：" + items.joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    availabilityStatusView
                }
            }

            DeskSurfaceCard(padding: 16, cornerRadius: 13) {
                unlockSection
            }

            if !embedded {
                HStack {
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .toggleStyle(SessionEffectSwitchStyle())
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 500)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .onExitCommand { if !embedded { done() } }
        .onAppear { model.refreshUnlockState() }
        .onDisappear { unlockPassword = "" }
    }

    private func effectRow(title: String, subtitle: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(disabled)
    }

    @ViewBuilder
    private var availabilityStatusView: some View {
        if !model.connected {
            Label("当前未连接远端，连接建立后可即时切换以上开关。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
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
                Text(model.sessionEffectsStatus)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var unlockSection: some View {
        let record = model.currentRecordID != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("远端锁屏自动输入密码解锁", systemImage: "lock.open.display")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                DeskInfoPopoverButton(
                    title: "自动解锁存储与安全机制",
                    lines: [
                        "按连接记录单独保存。连接后约 1.5 秒若检测到被控端处于锁屏，经端到端加密控制通道发送并逐字符输入解锁；未锁屏时不发送任何字符。",
                        "密码保存在当前 Mac 账户的私有文件（未单独加密，不写入日志）；能读取本机当前账户文件的人也可借此解锁被控 Mac。被控端需已生效辅助功能权限。"
                    ],
                    label: "安全说明"
                )
            }

            Toggle("连接时若被控 Mac 处于锁屏，自动输入密码解锁", isOn: Binding(get: { model.autoUnlockEnabled }, set: model.setAutoUnlock))
                .font(.system(size: 13, weight: .medium))
                .disabled(!record || !model.unlockPasswordSaved)

            HStack(spacing: 8) {
                SecureField(model.unlockPasswordSaved ? "已保存登录密码；输入新密码可替换" : "输入被控 Mac 的系统登录密码", text: $unlockPassword)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!record)
                Button("保存密码") { if model.saveUnlockPassword(unlockPassword) { unlockPassword = "" } }
                    .disabled(!record || unlockPassword.isEmpty)
                if model.unlockPasswordSaved {
                    Button("删除", role: .destructive) { model.removeUnlockPassword() }
                }
            }

            HStack(spacing: 8) {
                Button("立即输入密码解锁") { model.unlockNow() }
                    .controlSize(.small)
                    .disabled(!model.connected || !model.supportsSessionUnlock || !model.unlockPasswordSaved || model.unlockWorking)
                if model.unlockWorking { ProgressView().controlSize(.small) }
            }

            if !record {
                Text("成功连接一次某台设备后，即可为该连接记录配置自动解锁密码。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.connected, !model.supportsSessionUnlock {
                Text("共享端需更新后才能自动解锁。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.unlockStatus.isEmpty {
                Text(model.unlockStatus).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
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
