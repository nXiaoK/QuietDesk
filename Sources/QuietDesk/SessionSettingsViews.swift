import AppKit
import QuietDeskCore
import SwiftUI

struct RelayPeerAssistPicker: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("中继打洞")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.ink)
                Spacer()
                Picker("中继打洞", selection: $model.relayPeerAssist) {
                    ForEach(RelayPeerAssistMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 146)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.connected, !model.relayPeerStatus.isEmpty {
                Text(model.relayPeerStatus)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
            }
        }
    }

    private var summary: String {
        switch model.relayPeerAssist {
        case .automatic:
            return "自动/开启：已配对的两台 Mac 会看到彼此网络地址；仅视频尝试直连。"
        case .on:
            return "打通后视频始终直连，直连中断时立即回到中继；两台 Mac 会看到彼此网络地址。"
        case .off:
            return "关闭不交换地址，视频始终经中继；改出关闭状态需下次连接生效。"
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
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(model.relayProbing ? "测量中…" : "测速") { model.measureRelayNodes() }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .disabled(model.relayProbing)
                    .help("测量各节点的 TCP 连接延迟（约一次网络往返，不含中继凭据）；连接前也会自动测量")
            }
            .onAppear { model.measureRelayNodesIfStale() }
        } else {
            Text(model.relayAddress.isEmpty ? "尚未添加中继节点" : model.relayAddress)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var automaticTitle: String {
        let best = model.relayNodes.min { (score($0) ?? .infinity) < (score($1) ?? .infinity) }
        guard let best, score(best) != nil, let host = try? RelayEndpoint(address: best).host else { return "自动选择最快节点" }
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
        let content = VStack(alignment: .leading, spacing: 18) {
            if embedded {
                embeddedConnectionDefaults
            } else {
                ConnectionOptionsSections(model: model, compact: false)
                Divider()
                HStack(spacing: 8) {
                    Label("键盘与快捷键", systemImage: "keyboard")
                    CapsLockStateLabel(model: model)
                    Spacer(minLength: 0)
                    Button("设置…", action: openCaps).buttonStyle(.link)
                }
                Text(model.systemShortcutStatus)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let openBenchmark, !model.connected {
                    Button(action: openBenchmark) {
                        Label("连接与中继线路质量实测…", systemImage: "speedometer")
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(model.active || model.working)
                }
                HStack(spacing: 8) {
                    Button("隐私与安全…", action: openEffects)
                        .buttonStyle(DeskButtonStyle(.secondary))
                    Button("历史流量…", action: openTraffic)
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.small)

        if embedded {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                content
                    .padding(16)
                    .frame(width: 356)
                    .deskSurface()
            }
            .frame(width: 356)
            .frame(maxHeight: 560)
        }
    }

    private var embeddedConnectionDefaults: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeskSettingsGroup(title: "传输偏好") {
                DeskSettingsRow(
                    title: "仅使用 TCP 视频",
                    detail: model.mediaTCPOnly ? "下次连接视频固定走可靠 TCP" : "默认优先加密 UDP，不可达时自动回退 TCP"
                ) {
                    Toggle("仅使用 TCP 视频", isOn: $model.mediaTCPOnly).labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: "断线自动重连") {
                    Toggle("断线自动重连", isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) }))
                        .labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: IdleAutoPausePresentation.toggleTitle, detail: "离开前台满 10 分钟默认暂停画面省流") {
                    Toggle(IdleAutoPausePresentation.toggleTitle, isOn: Binding(
                        get: { model.disableIdleAutoPause }, set: { model.setDisableIdleAutoPause($0) }
                    ))
                    .labelsHidden()
                    .help(IdleAutoPausePresentation.toggleHelp)
                }
                Divider()
                DeskSettingsRow(title: "结束连接后生成诊断报告") {
                    Toggle("结束连接后生成诊断报告", isOn: $model.connectionDiagnosticsEnabled)
                        .labelsHidden()
                        .disabled(model.isControllingAnotherMac)
                }
                if model.relayEnabled {
                    Divider()
                    RelayPeerAssistPicker(model: model)
                        .padding(.vertical, 10)
                }
            }

            DeskSettingsGroup(title: "显示、音频与剪贴板默认项") {
                DeskSettingsRow(title: "画面缩放") {
                    Picker("画面缩放", selection: $model.canvasScalingMode) {
                        ForEach(RemoteCanvasScalingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 176)
                }
                Divider()
                DeskSettingsRow(title: "本地即时光标", detail: "首帧分离视频与指针，消除双光标跟随") {
                    Toggle("本地即时光标", isOn: $model.lowLatencyCursorEnabled).labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: "远端系统声音回传", detail: "可与「被控端本机静音」同时开启") {
                    Toggle("远端系统声音回传", isOn: Binding(
                        get: { model.remoteAudioEnabled }, set: { model.setRemoteAudioEnabled($0) }
                    ))
                    .labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: "双向按需同步文字、图片与文件", detail: "⌘V 按需拉取文字图片；文件逐次确认后下载") {
                    Toggle("双向按需同步", isOn: Binding(
                        get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) }
                    ))
                    .labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: "全屏顶部工具条", detail: "指针在屏幕顶部中间停留片刻时显示切换屏幕、画质、退出全屏和断开") {
                    Toggle("全屏顶部工具条", isOn: $model.fullScreenToolbarEnabled).labelsHidden()
                }
                Divider()
                DeskSettingsRow(title: "全屏显示实时连接指标") {
                    Toggle("全屏显示实时连接指标", isOn: $model.showFullScreenStatistics).labelsHidden()
                }
                if model.showFullScreenStatistics {
                    Divider()
                    FullScreenStatusSettings(model: model)
                        .padding(.vertical, 8)
                }
            }

            DeskSettingsGroup(title: "相关设置") {
                DeskSettingsRow(title: "键盘与快捷键") {
                    Button("打开设置", action: openCaps)
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
                Divider()
                DeskSettingsRow(title: "被控端隐私偏好") {
                    Button("打开设置", action: openEffects)
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }

            Text("连接级选项与共享端默认编码上限分开；不将待下次连接生效的设置表示为当前已生效。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
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

    private var showsSessionControls: Bool { compact || model.connected }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 11) {
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
                    DeskSettingsGroup(title: showsSessionControls ? "画质与屏幕" : "屏幕显示") {
                        displayAndQualityBlock.padding(.vertical, 10)
                    }
                    DeskSettingsGroup(title: "光标与声音") {
                        cursorAndAudioBlock.padding(.vertical, 10)
                    }
                    DeskSettingsGroup(title: "网络与同步") {
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
        VStack(alignment: .leading, spacing: 10) {
            if model.connected, model.supportsDisplaySwitching, !model.remoteDisplays.isEmpty {
                HStack(spacing: 8) {
                    Text("远端显示器")
                        .foregroundStyle(DeskPalette.ink)
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
                    .frame(width: 152)
                    .disabled(model.remoteDisplays.count < 2 || model.displaySwitchWorking)
                }
                if !model.displaySwitchStatus.isEmpty {
                    Text(model.displaySwitchStatus)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }

            if showsSessionControls {
                SessionQualitySection(model: model, compact: compact)
                Divider()
            }

            HStack(spacing: 8) {
                Text("画面缩放")
                    .foregroundStyle(DeskPalette.ink)
                Spacer(minLength: 4)
                Picker("画面显示", selection: $model.canvasScalingMode) {
                    ForEach(RemoteCanvasScalingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 152, alignment: .trailing)
            }
        }
    }

    private var cursorAndAudioBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactToggleRow(
                "本机仅观看防误触",
                detail: model.viewerViewOnlyLock ? "已锁定键鼠发送，画面照常播放" : nil,
                isOn: Binding(get: { model.viewerViewOnlyLock }, set: { model.setViewerViewOnlyLock($0) })
            )
            Divider()
            compactToggleRow(
                "远端系统声音回传",
                detail: model.connected && !model.supportsRemoteAudio ? "旧端不支持声音回传" : nil,
                isOn: Binding(get: { model.remoteAudioEnabled }, set: { model.setRemoteAudioEnabled($0) }),
                disabled: model.connected && !model.supportsRemoteAudio
            )
            Divider()
            compactToggleRow(
                "本地即时光标",
                detail: model.connected && !model.supportsIndependentCursor ? "旧端不支持独立光标" : nil,
                isOn: $model.lowLatencyCursorEnabled,
                disabled: model.connected && !model.supportsIndependentCursor
            )
            if showsSessionControls {
                Divider()
                compactToggleRow(
                    "相对鼠标 · 3D 视角",
                    detail: model.relativeMouseCaptured ? "已锁定 · 按 ⌃⌥Esc 释放" : nil,
                    isOn: Binding(get: { model.relativeMouseEnabled }, set: model.setRelativeMouseEnabled),
                    disabled: !model.connected || !model.supportsRelativeMouse || !model.effectiveViewerCanControl
                )
            }
            if model.connected {
                Divider()
                HStack {
                    Text("触控板手势")
                        .foregroundStyle(DeskPalette.ink)
                    Spacer()
                    Text(model.supportsTrackpadGestures ? "缩放 / 旋转已就绪" : "旧端不支持")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.secondary)
                }
                .padding(.vertical, 9)
            }

            Text("共享端权限未生效造成的仅观看，不等同于本机防误触锁定。旧端能力不足时明确禁用。")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private var networkAndClipboardBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactToggleRow(
                "双向按需同步",
                isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })
            )
            Divider()
            HStack {
                Text("接收文件目录")
                    .foregroundStyle(DeskPalette.ink)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
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
            .padding(.vertical, 8)

            if model.connected {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("模拟键入")
                            .foregroundStyle(DeskPalette.ink)
                        Spacer(minLength: 8)
                        if model.remoteTypingWorking {
                            Button("停止", role: .destructive) {
                                model.cancelRemoteTypedText()
                            }
                            .buttonStyle(DeskButtonStyle(.danger))
                        } else {
                            Button("输入文字 / 密码…") {
                                model.canvas.releaseControl()
                                showTypeTextSheet = true
                            }
                            .buttonStyle(DeskButtonStyle(.secondary))
                            .disabled(model.remoteTypingUnavailableReason != nil)
                        }
                    }
                    if !model.remoteTypingStatus.isEmpty {
                        Text(model.remoteTypingStatus)
                            .font(.caption)
                            .foregroundStyle(DeskPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
                .sheet(isPresented: $showTypeTextSheet) {
                    RemoteTypeTextSheet(model: model, done: { showTypeTextSheet = false })
                }
            }

            Divider()
            compactToggleRow("全屏顶部工具条", detail: "指针在屏幕顶部中间停留片刻时显示", isOn: $model.fullScreenToolbarEnabled)
            Divider()
            compactToggleRow("全屏实时连接指标", isOn: $model.showFullScreenStatistics)
            if model.showFullScreenStatistics {
                FullScreenStatusSettings(model: model)
                    .padding(.bottom, 8)
            }

            Divider()
            compactToggleRow(
                "断线自动重连",
                isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) })
            )
            Divider()
            compactToggleRow(
                IdleAutoPausePresentation.toggleTitle,
                isOn: Binding(get: { model.disableIdleAutoPause }, set: { model.setDisableIdleAutoPause($0) })
            )
            .help(IdleAutoPausePresentation.toggleHelp)

            Divider()
            compactToggleRow("仅使用 TCP 视频", isOn: $model.mediaTCPOnly)

            if model.relayEnabled {
                Divider()
                if !model.relayNodes.isEmpty {
                    HStack {
                        Text("中继节点")
                            .foregroundStyle(DeskPalette.ink)
                        Spacer()
                        RelayNodePicker(model: model)
                            .frame(maxWidth: 190)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                RelayPeerAssistPicker(model: model)
                    .padding(.vertical, 8)
            }

            Divider()
            compactToggleRow(
                "结束后生成诊断报告",
                isOn: $model.connectionDiagnosticsEnabled,
                disabled: model.isControllingAnotherMac
            )

            Text("TCP 视频仅下次连接生效；复制本身不传文件，粘贴按需拉取。")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if !model.lastDisconnect.isEmpty {
                Text("上次断开：\(model.lastDisconnect)")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
    }

    private func compactToggleRow(
        _ title: String,
        detail: String? = nil,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DeskPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.vertical, 8.5)
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
                    .frame(height: 390)
                HStack {
                    Spacer()
                    Button("完成", action: done)
                        .buttonStyle(DeskButtonStyle(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 13))
        .controlSize(.regular)
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 540)
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
    var endSession: (() -> Void)? = nil

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
        presentation.perform(action, releaseControl: {
            if action == .releaseControl { model.releaseControlByChoice() } else { model.canvas.releaseControl() }
        }) {
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
                if let endSession {
                    endSession()
                } else if model.active || model.working || model.reconnecting {
                    model.stop()
                } else if model.isFullScreen {
                    model.toggleFullScreen()
                }
            }
        }
    }
}

private struct FullScreenStatusSettings: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("样式").foregroundStyle(DeskPalette.secondary)
                Spacer()
                Picker("状态样式", selection: $model.fullScreenStatusCompact) {
                    Text("单行胶囊").tag(true)
                    Text("多行详细").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 128)
                .onChange(of: model.fullScreenStatusCompact) { _, _ in
                    model.fullScreenStatusPosition = nil
                }
            }
            HStack {
                Text("背景透明度").foregroundStyle(DeskPalette.secondary)
                Slider(value: Binding(get: { 1 - model.fullScreenStatusEffectiveBackgroundOpacity },
                                      set: { model.fullScreenStatusBackgroundOpacity = 1 - $0 }), in: 0...1, step: 0.05)
                    .accessibilityLabel("连接状态背景透明度")
                Text("\(Int(((1 - model.fullScreenStatusEffectiveBackgroundOpacity) * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("按住浮层可拖动位置")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                Spacer(minLength: 4)
                Button("恢复默认位置") { model.fullScreenStatusPosition = nil }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(model.fullScreenStatusPosition == nil)
            }
        }
        .padding(10)
        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DeskPalette.hairline, lineWidth: 1)
        }
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
            sharpnessFirst: model.supportsMediaTransport ? $model.videoPrefersSharpness : nil,
            localNetworkQuality: model.localNetworkQuality,
            qualityHelp: model.videoQualityHelp, compact: compact)
    }
}

private struct CapsLockStateLabel: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        DeskPillBadge(
            text: !model.capsLockEnabled ? "已关闭" : model.capsLockRunning ? "已就绪" : "尚未就绪",
            tint: !model.capsLockEnabled ? DeskPalette.secondary : model.capsLockRunning ? DeskPalette.emerald : DeskPalette.amber
        )
    }
}

private struct CapsLockDetails: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            forwardingGroup

            if model.connected || model.reconnecting {
                PermissionNextStepView(step: model.remoteKeyboardNextStep, compact: compact, perform: permissionAction)
            }

            if compact {
                DeskSettingsGroup(title: "Caps Lock 按键行为") {
                    behaviorRow("短按 Caps Lock", "切换远端输入法")
                    Divider()
                    behaviorRow("按住 ≥ 0.6 秒后松开", "切换大写锁定")
                    Divider()
                    behaviorRow("远端大写已开启", "短按先解除大写")
                }
            } else {
                capsBehaviorTable
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
                    HStack(spacing: 8) {
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(model.systemShortcutsRunning ? DeskPalette.emerald : DeskPalette.secondary)
                }
                Divider()
                DeskSettingsRow(title: "释放控制 / 退出全屏") {
                    Text("Ctrl+Option+Esc / Ctrl+Cmd+F")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(DeskPalette.secondary)
                }
            }
        }
    }

    private var capsBehaviorTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caps Lock 行为与实际状态")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)

            DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("按键条件").frame(width: 170, alignment: .leading)
                        Text("执行结果").frame(width: 160, alignment: .leading)
                        Text("说明").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(DeskPalette.insetBackground)

                    Divider()
                    behaviorTableRow("短按 Caps Lock", result: "切换远端中英文", note: "切换远端输入法")
                    Divider()
                    behaviorTableRow("按住 ≥ 0.6 秒后松开", result: "切换大写锁定", note: "开启 / 关闭远端大写")
                    Divider()
                    behaviorTableRow("远端大写已开启", result: "短按先解除大写", note: "再次短按才切换中英文")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func behaviorTableRow(_ condition: String, result: String, note: String) -> some View {
        HStack(spacing: 12) {
            Text(condition).frame(width: 170, alignment: .leading)
            Text(result).frame(width: 160, alignment: .leading)
            Text(note)
                .foregroundStyle(DeskPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(minHeight: 40)
    }

    private var permissionsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeskSettingsGroup(title: "本机权限 · 实际生效检测") {
                if model.capsLockEnabled {
                    DeskSettingsRow(title: "本机监听") {
                        Text(model.capsLockRunning ? "已就绪" : "尚未就绪")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.capsLockRunning ? DeskPalette.emerald : DeskPalette.amber)
                    }
                    Divider()
                }
                permissionRow("辅助功能", effective: model.localAccessibility, action: model.requestAccessibility)
                Divider()
                permissionRow("输入监控", effective: model.localInputMonitoring, action: model.requestInputMonitoring)
                Divider()
                DeskSettingsRow(title: "重新检测") {
                    Button("重新检测") { model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) }
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }

            Text("本机授权与被控端授权不能互相代替。系统安全输入开启时暂停快捷键转发。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)

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
            HStack(spacing: 10) {
                Text(effective ? "已生效" : "尚未生效")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(effective ? DeskPalette.emerald : DeskPalette.amber)
                Button("打开系统设置…", action: action)
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
    @FocusState private var secretFocused: Bool

    private var normalizedText: String {
        TypeTextRequest.normalizeLineEndings(text)
    }

    private var overLimit: Bool {
        normalizedText.count > TypeTextRequest.maximumCharacterCount
            || normalizedText.utf8.count > TypeTextRequest.maximumUTF8Bytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(concealed ? "模拟键入文字 / 密码" : "明文多行模拟键入")
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("先在远端点选目标输入框。逐字符模拟键盘，不写入远端剪贴板。")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
            }

            Picker("输入模式", selection: $concealed) {
                Text("隐藏输入（密码 / 令牌）").tag(true)
                Text("明文多行文字").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if concealed {
                SecureField("输入密码、sudo 口令或一次性验证码", text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($secretFocused)
                    .deskInputBox(focused: secretFocused)
                    .onSubmit { submit() }
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 120)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                    )
            }

            Text(concealed
                 ? "切换为明文模式时使用多行文本框。"
                 : "\(normalizedText.count) 字符 · \(normalizedText.utf8.count) 字节；按协议上限校验（最多 \(TypeTextRequest.maximumCharacterCount) 字符 / \(TypeTextRequest.maximumUTF8Bytes) 字节）。")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(overLimit ? DeskPalette.coral : DeskPalette.secondary)

            Toggle("键入完成后自动按回车提交", isOn: $submitReturn)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))

            Text("默认不提交；发送前可取消，键入过程中提供「停止」，取消不自动补发回车。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)

            if let errorMessage = localError ?? model.remoteTypingUnavailableReason {
                DeskCalloutBox(message: errorMessage, symbol: "exclamationmark.circle", tone: .danger)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    text = ""
                    done()
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

                Button("开始模拟键入") {
                    submit()
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedText.isEmpty || overLimit || model.remoteTypingUnavailableReason != nil)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .padding(26)
        .frame(width: 490)
        .deskSurface()
        .onAppear { if concealed { secretFocused = true } }
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
