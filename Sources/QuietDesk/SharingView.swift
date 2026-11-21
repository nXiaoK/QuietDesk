import SwiftUI
import AppKit
import QuietDeskCore

struct SharingView: View {
    @ObservedObject var model: DeskModel
    let openTraffic: () -> Void
    var openRelayWorkspace: (() -> Void)? = nil
    var updates: UpdateController? = nil
    @State private var showCode = false
    @State private var copiedCodeFeedback = false
    @State private var confirmingRegeneration = false
    @State private var previousCode = ""
    @State private var showRelaySettings = false
    @State private var showCustomEncoding = false
    @State private var showPermissionTroubleshooting = false

    private var locked: Bool { model.active || model.working }
    private var listenerSettingsLocked: Bool { locked || model.mappingHosting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroStatusBanner

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        pairingCredentialCard
                        permissionHealthCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        pairingCredentialCard
                        permissionHealthCard
                    }
                }

                displayAndQualityCard

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        launchAndRelayCard
                        clipboardAndFilesCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        launchAndRelayCard
                        clipboardAndFilesCard
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(DeskPalette.canvasBackground)
        .onAppear { model.prepareHostCode() }
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
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRelaySettings = false
            confirmingRegeneration = false
        }
    }

    // MARK: - Hero Banner

    private var heroAccent: Color {
        if model.connected { return DeskPalette.emerald }
        if model.active { return DeskPalette.emerald }
        if model.working { return DeskPalette.amber }
        return .secondary
    }

    private var heroStatusBanner: some View {
        DeskSurfaceCard(padding: 18, cornerRadius: 14, highlightColor: locked ? heroAccent : nil) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(locked ? heroAccent.opacity(0.14) : DeskPalette.subtleFill)
                        .frame(width: 50, height: 50)
                    Image(systemName: model.connected ? "person.2.wave.2.fill" : (model.active ? "dot.radiowaves.left.and.right" : "desktopcomputer"))
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(locked ? heroAccent : .secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(model.connected ? "正在共享本机画面" : model.active ? "共享已开启 · 等待连接" : model.working ? "正在准备共享…" : "共享已停止")
                            .font(.system(size: 17, weight: .bold))

                        if model.connected {
                            DeskPillBadge(text: "1 个控制连接", symbol: "bolt.fill", tint: DeskPalette.emerald)
                        }
                        DeskPillBadge(text: "加密监听 :\(model.hostPort)", tint: locked ? DeskPalette.emerald : .secondary, monospaced: true)
                        if locked, model.lanDiscoveryAdvertiseEnabled {
                            DeskPillBadge(text: "局域网可发现", symbol: "dot.radiowaves.up.forward", tint: .accentColor)
                        }
                        if model.relayEnabled {
                            DeskPillBadge(
                                text: model.relayNodes.isEmpty ? "中继未配节点" : "中继 \(model.relayNodes.count) 节点",
                                symbol: "network",
                                tint: .accentColor
                            )
                        }
                    }

                    if locked {
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if model.connected, let state = model.activeVideoState {
                            Text("当前会话生效：\(state.settings.summary)\(model.activeVideoFormatSuffix)（控制端会话内调整，不修改下方默认值）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("开启共享后，你自己的另一台 Mac 可经局域网、端口映射或自托管中继安全控制这台书桌。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.status != "准备就绪", model.status != "共享已停止" {
                            Text(model.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if locked {
                    HStack(spacing: 8) {
                        if model.hasIncomingControlConnection {
                            Button(role: .destructive) {
                                model.disconnectController()
                            } label: {
                                Label("断开控制端", systemImage: "xmark.circle")
                            }
                            .controlSize(.large)
                            .help("结束当前控制连接，共享保持开启；旧版控制端可能自动重连")
                        }
                        Button {
                            model.stop()
                        } label: {
                            Label("停止共享", systemImage: "stop.circle")
                        }
                        .controlSize(.large)
                    }
                } else {
                    Button {
                        model.startHosting()
                    } label: {
                        Label("开启共享", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Pairing Credential Card

    private var pairingCredentialCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("本机连接凭据（配对码）", systemImage: "key.horizontal.fill")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer()
                    DeskInfoPopoverButton(
                        title: "配对码安全与存储说明",
                        lines: [
                            "持有完整配对码即可查看并控制这台 Mac，请只通过可信渠道交给自己的设备。",
                            "配对码保存在当前账户的本机私有文件中，由系统账户文件权限保护，未单独加密，也不再读取旧钥匙串。",
                            "重新生成配对码会让原码立即失效；共享或独立端口映射服务运行期间锁定更换。"
                        ],
                        label: "安全说明"
                    )
                }

                if model.hostCode.isEmpty {
                    Text("尚未生成本机配对码")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if showCode {
                    Text(model.hostCode)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                        }
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            Text("••••")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                                }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        model.prepareHostCode()
                        showCode.toggle()
                    } label: {
                        Label(showCode ? "隐藏明文" : "显示明文", systemImage: showCode ? "eye.slash" : "eye")
                    }
                    .controlSize(.small)
                    .disabled(model.hostCode.isEmpty)

                    Button {
                        model.copyHostCode()
                        copiedCodeFeedback = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedCodeFeedback = false
                        }
                    } label: {
                        Label(copiedCodeFeedback ? "已复制配对码" : "复制完整配对码",
                              systemImage: copiedCodeFeedback ? "checkmark" : "doc.on.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.hostCode.isEmpty)

                    Button(model.hostCode.isEmpty ? "生成新码" : "更换…") {
                        if model.hostCode.isEmpty {
                            model.regenerateKey()
                        } else {
                            confirmingRegeneration = true
                        }
                    }
                    .controlSize(.small)
                    .disabled(listenerSettingsLocked)
                    .confirmationDialog("重新生成配对码？", isPresented: $confirmingRegeneration, titleVisibility: .visible) {
                        Button("重新生成", role: .destructive) { model.regenerateKey() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("旧配对码会立即失效，所有已配对的控制端都需要输入新配对码才能连接。")
                    }
                }

                if model.hostCodeNeedsSetup {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("若升级前已有配对码，可在此补录一次以保持原控制端免改码连接：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            SecureField("输入原来的完整配对码", text: $previousCode)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .accessibilityLabel("原来的主机配对码")
                            Button("保存原配对码") {
                                if model.restoreHostCode(previousCode) { previousCode = "" }
                            }
                            .controlSize(.small)
                            .disabled(previousCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .disabled(listenerSettingsLocked)
                    }
                }

                Text(listenerSettingsLocked
                     ? "持有配对码等同拥有本机控制权限。停止桌面共享与独立映射服务后可更换配对码。"
                     : "持有配对码等同拥有本机控制权限，请仅在自己的设备间传递。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 176, alignment: .topLeading)
        }
    }

    // MARK: - Permission Health Card

    private var permissionHealthCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("系统权限实际生效检测", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer()
                    Button("重新检测") {
                        model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
                    }
                    .controlSize(.small)
                }

                permissionStatusTile(
                    title: "屏幕录制与系统音频",
                    subtitle: model.localScreenRecording ? "ScreenCaptureKit 画面与音频采集已就绪" : "采集桌面画面必需权限",
                    symbol: "rectangle.dashed.badge.record",
                    granted: model.localScreenRecording,
                    action: model.openScreenPermission
                )

                permissionStatusTile(
                    title: "辅助功能（键鼠注入）",
                    subtitle: model.localAccessibility ? "远程点击、输入与自动解锁已生效" : "未生效时仅允许远端观看画面",
                    symbol: "accessibility",
                    granted: model.localAccessibility,
                    action: model.requestAccessibility
                )

                PermissionNextStepView(
                    step: .sharing(
                        screenRecording: model.localScreenRecording,
                        accessibility: model.localAccessibility,
                        started: locked
                    ),
                    compact: true
                ) { action in
                    switch action {
                    case .screenRecording: model.openScreenPermission()
                    case .accessibility: model.requestAccessibility()
                    case .inputMonitoring: model.requestInputMonitoring()
                    case .recheck: model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
                    }
                }

                DisclosureGroup("已勾选仍未生效？查看排障与当前应用路径", isExpanded: $showPermissionTroubleshooting) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("建议先将应用移到「应用程序」再授权。系统已勾选仍未生效时，请完全退出后重开；升级覆盖安装后的旧授权记录可能需要先在系统设置中移除（-），再重新拖入当前应用一次。")
                        Text("当前进程路径：\(Bundle.main.bundleURL.path)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 176, alignment: .topLeading)
        }
    }

    private func permissionStatusTile(
        title: String,
        subtitle: String,
        symbol: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 16))
                .foregroundStyle(granted ? DeskPalette.emerald : DeskPalette.amber)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            DeskPillBadge(
                text: granted ? "已生效" : "未生效",
                tint: granted ? DeskPalette.emerald : DeskPalette.amber
            )

            Button("系统设置…", action: action)
                .controlSize(.small)
                .accessibilityLabel("打开\(title)系统设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Display & Default Encoding Card

    private var displayAndQualityCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Label("共享显示器与默认编码上限", systemImage: "display")
                        .font(.system(size: 13.5, weight: .bold))
                    DeskPillBadge(text: "H.264 / HEVC · 端到端加密", tint: .secondary)
                    DeskInfoPopoverButton(
                        title: "编码档位与兼容说明",
                        lines: [
                            "此处设置共享端初始默认值；新版控制端在会话内调整画质按连接记忆，不会覆盖这里的默认档位。",
                            "静止画面最多渐进细化 4 次后停止重复编码，0 fps 属于正常省流表现。",
                            "原分辨率上限为单边 8192 像素、总计 3600 万像素；两端硬件均支持时自动启用 HEVC，最高可选 240 fps 与 100 Mbps。"
                        ]
                    )
                    Spacer(minLength: 8)
                    if locked {
                        Label("共享中可切屏幕；端口与默认画质需停止后修改", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("共享显示器")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker(
                            "显示器",
                            selection: Binding(get: { model.displayID }, set: { model.chooseDisplay($0) })
                        ) {
                            ForEach(model.screens, id: \.id) { screen in
                                Text(screen.name).tag(screen.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .disabled(model.working || model.displaySwitchWorking)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        Text("监听端口")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("5908", text: $model.hostPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(width: 82)
                            .accessibilityLabel("监听端口")
                    }
                    .disabled(listenerSettingsLocked)
                }

                if let notice = model.displayFallbackNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 4 Scenario Quality Presets
                HStack(spacing: 10) {
                    ForEach(SessionQualityPreset.allCases, id: \.self) { preset in
                        let resolved = preset.resolvedSettings(
                            longestEdges: StreamSettings.longestEdges,
                            frameRates: StreamSettings.frameRates,
                            bitRates: StreamSettings.bitRates
                        )
                        let active = model.settings == resolved
                        Button {
                            model.settings = resolved
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(preset.title)
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                                    Spacer(minLength: 2)
                                    if active {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(resolved.summary)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                active ? Color.accentColor.opacity(0.09) : DeskPalette.subtleFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        active ? Color.accentColor.opacity(0.45) : DeskPalette.hairline,
                                        lineWidth: active ? 1.2 : 0.8
                                    )
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(locked)
                    }
                }

                DisclosureGroup(
                    "自定义默认最长边、帧率上限与目标码率（当前：\(model.settings.summary)）",
                    isExpanded: $showCustomEncoding
                ) {
                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Text("最长边").foregroundStyle(.secondary)
                            Picker("最长边", selection: $model.settings.longestEdge) {
                                Text("1280 · 省流").tag(1280)
                                Text("1920 · 办公").tag(1920)
                                Text("2560 · 清晰").tag(2560)
                                Text("3840 · 高分辨率").tag(3840)
                                Text(StreamSettings.resolutionLabel(StreamSettings.nativeLongestEdge))
                                    .tag(StreamSettings.nativeLongestEdge)
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 8) {
                            Text("帧率上限").foregroundStyle(.secondary)
                            Picker("帧率上限", selection: $model.settings.framesPerSecond) {
                                ForEach(StreamSettings.frameRates, id: \.self) {
                                    Text("\($0) fps").tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)

                        HStack(spacing: 8) {
                            Text("目标码率").foregroundStyle(.secondary)
                            Picker("目标码率", selection: $model.settings.megabits) {
                                ForEach(StreamSettings.bitRates, id: \.self) {
                                    Text("\($0) Mbps").tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 10)
                    .disabled(locked)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Launch, Relay & Clipboard Cards

    private var launchAndRelayCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("后台启动与自托管中继", systemImage: "power.circle.fill")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer()
                    DeskInfoPopoverButton(
                        title: "后台共享边界说明",
                        lines: [
                            "应用运行于用户态，macOS 登录前或 FileVault 解锁前无法共享。",
                            "关闭主窗口后共享仍在菜单栏后台运行；完全退出 QuietDesk 会停止共享。",
                            "开启共享后仍可在「远程桌面」连接其他 Mac，外连期间本机暂不接受连入。",
                            "启用局域网零配置发现后，仅在共享开启期间广播设备名称与匿名标识，不含配对码；控制端仍须凭配对码完成加密认证。"
                        ]
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "登录后自动启动 QuietDesk",
                        isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) })
                    )
                    Toggle("启动后自动开启本机共享", isOn: $model.autoStartSharing)
                    Toggle("登录自动启动时最小化主窗口", isOn: $model.minimizeAtLogin)
                    Toggle("开启共享时允许局域网零配置发现（Bonjour）", isOn: $model.lanDiscoveryAdvertiseEnabled)
                    if let updates, updates.enabled {
                        SharingAutoUpdateToggleRow(updates: updates)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.callout)

                if model.loginNeedsApproval {
                    Button("在系统设置中允许登录启动…") {
                        LaunchSettings.openSettings()
                    }
                    .controlSize(.small)
                }

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                            Text("自托管中继")
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(model.relayEnabled ? model.relayHostStatus : "未启用；直连与路由器端口映射保持可用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.relayEnabled, !model.relayDeviceID.isEmpty {
                            Text("本机设备 ID：\(model.relayDeviceID)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 6)
                    Button("配置中继…") {
                        if let openRelayWorkspace {
                            openRelayWorkspace()
                        } else {
                            showRelaySettings = true
                        }
                    }
                    .controlSize(.small)
                }

                if model.relayEnabled {
                    RelayPeerAssistPicker(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var clipboardAndFilesCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("剪贴板与文件接收", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer()
                    Button(action: openTraffic) {
                        Label("地址流量统计 →", systemImage: "chart.bar.xaxis")
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                }

                Toggle(
                    "双向按需同步文字、图片与文件",
                    isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })
                )
                .toggleStyle(.checkbox)
                .font(.callout)

                Text("文字和图片仅在按 ⌘V 或右键粘贴时拉取传输，复制本身不占流量；文件和文件夹走独立分片通道，需接收端逐次确认后才落盘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        model.openReceivedFiles()
                    } label: {
                        Label("打开接收文件目录", systemImage: "folder")
                    }
                    .controlSize(.small)

                    if let id = model.receivingFileID {
                        Button("中断接收", role: .destructive) {
                            model.cancelFileReception(id: id)
                        }
                        .controlSize(.small)
                    }
                }

                if let notice = model.fileTransferNotice {
                    FileTransferResultView(
                        notice: notice,
                        openFolder: { model.openReceivedFiles() },
                        dismiss: { model.dismissReceivedFilesNotice() }
                    )
                } else if model.receivedFilesKeptInFolder {
                    Text(ClipboardSync.keptFilesNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.clipboardStatus.isEmpty {
                    Divider()
                    Text(model.clipboardStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct SharingAutoUpdateToggleRow: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Toggle(
            "非远程控制时自动更新安装（重启后自动恢复共享）",
            isOn: Binding(get: { updates.autoInstallPreference }, set: { updates.setAutomaticInstall($0) })
        )
    }
}
