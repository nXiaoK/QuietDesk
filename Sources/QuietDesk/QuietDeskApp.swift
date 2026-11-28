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
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            QuietDeskAboutCommands()
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
        .defaultSize(width: 1220, height: 800)
        .windowToolbarStyle(.unified)
        Window("关于 QuietDesk", id: "about") {
            QuietDeskAboutView(version: updates.currentVersion, build: updates.currentBuild)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("QuietDesk", systemImage: "display.2") {
            TrayView(models: models, viewer: models.viewer, host: models.host, updates: updates)
        }
    }
}

private struct QuietDeskAboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 QuietDesk") { openWindow(id: "about") }
        }
    }
}

private struct QuietDeskAboutView: View {
    let version: String
    let build: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 37, weight: .medium))
                .foregroundStyle(DeskPalette.accent)
                .frame(width: 82, height: 82)
                .background(DeskPalette.selection, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text("QuietDesk")
                .font(.system(size: 29, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("版本 \(version)（\(build)）")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DeskPalette.secondary)
                .textSelection(.enabled)
        }
        .frame(width: 408, height: 242)
        .deskSurface()
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
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window, self?.window === window else { return }
                window.close()
            }
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
            Button("释放控制") {
                activeViewer.cancelRemoteTypedText()
                activeViewer.releaseControlByChoice()
            }
            .keyboardShortcut(.escape, modifiers: [.control, .option])

            Button(activeViewer.isFullScreen ? "退出全屏" : "进入全屏") { activeViewer.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [.control, .command])

            Toggle("仅观看防误触（锁定键鼠发送）", isOn: Binding(
                get: { activeViewer.viewerViewOnlyLock },
                set: { activeViewer.setViewerViewOnlyLock($0) }
            ))

            Divider()

            Button("发送本机剪贴板文字") {
                activeViewer.releaseControlForLocalUI()
                activeViewer.pushClipboard()
                activeViewer.resumeControlAfterLocalUI()
            }
            .disabled(!activeViewer.connected)

            Button("获取远端剪贴板文字") {
                activeViewer.releaseControlForLocalUI()
                activeViewer.pullClipboard()
                activeViewer.resumeControlAfterLocalUI()
            }
            .disabled(!activeViewer.connected)

            Button("模拟键入剪贴板文字") { activeViewer.typeLocalClipboardText() }
                .disabled(activeViewer.remoteTypingUnavailableReason != nil)

            if activeViewer.remoteTypingWorking {
                Button("停止模拟键入") { activeViewer.cancelRemoteTypedText() }
            }

            Button("截取远端画面到剪贴板") { activeViewer.copyRemoteFrame() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!activeViewer.connected)

            Divider()

            Button("断开远程连接") {
                if activeViewer !== models.viewer {
                    models.disconnectViewerSession(id: activeViewer.sessionID)
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
        window.title = "连接诊断报告"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 820, height: 680))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showCapsSettings = false
    @State private var showOptions = false
    @State private var showFullScreenMenu = false
    @StateObject private var fullScreenToolbar = FullScreenToolbarController()
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
    @State private var openDeviceRequest: UUID?
    @State private var recordToRename: ConnectionRecord?
    @State private var sidebarCollapsed = false
    @State private var dismissedClipboardStatus = ""
    @State private var dismissedReceptionID: UUID?
    @State private var clipboardNoticeRevision: UInt64 = 0

    // Sharing and remote session windows run independently; only an active inline benchmark locks the hub.
    private var roleLocked: Bool { !isDedicatedSessionWindow && (routeBenchmarkRunner != nil || models.viewer.isRunningRouteBenchmark) }
    private var viewerHasSession: Bool {
        !models.viewer.isRunningRouteBenchmark && (models.viewer.connected || models.viewer.reconnecting)
    }
    private var sessionLayout: Bool { isDedicatedSessionWindow || (model.mode == .viewer && viewerHasSession) }
    private var immersive: Bool { sessionLayout && model.isFullScreen }
    private var remoteTitle: String { model.sessionWindowTitle }
    private var remoteSubtitle: String {
        let phase: String
        if model.connected {
            phase = !model.effectiveViewerCanControl ? "仅观看" : (model.controlling ? "控制中" : "已连接")
        } else if model.reconnecting {
            phase = "正在重连"
        } else if model.working {
            phase = "正在连接"
        } else {
            phase = "未连接"
        }
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
            if sessionLayout {
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
        .background(immersive ? Color.black : DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .background(
            WindowReader(
                sessionChrome: sessionLayout && !immersive,
                immersiveFullScreen: sessionLayout,
                restorable: !isDedicatedSessionWindow,
                resolved: { window in
                    if isDedicatedSessionWindow {
                        model.attachWindow(window)
                        model.fitSessionWindowToPicture(window)
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
        .frame(minWidth: 700, minHeight: 560)
        .ignoresSafeArea(.all, edges: immersive ? .all : [])
        .navigationTitle(sessionLayout ? remoteTitle : "")
        .navigationSubtitle(sessionLayout ? remoteSubtitle : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if sessionLayout && !immersive {
                    sessionScreenAndSpacesMenu
                    if model.supportsLiveSettings {
                        sessionQualityMenu
                    }
                    if model.supportsRemoteAudio {
                        Button {
                            sessionAction { model.setRemoteAudioEnabled(!model.remoteAudioEnabled) }
                        } label: {
                            Label(model.remoteAudioEnabled ? "关闭远端声音" : "开启远端声音",
                                  systemImage: model.remoteAudioStreaming ? "speaker.wave.2.fill"
                                      : (model.remoteAudioEnabled ? "speaker.wave.1" : "speaker.slash"))
                        }
                        .help(model.remoteAudioStatus.isEmpty ? "切换远端系统声音回传" : model.remoteAudioStatus)
                        .disabled(!model.connected)
                    }

                    sessionClipboardMenu

                    Button {
                        sessionAction { model.toggleFullScreen() }
                    } label: {
                        Label(SessionToolAction.fullScreen.title(), systemImage: SessionToolAction.fullScreen.symbol())
                    }
                    .help(SessionToolAction.fullScreen.help)

                    sessionMoreMenu

                    Button {
                        model.releaseControlForLocalUI()
                        showOptions.toggle()
                    } label: {
                        Label("会话设置", systemImage: "gearshape")
                    }
                    .help("画面与声音、输入与剪贴板、连接及全屏共用控制面板")
                    .popover(isPresented: $showOptions, arrowEdge: .top) {
                        SessionControlsView(
                            model: model,
                            close: { showOptions = false },
                            openTraffic: openTrafficStatistics,
                            openEffects: openSessionEffects,
                            openPortMapping: openPortMapping,
                            endSession: endCurrentSessionAction
                        )
                    }
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
        .sheet(item: $recordToRename) { record in
            DeviceRenameSheet(name: ConnectionEntryPresentation.title(record)) { name in
                try models.viewer.renameConnection(id: record.id, to: name)
            }
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
            recordToRename = nil
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
            recordToRename = nil
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
        .onChange(of: fullScreenToolbarCanvas, initial: true) { _, canvas in
            if canvas != nil { fullScreenToolbar.start(canvas: model.canvas) } else { fullScreenToolbar.stop() }
        }
        .onChange(of: showOptions || showCapsSettings || showTrafficStatistics || showSessionEffects || showPortMapping || showTypeTextSheet || showFullScreenMenu || showNewConnection || recordToRename != nil || routeBenchmarkRunner != nil) { _, presented in
            updates.interfacePromptVisible = presented
            if !presented { model.resumeControlAfterLocalUI() }
        }
        .onDisappear {
            updates.interfacePromptVisible = false
            fullScreenToolbar.stop()
        }
    }

    private var sessionScreenAndSpacesMenu: some View {
        let selectedDisplayTitle: String = {
            if model.supportsDisplaySwitching, !model.remoteDisplays.isEmpty {
                if let index = model.remoteDisplays.firstIndex(where: { $0.id == model.remoteSelectedDisplayID }) {
                    return model.remoteDisplays.count > 1 ? "屏幕 \(index + 1)" : model.remoteDisplays[index].name
                }
            }
            return "屏幕与空间"
        }()

        return Menu {
            if model.supportsDisplaySwitching, !model.remoteDisplays.isEmpty {
                Section("屏幕与远端空间") {
                    ForEach(model.remoteDisplays) { display in
                        Button {
                            sessionAction { model.selectRemoteDisplay(display.id) }
                        } label: {
                            if display.id == model.remoteSelectedDisplayID {
                                Label(display.summary, systemImage: "checkmark")
                            } else {
                                Text(display.summary)
                            }
                        }
                        .disabled(display.id == model.remoteSelectedDisplayID || model.displaySwitchWorking || !model.connected)
                    }
                }
                Divider()
            }

            Button {
                sessionAction { model.sendDesktopAction(.previousSpace) }
            } label: {
                Label(RemoteDesktopAction.previousSpace.title, systemImage: RemoteDesktopAction.previousSpace.toolbarSymbol)
            }
            .disabled(model.desktopActionUnavailableReason != nil)

            Button {
                sessionAction { model.sendDesktopAction(.missionControl) }
            } label: {
                Label("调度中心…", systemImage: RemoteDesktopAction.missionControl.toolbarSymbol)
            }
            .disabled(model.desktopActionUnavailableReason != nil)

            Button {
                sessionAction { model.sendDesktopAction(.nextSpace) }
            } label: {
                Label(RemoteDesktopAction.nextSpace.title, systemImage: RemoteDesktopAction.nextSpace.toolbarSymbol)
            }
            .disabled(model.desktopActionUnavailableReason != nil)
        } label: {
            Label(selectedDisplayTitle, systemImage: "display")
        }
        .help(model.desktopActionUnavailableReason ?? "切换远端显示器、桌面空间与调度中心")
    }

    private var sessionClipboardMenu: some View {
        Menu {
            Section("剪贴板与截图") {
                Button {
                    sessionAction { model.pushClipboard() }
                } label: {
                    Label("发送本机文字", systemImage: SessionToolAction.sendText.symbol())
                }
                .disabled(!model.connected)

                Button {
                    sessionAction { model.pullClipboard() }
                } label: {
                    Label("获取远端文字", systemImage: SessionToolAction.receiveText.symbol())
                }
                .disabled(!model.connected)

                Button {
                    model.typeLocalClipboardText()
                } label: {
                    Label("模拟键入剪贴板", systemImage: "keyboard.badge.ellipsis")
                }
                .disabled(model.remoteTypingUnavailableReason != nil)

                Button {
                    model.releaseControlForLocalUI()
                    showTypeTextSheet = true
                } label: {
                    Label("输入文字 / 密码…", systemImage: "ellipsis.rectangle")
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
                    sessionAction { model.copyRemoteFrame() }
                } label: {
                    Label("截取当前远端画面（⌃⌘S）", systemImage: SessionToolAction.captureFrame.symbol())
                }
                .disabled(!model.connected)

                Button {
                    model.canvas.releaseControl()
                    model.openReceivedFiles()
                } label: {
                    Label("打开接收文件目录", systemImage: "folder")
                }
            }
        } label: {
            Label("剪贴板与截图", systemImage: "doc.on.clipboard")
        }
        .help("发送/获取剪贴板文字、模拟键入、截取远端画面（⌃⌘S）与接收文件目录")
    }

    private var sessionMoreMenu: some View {
        Menu {
            Button {
                model.cancelRemoteTypedText()
                model.releaseControlByChoice()
            } label: {
                Label("释放控制（⌃⌥Esc）", systemImage: "cursorarrow")
            }

            Button {
                model.setViewerViewOnlyLock(!model.viewerViewOnlyLock)
            } label: {
                Label(
                    model.viewerViewOnlyLock ? "关闭仅观看防误触" : "仅观看防误触（锁定键鼠发送）",
                    systemImage: model.viewerViewOnlyLock ? "eye.fill" : "eye"
                )
            }

            if model.supportsRelativeMouse {
                Button {
                    // The pointer is captured by the click on the picture that follows, not by this menu item.
                    model.releaseControlByChoice()
                    model.setRelativeMouseEnabled(!model.relativeMouseEnabled)
                } label: {
                    Label(
                        model.relativeMouseEnabled ? "关闭相对鼠标视角锁定" : "开启相对鼠标 · 3D 视角",
                        systemImage: model.relativeMouseCaptured ? "scope" : "cursorarrow.motionlines"
                    )
                }
                .disabled(!model.connected || !model.effectiveViewerCanControl)
            }

            Divider()

            Button {
                model.releaseControlForLocalUI()
                showCapsSettings = true
            } label: {
                Label("键盘与快捷键…", systemImage: "keyboard")
            }

            Button {
                openSessionEffects()
            } label: {
                Label("被控端隐私与安全…", systemImage: "lock.shield")
            }

            Button {
                openPortMapping()
            } label: {
                Label("TCP 端口映射…", systemImage: "point.3.connected.trianglepath.dotted")
            }

            Button {
                openTrafficStatistics()
            } label: {
                Label("地址历史流量…", systemImage: "chart.bar.xaxis")
            }

            Divider()

            Button(role: .destructive) {
                if isDedicatedSessionWindow {
                    models.disconnectViewerSession(id: model.sessionID)
                } else {
                    model.stop()
                }
            } label: {
                Label("断开远程连接", systemImage: "xmark.circle")
            }
        } label: {
            Label(
                model.relativeMouseCaptured ? "视角已锁" : "更多操作",
                systemImage: model.relativeMouseCaptured ? "scope" : "ellipsis.circle"
            )
        }
        .help("释放控制、防误触、键盘设置、隐私安全、端口映射、流量与断开连接")
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
                    sessionAction { model.chooseViewerPreset(preset) }
                } label: {
                    if activePreset == preset {
                        Label(preset.title, systemImage: "checkmark")
                    } else {
                        Text(preset.title)
                    }
                }
            }
            Divider()
            Button("高级设置…") {
                model.releaseControlForLocalUI()
                // Full screen has no window toolbar to attach the popover to; its panel holds the same settings.
                if immersive { showFullScreenMenu = true } else { showOptions = true }
            }
        } label: {
            Text(activePreset?.title ?? "连接画质")
        }
        .disabled(!model.connected)
        .help("当前生效的画质预设，或切换到另一项预设")
    }

    /// A session toolbar action that finishes at once: remote keys are released for it as before, and the
    /// keyboard returns to the picture afterwards if it had it.
    private func sessionAction(_ action: () -> Void) {
        model.releaseControlForLocalUI()
        action()
        model.resumeControlAfterLocalUI()
    }

    private var fullScreenToolbarBottom: CGFloat { FullScreenToolbarReveal.toolbarTop + FullScreenToolbarReveal.toolbarHeight }
    /// The picture whose top edge brings the full-screen toolbar, while there is one.
    private var fullScreenToolbarCanvas: ObjectIdentifier? {
        immersive && model.fullScreenToolbarEnabled ? ObjectIdentifier(model.canvas) : nil
    }

    private var endCurrentSessionAction: () -> Void {
        {
            if isDedicatedSessionWindow {
                models.disconnectViewerSession(id: model.sessionID)
            } else if model.active || model.working || model.reconnecting {
                model.stop()
            } else if model.isFullScreen {
                model.toggleFullScreen()
            }
        }
    }

    private var remoteContent: some View {
        ZStack {
            if model.connected || immersive { Color.black } else { DeskPalette.insetBackground }
            CanvasView(canvas: model.canvas)
                .opacity(model.connected ? 1 : 0)
            if model.connected && model.sessionInputSuspended {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: model.sessionPauseWorking ? "arrow.triangle.2.circlepath" : "pause.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                        Text(model.sessionPauseWorking ? "画面恢复中" : "空闲暂停")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Text(model.sessionPauseStatus.isEmpty ? "窗口离开前台已满 10 分钟，已暂停画面与自动剪贴板。" : model.sessionPauseStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("加密连接保持，暂不发送键鼠；返回窗口后继续连接，首次操作不会发往旧画面。")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.sessionPauseWorking {
                        HStack {
                            Spacer()
                            Button("恢复画面") { model.resumeSession() }
                                .buttonStyle(DeskButtonStyle(.primary))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(24)
                .frame(maxWidth: 420)
                .foregroundStyle(DeskPalette.ink)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DeskPalette.cardBackground)
                        .shadow(color: reduceTransparency ? .clear : .black.opacity(0.16), radius: 14, y: 6)
                }
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DeskPalette.hairline) }
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
                            models.disconnectViewerSession(id: model.sessionID)
                        } else {
                            model.stop()
                        }
                    },
                    returnToConnection: {
                        if isDedicatedSessionWindow {
                            models.disconnectViewerSession(id: model.sessionID)
                        } else {
                            model.toggleFullScreen()
                        }
                    },
                    connecting: model.working && !model.reconnecting,
                    failure: model.connectionFailure,
                    disconnectedActionTitle: isDedicatedSessionWindow ? "关闭窗口" : "返回连接",
                    isDedicatedSessionWindow: isDedicatedSessionWindow,
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
                    reduceTransparency: reduceTransparency,
                    beginDrag: { model.releaseControlForLocalUI() },
                    endDrag: { model.resumeControlAfterLocalUI() },
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
                if !(immersive ? showFullScreenMenu : showOptions), let notice = model.desktopActionNotice {
                    sessionNotice(notice, symbol: "exclamationmark.triangle")
                }
                if !(immersive ? showFullScreenMenu : showOptions), let notice = model.remoteTypingNotice {
                    sessionNotice(notice, symbol: model.remoteTypingWorking ? "keyboard.badge.ellipsis" : "keyboard")
                }
            }
            .padding(.top, immersive ? (fullScreenToolbar.revealed ? fullScreenToolbarBottom + 12 : 44) : 16).allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if immersive && fullScreenToolbar.revealed {
                FullScreenToolbar(reduceTransparency: reduceTransparency) {
                    sessionScreenAndSpacesMenu.fullScreenToolbarMenu()
                    if model.supportsLiveSettings {
                        sessionQualityMenu.fullScreenToolbarMenu()
                    }
                    FullScreenToolbarDivider()
                    FullScreenToolbarButton(title: SessionToolAction.fullScreen.title(fullScreen: true),
                                            symbol: SessionToolAction.fullScreen.symbol(fullScreen: true)) {
                        sessionAction { model.toggleFullScreen() }
                    }
                    FullScreenToolbarButton(title: SessionToolAction.endSession.title(), symbol: SessionToolAction.endSession.symbol(),
                                            destructive: true, action: endCurrentSessionAction)
                }
                .padding(.top, FullScreenToolbarReveal.toolbarTop)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: fullScreenToolbar.revealed)
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
                                                openPortMapping: openPortMapping,
                                                endSession: endCurrentSessionAction)
                                .frame(height: min(708, max(0, geometry.size.height - 32)))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .background {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(DeskPalette.cardBackground)
                                        .shadow(color: reduceTransparency ? .clear : .black.opacity(0.28), radius: 20, y: 8)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                                }
                        }
                        FullScreenControlsButton(expanded: showFullScreenMenu, dimmed: model.controlling,
                                                 position: $model.fullScreenControlsPosition,
                                                 containerHeight: geometry.size.height) {
                            model.releaseControlForLocalUI()
                            showFullScreenMenu.toggle()
                        }
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
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DeskPalette.cardBackground)
                    .shadow(color: reduceTransparency ? .clear : .black.opacity(0.12), radius: 8, y: 3)
            }
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DeskPalette.hairline) }
    }

    private var workspaceShell: some View {
        GeometryReader { geometry in
            let autoCompact = geometry.size.width < 780
            let isSidebarVisible = !sidebarCollapsed && !autoCompact
            HStack(spacing: 0) {
                if isSidebarVisible {
                    DeskWorkspaceSidebar(
                        models: models,
                        viewer: models.viewer,
                        host: models.host,
                        portMappings: models.viewer.portMappings,
                        updates: updates,
                        workspaceDeviceID: $workspaceDeviceID,
                        roleLocked: roleLocked,
                        toggleSidebar: {
                            withAnimation(.snappy(duration: 0.18)) {
                                sidebarCollapsed.toggle()
                            }
                        },
                        newConnection: {
                            models.workspaceSection = .connect
                            showNewConnection = true
                        },
                        openDevice: { id in
                            workspaceDeviceID = id
                            models.workspaceSection = .connect
                            openDeviceRequest = id
                        },
                        renameDevice: { recordToRename = $0 },
                        showNetwork: {
                            guard !roleLocked else { return }
                            if models.viewer.portMappings.hostApprovalPending || models.host.portMappings.hostApprovalPending {
                                networkSubTab = .hostApprovals
                                models.workspaceSection = .network
                            } else if models.workspaceSection != .benchmark {
                                models.workspaceSection = .network
                            }
                        }
                    )
                    .frame(width: min(208, max(176, geometry.size.width * 0.18)))

                    Rectangle()
                        .fill(DeskPalette.hairline)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 0) {
                    workspaceTopBar(sidebarVisible: isSidebarVisible, canExpandSidebar: !autoCompact)
                    if updates.showBanner {
                        UpdateBanner(controller: updates)
                    }
                    workspacePage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if workspaceShowsStatus {
                        Divider()
                        statusBar
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(workspaceContentBackground)
            }
            .background(DeskPalette.canvasBackground)
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

    private var workspaceContentBackground: Color {
        if models.workspaceSection == .connect, workspaceDeviceID != nil {
            return DeskPalette.cardBackground
        }
        return DeskPalette.canvasBackground
    }

    @ViewBuilder
    private func workspaceTopBar(sidebarVisible: Bool, canExpandSidebar: Bool) -> some View {
        if !sidebarVisible {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if canExpandSidebar {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                sidebarCollapsed = false
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .help("展开侧边栏")
                        .accessibilityLabel("展开侧边栏")
                    }
                    Text("QuietDesk")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DeskPalette.ink)
                }
                .padding(.leading, 16)

                Spacer(minLength: 0)

                Menu {
                    ForEach(models.viewer.connections) { record in
                        Button(ConnectionEntryPresentation.title(record)) {
                            workspaceDeviceID = record.id
                            models.workspaceSection = .connect
                        }
                    }
                    if !models.viewer.connections.isEmpty { Divider() }
                    Button("全部设备") {
                        workspaceDeviceID = nil
                        models.workspaceSection = .connect
                    }
                    Button("本机共享") { models.workspaceSection = .sharing }
                    Button("网络与线路") { models.workspaceSection = .network }
                    Button("设置") { models.workspaceSection = .preferences }
                } label: {
                    Label(models.workspaceSection.title, systemImage: models.workspaceSection.symbol)
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 16)
            }
            .frame(height: 44)
            Divider()
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
                selectRecord: { workspaceDeviceID = $0.id },
                showNewConnection: $showNewConnection,
                openRecordRequest: $openDeviceRequest
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
                activeSessions: models.activeSessionSummaries,
                openSession: { models.focusViewerSession(id: $0) },
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
        model.releaseControlForLocalUI()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout {
            showPortMapping = true
        } else {
            networkSubTab = model.mode == .host ? .hostApprovals : .viewerMappings
            models.workspaceSection = .network
        }
    }

    private func openTrafficStatistics() {
        model.releaseControlForLocalUI()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout {
            showTrafficStatistics = true
        } else {
            diagnosticsSubTab = .traffic
            models.workspaceSection = .benchmark
        }
    }

    private func openSessionEffects() {
        model.releaseControlForLocalUI()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout {
            showSessionEffects = true
        } else {
            preferencesSubTab = .privacy
            models.workspaceSection = .preferences
        }
    }

    private func openRouteBenchmark(_ record: ConnectionRecord? = nil) {
        guard !models.viewer.active, !models.viewer.working, routeBenchmarkRunner == nil else { return }
        model.releaseControlForLocalUI()
        showOptions = false
        showFullScreenMenu = false
        if sessionLayout {
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
                        .frame(width: 6.5, height: 6.5)
                        .accessibilityHidden(true)
                    Text(sessionStatusHeadline)
                        .lineLimit(1)
                }
                .fontWeight(model.controlling ? .semibold : .medium)
                .foregroundStyle(model.controlling ? DeskPalette.emerald : DeskPalette.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.status)

                if model.connected && !model.resolution.isEmpty {
                    Text(model.resolution)
                        .foregroundStyle(DeskPalette.muted)
                }

                Spacer(minLength: 8)

                if model.pendingFileOffer != nil {
                    Label("1 个文件待确认", systemImage: "doc.on.doc")
                        .foregroundStyle(DeskPalette.amber)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        metrics
                        if model.controlling {
                            Text("释放控制 Ctrl + Option + Esc")
                                .foregroundStyle(DeskPalette.muted)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 10) {
                        Text(model.latency)
                        Text(model.frameRate)
                        if model.controlling {
                            Text("⌃⌥Esc 释放")
                        }
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
                    Button {
                        workspaceDeviceID = nil
                        models.workspaceSection = .connect
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(DeskPalette.emerald)
                                .frame(width: 6, height: 6)
                            Text("\(models.viewerSessions.count) 个活动会话")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DeskPalette.secondary)
                }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(DeskPalette.muted)
        .padding(.horizontal, sessionLayout ? 16 : 24)
        .frame(height: 30)
        .background(sessionLayout ? DeskPalette.insetBackground : DeskPalette.canvasBackground)
        .help(sessionLayout ? "⌃⌥Esc 释放键鼠 · ⌃⌘F 全屏 · ⌃⌘S 远端截图 · Esc 发送到远端" : "")
    }

    private var sessionStatusHeadline: String {
        if model.relativeMouseCaptured {
            return "相对鼠标锁定（⌃⌥Esc 释放）"
        }
        if model.connected {
            let route = shortTransportLabel.hasPrefix("中继") ? "中继" : "直连"
            if model.controlling {
                return "\(route) · 控制中"
            }
            if !model.effectiveViewerCanControl {
                return "\(route) · 仅观看"
            }
            return "\(route) · 已释放"
        }
        if model.reconnecting {
            return controlStatus
        }
        if model.working {
            return "正在建立加密连接…"
        }
        return model.connectionFailure ?? "未连接"
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
                Text(model.remoteName.isEmpty ? (!model.effectiveViewerCanControl ? "仅观看" : (model.controlling ? "控制中" : "已释放")) : model.remoteName)
            }
            Text("·").foregroundStyle(DeskPalette.muted)
            Text(model.latency.isEmpty ? shortTransportLabel : model.latency)
            if !model.mediaLoss.isEmpty {
                if model.mediaLossHigh {
                    Text(model.mediaLoss).foregroundStyle(DeskPalette.coral)
                } else {
                    Text(model.mediaLoss)
                }
            }
            Text("·").foregroundStyle(DeskPalette.muted)
            Text(model.frameRate)
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
            .padding(16)
            .frame(width: 336)
            .foregroundStyle(DeskPalette.ink)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DeskPalette.hairline) }
            .shadow(color: reduceTransparency ? .clear : .black.opacity(0.15), radius: 14, y: 4)
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
    let toggleSidebar: () -> Void
    let newConnection: () -> Void
    /// Shows a device's page and connects to it, or brings its session window forward.
    let openDevice: (UUID) -> Void
    let renameDevice: (ConnectionRecord) -> Void
    let showNetwork: () -> Void
    @State private var copiedHostCode = false
    @State private var recordToRemove: ConnectionRecord?

    /// The device whose page shows; none while another section does. Clicking empty space keeps it.
    private var deviceSelection: Binding<UUID?> {
        Binding(
            get: { models.workspaceSection == .connect ? workspaceDeviceID : nil },
            set: { id in
                guard let id else { return }
                workspaceDeviceID = id
                models.workspaceSection = .connect
            }
        )
    }

    private var sharingStatus: String {
        if host.connected { return "正在被控制" }
        if host.working { return "正在准备共享" }
        if host.active { return "本机共享已开启" }
        if host.mappingHosting { return "独立映射服务已开" }
        return "共享未开启"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DeskPalette.accent)
                    .accessibilityHidden(true)
                Text("QuietDesk")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DeskPalette.ink)
                Spacer(minLength: 0)
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                .help("收起设备栏")
                .accessibilityLabel("收起设备栏")
            }
            .frame(height: 42)
            .padding(.horizontal, 12)

            Button(action: newConnection) {
                Label("新建连接", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DeskButtonStyle(.secondary))
            .disabled(roleLocked)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                navigationRow(.connect, selected: models.workspaceSection == .connect && workspaceDeviceID == nil) {
                    workspaceDeviceID = nil
                    models.workspaceSection = .connect
                }
                navigationRow(
                    .sharing,
                    accessory: host.connected ? "被控中" : (host.active ? "已开启" : nil),
                    tint: host.connected ? DeskPalette.amber : DeskPalette.emerald
                ) {
                    models.workspaceSection = .sharing
                }
                navigationRow(
                    .network,
                    selected: models.workspaceSection == .network || models.workspaceSection == .benchmark,
                    accessory: (portMappings.hostApprovalPending || host.portMappings.hostApprovalPending) ? "待确认" : nil,
                    tint: DeskPalette.amber,
                    action: showNetwork
                )
                navigationRow(
                    .preferences,
                    accessory: updates.manifest != nil || updates.manualReleaseURL != nil ? "有更新" : nil,
                    tint: DeskPalette.accent
                ) {
                    models.workspaceSection = .preferences
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Divider()
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            if !models.arrangedConnections.isEmpty {
                Text("设备记录")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DeskPalette.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 14)
                    .padding(.bottom, 5)
                // A native list: arrow keys move the selection, Return or a double-click connects, a right-click
                // opens the device's menu and a drag reorders.
                List(selection: deviceSelection) {
                    ForEach(models.arrangedConnections) { record in
                        deviceRow(record)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { models.moveDevices(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, 35)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    deviceMenu(ids)
                } primaryAction: { ids in
                    if let id = ids.first { openDevice(id) }
                }
                .disabled(roleLocked)
            } else {
                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                Rectangle().fill(DeskPalette.hairline).frame(height: 1)
                sharingMenu
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(DeskPalette.sidebarBackground)
        .modifier(RecordRemovalAlert(record: $recordToRemove, active: true, remove: viewer.removeConnection))
    }

    /// Brings the symbols of the list's rows in line with those of the rows below it.
    private static let listRowLeading: CGFloat = 4

    // Colours follow the list: the title and symbol turn light on the highlight of a focused list.
    private func deviceRow(_ record: ConnectionRecord) -> some View {
        let session = models.existingSession(for: record)
        let title = ConnectionEntryPresentation.title(record)
        let status = session?.activeSessionSummary.statusLabel
        return HStack(spacing: 9) {
            Image(systemName: ConnectionEntryPresentation.deviceSymbol(record))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 19)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let session, session.connected || session.working || session.reconnecting {
                Circle()
                    .fill(session.connected ? DeskPalette.emerald : DeskPalette.amber)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Self.listRowLeading)
        .frame(minHeight: 31)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(status ?? "未连接")
        .help("\(title)\n\(status ?? "点按查看设备；连按两次或按 Return 连接，右键可重命名，按住拖动可调整顺序")")
        .padding(.trailing, deviceSelection.wrappedValue == record.id ? 25 : 0)
        .overlay(alignment: .trailing) {
            if deviceSelection.wrappedValue == record.id {
                Menu {
                    deviceMenu([record.id])
                } label: {
                    Image(systemName: "ellipsis").frame(width: 21, height: 23)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("设备记录操作")
                .accessibilityLabel("设备记录操作")
            }
        }
    }

    @ViewBuilder
    private func deviceMenu(_ ids: Set<UUID>) -> some View {
        if let record = viewer.connections.first(where: { ids.contains($0.id) }) {
            let session = models.existingSession(for: record).flatMap { $0.active || $0.working || $0.reconnecting ? $0 : nil }
            Button(session == nil ? "连接" : "切到窗口") { openDevice(record.id) }
            if let session {
                Button("断开连接", role: .destructive) { models.disconnectViewerSession(id: session.sessionID) }
            }
            Divider()
            Button("重命名…") { renameDevice(record) }
            Button("移除此记录…", role: .destructive) { recordToRemove = record }
                .disabled(viewer.active || viewer.working || viewer.isRunningRouteBenchmark)
        } else {
            Button("新建连接…", action: newConnection)
        }
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
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? DeskPalette.accent : DeskPalette.secondary)
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
                if host.active || host.working || host.mappingHosting {
                    Circle()
                        .fill(host.connected || host.working ? DeskPalette.amber : DeskPalette.emerald)
                        .frame(width: 6.5, height: 6.5)
                        .accessibilityHidden(true)
                }
                Text(sharingStatus)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(DeskPalette.muted)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(DeskPalette.muted)
        .help("共享快捷操作")
    }
}

private struct DeviceRenameSheet: View {
    let save: (String) throws -> Void
    private let initialName: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var failure: String?

    init(name: String, save: @escaping (String) throws -> Void) {
        initialName = name
        _name = State(initialValue: name)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            DeskSectionHeading(title: "重命名设备", detail: "此名称仅在本机显示。")

            VStack(alignment: .leading, spacing: 6) {
                Text("设备名称")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .accessibilityHidden(true)
                TextField("设备名称", text: $name)
                    .font(.system(size: 13))
                    .focused($nameFocused)
                    .deskInputBox(focused: nameFocused)
            }

            if let failure {
                DeskCalloutBox(message: failure, symbol: "exclamationmark.circle", tone: .danger)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try save(name)
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(name == initialName)
            }
        }
        .padding(26)
        .frame(width: 420)
        .deskSurface()
        .onAppear { nameFocused = true }
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
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .padding(.horizontal, 10)
                .frame(minHeight: 35)
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

    private var hostHeadline: String {
        if host.connected { return "本机共享 · 正在被控制" }
        if host.working { return "本机共享 · 正在启动" }
        if host.active { return "本机共享 · 运行中" }
        return "本机共享 · 已停止"
    }

    var body: some View {
        Button("打开主窗口") {
            models.prepareShowWindow()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            models.mainWindow?.deminiaturize(nil)
            models.mainWindow?.makeKeyAndOrderFront(nil)
        }
        .onAppear {
            let open = openWindow
            models.openSessionWindow = { id in
                open(id: "remote-session", value: id)
            }
        }

        Divider()

        Text(hostHeadline)
        if host.hasIncomingControlConnection {
            Button("断开控制端") { host.disconnectController() }
        }
        Button(host.active || host.working ? "停止本机共享" : "开启本机共享") {
            if host.active || host.working { host.stop() } else { host.startHosting() }
        }

        if !models.viewerSessions.isEmpty {
            Divider()
            ForEach(models.activeSessionSummaries) { summary in
                let state = summary.connected ? summary.statusLabel
                    : summary.reconnecting ? "重连中"
                    : summary.working ? "连接中" : "未连接"
                Text("\(summary.title) · \(state)")
                Button("切到远控窗口") { models.focusViewerSession(id: summary.id) }
                Button("断开 \(summary.title)", role: .destructive) { models.disconnectViewerSession(id: summary.id) }
            }
            if models.viewerSessions.count > 1 {
                Button("断开全部远程连接（\(models.viewerSessions.count)）", role: .destructive) {
                    models.disconnectAllViewerSessions()
                }
            }
        } else if viewer.isControllingAnotherMac {
            Divider()
            Text("远程连接：" + viewer.status)
            Button("断开远程连接", role: .destructive) { viewer.stop() }
        }

        Divider()

        if updates.enabled {
            Button(updates.menuTitle) { updates.check() }
            if updates.autoInstallDeferredBySession {
                Text("自动更新已待命（远控结束后安装）")
            }
        }

        Button(exportingLogs ? "正在导出日志…" : "导出日志…") { exportLogs() }
            .disabled(exportingLogs)

        Menu("后台与诊断偏好") {
            Toggle("共享时接通电源阻止空闲睡眠", isOn: $host.preventHostSleepOnExternalPower)
            if updates.enabled {
                Toggle("自动检查更新", isOn: Binding(get: { updates.autoCheckPreference == true },
                    set: { updates.setAutomaticChecks($0) }))
                Toggle("非远程控制时自动更新", isOn: Binding(get: { updates.autoInstallPreference },
                    set: { updates.setAutomaticInstall($0) }))
            }
            Divider()
            Toggle("性能诊断", isOn: Binding(get: { viewer.performanceDiagnosticsEnabled },
                set: { models.setPerformanceDiagnosticsEnabled($0) }))
        }

        Divider()
        Button("退出 QuietDesk") { NSApp.terminate(nil) }
    }

    private func exportLogs() {
        viewer.canvas.releaseControl()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 QuietDesk 日志"
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
    var immersiveFullScreen: Bool = false
    var restorable: Bool = true
    let resolved: (NSWindow) -> Void
    let fullScreen: (Bool) -> Void
    var willClose: (() -> Void)? = nil
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.sessionChrome = sessionChrome
        view.immersiveFullScreen = immersiveFullScreen
        view.restorable = restorable
        view.resolved = resolved
        view.fullScreen = fullScreen
        view.willClose = willClose
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        let chromeChanged = view.sessionChrome != sessionChrome
            || view.immersiveFullScreen != immersiveFullScreen
            || view.restorable != restorable
        view.sessionChrome = sessionChrome
        view.immersiveFullScreen = immersiveFullScreen
        view.restorable = restorable
        view.resolved = resolved
        view.fullScreen = fullScreen
        view.willClose = willClose
        if chromeChanged {
            view.applyWindowChrome()
            DispatchQueue.main.async { [weak view] in
                view?.applyWindowChrome()
            }
        }
    }
    final class Probe: NSView {
        var sessionChrome = false
        var immersiveFullScreen = false
        var restorable = true
        var resolved: ((NSWindow) -> Void)?
        var fullScreen: ((Bool) -> Void)?
        var willClose: (() -> Void)?
        private var enteringFullScreen = false
        private var observers: [NSObjectProtocol] = []
        func applyWindowChrome() {
            guard let window else { return }
            if window.isRestorable != restorable { window.isRestorable = restorable }
            let inFullScreen = enteringFullScreen || window.styleMask.contains(.fullScreen)
            if inFullScreen {
                if immersiveFullScreen {
                    if !window.styleMask.contains(.fullSizeContentView) {
                        window.styleMask.insert(.fullSizeContentView)
                    }
                    if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
                    if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
                    if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
                    if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
                    if window.backgroundColor != .black { window.backgroundColor = .black }
                }
                return
            }
            if window.backgroundColor == .black {
                window.backgroundColor = .windowBackgroundColor
            }
            // AppKit reserves the title bar above the workspace, including after a resize.
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
            }
            if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
            let titleVisibility: NSWindow.TitleVisibility = sessionChrome ? .visible : .hidden
            if window.titleVisibility != titleVisibility { window.titleVisibility = titleVisibility }
            let separatorStyle: NSTitlebarSeparatorStyle = sessionChrome ? .automatic : .none
            if window.titlebarSeparatorStyle != separatorStyle { window.titlebarSeparatorStyle = separatorStyle }
            if let toolbar = window.toolbar, toolbar.isVisible != sessionChrome { toolbar.isVisible = sessionChrome }
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(buttonType) {
                    if button.isHidden { button.isHidden = false }
                    if button.superview?.isHidden == true { button.superview?.isHidden = false }
                }
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { return }
            window.minSize = NSSize(width: 720, height: 580)
            enteringFullScreen = window.styleMask.contains(.fullScreen)
            applyWindowChrome()
            DispatchQueue.main.async { [weak self] in
                self?.applyWindowChrome()
            }
            resolved?(window)
            fullScreen?(window.styleMask.contains(.fullScreen))
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.enteringFullScreen = true
                    self?.fullScreen?(true)
                    self?.applyWindowChrome()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.enteringFullScreen = false
                    self?.fullScreen?(self?.window?.styleMask.contains(.fullScreen) == true)
                    self?.applyWindowChrome()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.enteringFullScreen = false
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.enteringFullScreen = false
                    self?.fullScreen?(self?.window?.styleMask.contains(.fullScreen) == true)
                    self?.applyWindowChrome()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willClose?()
                }
            })
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
