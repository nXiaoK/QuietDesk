import AppKit
import QuietDeskCore
import SwiftUI

struct RelayPeerAssistPicker: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("中继打洞", selection: $model.relayPeerAssist) {
                ForEach(RelayPeerAssistMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.connected, !model.relayPeerStatus.isEmpty {
                Text(model.relayPeerStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        switch model.relayPeerAssist {
        case .automatic:
            return "经中继接通后尝试打洞，按延迟和丢包自动选择直连或中继。只有视频会直连；两台已配对的 Mac 会互相看到对方的网络地址。"
        case .on:
            return "打通后视频始终直连，直连中断时立即回到中继。两台已配对的 Mac 会互相看到对方的网络地址。"
        case .off:
            return "视频始终经中继，不交换网络地址。从“关”改为其他选项后，下次连接（被控端为下次开启共享）生效。"
        }
    }
}

/// Chooses the relay node for the next connection; automatic uses the node with the best measured connection.
struct RelayNodePicker: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        if model.relayNodes.count > 1 {
            HStack(spacing: 10) {
                Picker("中继节点", selection: $model.relayNodeChoice) {
                    Text(automaticTitle).tag("")
                    ForEach(model.relayNodes, id: \.self) { node in Text(title(node)).tag(node) }
                }
                .labelsHidden().pickerStyle(.menu)
                Button(model.relayProbing ? "测量中…" : "测速") { model.measureRelayNodes() }
                    .disabled(model.relayProbing)
                    .help("测量各节点的 TCP 连接延迟（约一次网络往返，不含中继凭据）；连接前也会自动测量")
            }
            .onAppear { model.measureRelayNodesIfStale() }
        } else {
            Text(model.relayAddress.isEmpty ? "尚未添加中继节点" : model.relayAddress)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var automaticTitle: String {
        let best = model.relayNodes.min { (score($0) ?? .infinity) < (score($1) ?? .infinity) }
        guard let best, score(best) != nil, let host = try? RelayEndpoint(address: best).host else { return "自动（连接质量最好的节点）" }
        return "自动 · 当前最快 \(host)"
    }

    private func score(_ node: String) -> Double? { model.relayNodeMeasurements[node]?.score }

    private func title(_ node: String) -> String {
        let name = (try? RelayEndpoint(address: node)).map { "\($0.host):\($0.port)" } ?? node
        return RelayNodeLabel.latency(model.relayNodeMeasurements[node]).map { "\(name) · \($0)" } ?? name
    }
}

struct ConnectionSettingsView: View {
    @ObservedObject var model: DeskModel
    let openCaps: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    var openBenchmark: (() -> Void)? = nil
    var embedded: Bool = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            ConnectionOptionsSections(model: model, compact: false)
            if !embedded {
                Divider()
                HStack(spacing: 8) {
                    Label("键盘与快捷键", systemImage: "keyboard")
                    CapsLockStateLabel(model: model)
                    Spacer(minLength: 0)
                    Button("设置…", action: openCaps).buttonStyle(.link)
                }
                Text(model.systemShortcutStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let openBenchmark, !model.connected {
                    Button(action: openBenchmark) {
                        Label("连接与中继线路质量实测…", systemImage: "speedometer")
                    }
                    .disabled(model.active || model.working)
                }
                Button(action: openEffects) { Label("被控端隐私与安全…", systemImage: "lock.shield") }
                Button(action: openTraffic) { Label("设备历史流量…", systemImage: "chart.bar.xaxis") }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.switch).controlSize(.small)

        if embedded {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                content
                    .padding(16).frame(width: 340)
                    .deskSurface()
            }
            .frame(width: 340).frame(maxHeight: 560)
        }
    }
}

private struct ConnectionOptionsSections: View {
    private enum CompactTab: String, CaseIterable, Hashable {
        case display = "画质与屏幕"
        case inputAudio = "光标与声音"
        case transport = "网络与同步"
    }

    @ObservedObject var model: DeskModel
    let compact: Bool
    @State private var compactTab: CompactTab = .display
    @State private var showTypeTextSheet = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    DeskSegmentedTabs(
                        tabs: CompactTab.allCases.map { ($0, $0.rawValue) },
                        selection: $compactTab
                    )
                    switch compactTab {
                    case .display:
                        displayAndQualityBlock
                    case .inputAudio:
                        cursorAndAudioBlock
                    case .transport:
                        networkAndClipboardBlock
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 17) {
                    DeskSettingsGroup(title: "画质与屏幕") {
                        displayAndQualityBlock.padding(.vertical, 10)
                    }
                    DeskSettingsGroup(title: "光标、触控板与音频") {
                        cursorAndAudioBlock.padding(.vertical, 10)
                    }
                    DeskSettingsGroup(title: "连接策略、全屏状态与剪贴板") {
                        networkAndClipboardBlock.padding(.vertical, 10)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(DeskPalette.accent)
    }

    private var displayAndQualityBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.connected, model.supportsDisplaySwitching, !model.remoteDisplays.isEmpty {
                HStack(spacing: 8) {
                    Text("远端显示器").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Picker("远端屏幕", selection: Binding(
                        get: { model.remoteSelectedDisplayID },
                        set: { model.selectRemoteDisplay($0) }
                    )) {
                        ForEach(model.remoteDisplays) { display in
                            Text(display.summary).tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.remoteDisplays.count < 2 || model.displaySwitchWorking)
                }
                if !model.displaySwitchStatus.isEmpty {
                    Text(model.displaySwitchStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text("画面缩放")
                Spacer(minLength: 4)
                Picker("画面显示", selection: $model.canvasScalingMode) {
                    ForEach(RemoteCanvasScalingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 146, alignment: .trailing)
            }

            Divider()
            SessionQualitySection(model: model, compact: compact)
        }
    }

    private var cursorAndAudioBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { model.viewerViewOnlyLock }, set: { model.setViewerViewOnlyLock($0) })) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("本机仅观看防误触（锁定键鼠发送）")
                        .fontWeight(.medium)
                    Text(model.viewerViewOnlyLock
                         ? "已锁定：点击画面不会接管远端键鼠，画面与声音照常播放"
                         : "观看演示或后台任务时开启，避免误点或按键传往远端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Toggle(isOn: Binding(get: { model.remoteAudioEnabled }, set: { model.setRemoteAudioEnabled($0) })) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("远端系统声音回传")
                        .fontWeight(.medium)
                    Text(model.connected
                         ? (model.supportsRemoteAudio ? (model.remoteAudioStatus.isEmpty ? "48 kHz Opus 低延迟音频" : model.remoteAudioStatus) : "对端版本不支持声音回传")
                         : "可与「被控端本机静音」同时开启")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.connected && !model.supportsRemoteAudio)

            Divider()

            Toggle(isOn: $model.lowLatencyCursorEnabled) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("本地即时光标")
                        .fontWeight(.medium)
                    Text(model.connected
                         ? (model.supportsIndependentCursor ? model.cursorStatus : "对端版本不支持独立光标")
                         : "首帧分离视频与指针，消除双光标跟随")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.connected && !model.supportsIndependentCursor)

            Divider()

            Toggle(isOn: Binding(get: { model.relativeMouseEnabled }, set: { model.setRelativeMouseEnabled($0) })) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("相对鼠标（3D 视角锁定）")
                        .fontWeight(.medium)
                    Text(!model.connected ? "连接后可用 · 适合 3D 建模与视角旋转"
                         : !model.supportsRelativeMouse ? "对端版本不支持相对鼠标"
                         : model.relativeMouseCaptured ? "已锁定 · 按 ⌃⌥Esc 立即释放光标"
                         : model.relativeMouseEnabled ? "待激活 · 点击远程画面锁定（⌃⌥Esc 释放）"
                         : "点击画面锁定无边界位移（会话结束重置）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.connected || !model.supportsRelativeMouse || !model.effectiveViewerCanControl)

            if model.connected {
                Text("\(model.controlTransportStatus) · \(model.supportsTrackpadGestures ? "触控板缩放/旋转手势已就绪" : "旧端不含触控板缩放手势")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var networkAndClipboardBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("双向按需同步文字、图片与文件")
                        .fontWeight(.medium)
                    Text("按 ⌘V 时拉取文字图片；文件需接收端确认后下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("接收文件目录")
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Button("打开目录") {
                        model.canvas.releaseControl()
                        model.openReceivedFiles()
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .help(ClipboardSync.receivingDirectory)
                    if let id = model.receivingFileID {
                        Button("中断接收", role: .destructive) { model.cancelFileReception(id: id) }
                            .buttonStyle(DeskButtonStyle(.danger))
                    }
                }
            }

            if model.connected {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Button {
                            model.typeLocalClipboardText()
                        } label: {
                            Label("模拟键入剪贴板", systemImage: "keyboard.badge.ellipsis")
                        }
                        .disabled(model.remoteTypingUnavailableReason != nil)
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .help(model.remoteTypingUnavailableReason ?? "不经过远端剪贴板，将本机剪贴板纯文本逐字符键入远端焦点框")

                        Button {
                            model.canvas.releaseControl()
                            showTypeTextSheet = true
                        } label: {
                            Label("输入文字/密码…", systemImage: "ellipsis.rectangle")
                        }
                        .disabled(model.remoteTypingUnavailableReason != nil)
                        .buttonStyle(DeskButtonStyle(.secondary))

                        if model.remoteTypingWorking {
                            Button("停止", role: .destructive) {
                                model.cancelRemoteTypedText()
                            }
                            .buttonStyle(DeskButtonStyle(.danger))
                        }
                    }
                    if !model.remoteTypingStatus.isEmpty {
                        Text(model.remoteTypingStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .sheet(isPresented: $showTypeTextSheet) {
                    RemoteTypeTextSheet(model: model, done: { showTypeTextSheet = false })
                }
            }

            Divider()

            Toggle(isOn: $model.showFullScreenStatistics) {
                HStack(spacing: 6) {
                    Text("全屏显示实时连接指标")
                        .fontWeight(.medium)
                    DeskInfoPopoverButton(
                        title: "全屏连接状态说明",
                        lines: [
                            "单行胶囊模式精简展示控制态、线路延迟、UDP 丢包（≥3% 标红）、画质帧率与时长，默认顶部居中。",
                            "多行详细模式逐行展示时长、线路、FPS、实时与累计流量、RTT、丢包与分辨率，默认右下角。",
                            "可直接按住浮层拖拽调整位置；RTT 约每 5 秒更新，静止画面 0 fps 属正常省流。"
                        ]
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showFullScreenStatistics { FullScreenStatusSettings(model: model) }

            Divider()

            Toggle(isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) })) {
                Text("断线自动重连").frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Toggle(isOn: Binding(get: { model.disableIdleAutoPause }, set: { model.setDisableIdleAutoPause($0) })) {
                Text(IdleAutoPausePresentation.toggleTitle).frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(IdleAutoPausePresentation.toggleHelp)

            Divider()

            Toggle("仅使用 TCP 视频（下次连接生效）", isOn: $model.mediaTCPOnly)
            Text(model.connected ? model.mediaRouteSummary : (model.mediaTCPOnly ? "下次连接视频固定走 TCP" : "优先加密 UDP，不可达自动回退 TCP"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.relayEnabled { RelayPeerAssistPicker(model: model) }

            if !compact {
                Divider()
                Toggle("结束连接后生成会话诊断报告", isOn: $model.connectionDiagnosticsEnabled)
                    .disabled(model.isControllingAnotherMac)
            }

            if !model.lastDisconnect.isEmpty {
                Text("上次断开：\(model.lastDisconnect)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

struct CapsLockSettingsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    var embedded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !embedded {
                DeskSectionHeading(title: "键盘与快捷键", detail: "设置全屏系统快捷键与 Caps Lock 转发。")
            }
            if embedded {
                CapsLockDetails(model: model, compact: false)
            } else {
                ScrollView { CapsLockDetails(model: model, compact: false) }
                    .frame(height: 350)
                HStack {
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(DeskButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 13)).controlSize(.regular)
        .padding(embedded ? 0 : 22)
        .frame(width: embedded ? nil : 500)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .background(embedded ? Color.clear : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onAppear {
            model.canvas.releaseControl()
            model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
        }
        .onExitCommand { if !embedded { done() } }
    }
}

struct SessionControlsView: View {
    @ObservedObject var model: DeskModel
    let close: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    let openPortMapping: () -> Void

    private var presentation: SessionToolsPresentation {
        SessionToolsPresentation(connected: model.connected, reconnecting: model.reconnecting,
            hasSession: model.active || model.working || model.reconnecting,
            fullScreen: model.isFullScreen, remoteName: model.remoteName, latency: model.latency,
            control: SessionControlPresentation(reconnecting: model.reconnecting, sessionPaused: model.sessionPaused,
                inputSuspended: model.sessionInputSuspended, canControl: model.canControl, controlling: model.controlling,
                localViewOnly: model.viewerViewOnlyLock),
            keyboardSummary: "Caps Lock " + (!model.capsLockEnabled ? "关闭" : model.capsLockRunning ? "已就绪" : "待生效"))
    }

    var body: some View {
        SessionToolsView(presentation: presentation,
            settings: ConnectionOptionsSections(model: model, compact: true),
            keyboard: CapsLockDetails(model: model, compact: true),
            desktop: RemoteDesktopActionsView(unavailableReason: model.desktopActionUnavailableReason,
                status: model.desktopActionStatus, privacyEnabled: model.sessionEffects.privacy,
                perform: { action in
                    model.canvas.releaseControl()
                    model.sendDesktopAction(action)
                }),
            perform: perform, close: close)
        .onChange(of: model.active) { _, active in if !active { close() } }
    }

    private func perform(_ action: SessionToolAction) {
        presentation.perform(action, releaseControl: { model.canvas.releaseControl() }) {
            switch action {
            case .releaseControl: break
            case .fullScreen: close(); model.toggleFullScreen()
            case .sendText: model.pushClipboard()
            case .receiveText: model.pullClipboard()
            case .captureFrame: model.copyRemoteFrame()
            case .keyboard: model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
            case .portMapping: openPortMapping()
            case .privacy: openEffects()
            case .traffic: openTraffic()
            case .endSession:
                close()
                if model.active || model.working || model.reconnecting { model.stop() }
                else if model.isFullScreen { model.toggleFullScreen() }
            }
        }
    }
}

private struct FullScreenStatusSettings: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("样式").foregroundStyle(.secondary)
                Spacer()
                Picker("状态样式", selection: $model.fullScreenStatusCompact) {
                    Text("单行胶囊").tag(true)
                    Text("多行详细").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: model.fullScreenStatusCompact) { _, _ in
                    model.fullScreenStatusPosition = nil
                }
            }
            HStack {
                Text("背景透明度").foregroundStyle(.secondary)
                Slider(value: Binding(get: { 1 - model.fullScreenStatusEffectiveBackgroundOpacity },
                                      set: { model.fullScreenStatusBackgroundOpacity = 1 - $0 }), in: 0...1, step: 0.05)
                    .accessibilityLabel("连接状态背景透明度")
                Text("\(Int(((1 - model.fullScreenStatusEffectiveBackgroundOpacity) * 100).rounded()))%")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            HStack {
                Text("按住状态浮层可直接拖动位置").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("恢复默认位置") { model.fullScreenStatusPosition = nil }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.fullScreenStatusPosition == nil)
            }
        }
        .padding(8)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SessionQualitySection: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        SessionQualityView(settings: Binding(get: { model.viewerSettings }, set: { model.chooseViewerSettings($0) }),
            presentation: SessionQualityPresentation(connected: model.connected, supportsLiveSettings: model.supportsLiveSettings,
                applied: model.activeVideoState, tuning: model.videoTuning, status: model.videoSettingsStatus),
            longestEdges: model.viewerLongestEdges, frameRates: model.viewerFrameRates, bitRates: model.viewerBitRates,
            supportsMediaTransport: model.supportsMediaTransport, supportsExtendedVideoSettings: model.supportsExtendedVideoSettings,
            supportsAdaptiveVideo: model.supportsAdaptiveVideo,
            supportsTrueColor: model.supportsHEVC444Video,
            trueColor: Binding(get: { model.viewerTrueColor }, set: { model.setViewerTrueColor($0) }),
            appliedCodec: model.activeVideoCodec,
            appliedChroma: model.activeVideoChroma,
            onSelectPreset: { model.chooseViewerPreset($0) },
            localNetworkQuality: model.localNetworkQuality,
            qualityHelp: model.videoQualityHelp, compact: compact)
    }
}

private struct CapsLockStateLabel: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        DeskPillBadge(
            text: !model.capsLockEnabled ? "已关闭" : model.capsLockRunning ? "已开启" : "待生效",
            tint: !model.capsLockEnabled ? DeskPalette.secondary : model.capsLockRunning ? DeskPalette.emerald : DeskPalette.amber
        )
    }
}

private struct CapsLockDetails: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 11 : 16) {
            forwardingGroup

            PermissionNextStepView(step: model.remoteKeyboardNextStep, compact: compact, perform: permissionAction)

            DeskSettingsGroup(title: "Caps Lock 按键行为") {
                behaviorRow("短按 Caps Lock", "切换远端输入法")
                Divider()
                behaviorRow("按住至少 0.6 秒后松开", "切换大写锁定")
                Divider()
                behaviorRow("大写锁定开启时短按", "先解除大写锁定")
            }

            permissionsGroup

            if !model.inputStatus.isEmpty {
                Text(model.inputStatus)
                    .font(.caption)
                    .foregroundStyle(model.capsLockEnabled && !model.capsLockRunning ? DeskPalette.amber : DeskPalette.secondary)
                    .lineLimit(compact ? 3 : nil)
                    .textSelection(.enabled)
                    .help(model.inputStatus)
            }
        }
        .tint(DeskPalette.accent)
    }

    private var forwardingGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeskSettingsGroup(title: "转发行为") {
                DeskSettingsRow(title: "启用 Caps Lock 转发") {
                    HStack(spacing: 7) {
                        CapsLockStateLabel(model: model)
                        Toggle("启用 Caps Lock 转发", isOn: Binding(
                            get: { model.capsLockEnabled }, set: { model.setCapsLockEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                Divider()
                DeskSettingsRow(title: "全屏系统快捷键") {
                    Text(model.systemShortcutStatus)
                        .font(.caption)
                        .foregroundStyle(model.systemShortcutsRunning ? DeskPalette.emerald : DeskPalette.secondary)
                }
                Divider()
                DeskSettingsRow(title: "释放控制 / 退出全屏") {
                    Text("⌃⌥Esc / ⌃⌘F")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DeskPalette.secondary)
                }
            }
            Text("全屏并点按远程画面后，⌘空格、⌘Tab 等组合键转发到远端。需下方两项本机权限；系统安全输入开启时暂停转发。")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeskSettingsGroup(title: "本机权限") {
                permissionRow("辅助功能", effective: model.localAccessibility, action: model.requestAccessibility)
                Divider()
                permissionRow("输入监控", effective: model.localInputMonitoring, action: model.requestInputMonitoring)
                Divider()
                DeskSettingsRow(title: "权限与监听检测") {
                    Button("重新检测") { model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) }
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }
            Text("当前应用：\(Bundle.main.bundleURL.path)")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .lineLimit(compact ? 2 : 3)
                .textSelection(.enabled)
                .help(Bundle.main.bundleURL.path)
            PermissionNextStepView(step: .localKeyboard(accessibility: model.localAccessibility,
                inputMonitoring: model.localInputMonitoring, capsEnabled: model.capsLockEnabled,
                capsRunning: model.capsLockRunning), compact: compact, perform: permissionAction)
        }
    }

    private func behaviorRow(_ title: String, _ behavior: String) -> some View {
        DeskSettingsRow(title: title) {
            Text(behavior).font(.caption).foregroundStyle(DeskPalette.secondary)
        }
    }

    private func permissionRow(_ title: String, effective: Bool, action: @escaping () -> Void) -> some View {
        DeskSettingsRow(title: title) {
            HStack(spacing: 7) {
                Text(effective ? "已生效" : "未生效")
                    .font(.caption)
                    .foregroundStyle(effective ? DeskPalette.emerald : DeskPalette.amber)
                Button("系统设置…", action: action)
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .accessibilityLabel("打开\(title)系统设置")
            }
        }
    }

    private func permissionAction(_ action: PermissionNextStep.Action) {
        switch action {
        case .screenRecording: model.openScreenPermission()
        case .accessibility: model.requestAccessibility()
        case .inputMonitoring: model.requestInputMonitoring()
        case .recheck: model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
        }
    }
}

struct RemoteTypeTextSheet: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    @State private var text = ""
    @State private var concealed = true
    @State private var submitReturn = false
    @State private var localError: String?

    private var normalizedText: String {
        TypeTextRequest.normalizeLineEndings(text)
    }

    private var overLimit: Bool {
        normalizedText.count > TypeTextRequest.maximumCharacterCount
            || normalizedText.utf8.count > TypeTextRequest.maximumUTF8Bytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeskSectionHeading(
                title: "模拟键入文字 / 密码",
                detail: "先在远端画面点选目标输入框，再在此发送。内容经加密会话逐字符模拟键盘输入，不写入远端剪贴板。"
            )

            Picker("输入模式", selection: $concealed) {
                Text("隐藏输入（密码 / 令牌）").tag(true)
                Text("明文多行文字").tag(false)
            }
            .pickerStyle(.segmented)

            if concealed {
                SecureField("输入密码、sudo 口令或一次性验证码", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(height: 110)
                    .padding(4)
                    .scrollContentBackground(.hidden)
                    .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                    )
            }

            HStack {
                Toggle("键入完成后自动按回车提交", isOn: $submitReturn)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                Text("\(normalizedText.count)/\(TypeTextRequest.maximumCharacterCount) 字符 · \(normalizedText.utf8.count)/\(TypeTextRequest.maximumUTF8Bytes) 字节")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(overLimit ? DeskPalette.coral : DeskPalette.secondary)
            }

            if let errorMessage = localError ?? model.remoteTypingUnavailableReason {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("取消") {
                    text = ""
                    done()
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始模拟键入") {
                    submit()
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedText.isEmpty || overLimit || model.remoteTypingUnavailableReason != nil)
            }
        }
        .font(.system(size: 13))
        .padding(22)
        .frame(width: 460)
        .deskSurface()
        .onChange(of: text) { _, _ in localError = nil }
        .onDisappear { text = "" }
    }

    private func submit() {
        guard !normalizedText.isEmpty, !overLimit else { return }
        if model.sendRemoteTypedText(text, submitReturn: submitReturn) {
            text = ""
            done()
        } else {
            localError = model.remoteTypingStatus
        }
    }
}
