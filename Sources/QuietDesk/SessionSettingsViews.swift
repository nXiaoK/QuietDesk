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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionOptionsSections(model: model, compact: false)
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
            .font(.system(size: 13))
            .toggleStyle(.switch).controlSize(.small)
            .padding(16).frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 340).frame(maxHeight: 560)
    }
}

private struct ConnectionOptionsSections: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionQualitySection(model: model, compact: compact)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("连接").font(.headline)
                if model.connected, model.supportsDisplaySwitching, !model.remoteDisplays.isEmpty {
                    HStack(spacing: 8) {
                        Text("远端屏幕").foregroundStyle(.secondary)
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
                        Text(model.displaySwitchStatus).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Text("画面显示").foregroundStyle(.secondary)
                    Picker("画面显示", selection: $model.canvasScalingMode) {
                        ForEach(RemoteCanvasScalingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Toggle("本地即时光标", isOn: $model.lowLatencyCursorEnabled)
                    .disabled(model.connected && !model.supportsIndependentCursor)
                    .help("减少双光标跟随；远端形状不可用时使用通用指针。")
                if model.connected {
                    Text(model.controlTransportStatus).font(.caption).foregroundStyle(.secondary)
                    Text(model.supportsIndependentCursor ? model.cursorStatus : "对端版本不支持独立光标")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { model.relativeMouseEnabled }, set: { model.setRelativeMouseEnabled($0) })) {
                    Text("相对鼠标（3D 视角锁定）").frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.connected || !model.supportsRelativeMouse || !model.canControl)
                .help("开启后点击远程画面会隐藏并锁定本地光标，按无边界相对位移驱动远端视角或鼠标；按 ⌃⌥Esc 立即释放光标。")
                if model.connected {
                    Text(!model.supportsRelativeMouse ? "对端版本不支持相对鼠标视角锁定"
                         : model.relativeMouseCaptured ? "相对鼠标已锁定 · 按 ⌃⌥Esc 立即释放光标"
                         : model.relativeMouseEnabled ? "相对鼠标待激活 · 点击远程画面锁定光标（按 ⌃⌥Esc 释放）"
                         : "相对鼠标未开启（适合 3D 建模/第一人称视角；会话结束自动重置）")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(model.supportsTrackpadGestures ? "触控板双指缩放/旋转手势透传已就绪" : "对端版本不支持触控板缩放/旋转手势")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: Binding(get: { model.remoteAudioEnabled }, set: { model.setRemoteAudioEnabled($0) })) {
                    Text("远端声音回传").frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.connected && !model.supportsRemoteAudio)
                .help("通过 ScreenCaptureKit 原生采集远端系统声音并以低延迟 Opus 回传；可与“被控端本机静音”同时开启。")
                if model.connected {
                    Text(model.supportsRemoteAudio ? model.remoteAudioStatus : "对端版本不支持远端声音回传")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("仅使用 TCP（下次连接生效）", isOn: $model.mediaTCPOnly)
                Text(model.connected ? model.mediaRouteSummary : (model.mediaTCPOnly ? "视频使用 TCP" : "视频优先 UDP，不可用时自动使用 TCP"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.relayEnabled { RelayPeerAssistPicker(model: model) }
                Toggle(isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) })) { Text("断线自动重连").frame(maxWidth: .infinity, alignment: .leading) }
                Toggle(isOn: Binding(get: { model.disableIdleAutoPause }, set: { model.setDisableIdleAutoPause($0) })) {
                    Text(IdleAutoPausePresentation.toggleTitle).frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(IdleAutoPausePresentation.toggleHelp)
                Text(IdleAutoPausePresentation(
                    disableAutoPause: model.disableIdleAutoPause,
                    connected: model.connected,
                    reconnecting: model.reconnecting,
                    supportsSessionPause: model.supportsSessionPause,
                    sessionPaused: model.sessionPaused,
                    sessionPauseStatus: model.sessionPauseStatus
                ).summary)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("连接诊断", isOn: $model.connectionDiagnosticsEnabled)
                    .disabled(model.isControllingAnotherMac)
                Text("连接前开启，结束后自动显示整段会话的线路、延迟、UDP 丢包、帧率和吞吐量。报告仅在本机内存中保留。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $model.showFullScreenStatistics) { Text("全屏显示连接状态").frame(maxWidth: .infinity, alignment: .leading) }
                if model.showFullScreenStatistics { FullScreenStatusSettings(model: model) }
                Text("每行一项，依次为连接时长、视频线路、解码 FPS、收发流量、本次连接累计流量、往返延迟、UDP 丢包（达到 3% 时为红色）、分辨率。线路名精简显示，白字黑底，默认在右下角；背景透明度可调，可直接拖动状态调整位置。累计流量含视频、控制和剪贴板的收发，断线自动重连后重新累计。往返延迟约每 5 秒更新；不代表画面上屏延迟。静止画面 FPS 可能为 0。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("剪贴板与文件").font(.headline)
                Toggle(isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })) { Text("双向同步文字、图片和文件").frame(maxWidth: .infinity, alignment: .leading) }
                Text("文字和图片仅在按 ⌘V 或右键粘贴时按需同步，复制不占流量；文件需接收端确认后下载，完成后再粘贴。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { model.canvas.releaseControl(); model.openReceivedFiles() } label: {
                    Label("打开接收文件目录", systemImage: "folder")
                }
                .help(ClipboardSync.receivingDirectory)
                if let id = model.receivingFileID {
                    Button("中断接收", role: .destructive) { model.cancelFileReception(id: id) }
                }
            }
            if !model.lastDisconnect.isEmpty {
                Text("上次断开：\(model.lastDisconnect)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled).help(model.lastDisconnect)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

struct CapsLockSettingsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "capslock")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("键盘与快捷键").font(.system(size: 15, weight: .semibold))
                    Text("全屏系统快捷键与 Caps Lock 操作远端。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView { CapsLockDetails(model: model, compact: false) }
                .frame(height: 350)
            HStack {
                Spacer()
                Button("完成", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13)).controlSize(.regular)
        .padding(22).frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.canvas.releaseControl()
            model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
        }
        .onExitCommand(perform: done)
    }
}

struct SessionControlsView: View {
    @ObservedObject var model: DeskModel
    let close: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void

    private var presentation: SessionToolsPresentation {
        SessionToolsPresentation(connected: model.connected, reconnecting: model.reconnecting,
            hasSession: model.active || model.working || model.reconnecting,
            fullScreen: model.isFullScreen, remoteName: model.remoteName, latency: model.latency,
            control: SessionControlPresentation(reconnecting: model.reconnecting, sessionPaused: model.sessionPaused,
                inputSuspended: model.sessionInputSuspended, canControl: model.canControl, controlling: model.controlling),
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("背景透明度")
                Slider(value: Binding(get: { 1 - model.fullScreenStatusEffectiveBackgroundOpacity },
                                      set: { model.fullScreenStatusBackgroundOpacity = 1 - $0 }), in: 0...1, step: 0.05)
                    .accessibilityLabel("连接状态背景透明度")
                Text("\(Int(((1 - model.fullScreenStatusEffectiveBackgroundOpacity) * 100).rounded()))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("直接拖动状态可调整位置").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("恢复自动位置") { model.fullScreenStatusPosition = nil }
                    .buttonStyle(.link).disabled(model.fullScreenStatusPosition == nil)
            }
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
            localNetworkQuality: model.localNetworkQuality,
            qualityHelp: model.videoQualityHelp, compact: compact)
    }
}

private struct CapsLockStateLabel: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        Text(!model.capsLockEnabled ? "已关闭" : (model.capsLockRunning ? "已开启" : "待生效"))
            .font(.system(size: 10))
            .foregroundStyle(!model.capsLockEnabled ? Color.secondary : (model.capsLockRunning ? Color.green : Color.orange))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((!model.capsLockEnabled ? Color.secondary : (model.capsLockRunning ? Color.green : Color.orange)).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct CapsLockDetails: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("全屏系统快捷键").font(.headline)
                Text(model.systemShortcutStatus)
                    .foregroundStyle(model.systemShortcutsRunning ? Color.green : Color.secondary)
                Text("全屏并点按远程画面后，⌘空格、⌘Tab 等组合键转发到远端。⌃⌥Esc 释放控制、⌃⌘F 退出全屏仍在本机执行。需要下方两项本机权限；系统安全输入开启时暂停转发。")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: compact ? 10 : 11))
            .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { model.capsLockEnabled }, set: { model.setCapsLockEnabled($0) })) { Text("启用 Caps Lock 转发").frame(maxWidth: .infinity, alignment: .leading) }
                .toggleStyle(.switch).controlSize(.small)
                .padding(compact ? 9 : 11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            PermissionNextStepView(step: model.remoteKeyboardNextStep, compact: compact, perform: permissionAction)
            VStack(alignment: .leading, spacing: 8) {
                Text("按键行为").font(.headline)
                if compact {
                    VStack(alignment: .leading, spacing: 8) {
                        CapsBehaviorCard(key: "⇪ 短按", title: "切换中英文", detail: "切换远端输入法", compact: true)
                        CapsBehaviorCard(key: "⇪ 按住 ≥ 0.6 秒后松开", title: "切换大写锁定", detail: "开启 / 关闭远端大写", compact: true)
                        CapsBehaviorCard(key: "大写已开启", title: "短按先解除大写", detail: "再次短按才切换中英文", compact: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        CapsBehaviorCard(key: "⇪ Caps Lock · 短按", title: "切换中英文", detail: "切换远端输入法", compact: false)
                        CapsBehaviorCard(key: "按住 ≥ 0.6 秒后松开", title: "切换大写锁定", detail: "开启 / 关闭远端大写", compact: false)
                        CapsBehaviorCard(key: "大写已开启", title: "短按先解除大写", detail: "再次短按才切换中英文", compact: false)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("本机权限").font(.headline)
                    Spacer()
                    Button("重新检测") { model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) }
                        .controlSize(.small)
                }
                VStack(spacing: 0) {
                    CapsPermissionRow(title: "辅助功能", symbol: "accessibility", effective: model.localAccessibility, compact: compact) { model.requestAccessibility() }
                    Divider().padding(.horizontal, 10)
                    CapsPermissionRow(title: "输入监控", symbol: "keyboard.badge.eye", effective: model.localInputMonitoring, compact: compact) { model.requestInputMonitoring() }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Text("当前应用：\(Bundle.main.bundleURL.path)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3).textSelection(.enabled).help(Bundle.main.bundleURL.path)
                PermissionNextStepView(step: .localKeyboard(accessibility: model.localAccessibility,
                    inputMonitoring: model.localInputMonitoring, capsEnabled: model.capsLockEnabled,
                    capsRunning: model.capsLockRunning), compact: compact, perform: permissionAction)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("实际状态").fontWeight(.semibold)
                    CapsLockStateLabel(model: model)
                    if model.capsLockRunning {
                        Text("本机监听已就绪").foregroundStyle(.secondary)
                    }
                }
                if !model.inputStatus.isEmpty {
                    Text(model.inputStatus)
                        .foregroundStyle(model.capsLockEnabled && !model.capsLockRunning ? Color.orange : Color.secondary)
                        .lineLimit(compact ? 3 : nil).textSelection(.enabled).help(model.inputStatus)
                }
            }
            .font(.system(size: compact ? 10 : 11))
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

private struct CapsBehaviorCard: View {
    let key: String
    let title: String
    let detail: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 7) {
            Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
            if compact {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 27 : 76, alignment: .topLeading)
        .padding(compact ? 8 : 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CapsPermissionRow: View {
    let title: String
    let symbol: String
    let effective: Bool
    let compact: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            Label(title, systemImage: symbol).font(.system(size: compact ? 11 : 12))
            Spacer(minLength: 0)
            Text(effective ? "已生效" : "未生效")
                .font(.system(size: 10)).foregroundStyle(effective ? Color.green : Color.orange)
            Button(compact ? "系统设置…" : "打开系统设置…", action: openSettings).controlSize(.small)
        }
        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 7 : 8)
    }
}
