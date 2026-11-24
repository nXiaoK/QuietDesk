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
        let updater = UpdateController(sessionContext: { [weak models] in
            guard let models else { return .init() }
            let viewer = models.viewer, host = models.host, window = models.mainWindow
            return UpdateSessionContext(
                mainWindowVisible: window?.isVisible == true && window?.isMiniaturized == false,
                applicationActive: NSApp.isActive,
                isControlling: models.hasActiveViewerSession || viewer.isRunningRouteBenchmark,
                isFullScreen: models.anyViewerFullScreen,
                hasHostConnection: host.hasIncomingControlConnection,
                isSharing: host.active || host.working || host.mappingHosting,
                isHostDesktopSharing: host.active || host.working,
                isMappingHosting: host.mappingHosting,
                hasActiveConnection: models.hasConnectedViewerSession || host.connected || viewer.portMappings.hasRunningMappings || host.portMappings.hasIncomingMappings,
                autoStartSharing: host.autoStartSharing,
                hasOtherPrompt: models.updatePromptBlocked
            )
        }, mainWindow: { [weak models] in models?.preferredAlertWindow }, releaseControl: { [weak models] in models?.releaseAllViewerControls() },
            contextChanges: models.changes)
        updater.onRestoreLaunchOptions = { [weak models] options in
            guard let models else { return }
            if options.minimizeWindowOnLaunch {
                models.minimizeForBackgroundLaunch()
            }
            if options.resumeHostSharing && !models.host.active && !models.host.working {
                models.host.startHosting(interactive: false)
            }
            if options.resumeMappingHosting && !models.host.mappingHosting {
                models.host.setMappingHosting(true)
            }
        }
        _updates = StateObject(wrappedValue: updater)
        appDelegate.models = models
        appDelegate.updates = updater
        models.onConnectionDiagnosticReport = { [weak appDelegate] report in
            appDelegate?.showConnectionReport(report)
        }
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
                if updates.enabled {
                    Button("检查更新…") { updates.check() }
                    Toggle("非远程控制时自动更新", isOn: Binding(
                        get: { updates.autoInstallPreference },
                        set: { updates.setAutomaticInstall($0) }
                    ))
                }
            }
            RemoteControlCommands(models: models, host: models.host)
        }
        WindowGroup("远程桌面", id: "remote-session", for: UUID.self) { $sessionID in
            RemoteSessionSceneView(models: models, updates: updates, sessionID: sessionID)
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        MenuBarExtra("QuietDesk", systemImage: "display.2") {
            TrayView(models: models, viewer: models.viewer, host: models.host, updates: updates)
        }
    }
}

private struct FocusedViewerSessionKey: FocusedValueKey {
    typealias Value = DeskModel
}

private extension FocusedValues {
    var viewerSession: DeskModel? {
        get { self[FocusedViewerSessionKey.self] }
        set { self[FocusedViewerSessionKey.self] = newValue }
    }
}

private struct RemoteSessionSceneView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var updates: UpdateController
    let sessionID: UUID?

    var body: some View {
        if let sessionID, let session = models.session(for: sessionID) {
            DeskView(models: models, model: session, updates: updates, isDedicatedSessionWindow: true)
        } else {
            StaleSessionWindowCloser()
        }
    }
}

private struct StaleSessionWindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> CloserView { CloserView() }
    func updateNSView(_ nsView: CloserView, context: Context) {}
    final class CloserView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            DispatchQueue.main.async { [weak window] in window?.close() }
        }
    }
}

private struct RemoteControlCommands: Commands {
    @ObservedObject var models: DeskModels
    @ObservedObject var host: DeskModel
    @FocusedValue(\.viewerSession) private var focusedSession

    private var activeViewer: DeskModel {
        focusedSession ?? models.preferredCommandViewer
    }

    var body: some Commands {
        CommandMenu("远程控制") {
            Button(activeViewer.isFullScreen ? "退出全屏" : "进入全屏") { activeViewer.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Button("释放键盘鼠标") {
                activeViewer.cancelRemoteTypedText()
                activeViewer.canvas.releaseControl()
            }
                .keyboardShortcut(.escape, modifiers: [.control, .option])
            Toggle("仅观看防误触（锁定键鼠发送）", isOn: Binding(
                get: { activeViewer.viewerViewOnlyLock },
                set: { activeViewer.setViewerViewOnlyLock($0) }
            ))
            Button("模拟键入本机剪贴板文字") { activeViewer.typeLocalClipboardText() }
                .disabled(activeViewer.remoteTypingUnavailableReason != nil)
            if activeViewer.remoteTypingWorking {
                Button("停止模拟键入") { activeViewer.cancelRemoteTypedText() }
            }
            Button("截取远端画面到剪贴板") { activeViewer.copyRemoteFrame() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!activeViewer.connected)
            Button("断开远程连接") {
                if activeViewer !== models.viewer {
                    models.disconnectViewerSession(activeViewer)
                } else {
                    activeViewer.stop()
                }
            }
            .disabled(!activeViewer.active && !activeViewer.working && !activeViewer.reconnecting)
            if models.viewerSessions.count > 1 {
                Button("断开全部远程连接（\(models.viewerSessions.count)）") {
                    models.disconnectAllViewerSessions()
                }
            }
            Divider()
            Button("断开控制端") { host.disconnectController() }.disabled(!host.hasIncomingControlConnection)
            Button("停止共享") { host.stop() }.disabled(!host.active && !host.working)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var models: DeskModels?
    weak var updates: UpdateController?
    private(set) var launchedAtLogin = false
    private let quitHandler = SystemQuitHandler()
    private var reportWindows = Set<NSWindow>()

    func showConnectionReport(_ report: ConnectionDiagnosticReport) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ConnectionDiagnosticReportView(report: report)))
        window.title = "连接诊断 · " + report.remoteName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 800, height: 720))
        window.contentMinSize = NSSize(width: 620, height: 440)
        if let previous = reportWindows.first(where: { $0.isVisible }) {
            window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
        } else { window.center() }
        window.delegate = self
        reportWindows.insert(window)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { reportWindows.remove(window) }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        quitHandler.install()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let models else { return true }
        let host = models.host
        return !(models.hasActiveViewerSession || host.active || host.working || host.autoStartSharing || host.mappingHosting || host.portMappings.hasRunningMappings)
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
            model.sessionAttentionChanged()
        }
        updates?.tick()
    }
    func applicationDidResignActive(_ notification: Notification) {
        for model in models?.all ?? [] {
            model.refreshClipboardFocus()
            model.sessionAttentionChanged()
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
        models?.onConnectionDiagnosticReport = nil
        models?.stopAll()
        DiagnosticLog.shared.record(.applicationStopped)
        DiagnosticLog.shared.flush()
    }
}

/// Shows the selected role in the main workspace hub; remote sessions run in independent windows.
struct DeskRootView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DeskView(models: models, model: models.current, updates: updates)
            .onAppear {
                let open = openWindow
                models.openSessionWindow = { id in
                    open(id: "remote-session", value: id)
                }
            }
    }
}

struct DeskView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var model: DeskModel
    @ObservedObject var updates: UpdateController
    var isDedicatedSessionWindow: Bool = false
    @State private var showCapsSettings = false
    @State private var showOptions = false
    @State private var showFullScreenMenu = false
    @State private var hoveringFullScreenTrigger = false
    @State private var showTrafficStatistics = false
    @State private var showSessionEffects = false
    @State private var showPortMapping = false
    @State private var showTypeTextSheet = false
    @State private var routeBenchmarkRunner: RouteQualityBenchmarkRunner?
    @State private var networkSubTab: NetworkWorkspaceSubTab = .viewerMappings
    @State private var diagnosticsSubTab: DiagnosticsWorkspaceSubTab = .benchmark
    @State private var preferencesSubTab: PreferencesWorkspaceSubTab = .keyboard
    @State private var preferredMappingDeviceID: UUID?
    @State private var inlineBenchmarkRecord: ConnectionRecord?
    @State private var workspaceDeviceID: UUID?
    @State private var workspaceDeviceListInitialized = false
    @State private var showNewConnection = false
    @State private var dismissedClipboardStatus = ""
    @State private var dismissedReceptionID: UUID?
    @State private var clipboardNoticeRevision: UInt64 = 0

    // Sharing and remote session windows run independently; only an active inline benchmark locks the hub.
    private var roleLocked: Bool { !isDedicatedSessionWindow && (routeBenchmarkRunner != nil || models.viewer.isRunningRouteBenchmark) }
    private var viewerHasSession: Bool {
        !models.viewer.isRunningRouteBenchmark && (models.viewer.connected || models.viewer.reconnecting)
    }
    private var sessionLayout: Bool { isDedicatedSessionWindow || (model.mode == .viewer && viewerHasSession) }
    private var immersive: Bool { model.isFullScreen && model.mode == .viewer }
    private var remoteTitle: String { model.sessionWindowTitle }
    private var remoteSubtitle: String {
        let phase = model.connected ? "已连接" : model.reconnecting ? "正在重连" : model.working ? "正在连接" : "未连接"
        return "\(phase) · \(model.sessionEndpointSubtitle)"
    }
    private var showClipboardActivity: Bool { model.fileTransferNotice != nil || showClipboardStatus }
    private var showKeptFilesFallback: Bool { model.receivedFilesKeptInFolder && model.fileTransferNotice == nil }
    private var showClipboardStatus: Bool {
        Self.showsClipboardActivity(status: model.clipboardStatus, dismissedStatus: dismissedClipboardStatus,
                                    receivingFileID: model.receivingFileID, dismissedReceptionID: dismissedReceptionID,
                                    keptInFolder: showKeptFilesFallback)
    }

    /// 接收进度约每 0.5 秒更新状态；按 × 收起的是这次接收，结束后的结果仍会显示。
    static func showsClipboardActivity(status: String, dismissedStatus: String, receivingFileID: UUID?,
                                       dismissedReceptionID: UUID?, keptInFolder: Bool) -> Bool {
        if keptInFolder { return true }
        if let receivingFileID, receivingFileID == dismissedReceptionID { return false }
        return !status.isEmpty && status != dismissedStatus
            && !status.hasPrefix("双向剪贴板已开启")
            && !status.hasPrefix("自动剪贴板已关闭")
            && !status.hasPrefix("对端版本较旧")
    }

    var body: some View {
        Group {
            if sessionLayout || immersive {
                VStack(spacing: 0) {
                    if updates.showBanner && !immersive { UpdateBanner(controller: updates) }
                    remoteContent
                    if !immersive {
                        Divider()
                        statusBar
                    }
                }
            } else {
                workspaceShell
            }
        }
        .background(DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .background(
            WindowReader(
                sessionChrome: sessionLayout && !immersive,
                restorable: !isDedicatedSessionWindow,
                resolved: { window in
                    if isDedicatedSessionWindow {
                        model.attachWindow(window)
                    } else {
                        models.attachWindow(window)
                    }
                },
                fullScreen: { value in
                    if isDedicatedSessionWindow {
                        model.isFullScreen = value
                    } else {
                        models.viewer.isFullScreen = value
                        models.host.isFullScreen = value
                    }
                },
                willClose: isDedicatedSessionWindow ? {
                    models.windowDidCloseForSession(id: model.sessionID)
                } : nil
            )
            .frame(width: 0, height: 0)
        )
        .focusedSceneValue(\.viewerSession, isDedicatedSessionWindow ? model : nil)
        .frame(minWidth: 880, minHeight: 580)
        .ignoresSafeArea(immersive ? .container : (!sessionLayout ? .container : []), edges: immersive ? .all : .top)
        .navigationTitle(sessionLayout ? remoteTitle : "QuietDesk")
        .navigationSubtitle(sessionLayout ? remoteSubtitle : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if sessionLayout {
                    // Group 1: Remote Screen & Audio
                    if model.supportsDisplaySwitching, model.remoteDisplays.count > 1 {
                        Menu {
                            ForEach(model.remoteDisplays) { display in
                                Button {
                                    model.canvas.releaseControl()
                                    model.selectRemoteDisplay(display.id)
                                } label: {
                                    if display.id == model.remoteSelectedDisplayID {
                                        Label(display.summary, systemImage: "checkmark")
                                    } else {
                                        Text(display.summary)
                                    }
                                }
                                .disabled(display.id == model.remoteSelectedDisplayID || model.displaySwitchWorking)
                            }
                        } label: {
                            Label("切换屏幕", systemImage: "display.2")
                        }
                        .help("在远端多台显示器之间无缝切换")
                        .disabled(!model.connected || model.displaySwitchWorking)
                    }
                    if model.supportsLiveSettings {
                        sessionQualityMenu
                    }
                    if model.supportsRemoteAudio {
                        Button {
                            model.canvas.releaseControl()
                            model.setRemoteAudioEnabled(!model.remoteAudioEnabled)
                        } label: {
                            Label(model.remoteAudioEnabled ? "关闭远端声音" : "开启远端声音",
                                  systemImage: model.remoteAudioStreaming ? "speaker.wave.2.fill"
                                      : (model.remoteAudioEnabled ? "speaker.wave.1" : "speaker.slash"))
                        }
                        .help(model.remoteAudioStatus.isEmpty ? "切换远端系统声音回传" : model.remoteAudioStatus)
                        .disabled(!model.connected)
                    }

                    // Group 2: Spaces & Input Mode Menu
                    Menu {
                        Button {
                            model.sendDesktopAction(.previousSpace)
                        } label: {
                            Label(RemoteDesktopAction.previousSpace.title, systemImage: RemoteDesktopAction.previousSpace.toolbarSymbol)
                        }
                        .disabled(model.desktopActionUnavailableReason != nil)

                        Button {
                            model.sendDesktopAction(.missionControl)
                        } label: {
                            Label(RemoteDesktopAction.missionControl.title, systemImage: RemoteDesktopAction.missionControl.toolbarSymbol)
                        }
                        .disabled(model.desktopActionUnavailableReason != nil)

                        Button {
                            model.sendDesktopAction(.nextSpace)
                        } label: {
                            Label(RemoteDesktopAction.nextSpace.title, systemImage: RemoteDesktopAction.nextSpace.toolbarSymbol)
                        }
                        .disabled(model.desktopActionUnavailableReason != nil)

                        Divider()

                        Button {
                            model.setViewerViewOnlyLock(!model.viewerViewOnlyLock)
                        } label: {
                            Label(
                                model.viewerViewOnlyLock ? "关闭仅观看防误触（恢复键鼠控制）" : "开启仅观看防误触（锁定键鼠发送）",
                                systemImage: model.viewerViewOnlyLock ? "hand.raised.fill" : "hand.raised"
                            )
                        }

                        if model.supportsRelativeMouse {
                            Button {
                                model.canvas.releaseControl()
                                model.setRelativeMouseEnabled(!model.relativeMouseEnabled)
                            } label: {
                                Label(
                                    model.relativeMouseEnabled ? "关闭相对鼠标视角锁定" : "开启相对鼠标（3D 视角锁定）",
                                    systemImage: model.relativeMouseCaptured ? "scope" : "cursorarrow.motionlines"
                                )
                            }
                            .disabled(!model.connected || !model.effectiveViewerCanControl)
                        }

                        Button {
                            model.canvas.releaseControl()
                            showCapsSettings = true
                        } label: {
                            Label(SessionToolAction.keyboard.title(), systemImage: SessionToolAction.keyboard.symbol())
                        }
                    } label: {
                        Label(
                            model.relativeMouseCaptured ? "视角已锁" : "空间与输入",
                            systemImage: model.relativeMouseCaptured ? "scope" : "rectangle.3.group"
                        )
                    }
                    .help(model.desktopActionUnavailableReason ?? "远端调度中心、桌面空间切换、3D 相对鼠标与键盘设置")

                    // Group 3: Clipboard & Frame Capture
                    Menu {
                        Button {
                            model.canvas.releaseControl()
                            model.pushClipboard()
                        } label: {
                            Label(SessionToolAction.sendText.title(), systemImage: SessionToolAction.sendText.symbol())
                        }
                        .disabled(!model.connected)

                        Button {
                            model.canvas.releaseControl()
                            model.pullClipboard()
                        } label: {
                            Label(SessionToolAction.receiveText.title(), systemImage: SessionToolAction.receiveText.symbol())
                        }
                        .disabled(!model.connected)

                        Divider()

                        Button {
                            model.typeLocalClipboardText()
                        } label: {
                            Label("模拟键入本机剪贴板文字", systemImage: "keyboard.badge.ellipsis")
                        }
                        .disabled(model.remoteTypingUnavailableReason != nil)

                        Button {
                            model.canvas.releaseControl()
                            showTypeTextSheet = true
                        } label: {
                            Label("输入文字/密码模拟键入…", systemImage: "ellipsis.rectangle")
                        }
                        .disabled(model.remoteTypingUnavailableReason != nil)

                        if model.remoteTypingWorking {
                            Button(role: .destructive) {
                                model.cancelRemoteTypedText()
                            } label: {
                                Label("停止模拟键入", systemImage: "xmark.circle")
                            }
                        }

                        Divider()

                        Button {
                            model.canvas.releaseControl()
                            model.copyRemoteFrame()
                        } label: {
                            Label("截取远端画面（⌃⌘S）", systemImage: SessionToolAction.captureFrame.symbol())
                        }
                        .disabled(!model.connected)

                        Button {
                            model.canvas.releaseControl()
                            model.openReceivedFiles()
                        } label: {
                            Label("打开接收文件目录", systemImage: "folder")
                        }
                    } label: {
                        Label("剪贴板与截图", systemImage: "doc.on.clipboard")
                    }
                    .help("发送/获取剪贴板文字、截取远端画面（⌃⌘S）与接收文件目录")

                    // Group 4: Unified Session Controls & Settings Popover
                    Button {
                        model.canvas.releaseControl()
                        showOptions.toggle()
                    } label: {
                        Label("会话设置", systemImage: "gearshape")
                    }
                    .help("画质、防窥安全、光标、音频与端口映射；与全屏共用面板")
                    .popover(isPresented: $showOptions, arrowEdge: .top) {
                        SessionControlsView(
                            model: model,
                            close: { showOptions = false },
                            openTraffic: openTrafficStatistics,
                            openEffects: openSessionEffects,
                            openPortMapping: openPortMapping
                        )
                    }

                    // Group 5: Full Screen & Disconnect
                    Button {
                        model.canvas.releaseControl()
                        model.toggleFullScreen()
                    } label: {
                        Label(SessionToolAction.fullScreen.title(), systemImage: SessionToolAction.fullScreen.symbol())
                    }
                    .help(SessionToolAction.fullScreen.help)

                    Divider()

                    Button {
                        if isDedicatedSessionWindow {
                            models.disconnectViewerSession(model)
                        } else {
                            model.stop()
                        }
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                    }
                    .help("断开远程连接")
                }
            }
        }
        .toolbar(immersive ? .hidden : .visible, for: .windowToolbar)
        .onChange(of: viewerHasSession) { _, activeSession in
            if activeSession, models.workspaceSection != .connect {
                models.workspaceSection = .connect
            }
        }
        .sheet(isPresented: $showPortMapping) {
            if model.mode == .host {
                PortMappingHostView(model: model, manager: model.portMappings, done: { showPortMapping = false })
            } else {
                PortMappingView(model: model, manager: model.portMappings, done: { showPortMapping = false })
            }
        }
        .sheet(isPresented: $showCapsSettings) {
            CapsLockSettingsView(model: model, done: { showCapsSettings = false })
        }
        .sheet(isPresented: $showTrafficStatistics) {
            TrafficStatisticsView(model: model, history: model.trafficHistory, done: { showTrafficStatistics = false })
        }
        .sheet(isPresented: $showSessionEffects) {
            SessionEffectsView(model: model, done: { showSessionEffects = false })
        }
        .sheet(isPresented: $showTypeTextSheet) {
            RemoteTypeTextSheet(model: model, done: { showTypeTextSheet = false })
        }
        .sheet(item: $routeBenchmarkRunner) { runner in
            RouteQualityBenchmarkView(
                runner: runner,
                onConnectCandidate: { candidate, record in
                    routeBenchmarkRunner = nil
                    DispatchQueue.main.async {
                        _ = models.connectUsingBenchmarkCandidate(candidate, record: record)
                    }
                },
                onClose: {
                    routeBenchmarkRunner = nil
                }
            )
        }
        .alert("QuietDesk", isPresented: Binding(get: { model.error != nil },
            set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: immersive) { _, _ in
            showFullScreenMenu = false
            showOptions = false
            showCapsSettings = false
            showTrafficStatistics = false
            showSessionEffects = false
            showPortMapping = false
            showTypeTextSheet = false
            showNewConnection = false
            routeBenchmarkRunner?.shutdown()
            routeBenchmarkRunner = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showCapsSettings = false
            showTrafficStatistics = false
            showSessionEffects = false
            showPortMapping = false
            showTypeTextSheet = false
            showNewConnection = false
            routeBenchmarkRunner?.shutdown()
            routeBenchmarkRunner = nil
        }
        .onReceive(model.$clipboardStatus) { _ in
            dismissedClipboardStatus = ""
            clipboardNoticeRevision &+= 1
        }
        .onChange(of: model.receivingFileID) { _, id in
            if id != nil { dismissedClipboardStatus = "" }
            clipboardNoticeRevision &+= 1
        }
        .onChange(of: model.receivedFilesKeptInFolder) { _, kept in
            if kept { dismissedClipboardStatus = "" }
            clipboardNoticeRevision &+= 1
        }
        .task(id: clipboardNoticeRevision) {
            let message = model.clipboardStatus
            guard !message.isEmpty, model.receivingFileID == nil, !showKeptFilesFallback else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard model.receivingFileID == nil, !showKeptFilesFallback else { return }
            dismissedClipboardStatus = message
        }
        .onChange(of: model.controlling) { _, controlling in if controlling { showFullScreenMenu = false; showOptions = false } }
        .onChange(of: showOptions || showCapsSettings || showTrafficStatistics || showSessionEffects || showPortMapping || showTypeTextSheet || showFullScreenMenu || showNewConnection || routeBenchmarkRunner != nil) { _, presented in
            updates.interfacePromptVisible = presented
        }
        .onDisappear { updates.interfacePromptVisible = false }
    }

    private var sessionQualityMenu: some View {
        let activePreset = model.activeVideoState.flatMap { state in
            SessionQualityPreset.allCases.first { preset in
                preset.resolvedSettings(longestEdges: model.viewerLongestEdges,
                                        frameRates: model.viewerFrameRates, bitRates: model.viewerBitRates) == state.settings
                    && (!model.supportsHEVC444Video || preset.prefersTrueColor == (model.activeVideoChroma == .yuv444))
            }
        }
        return Menu {
            ForEach(SessionQualityPreset.allCases, id: \.self) { preset in
                Button {
                    model.canvas.releaseControl()
                    model.chooseViewerPreset(preset)
                } label: {
                    if activePreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
            Divider()
            Button("高级画质设置…") {
                model.canvas.releaseControl()
                showOptions = true
            }
        } label: {
            Text(activePreset?.title ?? "连接画质")
        }
        .disabled(!model.connected)
        .help("当前生效的画质预设，或切换到另一项预设")
    }

    private var remoteContent: some View {
        ZStack {
            if model.connected { Color.black } else { DeskPalette.insetBackground }
            CanvasView(canvas: model.canvas)
                .opacity(model.connected ? 1 : 0)
            if model.connected && model.sessionInputSuspended {
                VStack(spacing: 12) {
                    Image(systemName: model.sessionPauseWorking ? "arrow.triangle.2.circlepath" : "pause.circle")
                        .font(.system(size: 28)).foregroundStyle(DeskPalette.secondary)
                    Text("空闲暂停")
                        .font(.title3.weight(.semibold))
                    Text(model.sessionPauseStatus.isEmpty ? "QuietDesk 窗口离开前台或不可见已满 10 分钟，已暂停画面与自动剪贴板。" : model.sessionPauseStatus)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("加密连接保持；已确认的文件传输继续。窗口在前台且可见时不会暂停；切回窗口或在窗口操作即可恢复，首次操作不会发送到旧画面。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.sessionPauseWorking {
                        Button("恢复画面") { model.resumeSession() }
                            .buttonStyle(DeskButtonStyle(.primary))
                    }
                }
                .padding(24).frame(maxWidth: 400)
                .foregroundStyle(DeskPalette.ink)
                .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DeskPalette.hairline) }
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
            }
            if !model.connected {
                ConnectionRecoveryView(
                    reconnecting: model.reconnecting,
                    paused: model.sessionPaused,
                    wait: model.reconnectWait,
                    status: model.status,
                    now: { SessionClock.now },
                    stop: {
                        if isDedicatedSessionWindow {
                            models.disconnectViewerSession(model)
                        } else {
                            model.stop()
                        }
                    },
                    returnToConnection: {
                        if isDedicatedSessionWindow {
                            models.disconnectViewerSession(model)
                        } else {
                            model.toggleFullScreen()
                        }
                    },
                    connecting: model.working && !model.reconnecting,
                    failure: model.connectionFailure,
                    disconnectedActionTitle: isDedicatedSessionWindow ? "关闭窗口" : "返回连接",
                    retry: (isDedicatedSessionWindow && model.canRetryLastSessionLaunch)
                        ? { model.retryLastSessionLaunch() }
                        : nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.controlling && !immersive { Rectangle().strokeBorder(DeskPalette.accent, lineWidth: 1).allowsHitTesting(false) }
        }
        .overlay {
            if immersive && model.showFullScreenStatistics {
                FullScreenStatusOverlay(
                    position: $model.fullScreenStatusPosition,
                    backgroundOpacity: model.fullScreenStatusBackgroundOpacity,
                    beginDrag: { model.canvas.releaseControl() },
                    capsule: model.fullScreenStatusCompact
                ) {
                    if model.fullScreenStatusCompact {
                        compactFullScreenMetrics
                    } else {
                        fullScreenMetrics
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let notice = model.unlockNotice {
                    sessionNotice(notice, symbol: model.unlockWorking ? "lock" : "lock.open")
                }
                // While 控制与设置 is open, its inline desktop row shows the status; otherwise show a top notice.
                if !(immersive ? showFullScreenMenu : showOptions), let notice = model.desktopActionNotice {
                    sessionNotice(notice, symbol: "exclamationmark.triangle")
                }
                if !(immersive ? showFullScreenMenu : showOptions), let notice = model.remoteTypingNotice {
                    sessionNotice(notice, symbol: model.remoteTypingWorking ? "keyboard.badge.ellipsis" : "keyboard")
                }
            }
            .padding(.top, immersive ? 44 : 16).allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if showClipboardActivity {
                clipboardActivity.padding(.top, 16).padding(.trailing, immersive ? 76 : 16)
            }
        }
        .overlay(alignment: .trailing) {
            if immersive {
                GeometryReader { geometry in
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        if showFullScreenMenu {
                            SessionControlsView(model: model, close: { showFullScreenMenu = false },
                                                openTraffic: openTrafficStatistics, openEffects: openSessionEffects,
                                                openPortMapping: openPortMapping)
                                .frame(height: min(540, max(0, geometry.size.height - 32)))
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.9)
                                }
                                .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
                        }
                        Button {
                            model.canvas.releaseControl()
                            showFullScreenMenu.toggle()
                        } label: {
                            Image(systemName: showFullScreenMenu ? "chevron.right" : "slider.horizontal.3")
                                .font(.system(size: 13.5, weight: .semibold))
                                .frame(width: 26, height: 66)
                                .foregroundStyle(showFullScreenMenu ? Color.white : Color.primary)
                                .background {
                                    if showFullScreenMenu {
                                        Capsule().fill(DeskPalette.actionFill)
                                    } else {
                                        Capsule().fill(DeskPalette.cardBackground)
                                    }
                                }
                                .overlay(Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.8))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(model.controlling && !hoveringFullScreenTrigger && !showFullScreenMenu ? 0.42 : 1.0)
                        .onHover { hoveringFullScreenTrigger = $0 }
                        .animation(.easeOut(duration: 0.16), value: hoveringFullScreenTrigger)
                        .help(showFullScreenMenu ? "收起控制与设置" : "展开控制与设置")
                        .accessibilityLabel(showFullScreenMenu ? "收起控制与设置" : "展开控制与设置")
                    }
                    .padding(.trailing, 8)
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func sessionNotice(_ notice: String, symbol: String) -> some View {
        Label(notice, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DeskPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DeskPalette.hairline) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var workspaceShell: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                DeskWorkspaceSidebar(
                    models: models,
                    viewer: models.viewer,
                    host: models.host,
                    portMappings: models.viewer.portMappings,
                    updates: updates,
                    workspaceDeviceID: $workspaceDeviceID,
                    roleLocked: roleLocked,
                    newConnection: {
                        models.workspaceSection = .connect
                        showNewConnection = true
                    },
                    showNetwork: {
                        guard !roleLocked else { return }
                        if models.viewer.portMappings.hostApprovalPending {
                            networkSubTab = .hostApprovals
                            models.workspaceSection = .network
                        } else if models.workspaceSection != .benchmark {
                            models.workspaceSection = .network
                        }
                    }
                )
                .frame(width: min(248, max(192, geometry.size.width * 0.22)))
                .padding(8)
                .background(models.workspaceSection == .connect ? DeskPalette.cardBackground : DeskPalette.canvasBackground)

                VStack(spacing: 0) {
                    if models.workspaceSection != .connect {
                        Text(models.workspaceSection == .benchmark ? DeskWorkspaceSection.network.title : models.workspaceSection.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DeskPalette.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 37)
                    }
                    if updates.showBanner {
                        UpdateBanner(controller: updates)
                    }
                    workspacePage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if workspaceShowsStatus { statusBar }
                }
                .padding(.top, models.workspaceSection == .connect ? 8 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(models.workspaceSection == .connect ? DeskPalette.cardBackground : DeskPalette.canvasBackground)
        }
        .onChange(of: models.viewer.connections.map(\.id), initial: true) { _, ids in
            if !workspaceDeviceListInitialized {
                workspaceDeviceID = ids.first
                workspaceDeviceListInitialized = true
            } else if let workspaceDeviceID, !ids.contains(workspaceDeviceID) {
                self.workspaceDeviceID = nil
            }
        }
    }

    private var workspaceShowsStatus: Bool {
        (models.workspaceSection == .sharing && (model.active || model.working))
            || models.viewer.working || !models.viewerSessions.isEmpty
    }

    @ViewBuilder
    private var workspacePage: some View {
        switch models.workspaceSection {
        case .connect:
            ConnectionView(
                models: models,
                model: models.viewer,
                showOptions: $showOptions,
                openCaps: {
                    models.viewer.canvas.releaseControl()
                    preferencesSubTab = .keyboard
                    models.workspaceSection = .preferences
                },
                openTraffic: openTrafficStatistics,
                openEffects: openSessionEffects,
                openBenchmark: openRouteBenchmark,
                openRelayWorkspace: {
                    networkSubTab = .relayNodes
                    models.workspaceSection = .network
                },
                openPortMappingWorkspace: { record in
                    preferredMappingDeviceID = record?.id
                    networkSubTab = .viewerMappings
                    models.workspaceSection = .network
                },
                selectedRecord: models.viewer.connections.first { $0.id == workspaceDeviceID },
                showNewConnection: $showNewConnection
            )
        case .sharing:
            SharingView(
                model: models.host,
                openTraffic: openTrafficStatistics,
                openRelayWorkspace: {
                    networkSubTab = .relayNodes
                    models.workspaceSection = .network
                },
                updates: updates
            )
        case .network:
            NetworkWorkspaceView(
                viewer: models.viewer,
                host: models.host,
                portMappings: models.viewer.portMappings,
                subTab: $networkSubTab,
                preferredDeviceID: $preferredMappingDeviceID,
                openBenchmarkForRecord: { record in
                    inlineBenchmarkRecord = record
                    diagnosticsSubTab = .benchmark
                    models.workspaceSection = .benchmark
                },
                openDiagnostics: {
                    diagnosticsSubTab = $0
                    models.workspaceSection = .benchmark
                }
            )
        case .benchmark:
            DiagnosticsWorkspaceView(
                models: models,
                viewer: models.viewer,
                history: models.viewer.trafficHistory,
                subTab: $diagnosticsSubTab,
                benchmarkTargetRecord: $inlineBenchmarkRecord,
                openNetwork: {
                    networkSubTab = $0
                    models.workspaceSection = .network
                }
            )
        case .preferences:
            PreferencesWorkspaceView(
                viewer: models.viewer,
                updates: updates,
                subTab: $preferencesSubTab,
                openBenchmark: {
                    diagnosticsSubTab = .benchmark
                    models.workspaceSection = .benchmark
                },
                openTraffic: {
                    diagnosticsSubTab = .traffic
                    models.workspaceSection = .benchmark
                }
            )
        }
    }

    private func openPortMapping() {
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout || immersive {
            showPortMapping = true
        } else {
            networkSubTab = model.mode == .host ? .hostApprovals : .viewerMappings
            models.workspaceSection = .network
        }
    }

    private func openTrafficStatistics() {
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout || immersive {
            showTrafficStatistics = true
        } else {
            diagnosticsSubTab = .traffic
            models.workspaceSection = .benchmark
        }
    }

    private func openSessionEffects() {
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout || immersive {
            showSessionEffects = true
        } else {
            preferencesSubTab = .privacy
            models.workspaceSection = .preferences
        }
    }

    private func openRouteBenchmark(_ record: ConnectionRecord? = nil) {
        guard !models.viewer.active, !models.viewer.working, routeBenchmarkRunner == nil else { return }
        model.canvas.releaseControl()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout || immersive {
            routeBenchmarkRunner = RouteQualityBenchmarkRunner(model: models.viewer, record: record)
        } else {
            inlineBenchmarkRecord = record
            diagnosticsSubTab = .benchmark
            models.workspaceSection = .benchmark
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if models.workspaceSection == .sharing && !sessionLayout && (model.active || model.working) {
                Circle()
                    .fill(model.active ? DeskPalette.emerald : model.working ? DeskPalette.amber : .secondary)
                    .frame(width: 6.5, height: 6.5)
                Text(model.status).lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 8)
                if !model.resolution.isEmpty { statusPill(model.resolution) }
                statusPill(model.frameRate)
                statusPill(model.traffic)
            } else if sessionLayout {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.controlling ? DeskPalette.emerald : model.reconnecting ? DeskPalette.amber : DeskPalette.muted)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(model.relativeMouseCaptured ? "相对鼠标锁定（⌃⌥Esc 释放）" : controlStatus)
                        .lineLimit(1)
                }
                .fontWeight(model.controlling ? .semibold : .regular)
                .foregroundStyle(model.controlling ? DeskPalette.emerald : DeskPalette.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.status)

                Spacer(minLength: 8)

                if model.pendingFileOffer != nil {
                    Label("1 个文件待确认", systemImage: "doc.on.doc")
                        .foregroundStyle(DeskPalette.amber)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { metrics }
                        .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 10) {
                        Text(model.resolution)
                        Text(model.latency)
                        Text(model.frameRate)
                        SessionMetricsPopover {
                            metrics
                        }
                    }
                }
            } else {
                if models.viewer.working {
                    ProgressView().controlSize(.mini)
                    Text(models.viewer.status).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !models.viewerSessions.isEmpty {
                    Text("\(models.viewerSessions.count) 个会话")
                }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(DeskPalette.muted)
        .padding(.horizontal, sessionLayout ? 16 : 25)
        .frame(height: 30)
        .background(sessionLayout ? DeskPalette.insetBackground : .clear)
        .help(sessionLayout ? "⌃⌥Esc 释放键鼠 · ⌃⌘F 全屏 · ⌃⌘S 远端截图 · Esc 发送到远端" : "")
    }

    private func statusPill(_ value: String) -> some View {
        Text(value)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
    }

    private var shortTransportLabel: String {
        switch model.mediaTransportStatus {
        case "UDP 视频": return "UDP"
        case "TCP 视频": return "TCP"
        case "TCP 兼容模式": return "TCP 兼容"
        case "中继 UDP 视频": return "中继 UDP"
        case "中继 TCP 视频": return "中继 TCP"
        case "中继 TCP 兼容模式": return "中继 TCP 兼容"
        case "直连 UDP 视频（中继打洞）": return "直连 UDP"
        default: return model.mediaTransportStatus
        }
    }

    @ViewBuilder
    private var compactFullScreenMetrics: some View {
        if model.connected {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.controlling ? DeskPalette.emerald : DeskPalette.muted)
                    .frame(width: 6.5, height: 6.5)
                Text(!model.effectiveViewerCanControl ? "仅观看" : (model.controlling ? "控制中" : "已释放"))
            }
            Text("·").foregroundStyle(DeskPalette.muted)
            Text("\(shortTransportLabel) \(model.latency)")
            if !model.mediaLoss.isEmpty {
                if model.mediaLossHigh {
                    Text(model.mediaLoss).foregroundStyle(DeskPalette.coral)
                } else {
                    Text(model.mediaLoss)
                }
            }
            Text("·").foregroundStyle(DeskPalette.muted)
            if !model.activeVideoFormatBadge.isEmpty {
                Text(model.activeVideoFormatBadge)
            }
            Text("\(model.frameRate) · \(model.traffic)")
            if let since = model.connectedSince {
                Text("·").foregroundStyle(DeskPalette.muted)
                Text(since, style: .timer)
            }
        } else {
            Text(model.sessionPaused ? "空闲暂停" : model.reconnecting ? "正在重连…" : "未连接")
                .foregroundStyle(DeskPalette.amber)
        }
    }

    private var controlStatus: String {
        SessionControlPresentation(reconnecting: model.reconnecting, sessionPaused: model.sessionPaused,
            inputSuspended: model.sessionInputSuspended, canControl: model.canControl, controlling: model.controlling,
            localViewOnly: model.viewerViewOnlyLock).title
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
            Text(model.frameRate).help("解码完成 FPS；静止画面细化完成后，0 fps 正常")
            Text(model.traffic).help("视频、控制和剪贴板的收发流量")
        } else { Text(model.sessionPaused ? "空闲暂停" : model.reconnecting ? "正在重连" : "未连接") }
    }

    /// The full-screen status: one value per line, without labels where the unit already says what it is.
    /// The lines take no pointer events (the whole status is a drag handle), so they carry no tooltips.
    @ViewBuilder private var fullScreenMetrics: some View {
        if model.connected {
            if let since = model.connectedSince { Text(since, style: .timer) }
            switch model.mediaTransportStatus {
            case "UDP 视频": Text("UDP")
            case "TCP 视频": Text("TCP")
            case "TCP 兼容模式": Text("TCP 兼容")
            case "中继 UDP 视频": Text("中继 UDP")
            case "中继 TCP 视频": Text("中继 TCP")
            case "中继 TCP 兼容模式": Text("中继 TCP 兼容")
            case "直连 UDP 视频（中继打洞）": Text("直连 UDP")
            default: Text(model.mediaTransportStatus)
            }
            Text(model.frameRate)
            Text(model.traffic)
            if !model.sessionTraffic.isEmpty { Text("累计 " + model.sessionTraffic) }
            Text(model.latency)
            if !model.mediaLoss.isEmpty {
                if model.mediaLossHigh { Text(model.mediaLoss).foregroundStyle(Color.red) } else { Text(model.mediaLoss) }
            }
            if !model.resolution.isEmpty { Text(model.resolution.replacingOccurrences(of: " × ", with: "×")) }
        } else {
            Text(model.sessionPaused ? "空闲暂停" : model.reconnecting ? "正在重连" : "未连接").foregroundStyle(Color.orange)
        }
    }

    private func dismissClipboardStatus() {
        dismissedClipboardStatus = model.clipboardStatus
        dismissedReceptionID = model.receivingFileID
    }

    private func dismissClipboardActivity() {
        dismissClipboardStatus()
        model.dismissReceivedFilesNotice()
    }

    private var clipboardActivity: some View {
        ClipboardActivityView(notice: model.fileTransferNotice,
                              status: showClipboardStatus ? model.clipboardStatus : nil,
                              pendingOffer: model.pendingFileOffer != nil,
                              keptFilesMessage: showKeptFilesFallback ? ClipboardSync.keptFilesNotice : nil,
                              cancelReception: model.receivingFileID.map { id in { model.cancelFileReception(id: id) } },
                              openFolder: { model.canvas.releaseControl(); model.openReceivedFiles() },
                              dismissResult: { model.dismissReceivedFilesNotice() },
                              dismissStatus: {
                                  if model.fileTransferNotice == nil { dismissClipboardActivity() }
                                  else { dismissClipboardStatus() }
                              })
            .padding(16).frame(width: 330)
            .foregroundStyle(DeskPalette.ink)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DeskPalette.hairline) }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    }
}

private struct SessionMetricsPopover<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(DeskButtonStyle(.quiet))
        .accessibilityLabel("会话指标")
        .help("查看全部会话指标")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 7, content: content)
                .font(.system(size: 12))
                .monospacedDigit()
                .textSelection(.enabled)
                .padding(15)
                .foregroundStyle(DeskPalette.ink)
                .background(DeskPalette.cardBackground)
        }
    }
}

private struct DeskWorkspaceSidebar: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel
    @ObservedObject var portMappings: PortMappingManager
    @ObservedObject var updates: UpdateController
    @Binding var workspaceDeviceID: UUID?
    let roleLocked: Bool
    let newConnection: () -> Void
    let showNetwork: () -> Void
    @State private var copiedHostCode = false

    private var sharingStatus: String {
        if host.connected { return "正在被控制" }
        if host.working { return "正在准备共享" }
        if host.active { return "本机共享已开启" }
        if host.mappingHosting { return "独立映射服务已开" }
        return "共享未开启"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("我的设备")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DeskPalette.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: newConnection) {
                    Image(systemName: "plus")
                }
                .buttonStyle(DeskButtonStyle(.quiet))
                .disabled(roleLocked)
                .help("新建连接")
                .accessibilityLabel("新建连接")
            }
            .padding(.leading, 10)
            .padding(.top, 50)
            .padding(.bottom, 6)

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(viewer.connections) { record in
                            deviceRow(record)
                        }
                        Button(action: newConnection) {
                            rowLabel("新建连接", symbol: "plus")
                                .foregroundStyle(DeskPalette.muted)
                        }
                        .buttonStyle(DeskSidebarRowStyle(selected: false))
                        .disabled(roleLocked)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: geometry.size.height)
            }

            VStack(spacing: 3) {
                navigationRow(.connect, selected: models.workspaceSection == .connect && workspaceDeviceID == nil) {
                    workspaceDeviceID = nil
                    models.workspaceSection = .connect
                }
                navigationRow(.sharing) { models.workspaceSection = .sharing }
                navigationRow(.network, selected: models.workspaceSection == .network || models.workspaceSection == .benchmark,
                              accessory: portMappings.hostApprovalPending ? "待确认" : nil, tint: DeskPalette.amber,
                              action: showNetwork)
                navigationRow(.preferences, accessory: updates.manifest != nil || updates.manualReleaseURL != nil ? "有更新" : nil,
                              tint: DeskPalette.accent) {
                    models.workspaceSection = .preferences
                }
            }
            .padding(.top, 8)

            VStack(spacing: 5) {
                Rectangle().fill(DeskPalette.hairline).frame(height: 1)
                sharingMenu
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 11)
        .background(DeskPalette.sidebarBackground, in: RoundedRectangle(cornerRadius: 13))
    }

    private func deviceRow(_ record: ConnectionRecord) -> some View {
        let session = models.existingSession(for: record)
        let selected = models.workspaceSection == .connect && workspaceDeviceID == record.id
        let title = ConnectionEntryPresentation.title(record)
        return Button {
            workspaceDeviceID = record.id
            models.workspaceSection = .connect
        } label: {
            HStack(spacing: 6) {
                rowLabel(title, symbol: ConnectionEntryPresentation.deviceSymbol(record))
                    .foregroundStyle(DeskPalette.ink)
                if let session, session.connected || session.working || session.reconnecting {
                    Circle()
                        .fill(session.connected ? DeskPalette.emerald : DeskPalette.amber)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(DeskSidebarRowStyle(selected: selected))
        .disabled(roleLocked)
        .accessibilityLabel(title)
        .accessibilityValue(session?.activeSessionSummary.statusLabel ?? "未连接")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(session?.activeSessionSummary.statusLabel ?? "查看设备")
    }

    private func navigationRow(
        _ section: DeskWorkspaceSection, selected: Bool? = nil, accessory: String? = nil,
        tint: Color = .secondary, action: @escaping () -> Void
    ) -> some View {
        let isSelected = selected ?? (models.workspaceSection == section)
        return Button(action: action) {
            HStack(alignment: .center, spacing: 5) {
                rowLabel(section.title, symbol: section.symbol)
                if let accessory {
                    Text(accessory)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? DeskPalette.ink : DeskPalette.secondary)
        }
        .buttonStyle(DeskSidebarRowStyle(selected: isSelected))
        .disabled(roleLocked && !isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
                .frame(width: 19)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var sharingMenu: some View {
        Menu {
            Text(sharingStatus + " · " + String(host.hostPort))
            Button(copiedHostCode ? "已复制" : "复制配对码") {
                host.prepareHostCode()
                if host.hostCode.isEmpty {
                    models.workspaceSection = .sharing
                } else {
                    host.copyHostCode()
                    copiedHostCode = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copiedHostCode = false
                    }
                }
            }
            if host.hasIncomingControlConnection {
                Button("断开控制端", role: .destructive) { host.disconnectController() }
            } else {
                Button(host.active || host.working ? "停止共享" : "开启共享") {
                    if host.active || host.working { host.stop() } else { host.startHosting() }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(host.connected || host.working ? DeskPalette.amber : host.active || host.mappingHosting ? DeskPalette.emerald : DeskPalette.muted)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(sharingStatus)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(DeskPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .tint(DeskPalette.muted)
        .help("共享快捷操作")
    }
}

private struct DeskSidebarRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8)
            configuration.label
                .padding(.horizontal, 10)
                .frame(minHeight: 37)
                .background(fill, in: shape)
                .overlay { shape.strokeBorder(isFocused ? DeskPalette.accent : .clear, lineWidth: 2) }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.48)
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            if selected || configuration.isPressed { return DeskPalette.selection }
            return hovered && isEnabled ? DeskPalette.subtleFill : .clear
        }
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
            .onAppear {
                let open = openWindow
                models.openSessionWindow = { id in
                    open(id: "remote-session", value: id)
                }
            }
        if !models.viewerSessions.isEmpty {
            ForEach(models.activeSessionSummaries) { summary in
                Menu("远控 · \(summary.title)（\(summary.connected ? "已连接" : summary.reconnecting ? "重连中" : summary.working ? "连接中" : "未连接")）") {
                    Text(summary.endpointLabel)
                    Button("切到窗口") { models.focusViewerSession(id: summary.id) }
                    Button("断开此连接", role: .destructive) { models.disconnectViewerSession(id: summary.id) }
                }
            }
        } else if viewer.isControllingAnotherMac {
            Text("远程连接：" + viewer.status)
        }
        Button("打开主窗口") {
            models.prepareShowWindow()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            models.mainWindow?.deminiaturize(nil)
            models.mainWindow?.makeKeyAndOrderFront(nil)
        }
        if host.hasIncomingControlConnection { Button("断开控制端") { host.disconnectController() } }
        Button(host.active || host.working ? "停止共享" : "开启共享") {
            if host.active || host.working { host.stop() } else { host.startHosting() }
        }
        Toggle("共享时接通电源阻止空闲睡眠", isOn: $host.preventHostSleepOnExternalPower)
        if models.viewerSessions.count == 1, let only = models.viewerSessions.first {
            Button("断开远程连接（\(only.sessionWindowTitle)）") { models.disconnectViewerSession(only) }
        } else if models.viewerSessions.count > 1 {
            Button("断开全部远程连接（\(models.viewerSessions.count)）") { models.disconnectAllViewerSessions() }
        } else if viewer.isControllingAnotherMac {
            Button("断开远程连接") { viewer.stop() }
        }
        Divider()
        if updates.enabled {
            Button(updates.menuTitle) { updates.check() }
            if updates.autoInstallDeferredBySession {
                Text("自动更新已待命（远控结束后安装）")
            }
            Toggle("自动检查更新", isOn: Binding(get: { updates.autoCheckPreference == true },
                set: { updates.setAutomaticChecks($0) }))
            Toggle("非远程控制时自动更新", isOn: Binding(get: { updates.autoInstallPreference },
                set: { updates.setAutomaticInstall($0) }))
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
    let sessionChrome: Bool
    var restorable: Bool = true
    let resolved: (NSWindow) -> Void
    let fullScreen: (Bool) -> Void
    var willClose: (() -> Void)? = nil
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.sessionChrome = sessionChrome
        view.restorable = restorable
        view.resolved = resolved
        view.fullScreen = fullScreen
        view.willClose = willClose
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.sessionChrome = sessionChrome
        view.restorable = restorable
        view.resolved = resolved
        view.fullScreen = fullScreen
        view.willClose = willClose
        view.applyWindowChrome()
    }
    final class Probe: NSView {
        var sessionChrome = false
        var restorable = true
        var resolved: ((NSWindow) -> Void)?
        var fullScreen: ((Bool) -> Void)?
        var willClose: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        func applyWindowChrome() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if window.isRestorable != restorable { window.isRestorable = restorable }
            if sessionChrome {
                if window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.remove(.fullSizeContentView)
                }
                if window.titleVisibility != .visible { window.titleVisibility = .visible }
                if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
                if window.titlebarSeparatorStyle != .automatic { window.titlebarSeparatorStyle = .automatic }
            } else {
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                if window.titleVisibility != .visible { window.titleVisibility = .visible }
                if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { return }
            window.minSize = NSSize(width: 880, height: 620)
            applyWindowChrome()
            resolved?(window)
            fullScreen?(window.styleMask.contains(.fullScreen))
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.fullScreen?(self?.window?.styleMask.contains(.fullScreen) == true)
                        self?.applyWindowChrome()
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willClose?()
                }
            })
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
