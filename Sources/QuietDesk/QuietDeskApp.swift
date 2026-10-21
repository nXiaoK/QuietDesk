import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers
import QuietDeskCore

@main
enum QuietDeskEntry {
    @MainActor static func main() {
        if UpdateInstaller.runInstallerIfRequested() { return }
        if HostSessionEffects.runWatchdogIfRequested() { return }
        if SystemQuitHandler.runReopenHelperIfRequested() { return }
        DiagnosticLog.shared.record(.applicationStarted)
        QuietDeskApp.main()
    }
}

struct QuietDeskApp: App {
    @StateObject private var models: DeskModels
    @StateObject private var updates: UpdateController
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let models = DeskModels()
        _models = StateObject(wrappedValue: models)
        let viewer = models.viewer
        let updater = UpdateController(sessionContext: { [weak models] in
            guard let models else { return .init() }
            let viewer = models.viewer, host = models.host, window = models.mainWindow
            return UpdateSessionContext(mainWindowVisible: window?.isVisible == true && window?.isMiniaturized == false,
                applicationActive: NSApp.isActive, isControlling: viewer.connected || viewer.working || viewer.reconnecting,
                isFullScreen: viewer.isFullScreen, hasHostConnection: host.hasIncomingControlConnection,
                isSharing: host.active || host.working, hasActiveConnection: viewer.connected || host.connected,
                autoStartSharing: host.autoStartSharing, hasOtherPrompt: models.updatePromptBlocked)
        }, mainWindow: { [weak models] in models?.mainWindow }, releaseControl: { [weak viewer] in viewer?.canvas.releaseControl() },
            contextChanges: models.changes)
        _updates = StateObject(wrappedValue: updater)
        appDelegate.models = models
        appDelegate.updates = updater
    }

    var body: some Scene {
        Window("QuietDesk", id: "main") {
            DeskRootView(models: models, updates: updates)
                .onAppear {
                    models.initialLaunch(atLogin: appDelegate.launchedAtLogin)
                    updates.start()
                }
        }
        .defaultSize(width: 1080, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                if updates.enabled { Button("检查更新…") { updates.check() } }
            }
            RemoteControlCommands(viewer: models.viewer, host: models.host)
        }
        MenuBarExtra("QuietDesk", systemImage: "display.2") {
            TrayView(models: models, viewer: models.viewer, host: models.host, updates: updates)
        }
    }
}

private struct RemoteControlCommands: Commands {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel

    var body: some Commands {
        CommandMenu("远程控制") {
            Button(viewer.isFullScreen ? "退出全屏" : "进入全屏") { viewer.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Button("释放键盘鼠标") { viewer.canvas.releaseControl() }
                .keyboardShortcut(.escape, modifiers: [.control, .option])
            Button("截取远端画面到剪贴板") { viewer.copyRemoteFrame() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!viewer.connected)
            Button("断开远程连接") { viewer.stop() }.disabled(!viewer.active && !viewer.working)
            Button("停止共享") { host.stop() }.disabled(!host.active && !host.working)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var models: DeskModels?
    weak var updates: UpdateController?
    private(set) var launchedAtLogin = false
    private let quitHandler = SystemQuitHandler()
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        quitHandler.install()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let host = models?.host else { return true }
        return !(host.active || host.working || host.autoStartSharing)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        models?.initialLaunch(atLogin: launchedAtLogin)
        updates?.start()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        for model in models?.all ?? [] {
            model.refreshLoginStatus()
            model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
            model.refreshClipboardFocus()
            model.sessionWindowFocusChanged()
        }
        updates?.tick()
    }
    func applicationDidResignActive(_ notification: Notification) {
        for model in models?.all ?? [] {
            model.refreshClipboardFocus()
            model.sessionWindowFocusChanged()
        }
        updates?.tick()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        models?.prepareShowWindow()
        models?.mainWindow?.deminiaturize(nil)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        updates?.shutdown()
        models?.stopAll()
        DiagnosticLog.shared.record(.applicationStopped)
        DiagnosticLog.shared.flush()
    }
}

/// Shows the selected role; the other role keeps running behind it.
struct DeskRootView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var updates: UpdateController
    var body: some View { DeskView(models: models, model: models.current, updates: updates) }
}

struct DeskView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var model: DeskModel
    @ObservedObject var updates: UpdateController
    @State private var showCapsSettings = false
    @State private var showOptions = false
    @State private var showFullScreenMenu = false
    @State private var showTrafficStatistics = false
    @State private var showSessionEffects = false
    @State private var dismissedClipboardStatus = ""
    @State private var clipboardNoticeRevision: UInt64 = 0

    // Sharing keeps running in the background; only a viewer session pins the window to its role.
    private var roleLocked: Bool { models.viewer.isControllingAnotherMac }
    private var locked: Bool { model.active || model.working }
    private var sessionLayout: Bool { model.mode == .viewer && (model.connected || model.reconnecting) }
    private var immersive: Bool { model.isFullScreen && model.mode == .viewer }
    private var remoteTitle: String { model.remoteName.isEmpty ? model.address : model.remoteName }
    private var showClipboardActivity: Bool {
        !model.clipboardStatus.isEmpty && model.clipboardStatus != dismissedClipboardStatus
            && !model.clipboardStatus.hasPrefix("双向剪贴板已开启")
            && !model.clipboardStatus.hasPrefix("自动剪贴板已关闭")
            && !model.clipboardStatus.hasPrefix("对端版本较旧")
    }

    var body: some View {
        VStack(spacing: 0) {
            if updates.showBanner { UpdateBanner(controller: updates) }
            if model.mode == .host {
                SharingView(model: model, openTraffic: openTrafficStatistics)
            } else if sessionLayout || immersive {
                remoteContent
            } else {
                ConnectionView(model: model, showOptions: $showOptions,
                               openCaps: { model.canvas.releaseControl(); showCapsSettings = true },
                               openTraffic: openTrafficStatistics, openEffects: openSessionEffects)
            }
            if !immersive {
                Divider()
                statusBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowReader(resolved: { models.attachWindow($0) }, fullScreen: { value in models.all.forEach { $0.isFullScreen = value } }).frame(width: 0, height: 0))
        .frame(minWidth: 860, minHeight: 540)
        .ignoresSafeArea(immersive ? .container : [], edges: .all)
        .navigationTitle(sessionLayout ? remoteTitle : "QuietDesk")
        .navigationSubtitle(sessionLayout ? "\(model.reconnecting ? "正在重连" : "已连接") · \(model.address):\(model.port)" : "为两台 Mac 之间的专注工作而做")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("模式", selection: $models.selected) {
                    ForEach(DeskModel.Mode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented).frame(width: 244).disabled(roleLocked)
                .help(roleLocked ? "断开远程连接后可切换" : "连接另一台 Mac，或共享这台 Mac；切换不会停止共享")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if sessionLayout {
                    Button { model.canvas.releaseControl(); model.pushClipboard() } label: { Label("发送文字", systemImage: "doc.badge.arrow.up") }
                        .help("发送本机剪贴板文字").disabled(!model.connected)
                    Button { model.canvas.releaseControl(); model.pullClipboard() } label: { Label("获取文字", systemImage: "arrow.down.doc") }
                        .help("获取远端剪贴板文字").disabled(!model.connected)
                    Button { model.copyRemoteFrame() } label: { Label("截取画面", systemImage: "camera.viewfinder") }
                        .help("把当前远端画面复制到剪贴板（⌃⌘S），防窥遮罩不会出现在截图里").disabled(!model.connected)
                    Button { model.canvas.releaseControl(); showCapsSettings = true } label: { Label("键盘设置", systemImage: "keyboard") }
                        .help("全屏系统快捷键与 Caps Lock 转发设置")
                    Button { model.canvas.releaseControl(); showOptions.toggle() } label: { Label("画质与连接", systemImage: "slider.horizontal.3") }
                        .help("本次会话画质、连接与剪贴板")
                        .popover(isPresented: $showOptions, arrowEdge: .top) {
                            ConnectionSettingsView(model: model, openCaps: { showOptions = false; showCapsSettings = true },
                                                   openTraffic: openTrafficStatistics, openEffects: openSessionEffects)
                        }
                    Button { model.toggleFullScreen() } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .help("进入全屏（⌃⌘F）")
                    Divider()
                    Button("断开") { model.stop() }
                } else if model.mode == .viewer {
                    SharingBadge(host: models.host) { models.selected = .host }.disabled(roleLocked)
                }
            }
        }
        .toolbar(immersive ? .hidden : .visible, for: .windowToolbar)
        .sheet(isPresented: $showCapsSettings) {
            CapsLockSettingsView(model: model, done: { showCapsSettings = false })
        }
        .sheet(isPresented: $showTrafficStatistics) {
            TrafficStatisticsView(model: model, history: model.trafficHistory, done: { showTrafficStatistics = false })
        }
        .sheet(isPresented: $showSessionEffects) {
            SessionEffectsView(model: model, done: { showSessionEffects = false })
        }
        .alert("QuietDesk", isPresented: Binding(get: { model.error != nil },
            set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: immersive) { _, _ in showFullScreenMenu = false; showOptions = false; showCapsSettings = false; showTrafficStatistics = false; showSessionEffects = false }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showCapsSettings = false; showTrafficStatistics = false; showSessionEffects = false
        }
        .onReceive(model.$clipboardStatus) { _ in
            dismissedClipboardStatus = ""
            clipboardNoticeRevision &+= 1
        }
        .task(id: clipboardNoticeRevision) {
            let message = model.clipboardStatus
            guard !message.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            dismissedClipboardStatus = message
        }
        .onChange(of: model.controlling) { _, controlling in if controlling { showFullScreenMenu = false; showOptions = false } }
        .onChange(of: showOptions || showCapsSettings || showTrafficStatistics || showSessionEffects || showFullScreenMenu) { _, presented in
            updates.interfacePromptVisible = presented
        }
        .onDisappear { updates.interfacePromptVisible = false }
    }

    private var remoteContent: some View {
        ZStack {
            Color.black
            CanvasView(canvas: model.canvas)
            if model.connected && model.sessionInputSuspended {
                VStack(spacing: 12) {
                    Image(systemName: model.sessionPauseWorking ? "arrow.triangle.2.circlepath" : "pause.circle")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("空闲暂停")
                        .font(.title3.weight(.semibold))
                    Text(model.sessionPauseStatus.isEmpty ? "10 分钟没有窗口操作，已暂停画面与自动剪贴板。" : model.sessionPauseStatus)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("加密连接保持；已确认的文件传输继续。切回窗口或在窗口操作即可恢复，首次操作不会发送到旧画面。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.sessionPauseWorking { Button("恢复画面") { model.resumeSession() } }
                }
                .padding(22).frame(maxWidth: 400)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            if !model.connected {
                VStack(spacing: 14) {
                    if model.sessionPaused {
                        Image(systemName: "pause.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                    Text(model.sessionPaused ? "空闲暂停，等待返回窗口" : model.reconnecting ? "连接中断，正在自动重连…" : "尚未连接").font(.title3.weight(.semibold))
                    Text(model.reconnecting ? model.status : "退出全屏后输入地址和配对码")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.reconnecting {
                        Text("重连期间不发送键盘鼠标").font(.caption).foregroundStyle(.secondary)
                        Button("停止重连") { model.stop() }
                    } else {
                        Button("返回连接") { model.toggleFullScreen() }
                    }
                }
                .padding(24).frame(maxWidth: 420)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.controlling && !immersive { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
        }
        .overlay {
            if immersive && model.showFullScreenStatistics {
                GeometryReader { geometry in fullScreenStatus(in: geometry.size) }.allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showClipboardActivity {
                clipboardActivity.padding(.top, 16).padding(.trailing, immersive ? 76 : 16)
            }
        }
        .overlay(alignment: .trailing) {
            if immersive {
                HStack(spacing: 16) {
                    if showFullScreenMenu {
                        FullScreenSettingsView(model: model, close: { showFullScreenMenu = false },
                                               openTraffic: openTrafficStatistics, openEffects: openSessionEffects)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    }
                    Button {
                        model.canvas.releaseControl()
                        showFullScreenMenu.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                            .foregroundStyle(showFullScreenMenu ? Color.white : Color.primary)
                            .background {
                                if showFullScreenMenu { Circle().fill(Color.accentColor) }
                                else { Circle().fill(.regularMaterial) }
                            }
                            .overlay(Circle().stroke(.white.opacity(0.2)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(showFullScreenMenu ? "收起控制与设置" : "展开控制与设置")
                    .accessibilityLabel(showFullScreenMenu ? "收起控制与设置" : "展开控制与设置")
                }
                .padding(.trailing, 16)
            }
        }
    }

    /// Puts the status in a black band outside the remote picture when one is large enough, so it covers
    /// nothing on the remote screen; otherwise it stays over the picture, small and translucent.
    @ViewBuilder private func fullScreenStatus(in size: CGSize) -> some View {
        let picture = model.activeVideoState.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let indicator = Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 6, height: 6)
        switch FullScreenStatusPlacement.choose(container: size, picture: picture) {
        case .topBand(let height):
            HStack(spacing: 10) { indicator; metrics }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                .padding(.horizontal, 16).frame(height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .leadingBand(let width):
            VStack(alignment: .leading, spacing: 6) { indicator; metrics }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).minimumScaleFactor(0.85)
                .padding(.horizontal, 12).padding(.top, 16).frame(width: width, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .overlay:
            HStack(spacing: 8) { indicator; metrics }
                .font(.caption2).monospacedDigit().foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.35), in: Capsule())
                .opacity(0.6).padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func openTrafficStatistics() {
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        showTrafficStatistics = true
    }

    private func openSessionEffects() {
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        showSessionEffects = true
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.mode == .host {
                Circle().fill(model.active ? .green : model.working ? .orange : .secondary).frame(width: 6, height: 6)
                Text(model.status).lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 8)
                if !model.resolution.isEmpty { Text(model.resolution) }
                Text(model.frameRate)
                Text(model.traffic)
            } else if sessionLayout {
                Label(controlStatus, systemImage: model.controlling ? "cursorarrow.rays" : "cursorarrow")
                    .foregroundStyle(model.controlling ? Color.accentColor : Color.secondary).lineLimit(1)
                    .help(model.status)
                Spacer(minLength: 8)
                Label(model.canvas.synchronizesClipboard ? "双向同步" : "同步未启用", systemImage: "arrow.triangle.2.circlepath")
                    .help(model.clipboardStatus.isEmpty ? "文字和图片按控制端焦点同步；文件需逐次确认，接收完成后再粘贴。" : model.clipboardStatus)
                Label(model.capsLockEnabled ? (model.capsLockRunning ? "Caps Lock 转发" : "Caps Lock 待生效") : "Caps Lock 关闭", systemImage: "capslock")
                    .help(model.inputStatus.isEmpty ? "短按切换中英文；按住至少 0.6 秒后松开切换大写。仅在远程画面获得焦点时捕获。" : model.inputStatus)
                if model.pendingFileOffer != nil {
                    Image(systemName: "doc.on.doc").foregroundStyle(.orange).help("1 个文件请求待确认")
                }
                metrics
            } else {
                Circle().fill(locked ? .orange : .secondary).frame(width: 6, height: 6)
                Text(locked ? model.status : model.connectionFailure == nil ? "未连接" : "连接失败").lineLimit(1)
                Spacer(minLength: 8)
                Text("连接后：⌃⌥Esc 释放键盘鼠标 · ⌃⌘F 全屏 · Esc 发送到远端")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var controlStatus: String {
        if model.sessionPaused && model.reconnecting { return "空闲暂停 · 返回窗口后继续连接" }
        if model.sessionInputSuspended { return "画面暂停或恢复中 · 暂不发送键盘鼠标" }
        if model.reconnecting { return "自动重连中 · 键盘鼠标暂不发送" }
        if !model.canControl { return "仅观看 · 共享端辅助功能未生效" }
        return model.controlling ? "正在控制远端 · ⌃⌥Esc 释放键盘鼠标" : "已释放 · 点按画面开始控制"
    }

    @ViewBuilder private var metrics: some View {
        if model.connected {
            if let since = model.connectedSince {
                Text("已连接 \(Text(since, style: .timer))").help("本次连接已持续的时间；断线自动重连后重新计时")
            }
            if !model.resolution.isEmpty { Text(model.resolution) }
            if !model.videoQualitySummary.isEmpty { Text(model.videoQualitySummary).help(model.videoQualityHelp) }
            Text(model.mediaTransportStatus)
            if !model.mediaLoss.isEmpty {
                Text(model.mediaLoss).help("约 5 秒内 UDP 视频分片未按时到达（需补传或最终缺失）的比例；TCP 视频由系统重传，不显示")
            }
            Text(model.latency).help("控制通道往返延迟（RTT），约每 5 秒更新；不代表画面上屏延迟")
            Text(model.frameRate).help("解码完成 FPS；静止画面不重复编码，0 fps 正常")
            Text(model.traffic).help("视频、控制和剪贴板的收发流量")
        } else { Text(model.sessionPaused ? "空闲暂停" : model.reconnecting ? "正在重连" : "未连接") }
    }

    private var clipboardActivity: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.pendingFileOffer == nil ? "arrow.triangle.2.circlepath" : "doc.on.doc")
                .foregroundStyle(model.pendingFileOffer == nil ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.pendingFileOffer == nil ? "剪贴板与文件" : "1 个文件请求待确认").font(.headline)
                Text(model.clipboardStatus).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if model.clipboardStatus.contains("接收完成") {
                    Button("打开接收文件目录") { model.openReceivedFiles() }.controlSize(.small)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { dismissedClipboardStatus = model.clipboardStatus } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("收起状态提示")
        }
        .padding(14).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}

/// The sharing state seen from the viewer's toolbar; sharing continues while this Mac connects elsewhere.
private struct SharingBadge: View {
    @ObservedObject var host: DeskModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Circle().fill(host.connected ? Color.orange : host.active ? Color.green : host.working ? Color.orange : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(host.connected ? "正在被控制" : host.active ? "共享已开启" : host.working ? "正在准备共享" : "共享已停止").font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(host.active ? "共享在后台保持开启；连接其他 Mac 期间暂不接受控制连接。点按打开「共享这台 Mac」" : "打开「共享这台 Mac」")
    }
}

private struct TrayView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var exportingLogs = false
    var body: some View {
        Text("共享：" + (host.active || host.working ? host.status : "未开启"))
        if viewer.isControllingAnotherMac { Text("远程连接：" + viewer.status) }
        Button("打开主窗口") {
            models.prepareShowWindow()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            models.mainWindow?.deminiaturize(nil)
            models.mainWindow?.makeKeyAndOrderFront(nil)
        }
        Button(host.active || host.working ? "停止共享" : "开启共享") {
            if host.active || host.working { host.stop() } else { host.startHosting() }
        }
        if viewer.isControllingAnotherMac { Button("断开远程连接") { viewer.stop() } }
        Divider()
        if updates.enabled {
            Button(updates.menuTitle) { updates.check() }
            Toggle("自动检查更新", isOn: Binding(get: { updates.autoCheckPreference == true },
                set: { updates.setAutomaticChecks($0) }))
            Divider()
        }
        Toggle("性能诊断", isOn: Binding(get: { viewer.performanceDiagnosticsEnabled },
            set: { models.setPerformanceDiagnosticsEnabled($0) }))
            .help("记录视频与传输耗时，导出诊断日志后发送两端日志")
        Button(exportingLogs ? "正在导出日志…" : "导出诊断日志…") { exportLogs() }
            .disabled(exportingLogs)
        Divider()
        Button("退出 QuietDesk") { NSApp.terminate(nil) }
    }

    private func exportLogs() {
        viewer.canvas.releaseControl()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 QuietDesk 诊断日志"
        panel.message = "导出最近的运行日志，方便排查连接、画质和剪贴板问题。日志不包含配对码或剪贴板内容。"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "QuietDesk-logs-\(date.string(from: Date())).txt"
        exportingLogs = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { exportingLogs = false; return }
            Task { @MainActor in
                defer { exportingLogs = false }
                do {
                    models.flushPerformanceDiagnostics()
                    try await DiagnosticLog.shared.export(to: destination)
                    DiagnosticLog.shared.record(.exportCompleted)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    DiagnosticLog.shared.record(.exportFailed, state: .failed, error: error)
                    let alert = NSAlert()
                    alert.messageText = "诊断日志未导出"
                    alert.informativeText = (error as? DiagnosticLog.Failure)?.localizedDescription
                        ?? "日志导出失败，请更换保存位置并检查可用空间和文件访问权限。"
                    alert.addButton(withTitle: "知道了")
                    alert.runModal()
                }
            }
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let resolved: (NSWindow) -> Void
    let fullScreen: (Bool) -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.resolved = resolved; view.fullScreen = fullScreen; return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.resolved = resolved; view.fullScreen = fullScreen }
    final class Probe: NSView {
        var resolved: ((NSWindow) -> Void)?
        var fullScreen: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { return }
            window.minSize = NSSize(width: 860, height: 640)
            resolved?(window)
            fullScreen?(window.styleMask.contains(.fullScreen))
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fullScreen?(self?.window?.styleMask.contains(.fullScreen) == true) }
                })
            }
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
