import SwiftUI
import AppKit
import QuietDeskCore

struct SharingView: View {
    @ObservedObject var model: DeskModel
    let openTraffic: () -> Void
    var openRelayWorkspace: (() -> Void)? = nil
    var updates: UpdateController? = nil

    private enum Page: String, CaseIterable {
        case sharing = "本机共享"
        case quality = "默认画质"
        case background = "后台与传输"
    }

    @State private var page: Page = .sharing
    @State private var showCode = false
    @State private var pairingCopyStatus: String?
    @State private var confirmingRegeneration = false
    @State private var showRestoreCodeSheet = false
    @State private var previousCode = ""
    @State private var showRelaySettings = false
    @State private var showPermissionTroubleshooting = false
    @FocusState private var portFocused: Bool

    private var locked: Bool { model.active || model.working }
    private var listenerSettingsLocked: Bool { locked || model.mappingHosting }

    var body: some View {
        DeskSettingsPageTabs(tabs: Page.allCases.map { ($0, $0.rawValue) }, selection: $page) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DeskSettingsPageHeading(
                        title: page == .sharing && locked ? "共享运行中" : page.rawValue,
                        badgeText: page == .sharing && locked
                            ? (model.connected ? "已连入控制端" : (model.working ? "正在准备" : "运行中"))
                            : nil,
                        badgeTint: model.connected || model.working ? DeskPalette.amber : DeskPalette.emerald
                    )

                    if page != .background, let notice = model.fileTransferNotice {
                        DeskSurfaceCard(padding: 14, cornerRadius: 10) {
                            fileTransferResult(notice)
                        }
                    }

                    switch page {
                    case .sharing:
                        sharingStatus
                        if locked {
                            sharingLockedNoticeGroup
                        }
                        permissionHealth
                    case .quality:
                        displayAndListener
                        defaultEncoding
                    case .background:
                        launchSettings
                        clipboardAndFiles
                        relaySettings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onAppear { model.prepareHostCode() }
        .onChange(of: page) { _, newPage in
            if newPage != .sharing {
                previousCode = ""
                showCode = false
            }
        }
        .onDisappear { previousCode = "" }
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(
                enabled: model.relayEnabled,
                nodes: model.relayNodes,
                deviceID: model.relayDeviceID,
                locked: model.relaySettingsLocked,
                measurements: model.relayNodeMeasurements,
                loadTrust: model.relayCertificate,
                saveNode: model.saveRelayNode,
                save: model.saveRelayConfiguration
            )
        }
        .sheet(isPresented: $showRestoreCodeSheet) {
            restorePreviousCodeSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRelaySettings = false
            showRestoreCodeSheet = false
            confirmingRegeneration = false
        }
    }

    // MARK: - Page 1: 本机共享 / 共享运行中 (Pages 12, 16, 17, 53)

    private var sharingStatus: some View {
        DeskSettingsGroup(title: locked ? "当前共享" : "共享状态") {
            DeskSettingsRow(title: "共享这台 Mac") {
                HStack(spacing: 8) {
                    if model.working { ProgressView().controlSize(.small) }
                    if model.connected {
                        DeskPillBadge(
                            text: model.canControl ? "控制连接" : "仅观看连接",
                            symbol: "circle.fill",
                            tint: DeskPalette.emerald
                        )
                    }
                    Toggle(locked ? "停止共享" : "开启共享", isOn: Binding(
                        get: { locked },
                        set: { enabled in
                            if enabled { model.startHosting() } else { model.stop() }
                        }
                    ))
                    .labelsHidden()
                    .help(locked ? "停止共享" : "开启共享")
                }
            }

            if model.connected || model.hasIncomingControlConnection {
                Divider()
                DeskSettingsRow(title: "控制端", detail: model.status) {
                    if model.hasIncomingControlConnection {
                        Button("断开控制端", role: .destructive) { model.disconnectController() }
                            .buttonStyle(DeskButtonStyle(.danger))
                            .help("结束当前控制连接，共享保持开启；旧版控制端可能自动重连")
                    }
                }
            } else if model.status != "准备就绪" && model.status != "共享已停止" && !model.status.isEmpty {
                Divider()
                DeskSettingsRow(title: "运行状态") {
                    Text(model.status)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                        .textSelection(.enabled)
                }
            }

            if model.connected, let state = model.activeVideoState {
                Divider()
                DeskSettingsRow(title: "当前生效画面", detail: "当前会话调整不会回写默认值。") {
                    Text("\(state.settings.summary)\(model.activeVideoFormatSuffix)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DeskPalette.secondary)
                }
            }

            Divider()
            DeskSettingsRow(title: "监听端口") {
                Text(model.hostPort)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
            }

            Divider()
            DeskSettingsRow(title: "本机配对码") {
                pairingCodeValue
            }

            Divider()
            DeskSettingsRow(title: "配对码操作", detail: pairingCopyStatus) {
                pairingActions
            }

            if model.hostCodeNeedsSetup {
                Divider()
                DeskSettingsRow(
                    title: "沿用升级前的配对码",
                    detail: "如果升级前已有配对码，输入一次后原控制端不用改码就能连接。"
                ) {
                    Button("输入原配对码…") {
                        previousCode = ""
                        showRestoreCodeSheet = true
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(listenerSettingsLocked)
                }
            }
        }
    }

    private var sharingLockedNoticeGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeskSettingsGroup(title: "共享期间锁定") {
                DeskSettingsRow(title: "监听端口") {
                    Text("\(model.hostPort) · 停止后修改")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                }
                Divider()
                DeskSettingsRow(title: "默认编码上限") {
                    Text("\(currentPreset?.title ?? model.settings.summary) · 停止后修改")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                }
            }

            HStack {
                Text("当前会话的画质调整不会回写默认值。停止共享会结束被控服务。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                Spacer(minLength: 12)
                Button("停止共享", role: .destructive) {
                    model.stop()
                }
                .buttonStyle(DeskButtonStyle(.danger))
            }
        }
    }

    @ViewBuilder
    private var pairingCodeValue: some View {
        if model.hostCode.isEmpty {
            Text("尚未生成")
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
        } else {
            Text(showCode ? model.hostCode : "• • • • • • • • • • • •")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DeskPalette.ink)
                .textSelection(.enabled)
                .lineLimit(showCode ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 196, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                }
                .accessibilityLabel(showCode ? model.hostCode : "配对码已隐藏")
        }
    }

    private var pairingActions: some View {
        HStack(spacing: 7) {
            DeskInfoPopoverButton(
                title: "配对码安全与存储说明",
                lines: [
                    "持有完整配对码即可查看并控制这台 Mac，请只通过可信渠道交给自己的设备。",
                    "配对码保存在当前账户的本机私有文件中，由系统账户文件权限保护，未单独加密，也不再读取旧钥匙串。",
                    "重新生成配对码会让原码立即失效；共享或独立端口映射服务运行期间锁定更换。"
                ]
            )
            Button(showCode ? "隐藏" : "显示") {
                model.prepareHostCode()
                showCode.toggle()
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(model.hostCode.isEmpty)

            Button("复制") {
                model.copyHostCode()
                pairingCopyStatus = model.clipboardStatus
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(model.hostCode.isEmpty)

            Button(model.hostCode.isEmpty ? "生成新码" : "更换…") {
                if model.hostCode.isEmpty {
                    model.regenerateKey()
                } else {
                    confirmingRegeneration = true
                }
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(listenerSettingsLocked)
            .confirmationDialog("重新生成本机配对码？", isPresented: $confirmingRegeneration, titleVisibility: .visible) {
                Button("重新生成", role: .destructive) { model.regenerateKey() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("旧配对码会立即失效。所有已配对的控制端都需要输入新配对码才能再次连接。")
            }
        }
    }

    private var restorePreviousCodeSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("输入升级前的配对码")
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("如果升级前已有配对码，在这里输入一次，原控制端就能继续使用原码连接。")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("输入原来的完整配对码", text: $previousCode)
                .font(.system(size: 13, design: .monospaced))
                .deskInputBox()
                .accessibilityLabel("原来的主机配对码")

            Text("不会显示或填入真实密码。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.muted)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    previousCode = ""
                    showRestoreCodeSheet = false
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

                Button("保存原配对码") {
                    if model.restoreHostCode(previousCode) {
                        previousCode = ""
                        showRestoreCodeSheet = false
                    }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(previousCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(26)
        .frame(width: 500)
        .deskSurface()
    }

    private var permissionHealth: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeskSettingsGroup(title: "系统权限 · 实际生效检测") {
                permissionRow("屏幕录制与系统音频",
                              granted: model.localScreenRecording, action: model.openScreenPermission)
                Divider()
                permissionRow("辅助功能", granted: model.localAccessibility, action: model.requestAccessibility)
                Divider()
                settingToggle("允许控制端操作键盘、鼠标与自动解锁", isOn: Binding(
                    get: { model.hostAllowsRemoteControl },
                    set: { model.setHostAllowsRemoteControl($0) }
                ))
                .help("关闭后仅允许查看画面，无需撤销辅助功能授权")
            }

            PermissionNextStepView(
                step: .sharing(screenRecording: model.localScreenRecording, accessibility: model.localAccessibility,
                               started: locked, allowsRemoteControl: model.hostAllowsRemoteControl),
                compact: false
            ) { action in
                switch action {
                case .screenRecording: model.openScreenPermission()
                case .accessibility: model.requestAccessibility()
                case .inputMonitoring: model.requestInputMonitoring()
                case .recheck: model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
                }
            }

            HStack(alignment: .top) {
                DisclosureGroup("已勾选仍未生效？查看排障与当前应用路径", isExpanded: $showPermissionTroubleshooting) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("建议先将应用移到「应用程序」再授权。系统已勾选仍未生效时，请完全退出后重开；升级覆盖安装后的旧授权记录可能需要先在系统设置中移除（-），再重新拖入当前应用一次。")
                        Text("当前进程路径：\(Bundle.main.bundleURL.path)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)

                Spacer(minLength: 12)

                Button("授权指引与重新检测") {
                    model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
                    if !model.localScreenRecording {
                        model.openScreenPermission()
                    } else if model.hostAllowsRemoteControl && !model.localAccessibility {
                        model.requestAccessibility()
                    }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        DeskSettingsRow(title: title) {
            HStack(spacing: 12) {
                Text(granted ? "已生效" : "尚未生效")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(granted ? DeskPalette.emerald : DeskPalette.amber)
                Button("系统设置…", action: action)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .accessibilityLabel("打开\(title)系统设置")
            }
        }
    }

    // MARK: - Page 2: 默认画质 (Page 13)

    private var displayAndListener: some View {
        VStack(alignment: .leading, spacing: 9) {
            DeskSettingsGroup(title: "共享显示与监听") {
                DeskSettingsRow(title: "共享显示器") {
                    Picker("共享显示器", selection: Binding(
                        get: { model.displayID }, set: { model.chooseDisplay($0) }
                    )) {
                        ForEach(model.screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                    }
                    .labelsHidden()
                    .frame(width: 196)
                    .disabled(model.working || model.displaySwitchWorking)
                }
                Divider()
                DeskSettingsRow(title: "监听端口") {
                    TextField("5908", text: $model.hostPort)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($portFocused)
                        .deskInputBox(focused: portFocused, cornerRadius: 7, minHeight: 32)
                        .frame(width: 196)
                        .accessibilityLabel("监听端口")
                        .disabled(listenerSettingsLocked)
                }
            }
            if let notice = model.displayFallbackNotice {
                Text(notice).font(.caption).foregroundStyle(DeskPalette.secondary)
            }
        }
    }

    private var currentPreset: SessionQualityPreset? {
        SessionQualityPreset.matching(model.settings, longestEdges: StreamSettings.longestEdges,
                                      frameRates: StreamSettings.frameRates, bitRates: StreamSettings.bitRates)
    }

    private var defaultEncoding: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskSettingsGroup(title: "新会话默认编码上限") {
                DeskSettingsRow(title: "画质预设") {
                    Picker("画质预设", selection: Binding<SessionQualityPreset?>(
                        get: { currentPreset },
                        set: { preset in
                            if let preset {
                                model.settings = preset.resolvedSettings(longestEdges: StreamSettings.longestEdges,
                                                                         frameRates: StreamSettings.frameRates,
                                                                         bitRates: StreamSettings.bitRates)
                            }
                        }
                    )) {
                        if currentPreset == nil { Text("自定义").tag(nil as SessionQualityPreset?) }
                        ForEach(SessionQualityPreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(Optional(preset))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 196)
                }
                Divider()
                DeskSettingsRow(title: "最长边") {
                    Picker("最长边", selection: $model.settings.longestEdge) {
                        Text("1280 · 省流").tag(1280)
                        Text("1920 · 办公").tag(1920)
                        Text("2560 · 清晰").tag(2560)
                        Text("3840 · 高分辨率").tag(3840)
                        Text(StreamSettings.resolutionLabel(StreamSettings.nativeLongestEdge))
                            .tag(StreamSettings.nativeLongestEdge)
                    }
                    .labelsHidden()
                    .frame(width: 196)
                }
                Divider()
                DeskSettingsRow(title: "帧率上限") {
                    Picker("帧率上限", selection: $model.settings.framesPerSecond) {
                        ForEach(StreamSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 196)
                }
                Divider()
                DeskSettingsRow(title: "目标码率") {
                    Picker("目标码率", selection: $model.settings.megabits) {
                        ForEach(StreamSettings.bitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 196)
                }
            }
            .disabled(locked)

            HStack(alignment: .center, spacing: 7) {
                Text("端口与默认画质需停止共享后修改；当前会话画质由控制端调整，不回写默认值。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DeskInfoPopoverButton(
                    title: "编码档位与兼容说明",
                    lines: [
                        "H.264 / HEVC 视频始终经端到端加密传送。",
                        "静止画面最多渐进细化 4 次后停止重复编码，0 fps 属于正常省流表现。",
                        "原分辨率上限为单边 8192 像素、总计 3600 万像素；两端硬件均支持时自动启用 HEVC，最高可选 240 fps 与 100 Mbps。"
                    ]
                )
            }
        }
    }

    // MARK: - Page 3: 后台与传输 (Pages 14 & 64)

    private var launchSettings: some View {
        DeskSettingsGroup(title: "启动与共享") {
            if model.loginNeedsApproval {
                DeskSettingsRow(title: "登录自动启动") {
                    Text("系统未允许")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DeskPalette.amber)
                }
                Divider()
                DeskSettingsRow(title: "登录启动设置", detail: "请在系统设置 → 通用 → 登录项与扩展中允许 QuietDesk。") {
                    Button("在系统设置中允许…") { LaunchSettings.openSettings() }
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            } else {
                settingToggle("登录启动", isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }
                ))
            }
            Divider()
            settingToggle("启动后自动开启本机共享", isOn: $model.autoStartSharing)
            Divider()
            settingToggle("登录自动启动时最小化主窗口", isOn: $model.minimizeAtLogin)
            Divider()
            settingToggle("接通外部电源时阻止空闲睡眠", isOn: $model.preventHostSleepOnExternalPower)
            Divider()
            settingToggle("允许 Bonjour 局域网发现", isOn: $model.lanDiscoveryAdvertiseEnabled)
            if let updates, updates.enabled {
                Divider()
                SharingAutoUpdateToggleRow(updates: updates)
            }
            Divider()
            DeskSettingsRow(title: "后台共享说明") {
                DeskInfoPopoverButton(
                    title: "后台共享边界说明",
                    lines: [
                        "应用运行于用户态，macOS 登录前或 FileVault 解锁前无法共享。",
                        "关闭主窗口后共享仍在菜单栏后台运行；完全退出 QuietDesk 会停止共享。",
                        "开启阻止空闲睡眠后只在外部供电时生效。使用电池时允许系统正常睡眠。",
                        "开启共享后可同时在「全部设备」中连接其他设备。",
                        "局域网发现只广播设备名称与匿名标识，控制端仍须凭配对码完成加密认证。"
                    ],
                    label: "查看边界说明"
                )
            }
        }
    }

    private var clipboardAndFiles: some View {
        VStack(alignment: .leading, spacing: 9) {
            DeskSettingsGroup(title: "剪贴板与文件接收") {
                settingToggle("双向按需同步文字、图片与文件", isOn: Binding(
                    get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) }
                ))
                Divider()
                DeskSettingsRow(title: "接收文件目录") {
                    HStack(spacing: 7) {
                        Button("打开目录") { model.openReceivedFiles() }
                            .buttonStyle(DeskButtonStyle(.secondary))
                            .help(ClipboardSync.receivingDirectory)
                        if let id = model.receivingFileID {
                            Button("中断接收", role: .destructive) { model.cancelFileReception(id: id) }
                                .buttonStyle(DeskButtonStyle(.danger))
                        }
                    }
                }
                Divider()
                DeskSettingsRow(title: "接收活动", detail: model.clipboardStatus.isEmpty ? nil : model.clipboardStatus) {
                    HStack(spacing: 10) {
                        if model.clipboardStatus.isEmpty {
                            Text("当前无传输")
                                .font(.system(size: 13))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                        Button("地址流量…", action: openTraffic)
                            .buttonStyle(DeskButtonStyle(.secondary))
                    }
                }
                .textSelection(.enabled)
                if let notice = model.fileTransferNotice {
                    Divider()
                    fileTransferResult(notice).padding(.vertical, 10)
                } else if model.receivedFilesKeptInFolder {
                    Divider()
                    Text(ClipboardSync.keptFilesNotice)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .padding(.vertical, 10)
                }
            }
            Text("文字/图片在粘贴时按需拉取；文件逐次确认后下载。登录启动被系统拒绝时明确显示未允许。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
        }
    }

    private func fileTransferResult(_ notice: FileTransferNotice) -> some View {
        FileTransferResultView(
            notice: notice,
            openFolder: { model.openReceivedFiles() },
            dismiss: { model.dismissReceivedFilesNotice() }
        )
    }

    private var relaySettings: some View {
        DeskSettingsGroup(title: "自托管中继") {
            DeskSettingsRow(title: "中继状态", detail: model.relayEnabled ? model.relayHostStatus : "未启用") {
                Button("配置中继…") {
                    if let openRelayWorkspace { openRelayWorkspace() } else { showRelaySettings = true }
                }
                .buttonStyle(DeskButtonStyle(.secondary))
            }
            if model.relayEnabled {
                if !model.relayDeviceID.isEmpty {
                    Divider()
                    DeskSettingsRow(title: "本机设备标识") {
                        Text(model.relayDeviceID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DeskPalette.secondary)
                            .textSelection(.enabled)
                    }
                }
                Divider()
                RelayPeerAssistPicker(model: model).padding(.vertical, 10)
            }
        }
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        DeskSettingsRow(title: title) {
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }
}

private struct SharingAutoUpdateToggleRow: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        let title = "非远程控制时自动更新并恢复共享"
        DeskSettingsRow(title: title) {
            Toggle(title, isOn: Binding(
                get: { updates.autoInstallPreference }, set: { updates.setAutomaticInstall($0) }
            ))
            .labelsHidden()
        }
    }
}
