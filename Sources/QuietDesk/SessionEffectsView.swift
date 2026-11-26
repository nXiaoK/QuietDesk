import SwiftUI

struct SessionEffectsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    var embedded: Bool = false
    @State private var showUnlockSheet = false
    @State private var showBoundarySheet = false

    private var switchesDisabled: Bool { !model.connected || !model.supportsSessionEffects || model.sessionEffectsWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if embedded {
                details
            } else {
                DeskSectionHeading(title: "被控端隐私与安全")
                ScrollView { details }
                    .frame(maxHeight: 500)
                HStack {
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(DeskButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .toggleStyle(SessionEffectSwitchStyle())
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 520)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .sheet(isPresented: $showBoundarySheet) {
            privacyBoundariesSheet
        }
        .sheet(isPresented: $showUnlockSheet) {
            AutoUnlockConfigurationSheet(model: model, done: { showUnlockSheet = false })
        }
        .onExitCommand { if !embedded { done() } }
        .onAppear { model.refreshUnlockState() }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showBoundarySheet = false
            showUnlockSheet = false
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            availabilityStatusView
            effectsGroup
            recordMemoryAndUnlockGroup

            HStack(alignment: .center, spacing: 8) {
                Text("断开时恢复原状。非笔记本/合盖可能不支持调光；旧端不支持时禁用。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                Spacer(minLength: 8)
                Button("防窥与锁屏边界…") { showBoundarySheet = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var effectsGroup: some View {
        DeskSettingsGroup(title: "会话期间策略") {
            effectRow(
                title: "被控端本机静音",
                subtitle: !model.connected ? "连接建立后才可即时切换" : "关闭被控 Mac 扬声器外放（不影响远端音频回传）",
                isOn: Binding(get: { model.connected && model.sessionEffects.muted }, set: model.setRemoteMuted),
                disabled: switchesDisabled
            )
            Divider()
            effectRow(
                title: "软件黑屏防窥遮罩",
                subtitle: !model.connected ? "连接建立后才可即时切换" : "被控屏幕覆盖全黑遮罩，远端照常查看与操作",
                isOn: Binding(get: { model.connected && model.sessionEffects.privacy }, set: model.setRemotePrivacy),
                disabled: switchesDisabled
            )
            Divider()
            effectRow(
                title: "笔记本内建屏幕亮度归零",
                subtitle: dimBuiltInSubtitle,
                isOn: Binding(get: { model.connected && model.sessionEffects.dimBuiltInDisplay }, set: model.setRemoteDisplayDim),
                disabled: switchesDisabled || !(model.hostDisplayDimmable || model.sessionEffects.dimBuiltInDisplay)
            )
            Divider()
            effectRow(
                title: "断开连接后立即锁屏",
                subtitle: lockOnDisconnectSubtitle,
                isOn: Binding(get: { model.connected && model.sessionEffects.lockOnDisconnect }, set: model.setRemoteLockOnDisconnect),
                disabled: switchesDisabled || !model.supportsSessionLock
            )
        }
    }

    private var dimBuiltInSubtitle: String {
        if !model.connected { return "连接建立后才可即时切换" }
        if !model.supportsDisplayDimming { return "共享端版本不支持，需升级共享端" }
        if !model.hostDisplayDimmable && !model.sessionEffects.dimBuiltInDisplay { return "非笔记本、合盖或无可调内屏时禁用" }
        return "关闭 MacBook 内建屏幕背光，锁屏与调度中心同样防窥"
    }

    private var lockOnDisconnectSubtitle: String {
        if !model.connected { return "连接建立后才可即时切换" }
        if !model.supportsSessionLock { return "共享端版本不支持，需升级共享端" }
        return "任意断线、休眠或重建连接时立即触发系统锁屏"
    }

    private func effectRow(title: String, subtitle: String, isOn: Binding<Bool>, disabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(disabled ? DeskPalette.muted : DeskPalette.ink)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(disabled)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var availabilityStatusView: some View {
        if !model.connected {
            DeskCalloutBox(
                title: "未连接远端",
                message: "连接建立后可在对应远控窗口的「会话设置」或「更多操作」即时切换以下策略；未连接时不将开关显示为已开启。",
                symbol: "info.circle",
                tone: .info
            )
        } else if !model.supportsSessionEffects {
            DeskCalloutBox(
                title: "共享端版本不支持",
                message: "需要升级被控端 QuietDesk 后才可使用防窥、静音与断开锁屏。",
                symbol: "exclamationmark.triangle",
                tone: .warning
            )
        }

        if !model.sessionEffectsStatus.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if model.sessionEffectsWorking { ProgressView().controlSize(.small) }
                Text(model.sessionEffectsStatus)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordMemoryAndUnlockGroup: some View {
        let rememberedItems: [String] = {
            guard let remembered = model.sessionEffectsMemory.connectionState else { return [] }
            return [
                remembered.muted ? "静音" : nil,
                remembered.privacy ? "黑屏防窥" : nil,
                remembered.dimBuiltInDisplay ? "亮度归零" : nil,
                remembered.lockOnDisconnect ? "断开锁屏" : nil
            ].compactMap { $0 }
        }()

        return DeskSettingsGroup(title: "连接记录") {
            DeskSettingsRow(
                title: "成功开启后记忆",
                detail: rememberedItems.isEmpty ? nil : "当前已记忆：\(rememberedItems.joined(separator: "、"))"
            ) {
                Text("后续连接自动生效")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
            }

            Divider()

            DeskSettingsRow(
                title: "自动解锁",
                detail: model.currentRecordID == nil
                    ? "在已连接会话中打开此页，即可为该设备保存或管理锁屏密码"
                    : (model.autoUnlockEnabled ? "已开启自动解锁" : (model.unlockPasswordSaved ? "已保存密码（未开启自动输入）" : "尚未保存锁屏密码"))
            ) {
                Button("设置锁屏密码…") {
                    showUnlockSheet = true
                }
                .buttonStyle(DeskButtonStyle(.secondary))
            }
        }
    }

    private var privacyBoundariesSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("防窥与锁屏边界")
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            boundaryItem(
                title: "软件遮罩",
                detail: "系统安全界面与 Mission Control 不保证遮住；文件确认与权限弹窗在远端仍可见可操作。可在被控端按 Ctrl+Option+Esc 退出。"
            )
            boundaryItem(
                title: "内建屏幕亮度归零",
                detail: "仅支持笔记本内屏，外接屏幕不变暗。本机手动调高亮度会自动关闭此项。"
            )
            boundaryItem(
                title: "断开后锁屏",
                detail: "覆盖断线、休眠与重连；被控进程崩溃或被强制终止时无法执行。"
            )

            HStack {
                Spacer()
                Button("知道了") { showBoundarySheet = false }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 500)
        .deskSurface()
    }

    private func boundaryItem(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DeskPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AutoUnlockConfigurationSheet: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    @State private var unlockPassword = ""
    @FocusState private var passwordFocused: Bool

    private var hasRecord: Bool { model.currentRecordID != nil }
    private var headingTitle: String {
        let target = model.remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? "自动解锁" : "\(target) · 自动解锁"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(headingTitle)
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            Toggle(
                "连接时若被控 Mac 锁屏，自动输入密码解锁",
                isOn: Binding(get: { model.autoUnlockEnabled }, set: model.setAutoUnlock)
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
            .disabled(!hasRecord || !model.unlockPasswordSaved)

            VStack(alignment: .leading, spacing: 6) {
                Text("锁屏密码")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                SecureField(
                    model.unlockPasswordSaved ? "已保存登录密码；输入新密码可替换" : "输入被控 Mac 的系统登录密码",
                    text: $unlockPassword
                )
                .font(.system(size: 13, design: .monospaced))
                .focused($passwordFocused)
                .deskInputBox(focused: passwordFocused)
                .disabled(!hasRecord)
            }

            HStack(spacing: 8) {
                Button("保存密码") {
                    if model.saveUnlockPassword(unlockPassword) { unlockPassword = "" }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .disabled(!hasRecord || unlockPassword.isEmpty)

                if model.unlockPasswordSaved {
                    Button("删除", role: .destructive) { model.removeUnlockPassword() }
                        .buttonStyle(DeskButtonStyle(.danger))
                }

                Spacer()

                if model.unlockWorking {
                    ProgressView().controlSize(.small)
                }
                Button("立即输入密码解锁") { model.unlockNow() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(!model.connected || !model.supportsSessionUnlock || !model.unlockPasswordSaved || model.unlockWorking)
            }

            DeskCalloutBox(
                title: "本机凭据存储",
                message: "按连接记录保存到本机私有文件，绑定当前配对码，未单独加密。",
                symbol: "info.circle",
                tone: .warning
            )

            Text(hasRecord
                 ? "立即输入前请确认目标仍为自己的设备；被控端需已生效辅助功能权限。"
                 : "需先成功连接一次目标设备，并在该会话窗口中打开自动解锁配置。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.unlockStatus.isEmpty {
                Text(model.unlockStatus)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("完成", action: done)
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 510)
        .deskSurface()
        .onAppear {
            model.refreshUnlockState()
            if hasRecord { passwordFocused = true }
        }
        .onDisappear { unlockPassword = "" }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? DeskPalette.actionFill : DeskPalette.hairline)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    }
                    .frame(width: 38, height: 22)
                    .opacity(isEnabled ? 1 : 0.48)
                    .animation(.snappy(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}
