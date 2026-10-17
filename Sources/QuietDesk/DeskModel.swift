import AppKit
import Network
import ScreenCaptureKit
import IOKit.hid
import QuietDeskCore

@MainActor
final class DeskModel: ObservableObject {
    enum Mode: String, CaseIterable { case viewer = "连接家里 Mac", host = "共享这台 Mac" }
    @Published var mode: Mode = .viewer
    @Published var address = UserDefaults.standard.string(forKey: "remoteAddress") ?? ""
    @Published var port = UserDefaults.standard.string(forKey: "remotePort") ?? "5908"
    @Published var viewerCode = ""
    @Published var hostCode = ""
    @Published private(set) var hostCodeNeedsSetup = false
    @Published var hostPort = UserDefaults.standard.string(forKey: "listenPort") ?? "5908" {
        didSet { UserDefaults.standard.set(hostPort, forKey: "listenPort") }
    }
    @Published var settings = StreamSettings() {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "streamSettings") } }
    }
    @Published var displayID = CGMainDisplayID() {
        didSet { UserDefaults.standard.set(Int(displayID), forKey: "sharedDisplay") }
    }
    @Published private(set) var screens: [(id: CGDirectDisplayID, name: String)] = []
    @Published var active = false
    @Published var working = false
    @Published var connected = false
    @Published var controlling = false
    @Published var status = "准备就绪"
    @Published var error: String?
    @Published private(set) var connectionError: String?
    var connectionFailure: String? {
        guard mode == .viewer, !active, !working, !connected else { return nil }
        return connectionError
    }
    @Published var traffic = "0.00 Mbps"
    @Published private(set) var trafficHistory: [DeviceTrafficRecord] = []
    @Published private(set) var trafficHistoryError: String?
    @Published private(set) var trafficHistoryStatus = "从本版开始按设备累计；旧版设备需双方升级。"
    @Published private(set) var currentTrafficDeviceID: UUID?
    @Published var frameRate = "0 fps"
    @Published var latency = "— ms"
    @Published private(set) var performanceDiagnosticsEnabled = false
    @Published private(set) var roundTripMilliseconds: Double?
    @Published var showFullScreenStatistics = UserDefaults.standard.bool(forKey: "showFullScreenStatistics") {
        didSet { UserDefaults.standard.set(showFullScreenStatistics, forKey: "showFullScreenStatistics") }
    }
    @Published var resolution = ""
    @Published var remoteName = ""
    @Published var clipboardStatus = ""
    @Published private(set) var pendingFileOffer: ClipboardFileOffer?
    @Published var canControl = false
    @Published private(set) var localAccessibility = false
    @Published private(set) var localInputMonitoring = false
    @Published private(set) var localScreenRecording = false
    @Published private(set) var capsLockRunning = false
    @Published var isFullScreen = false
    @Published private(set) var capsLockEnabled = UserDefaults.standard.bool(forKey: "capsLockActions")
    @Published private(set) var supportsInputActions = false
    @Published private(set) var supportsLiveSettings = false
    @Published private(set) var supportsExtendedVideoSettings = false
    @Published private(set) var supportsHighRefreshVideoSettings = false
    @Published private(set) var supportsSessionEffects = false
    @Published private(set) var sessionEffects = SessionEffectsState()
    @Published private(set) var sessionEffectsWorking = false
    @Published private(set) var sessionEffectsStatus = ""
    @Published private(set) var supportsSessionPause = false
    @Published private(set) var sessionPaused = false
    @Published private(set) var sessionPauseWorking = false
    @Published private(set) var sessionPauseStatus = ""
    var sessionInputSuspended: Bool { mode == .viewer && (idlePolicy.isPaused || pauseTransmission.inputSuspended) }
    @Published private(set) var activeVideoState: VideoStreamState?
    @Published private(set) var videoTuning: VideoTuningSession?
    @Published private(set) var videoSettingsStatus = ""
    var viewerSettings: StreamSettings { videoTuning?.desired ?? activeVideoState?.settings ?? StreamSettings() }
    var viewerLongestEdges: [Int] { supportsExtendedVideoSettings ? StreamSettings.longestEdges : StreamSettings.legacyLongestEdges }
    var viewerFrameRates: [Int] { supportsHighRefreshVideoSettings ? StreamSettings.frameRates : StreamSettings.legacyFrameRates }
    var viewerBitRates: [Int] { supportsHighRefreshVideoSettings ? StreamSettings.bitRates : supportsExtendedVideoSettings ? StreamSettings.extendedBitRates : StreamSettings.legacyBitRates }
    @Published var inputStatus = ""
    @Published private(set) var systemShortcutStatus = "全屏控制画面获得焦点后自动转发系统快捷键"
    @Published private(set) var systemShortcutsRunning = false
    @Published private(set) var connections = ConnectionStore.load()
    @Published var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
    @Published var reconnecting = false
    @Published var lastDisconnect = UserDefaults.standard.string(forKey: "lastDisconnect") ?? ""
    @Published var clipboardEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
    @Published var loginEnabled = LaunchSettings.enabled
    @Published var loginNeedsApproval = LaunchSettings.needsApproval
    @Published var autoStartSharing = UserDefaults.standard.bool(forKey: "autoStartSharing") {
        didSet { UserDefaults.standard.set(autoStartSharing, forKey: "autoStartSharing") }
    }
    @Published var minimizeAtLogin = UserDefaults.standard.object(forKey: "minimizeAtLogin") as? Bool ?? true {
        didSet { UserDefaults.standard.set(minimizeAtLogin, forKey: "minimizeAtLogin") }
    }
    weak var mainWindow: NSWindow?
    let canvas = RemoteCanvas()

    private var listener: NWListener?
    private var peer: Peer?
    private var dataChannel: SessionDataChannel?
    private var pending: [UUID: Peer] = [:]
    private var hostSession = HostSession()
    private var viewerSession = ViewerSession()
    private var generation = UUID()
    private var activity: NSObjectProtocol?
    private var metricsTimer: Timer?
    private var performanceDiagnostics: PerformanceDiagnostics?
    private let performanceQueue = DispatchQueue(label: "quietdesk.performance", qos: .utility)
    private var performanceTimer: DispatchSourceTimer?
    private var performanceConnectionID = 0
    private var performanceRole: DiagnosticLog.Role?
    private var permissionTimer: Timer?
    private var permissionGuide: PermissionGuide?
    private var capsLockStartAttempted = false
    private var controlStatusUpdatesEnabled = false
    private var lastMetrics = SessionClock.now
    private var reconnectTask: Task<Void, Never>?
    private var hostRetryTask: Task<Void, Never>?
    private var retryBackoff = RetryBackoff()
    private var hostBackoff = RetryBackoff()
    private var hostingRequested = false
    private var clipboardSync: ClipboardSync?
    private var supportsClipboard = false
    private var remoteClipboardEnabled = false
    private var remoteFileApproval = false
    private var remoteClipboardChunkWindow = false
    private var remoteReceivesAutomaticClipboard = true
    private var remoteClipboardFocusAware = false
    private var lastClipboardReceivePreference: Bool?
    private var clipboardFilePrompt: ClipboardFilePrompt?
    private var clipboardSession: UUID?
    private var initialLaunchHandled = false
    private var loginWindowHandled = false
    private var shouldMinimizeOnLaunch = false
    private struct Target {
        let address: String
        let port: UInt16
        let key: PairingKey
        let recordID: UUID?
    }
    private var target: Target?
    private var selectedConnectionID: UUID?
    private var savedTarget = false
    private var viewerQualityPolicy = ViewerQualityPolicy()
    private var screenObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var systemSleeping = false
    private var displayRefreshTask: Task<Void, Never>?
    private var hostPreparationTask: Task<Void, Never>?
    private let trafficHistoryStore = TrafficHistoryStore()
    private var trafficSession: TrafficSession?
    private var effectsCleanupTask: Task<Void, Never>?
    private var idlePolicy = SessionIdlePolicy(now: SessionClock.now)
    private var pauseTransmission = SessionPauseTransmission()
    private var wakeInputGate = SessionWakeInputGate()
    private var reconnectDeferredForIdle = false
    private var windowActivityMonitor: Any?
    private var sessionFocusObservers: [NSObjectProtocol] = []
    private var focusRefreshTask: Task<Void, Never>?
    private var suppressIdleFocusWake = false
    private var freshFrameRequiredOnReconnect = false

    init() {
        if autoStartSharing { mode = .host }
        if let data = UserDefaults.standard.data(forKey: "streamSettings"),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data),
           (try? saved.validateControlValues()) != nil { settings = saved }
        if let id = UserDefaults.standard.object(forKey: "sharedDisplay") as? Int { displayID = CGDirectDisplayID(clamping: id) }
        refreshDisplays()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displayRefreshTask?.cancel()
                    self.displayRefreshTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        self?.refreshDisplays()
                        self?.displayRefreshTask = nil
                    }
                }
            }

        powerObservers = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.willSleepNotification { self?.systemWillSleep() }
                    else { self?.systemDidWake() }
                }
            }
        }

        canvas.onUserActivity = { [weak self] in self?.recordSessionActivity() }
        canvas.onInput = { [weak self] value in
            guard let self else { return }
            self.recordSessionActivity()
            let allowed = self.wakeInputGate.allows(value, suspended: self.sessionInputSuspended || !self.connected)
            guard self.connected, self.canControl, allowed else {
                if value.kind == .scroll { DiagnosticLog.shared.count(.scrollSuppressed) }
                return
            }
            var input = value
            if input.kind == .switchInputSource || input.kind == .toggleCapsLock {
                guard self.supportsInputActions else { return }
            }
            if self.canvas.usesCapsLockActions { input.independentCapsLock = true }
            do {
                let message = try Wire.json(.input, input)
                if input.kind == .scroll {
                    self.peer?.send(message) { success in
                        DiagnosticLog.shared.count(success ? .scrollSent : .scrollSuppressed)
                    }
                } else { self.peer?.send(message) }
            } catch {
                self.recordDiagnosticFailure(.inputFailed, error: error)
                self.error = error.localizedDescription
            }
        }
        canvas.onRelease = { [weak self] in self?.peer?.send(Message(.releaseInput)) }
        canvas.onFocus = { [weak self] focused in
            guard let self else { return }
            self.controlling = focused
            self.refreshClipboardFocus()
        }
        canvas.onFailure = { [weak self] message in
            DiagnosticLog.shared.record(.captureFailed, role: .viewer, state: .failed)
            self?.peer?.close(message, retryable: true)
        }
        canvas.onPaste = { [weak self] input in
            guard let self, let peer = self.peer, self.connected else { return }
            self.recordSessionActivity()
            guard !self.sessionInputSuspended else { return }
            let interaction = self.canvas.interactionRevision
            self.clipboardStatus = "正在等待剪贴板同步后粘贴…"
            self.clipboardSync?.prepareForPaste { [weak self, weak peer] success in
                guard let self, let peer, self.peer === peer, self.connected else { return }
                guard success, !self.sessionInputSuspended, self.canvas.interactionRevision == interaction,
                      self.canvas.window?.firstResponder === self.canvas, self.canvas.window?.isKeyWindow == true else {
                    self.clipboardStatus = "粘贴未执行：同步失败、焦点离开或等待期间进行了其他操作"
                    return
                }
                do {
                    self.clipboardStatus = "剪贴板已就绪，已发送粘贴"
                    var down = input
                    if self.canvas.usesCapsLockActions { down.independentCapsLock = true }
                    peer.send(try Wire.json(.input, down))
                    var up = down
                    up.kind = .keyUp
                    up.flags = UInt64(NSEvent.modifierFlags.rawValue)
                    peer.send(try Wire.json(.input, up))
                } catch { self.clipboardStatus = error.localizedDescription }
            }
        }
        canvas.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        canvas.onFullScreen = { [weak self] enabled in
            self?.isFullScreen = enabled
        }
        canvas.onSystemShortcutStatus = { [weak self] message, running in
            self?.systemShortcutStatus = message
            self?.systemShortcutsRunning = running
        }
        canvas.capsLockMonitor.onFailure = { [weak self] message in
            let failedMonitor = self?.canvas.capsLockMonitor.generation
            DispatchQueue.main.async {
                guard let self, self.canvas.capsLockMonitor.generation == failedMonitor else { return }
                self.canvas.capsLockMonitor.stop()
                self.canvas.usesCapsLockActions = false
                self.capsLockRunning = false
                self.inputStatus = "\(message)；请点击重新检测，已勾选时可完全退出后重开，无需反复添加"
            }
        }
        refreshPermissions(checkScreenCapture: true)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let guideVisible = self.permissionGuide?.isVisible == true
                guard self.connected || self.capsLockEnabled || guideVisible else { return }
                self.refreshPermissions(checkScreenCapture: guideVisible)
            }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
        trafficHistoryStore.observe { [weak self] records, message in
            DispatchQueue.main.async {
                self?.trafficHistory = records
                self?.trafficHistoryError = message
            }
        }
    }

    private var diagnosticRole: DiagnosticLog.Role { mode == .viewer ? .viewer : .host }

    func setPerformanceDiagnosticsEnabled(_ enabled: Bool) {
        guard performanceDiagnosticsEnabled != enabled else { return }
        if !enabled { flushPerformanceDiagnostics() }
        performanceDiagnosticsEnabled = enabled
        performanceDiagnostics?.setEnabled(enabled)
        DiagnosticLog.shared.record(.performanceDiagnosticsChanged, role: diagnosticRole,
            state: enabled ? .enabled : .disabled)
        if enabled, let activeVideoState { recordVideoConfiguration(activeVideoState) }
    }

    private func attachPerformanceDiagnostics(_ diagnostics: PerformanceDiagnostics, role: DiagnosticLog.Role) {
        performanceTimer?.cancel()
        performanceConnectionID += 1
        let connectionID = performanceConnectionID
        performanceRole = role
        performanceDiagnostics = diagnostics
        diagnostics.setEnabled(performanceDiagnosticsEnabled)
        let timer = DispatchSource.makeTimerSource(queue: performanceQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            for summary in diagnostics.drain() {
                DiagnosticLog.shared.recordPerformance(summary, role: role, connectionID: connectionID)
            }
        }
        performanceTimer = timer
        timer.resume()
    }

    func flushPerformanceDiagnostics() {
        guard let performanceDiagnostics, let performanceRole else { return }
        let connectionID = performanceConnectionID
        // Finish any timer drain and enqueue its rows before the log export can start.
        performanceQueue.sync {
            for summary in performanceDiagnostics.drain() {
                DiagnosticLog.shared.recordPerformance(summary, role: performanceRole, connectionID: connectionID)
            }
        }
    }

    private func recordDiagnosticFailure(_ event: DiagnosticLog.Event, error: Error) {
        var values: [DiagnosticLog.Field: Int] = [:]
        if let failure = error as? DeskError, case .system(_, let code) = failure {
            values[.statusCode] = Int(code)
        }
        DiagnosticLog.shared.record(event, role: diagnosticRole, state: .failed, values: values, error: error)
    }

    private func recordVideoConfiguration(_ state: VideoStreamState, succeeded: Bool = true) {
        DiagnosticLog.shared.record(.streamConfigured, role: diagnosticRole, state: succeeded ? .ready : .failed,
            values: [.width: state.width, .height: state.height, .fps: state.settings.framesPerSecond,
                     .targetBitrate: state.settings.megabits * 1_000_000, .maximumDimension: state.settings.longestEdge])
    }

    private func recordClipboardDiagnostic(_ event: ClipboardSync.DiagnosticEvent) {
        func payload(_ event: DiagnosticLog.Event, state: DiagnosticLog.State,
                     kind: ClipboardSync.PayloadKind, count: Int) {
            DiagnosticLog.shared.record(event, role: diagnosticRole, state: state,
                values: [.fileCount: count, .payloadType: kind == .text ? 0 : kind == .png ? 1 : 2])
        }
        switch event {
        case .sending(let kind, let count): payload(.clipboardOffered, state: .local, kind: kind, count: count)
        case .sent(let kind, let count): payload(.clipboardCompleted, state: .local, kind: kind, count: count)
        case .sendFailed(let kind, let count): payload(.clipboardFailed, state: .local, kind: kind, count: count)
        case .applied(let kind, let count): payload(.clipboardCompleted, state: .remote, kind: kind, count: count)
        case .applyFailed(let kind, let count): payload(.clipboardFailed, state: .remote, kind: kind, count: count)
        case .fileOfferReceived(let count, let bytes):
            DiagnosticLog.shared.record(.clipboardOfferReceived, role: diagnosticRole, state: .remote,
                values: [.fileCount: count, .totalBytes: Int(clamping: bytes)])
        case .fileOfferAccepted: DiagnosticLog.shared.record(.clipboardAccepted, role: diagnosticRole, state: .accepted)
        case .fileOfferRejected: DiagnosticLog.shared.record(.clipboardRejected, role: diagnosticRole, state: .rejected)
        case .staleFilesSuppressed: DiagnosticLog.shared.record(.clipboardEchoSuppressed, role: diagnosticRole)
        }
    }

    func flushTrafficHistory() {
        if let trafficSession, let peer { trafficSession.receive(peer.trafficMeter.snapshot()) }
        trafficHistoryStore.flush()
    }

    private func makeTrafficSession(for peer: Peer) -> TrafficSession {
        let history = trafficHistoryStore
        let session = TrafficSession(connectionID: peer.trafficMeter.connectionID,
            onDelta: { identity, delta in history.record(identity, delta: delta) },
            onError: { history.reportCountingError($0) })
        peer.trafficMeter.onUpdate = session.receive
        return session
    }

    func toggleFullScreen() {
        guard let window = canvas.window ?? NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    func requestInputMonitoring() {
        if mode == .viewer { canvas.releaseControl() }
        openPermissionSettings(.inputMonitoring)
    }

    func setCapsLockEnabled(_ enabled: Bool) {
        capsLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "capsLockActions")
        refreshPermissions(retryCapsLock: true)
        if !enabled { inputStatus = "Caps Lock 转发已关闭" }
    }

    func refreshPermissions(checkScreenCapture: Bool = false, retryCapsLock: Bool = false) {
        permissionGuide?.refreshStatus()
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = mode == .viewer && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if localAccessibility != accessibility || localInputMonitoring != inputMonitoring {
            DiagnosticLog.shared.record(.permissionChanged, role: diagnosticRole,
                values: [.accessibilityGranted: accessibility ? 1 : 0, .inputMonitoringGranted: inputMonitoring ? 1 : 0])
        }
        if localAccessibility != accessibility { localAccessibility = accessibility }
        if localInputMonitoring != inputMonitoring { localInputMonitoring = inputMonitoring }
        if checkScreenCapture, mode == .host {
            let allowed = CGPreflightScreenCaptureAccess()
            if localScreenRecording != allowed {
                DiagnosticLog.shared.record(.permissionChanged, role: .host, values: [.screenRecordingGranted: allowed ? 1 : 0])
            }
            localScreenRecording = allowed
        }

        if mode == .host, connected, canControl != accessibility {
            canControl = accessibility
            if !accessibility { hostSession.injector?.releaseAll() }
            status = accessibility ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（辅助功能未生效）"
            if controlStatusUpdatesEnabled, let peer {
                do { peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: accessibility))) }
                catch { peer.close(error.localizedDescription) }
            } else if accessibility {
                status = "辅助功能已生效 · 旧版控制端需重新连接后操作"
            }
        }

        canvas.updateSystemShortcutCapture(sessionActive: mode == .viewer && connected && canControl && !sessionInputSuspended,
            accessibility: accessibility, inputMonitoring: inputMonitoring, retry: retryCapsLock)
        guard mode == .viewer, capsLockEnabled else {
            canvas.capsLockMonitor.stop()
            canvas.usesCapsLockActions = false
            capsLockRunning = false
            capsLockStartAttempted = false
            return
        }
        guard accessibility, inputMonitoring else {
            canvas.capsLockMonitor.stop()
            canvas.usesCapsLockActions = false
            capsLockRunning = false
            capsLockStartAttempted = false
            inputStatus = "Caps Lock 等待本机辅助功能和输入监控生效；已勾选时请完全退出后重开，无需反复添加"
            return
        }
        if !canvas.capsLockMonitor.isRunning, retryCapsLock || !capsLockStartAttempted {
            capsLockStartAttempted = true
            do {
                try canvas.capsLockMonitor.start()
                inputStatus = "Caps Lock：短按切输入法，长按后松开切大写"
            } catch {
                canvas.capsLockMonitor.stop()
                inputStatus = "系统权限已允许，输入监听尚未就绪：\(error.localizedDescription)。请重新检测或完全退出后重开"
            }
        }
        capsLockRunning = canvas.capsLockMonitor.isRunning
        canvas.usesCapsLockActions = capsLockRunning && supportsInputActions && canControl && !sessionInputSuspended
        if connected, !supportsInputActions { inputStatus = "远端版本较旧，请更新家里 Mac 后使用 Caps Lock 切换输入法" }
    }

    func prepareHostCode() {
        guard hostCode.isEmpty else { return }
        do {
            if let key = try KeyStore.load() {
                hostCode = key.code
                hostCodeNeedsSetup = false
            } else { hostCodeNeedsSetup = true }
        } catch { self.error = error.localizedDescription }
    }

    func regenerateKey() {
        guard !active, !working else { return }
        do {
            let key = try PairingKey.generate()
            try KeyStore.save(key)
            hostCode = key.code
            hostCodeNeedsSetup = false
            status = "新配对码已保存，可以开启共享；旧配对码已失效"
        } catch { self.error = error.localizedDescription }
    }

    func restoreHostCode(_ code: String) -> Bool {
        guard !active, !working else { return false }
        do {
            let key = try PairingKey(code: code)
            try KeyStore.save(key)
            hostCode = key.code
            hostCodeNeedsSetup = false
            status = "原配对码已保存，可以开启共享"
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func copyHostCode() {
        prepareHostCode()
        guard !hostCode.isEmpty else { return }
        guard ClipboardPrivacy.copyPairingCode(hostCode) else {
            clipboardStatus = "配对码复制失败，请重试"
            return
        }
        clipboardStatus = "配对码已复制，仅在本机保留 60 秒，请通过可信渠道传递"
    }

    func requestAccessibility() {
        if mode == .viewer { canvas.releaseControl() }
        openPermissionSettings(.accessibility)
    }

    func openScreenPermission() {
        if mode == .viewer { canvas.releaseControl() }
        openPermissionSettings(.screenRecording)
    }

    private func openPermissionSettings(_ kind: PermissionGuide.Kind) {
        if permissionGuide == nil {
            permissionGuide = PermissionGuide { [weak self] in
                self?.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
            }
        }
        permissionGuide?.present(for: kind)
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func validPort(_ text: String? = nil) throws -> NWEndpoint.Port {
        guard let number = UInt16(text ?? port), number > 0, let value = NWEndpoint.Port(rawValue: number) else {
            throw DeskError.invalid("端口需为 1 到 65535 的整数")
        }
        return value
    }

    private func displaySnapshot(_ id: CGDirectDisplayID) -> DisplaySnapshot {
        ScreenStreamer.displaySnapshot(id)
    }

    private func refreshDisplays() {
        let current = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, name: String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }
        screens = current
        let available = current.map { displaySnapshot($0.id) }
        if let selection = DisplaySelection.select(preferred: displayID, main: CGMainDisplayID(), available: available),
           selection.id != displayID { displayID = selection.id }
        if mode == .host, hostingRequested, active, let capturedDisplay = hostSession.capturedDisplay,
           DisplaySelection.requiresRestart(captured: capturedDisplay, available: available) {
            DiagnosticLog.shared.record(.displayChanged, role: .host, state: .requested)
            restartHostAfterFailure("共享显示器已变化，正在重新准备共享")
        }
    }

    private func selectShareableDisplay(_ displays: [SCDisplay]) throws -> (display: SCDisplay, snapshot: DisplaySnapshot) {
        guard let selection = DisplaySelection.select(preferred: displayID, main: CGMainDisplayID(),
            available: displays.filter { CGDisplayIsActive($0.displayID) != 0 }.map { displaySnapshot($0.displayID) }),
              let display = displays.first(where: { $0.displayID == selection.id }) else {
            throw DeskError.invalid("当前没有可共享的显示器，等待显示器恢复")
        }
        if displayID != selection.id { displayID = selection.id }
        return (display, selection)
    }

    func startHosting(interactive: Bool = true) {
        guard !active, !working, !systemSleeping else { return }
        prepareHostCode()
        guard !hostCode.isEmpty else {
            status = hostCodeNeedsSetup ? "请先补录原配对码，或明确选择生成新配对码，再开启共享" : "配对码未能读取，请检查本机凭据文件"
            return
        }
        DiagnosticLog.shared.record(.hostStarted, role: .host, state: .requested)
        hostingRequested = true
        hostRetryTask?.cancel()
        do {
            let key = try PairingKey(code: hostCode)
            let port = try validPort(hostPort)
            guard CGPreflightScreenCaptureAccess() else {
                localScreenRecording = false
                let failure = DeskError.invalid("请在系统设置中允许屏幕录制，权限实际生效后再开启共享")
                recordDiagnosticFailure(.hostStopped, error: failure)
                status = "共享未启动：\(failure.localizedDescription)"
                if interactive { openScreenPermission() }
                return
            }
            working = true
            status = "正在准备共享…"
            let token = UUID()
            generation = token
            hostPreparationTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == token { self.hostPreparationTask = nil } }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard self.generation == token, self.hostingRequested, !Task.isCancelled else { return }
                    self.refreshDisplays()
                    _ = try self.selectShareableDisplay(content.displays)
                    let listener = try NWListener(using: SecureTransport.parameters(key: key), on: port)
                    let admission = PendingHandshakeGate()
                    listener.newConnectionHandler = { [weak self] connection in
                        let address: String?
                        if case .hostPort(let host, _) = connection.endpoint { address = host.debugDescription }
                        else { address = nil }
                        guard let id = admission.reserve(address: address, now: SessionClock.now) else {
                            connection.cancel()
                            return
                        }
                        DispatchQueue.main.async {
                            guard let self, self.generation == token, self.active else {
                                admission.release(id)
                                connection.cancel()
                                return
                            }
                            self.accept(connection, generation: token, admission: admission, id: id)
                        }
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            switch state {
                            case .ready:
                                DiagnosticLog.shared.record(.hostStarted, role: .host, state: .ready)
                                self.working = false
                                self.hostBackoff.reset()
                                self.status = "等待连接 · TCP \(port.rawValue)"
                            case .failed(let error):
                                self.recordDiagnosticFailure(.hostStopped, error: error)
                                self.restartHostAfterFailure("监听失败：\(error.localizedDescription)")
                            default: break
                            }
                        }
                    }
                    self.listener = listener
                    self.active = true
                    self.activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                                                         reason: "远程桌面共享")
                    self.beginMetrics()
                    listener.start(queue: DispatchQueue(label: "quietdesk.listener"))
                } catch {
                    guard self.generation == token, self.hostingRequested, !Task.isCancelled else { return }
                    self.working = false
                    self.recordDiagnosticFailure(.hostStopped, error: error)
                    self.status = "共享未启动：\(error.localizedDescription)"
                    if self.hostingRequested { self.scheduleHostRetry() }
                    if interactive { self.error = error.localizedDescription }
                }
            }
        } catch {
            working = false
            recordDiagnosticFailure(.hostStopped, error: error)
            status = "共享未启动：\(error.localizedDescription)"
            if interactive { self.error = error.localizedDescription }
        }
    }

    private func accept(_ connection: NWConnection, generation token: UUID, admission: PendingHandshakeGate, id: UUID) {
        let diagnostics = PerformanceDiagnostics()
        let candidate = Peer(connection: connection, handshakeTimeout: peer == nil ? 15 : 5, diagnostics: diagnostics)
        let channel = makeDataChannel(for: candidate)
        let session = makeTrafficSession(for: candidate)
        let history = trafficHistoryStore
        pending[id] = candidate
        candidate.onReady = { [weak self, weak candidate] in
            admission.release(id)
            DispatchQueue.main.async {
                guard let self, let candidate, self.pending.removeValue(forKey: id) != nil,
                      self.generation == token, self.active, self.hostingRequested else { return }
                guard self.peer == nil else { candidate.close("这台 Mac 当前已有控制连接"); return }
                DiagnosticLog.shared.record(.connectionReady, role: .host, state: .ready)
                self.peer = candidate
                self.attachPerformanceDiagnostics(diagnostics, role: .host)
                self.dataChannel = channel
                self.trafficSession = session
                self.trafficHistoryStatus = "等待远端设备标识；旧版设备需双方升级后才能累计。"
                self.status = "正在准备连接画面…"
                let host = self.hostSession
                host.captureTask = Task { [weak self, weak candidate, weak host] in
                    guard let self, let candidate, let host, self.hostSession === host else { return }
                    do {
                        await self.effectsCleanupTask?.value
                        guard self.generation == token, self.peer === candidate, self.hostSession === host, !Task.isCancelled else { return }
                        self.installHostSessionEffects(for: candidate)
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        guard self.generation == token, self.active, self.peer === candidate, self.hostSession === host, !Task.isCancelled else { return }
                        self.refreshDisplays()
                        let (display, snapshot) = try self.selectShareableDisplay(content.displays)
                        let preferredSettings = self.settings
                        let settings = preferredSettings.legacyCompatible
                        let capture = ScreenStreamer.prepareCapture(display: display, settings: settings)
                        let (width, height) = (capture.width, capture.height)
                        host.capturedDisplay = snapshot
                        self.connected = true
                        self.canControl = AXIsProcessTrusted()
                        self.status = self.canControl ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（未授权辅助功能）"
                        self.resolution = "\(width) × \(height)"
                        let state = VideoStreamState(settings: settings, width: width, height: height)
                        self.activeVideoState = state
                        self.recordVideoConfiguration(state)
                        host.injector = InputInjector(displayID: display.displayID)
                        host.deviceIdentityAdvertised = self.trafficHistoryStore.localDeviceID != nil
                        candidate.send(try Wire.json(.hello, Hello(name: Host.current().localizedName ?? "家里 Mac",
                            width: width, height: height, settings: settings, canControl: self.canControl,
                            preferredSettings: preferredSettings.extendedCompatible, deviceID: self.trafficHistoryStore.localDeviceID,
                            deviceIdentityExchange: host.deviceIdentityAdvertised ? true : nil,
                            highRefreshVideoSettings: true, preferredHighRefreshSettings: preferredSettings,
                            sessionEffects: true, sessionPause: true)))
                        let streamer = ScreenStreamer(diagnostics: diagnostics)
                        host.streamer = streamer
                        channel.configureAcknowledgement { [weak streamer] in streamer?.acknowledge($0) }
                        streamer.onFrame = { [weak candidate] packet in
                            guard let candidate else { return }
                            do {
                                candidate.send(Message(.video, try packet.encode()))
                                channel.recordFrame()
                            } catch { candidate.close(error.localizedDescription) }
                        }
                        streamer.onDiagnosticError = { [weak self, weak candidate, weak host] error in
                            DispatchQueue.main.async {
                                guard let self, let candidate, let host, self.peer === candidate, self.hostSession === host else { return }
                                self.recordDiagnosticFailure(.captureFailed, error: error)
                            }
                        }
                        streamer.onError = { [weak candidate] in candidate?.close($0, retryable: true) }
                        streamer.onUserStop = { [weak self, weak candidate, weak host] in
                            DispatchQueue.main.async {
                                guard let self, let candidate, let host, self.peer === candidate, self.hostSession === host else { return }
                                self.recordDisconnect("用户从系统停止了屏幕共享")
                                self.stop()
                            }
                        }
                        try await streamer.start(capture)
                        guard self.generation == token, self.active, self.peer === candidate, self.hostSession === host, !Task.isCancelled else {
                            await streamer.stop()
                            return
                        }
                        DiagnosticLog.shared.record(.captureStarted, role: .host, state: .ready,
                            values: [.width: width, .height: height, .pixelWidth: capture.sourceWidth,
                                     .pixelHeight: capture.sourceHeight, .logicalWidth: Int(snapshot.bounds.width),
                                     .logicalHeight: Int(snapshot.bounds.height)])
                    } catch {
                        guard self.generation == token, self.active, self.peer === candidate, self.hostSession === host, !Task.isCancelled else { return }
                        self.recordDiagnosticFailure(.captureFailed, error: error)
                        if host.capturedDisplay == nil { self.restartHostAfterFailure("共享准备失败：\(error.localizedDescription)") }
                        else { candidate.close(error.localizedDescription, retryable: true) }
                    }
                }
            }
        }
        candidate.onMessageHandled = { [weak self, weak candidate] message, resume in
            do {
                if try channel.receive(message) { resume(); return }
            } catch { candidate?.close(error.localizedDescription); resume(); return }
            DispatchQueue.main.async {
                defer { resume() }
                guard let self, let candidate, self.generation == token, self.active, self.peer === candidate else { return }
                guard self.connected else { candidate.close("屏幕共享尚未就绪", retryable: true); return }
                do { try self.handleHost(message, peer: candidate) }
                catch {
                    self.recordDiagnosticFailure(.connectionFailed, error: error)
                    candidate.close(error.localizedDescription)
                }
            }
        }
        candidate.onClose = { [weak self, weak candidate] reason in
            admission.release(id)
            history.requestFlush()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.removeValue(forKey: id)
                if let candidate, self.generation == token, self.peer === candidate {
                    self.recordDisconnect(reason)
                    self.clearSession()
                    self.status = self.active ? "等待重新连接 · \(reason)" : "共享已停止"
                }
            }
        }
        candidate.onTraffic = { channel.recordBytes($0) }
        candidate.start()
    }

    func connect() {
        guard !active, !working else { return }
        connectionError = nil
        do {
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !address.contains("://"), !address.contains("/") else {
                throw DeskError.invalid("请输入域名或 IP，端口填在单独的端口栏")
            }
            let key = try PairingKey(code: viewerCode)
            let port = try validPort()
            UserDefaults.standard.set(address, forKey: "remoteAddress")
            UserDefaults.standard.set(self.port, forKey: "remotePort")
            let record = ConnectionStore.matching(connections, address: address, port: port.rawValue, preferredID: selectedConnectionID)
            let target = Target(address: address, port: port.rawValue, key: key, recordID: record?.id)
            self.target = target
            idlePolicy = SessionIdlePolicy(now: SessionClock.now)
            _ = idlePolicy.focusChanged(now: SessionClock.now, focused: sessionWindowFocused, suppressWake: true)
            pauseTransmission = SessionPauseTransmission()
            wakeInputGate = SessionWakeInputGate()
            reconnectDeferredForIdle = false
            freshFrameRequiredOnReconnect = false
            let saved = record?.videoSettings
            viewerQualityPolicy = ViewerQualityPolicy(preferred: saved.flatMap { (try? $0.validateControlValues()) != nil ? $0 : nil })
            savedTarget = false
            retryBackoff.reset()
            generation = UUID()
            beginMetrics()
            beginConnection(target)
        } catch {
            recordDiagnosticFailure(.connectionFailed, error: error)
            self.connectionError = error.localizedDescription
        }
    }

    private func makeDataChannel(for peer: Peer) -> SessionDataChannel {
        let viewer = viewerSession
        return SessionDataChannel(send: { [weak peer] in peer?.send($0) }) { [weak self, weak peer, weak viewer] token in
            DispatchQueue.main.async {
                guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                      self.pauseTransmission.decodedFreshFrame(token: token) else { return }
                self.dataChannel?.expectFreshFrame(nil)
                viewer.pauseRequestTimeout?.cancel()
                self.sessionPauseStatus = ""
                self.freshFrameRequiredOnReconnect = false
                self.publishSessionPause()
                if viewer.restoreCanvasFocusAfterIdle, self.sessionWindowFocused, self.canControl,
                   let window = self.mainWindow, NSApp.keyWindow === window,
                   window.firstResponder == nil || window.firstResponder === window || window.firstResponder === self.canvas {
                    window.makeFirstResponder(self.canvas)
                }
                viewer.restoreCanvasFocusAfterIdle = false
            }
        }
    }

    private func beginConnection(_ target: Target) {
        guard peer == nil, !systemSleeping else { return }
        if reconnecting {
            _ = idlePolicy.tick(now: SessionClock.now)
            if idlePolicy.isPaused { deferReconnectForIdle("10 分钟无窗口操作"); return }
        }
        let diagnostics = PerformanceDiagnostics(enabled: performanceDiagnosticsEnabled)
        let candidate = Peer(connection: NWConnection(host: NWEndpoint.Host(target.address),
            port: NWEndpoint.Port(rawValue: target.port)!, using: SecureTransport.parameters(key: target.key)), diagnostics: diagnostics)
        attachPerformanceDiagnostics(diagnostics, role: .viewer)
        DiagnosticLog.shared.record(.connectionStarted, role: .viewer, state: .requested)
        trafficSession = makeTrafficSession(for: candidate)
        let history = trafficHistoryStore
        currentTrafficDeviceID = nil
        trafficHistoryStatus = "等待远端设备标识；旧版设备需双方升级后才能累计。"
        peer = candidate
        let channel = makeDataChannel(for: candidate)
        dataChannel = channel
        active = true
        working = true
        let viewer = viewerSession
        viewer.helloReceived = false
        candidate.onRoundTripMilliseconds = { [weak self, weak candidate, weak viewer] milliseconds in
            DispatchQueue.main.async {
                guard let self, let candidate, let viewer, self.peer === candidate, self.viewerSession === viewer else { return }
                self.roundTripMilliseconds = milliseconds
                if let microseconds = Int(exactly: (milliseconds * 1_000).rounded()), microseconds >= 0 {
                    DiagnosticLog.shared.record(.connectionMetrics, role: .viewer, values: [.roundTripMicroseconds: microseconds])
                }
                self.latency = String(format: milliseconds < 10 ? "%.1f ms" : "%.0f ms", milliseconds)
                viewer.lastLatencyAt = SessionClock.now
                self.viewerQualityPolicy.observeRoundTrip(milliseconds)
                self.applyInitialVideoQualityIfReady()
            }
        }
        status = reconnecting ? "正在重新建立加密连接…" : "正在建立加密连接…"
        candidate.onReady = { [weak self, weak candidate] in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                DiagnosticLog.shared.record(.connectionReady, role: .viewer, state: .ready)
                self.status = "连接已加密，等待画面…"
            }
        }
        candidate.onMessageHandled = { [weak self, weak candidate] message, resume in
            do {
                if try channel.receive(message) { resume(); return }
            } catch { candidate?.close(error.localizedDescription); resume(); return }
            DispatchQueue.main.async {
                defer { resume() }
                guard let self, let candidate, self.peer === candidate else { return }
                do {
                    try self.handleViewer(message, peer: candidate)
                    channel.expectFreshFrame(self.pauseTransmission.freshFrameToken)
                } catch {
                    self.recordDiagnosticFailure(.connectionFailed, error: error)
                    candidate.close(error.localizedDescription)
                }
            }
        }
        candidate.onTraffic = { channel.recordBytes($0) }
        candidate.onClose = { [weak self, weak candidate] reason in
            history.requestFlush()
            let retryable = candidate?.closeIsRetryable == true
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                self.recordDisconnect(reason)
                self.clearSession()
                if retryable, self.autoReconnect, self.target != nil {
                    self.scheduleReconnect(reason)
                } else {
                    self.stop()
                    self.status = reason
                    self.connectionError = reason
                }
            }
        }
        candidate.start()
    }

    private func scheduleReconnect(_ reason: String) {
        reconnectTask?.cancel()
        guard !systemSleeping else { return }
        _ = idlePolicy.tick(now: SessionClock.now)
        if idlePolicy.isPaused {
            deferReconnectForIdle(reason)
            return
        }
        let delay = retryBackoff.next()
        DiagnosticLog.shared.record(.reconnectScheduled, role: .viewer, state: .requested,
            values: [.retryAttempt: retryBackoff.attempt])
        let token = generation
        active = true
        working = true
        reconnecting = true
        status = "\(Int(delay)) 秒后第 \(retryBackoff.attempt) 次重连 · \(reason)"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token, let target = self.target, self.autoReconnect,
                  !Task.isCancelled, self.peer == nil else { return }
            self.beginConnection(target)
        }
    }

    private func deferReconnectForIdle(_ reason: String) {
        reconnectTask?.cancel()
        active = true; working = false; reconnecting = true
        reconnectDeferredForIdle = true
        pauseTransmission.choose(paused: true)
        sessionPaused = true
        sessionPauseStatus = "空闲暂停 · 返回此窗口后继续重连"
        status = "连接已断开，空闲暂停期间不在后台重连 · \(reason)"
    }

    func quickConnect(_ record: ConnectionRecord) {
        guard !active, !working else { return }
        address = record.address
        port = String(record.port)
        selectedConnectionID = record.id
        viewerCode = ""
        connectionError = nil
        do {
            guard let key = try KeyStore.load(account: "remote." + record.id.uuidString) else {
                throw DeskError.invalid("此记录尚未保存到本机凭据文件。请在上方补录原配对码后连接；成功后会记住，无需读取钥匙串")
            }
            viewerCode = key.code
            connect()
        } catch { self.connectionError = error.localizedDescription }
    }

    func removeConnection(_ record: ConnectionRecord) {
        do {
            try KeyStore.remove(account: "remote." + record.id.uuidString)
            connections.removeAll { $0.id == record.id }
            if selectedConnectionID == record.id { selectedConnectionID = nil }
            try ConnectionStore.save(connections)
        } catch { self.error = error.localizedDescription }
    }

    private func saveConnection(name: String) {
        guard !savedTarget, let target else { return }
        do {
            var record = ConnectionStore.matching(connections, address: target.address, port: target.port, preferredID: target.recordID)
                ?? ConnectionRecord(address: target.address, port: target.port, name: name)
            record.name = name
            record.lastConnected = Date()
            try KeyStore.save(target.key, account: "remote." + record.id.uuidString)
            connections.removeAll { $0.id == record.id }
            connections.insert(record, at: 0)
            try ConnectionStore.save(connections)
            savedTarget = true
        } catch { self.error = "已连接，但快捷连接保存失败：\(error.localizedDescription)" }
    }

    private func recordDisconnect(_ reason: String) {
        DiagnosticLog.shared.record(.connectionClosed, role: diagnosticRole)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        lastDisconnect = "\(time) · \(reason)"
        UserDefaults.standard.set(lastDisconnect, forKey: "lastDisconnect")
    }

    private func handleHost(_ message: Message, peer: Peer) throws {
        switch message.kind {
        case .sessionPauseRequest:
            applyHostSessionPause(try Wire.readJSON(SessionPauseRequest.self, message.payload), peer: peer)
        case .sessionEffectsRequest:
            applyHostSessionEffects(try Wire.readJSON(SessionEffectsRequest.self, message.payload), peer: peer)
        case .deviceIdentity:
            guard hostSession.deviceIdentityAdvertised, let trafficSession,
                  trafficSession.connectionID == peer.trafficMeter.connectionID else {
                throw DeskError.invalid("当前连接未启用设备标识交换")
            }
            let identity = try Wire.readJSON(DeviceIdentity.self, message.payload)
            try trafficSession.bind(identity)
            currentTrafficDeviceID = identity.id
            trafficHistoryStatus = "历史流量已按远端设备持续累计。"
        case .controlStatus:
            guard message.payload.isEmpty else { throw DeskError.invalid("控制权限订阅消息无效") }
            refreshPermissions()
            controlStatusUpdatesEnabled = true
            status = canControl ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（辅助功能未生效）"
            peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: canControl)))
        case .acknowledgement:
            guard message.payload.count == 4 else { throw DeskError.invalid("画面确认无效") }
            var reader = ByteReader(message.payload)
            hostSession.streamer?.acknowledge(try reader.take() as UInt32)
        case .input:
            let input = try Wire.readJSON(RemoteInput.self, message.payload)
            try input.validate()
            if input.kind == .scroll {
                DiagnosticLog.shared.count(.scrollReceived)
                if !canControl || hostSession.paused || hostSession.pauseTask != nil { DiagnosticLog.shared.count(.scrollSuppressed) }
            }
            if canControl, !hostSession.paused, hostSession.pauseTask == nil, let feedback = try hostSession.injector?.receive(input) {
                peer.send(try Wire.json(.inputStatus, feedback))
            }
        case .releaseInput: hostSession.injector?.releaseAll()
        case .clipboard: try receiveClipboard(message.payload)
        case .requestClipboard: sendClipboard(to: peer)
        case .clipboardSettings:
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard let session = preference.session, clipboardSession == nil || clipboardSession == session else {
                throw DeskError.invalid("剪贴板会话无效")
            }
            clipboardSession = session
            let first = !supportsClipboard
            supportsClipboard = true
            remoteClipboardEnabled = preference.enabled
            remoteFileApproval = preference.fileApproval == true
            remoteClipboardChunkWindow = preference.chunkWindow == true
            remoteReceivesAutomaticClipboard = preference.receivesAutomaticUpdates ?? true
            remoteClipboardFocusAware = preference.receivesAutomaticUpdates != nil
            if first { try sendClipboardPreference(to: peer) }
            updateClipboardSync()
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            clipboardSync?.receive(message)
        case .streamSettingsRequest:
            let request = try Wire.readJSON(StreamSettingsRequest.self, message.payload)
            applyHostVideoSettings(request, peer: peer)
        default: throw DeskError.invalid("收到当前角色不支持的消息")
        }
    }

    private func handleViewer(_ message: Message, peer: Peer) throws {
        switch message.kind {
        case .hello:
            guard !viewerSession.helloReceived else { throw DeskError.invalid("重复的会话信息") }
            let hello = try Wire.readJSON(Hello.self, message.payload)
            try hello.validate()
            if reconnecting, idlePolicy.isPaused || idlePolicy.tick(now: SessionClock.now) {
                clearSession()
                peer.close("空闲暂停，返回窗口后继续连接")
                deferReconnectForIdle("连接恢复前已达到空闲时限")
                return
            }
            viewerSession.helloReceived = true
            dataChannel?.configureVideo(canvas.makeVideoReceiver(diagnostics: performanceDiagnostics))
            connected = true
            working = false
            remoteName = hello.name
            reconnecting = false
            supportsSessionPause = hello.sessionPause == true
            if !supportsSessionPause {
                idlePolicy.synchronize(paused: false, now: SessionClock.now)
                pauseTransmission = SessionPauseTransmission()
            } else if idlePolicy.tick(now: SessionClock.now) {
                pauseTransmission.choose(paused: true)
            }
            if freshFrameRequiredOnReconnect { pauseTransmission.requireFreshFrame() }
            saveConnection(name: hello.name)
            if let id = hello.deviceID, let trafficSession {
                try trafficSession.bind(DeviceIdentity(id: id, name: hello.name))
                currentTrafficDeviceID = id
                trafficHistoryStatus = "历史流量已按远端设备持续累计。"
            } else { trafficHistoryStatus = "对端没有设备标识，仅显示瞬时流量；双方升级后可累计历史。" }
            if hello.deviceIdentityExchange == true, let id = trafficHistoryStore.localDeviceID {
                peer.send(try Wire.json(.deviceIdentity, DeviceIdentity(id: id, name: Host.current().localizedName ?? "这台 Mac")))
            }
            let viewer = viewerSession
            viewer.stableTask?.cancel()
            viewer.stableTask = Task { [weak self, weak peer, weak viewer] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer else { return }
                self.retryBackoff.reset()
            }
            supportsClipboard = hello.clipboardSync == true
            if supportsClipboard {
                clipboardSession = UUID()
                try sendClipboardPreference(to: peer)
            } else {
                clipboardStatus = "对端版本较旧，可使用手动文字同步；图片和文件需两端升级到 0.3.0"
            }
            canControl = hello.canControl
            supportsInputActions = hello.inputActions == true
            canvas.canControl = hello.canControl
            controlStatusUpdatesEnabled = hello.controlStatusUpdates == true
            if controlStatusUpdatesEnabled { peer.send(Message(.controlStatus)) }
            refreshPermissions(retryCapsLock: true)
            canvas.remoteSize = CGSize(width: hello.width, height: hello.height)
            resolution = "\(hello.width) × \(hello.height)"
            status = hello.canControl ? "已连接 · 点击画面开始操作" : "已连接 · 仅观看（家里 Mac 需开启辅助功能）"
            let state = VideoStreamState(settings: hello.settings, width: hello.width, height: hello.height)
            activeVideoState = state
            recordVideoConfiguration(state)
            supportsLiveSettings = hello.liveSettings == true
            supportsExtendedVideoSettings = supportsLiveSettings && hello.extendedVideoSettings == true
            supportsHighRefreshVideoSettings = supportsExtendedVideoSettings && hello.highRefreshVideoSettings == true
            supportsSessionEffects = hello.sessionEffects == true
            if supportsLiveSettings {
                let hostDefault = supportsHighRefreshVideoSettings ? (hello.preferredHighRefreshSettings ?? hello.preferredSettings ?? hello.settings)
                    : supportsExtendedVideoSettings ? (hello.preferredSettings ?? hello.settings) : hello.settings
                let preferred = viewerQualityPolicy.settingsForConnection(hostDefault: hostDefault, supportsExtended: supportsExtendedVideoSettings,
                                                                         supportsHighRefresh: supportsHighRefreshVideoSettings)
                videoTuning = try VideoTuningSession(applied: state, preferred: preferred)
                videoSettingsStatus = "当前生效：\(state.settings.summary)"
                applyInitialVideoQualityIfReady()
                sendNextVideoSettings()
            } else { videoSettingsStatus = "主机需更新到 0.4.0 才能动态调整画质" }
            publishSessionPause()
            sendNextSessionPause()
            if let token = pauseTransmission.freshFrameToken { scheduleFreshFrameTimeout(token, peer: peer) }
        case .sessionPauseResult:
            guard viewerSession.helloReceived, supportsSessionPause else { throw DeskError.invalid("当前连接未启用空闲暂停") }
            let result = try Wire.readJSON(SessionPauseResult.self, message.payload)
            let oldRequest = pauseTransmission.pending
            guard pauseTransmission.receive(result) else { return }
            DiagnosticLog.shared.record(result.paused ? .sessionPaused : .sessionResumed, role: .viewer,
                state: result.error == nil ? .succeeded : .failed)
            viewerSession.pauseRequestTimeout?.cancel()
            if let error = result.error {
                sessionPauseStatus = "暂停/恢复失败：\(error)"
                if !result.paused, oldRequest?.paused == true { self.error = "空闲暂停失败，画面仍在传输：\(error)" }
                if oldRequest?.paused == idlePolicy.isPaused {
                    idlePolicy.synchronize(paused: result.paused, now: SessionClock.now)
                }
            } else { sessionPauseStatus = result.paused ? "空闲暂停 · 加密会话仍保持" : "正在等待恢复后的新画面…" }
            publishSessionPause()
            sendNextSessionPause()
            if let token = pauseTransmission.freshFrameToken { scheduleFreshFrameTimeout(token, peer: peer) }
        case .sessionEffectsResult:
            guard viewerSession.helloReceived, supportsSessionEffects else { throw DeskError.invalid("当前连接未启用被控端设置") }
            let result = try Wire.readJSON(SessionEffectsResult.self, message.payload)
            guard result.id == nil || result.id == viewerSession.effectsRequestID else { return }
            sessionEffects = result.state
            DiagnosticLog.shared.record(.sessionEffectsChanged, role: .viewer, state: result.error == nil ? .succeeded : .failed)
            sessionEffectsStatus = result.error ?? "被控端设置已生效"
            if result.id != nil {
                viewerSession.effectsRequestTimeout?.cancel()
                viewerSession.effectsRequestID = nil
                sessionEffectsWorking = false
            }
        case .controlStatus:
            guard viewerSession.helloReceived, controlStatusUpdatesEnabled else { throw DeskError.invalid("对端不支持控制权限更新") }
            let permission = try Wire.readJSON(ControlStatus.self, message.payload)
            if canControl != permission.canControl {
                if !permission.canControl { canvas.releaseControl() }
                canControl = permission.canControl
                canvas.canControl = permission.canControl
                canvas.usesCapsLockActions = capsLockRunning && capsLockEnabled && supportsInputActions && canControl && !sessionInputSuspended
                status = permission.canControl ? "已连接 · 辅助功能已生效，点击画面开始操作" : "已连接 · 仅观看（家里 Mac 的辅助功能未生效）"
            }
        case .video:
            throw DeskError.invalid("视频会话尚未就绪")
        case .clipboard:
            guard viewerSession.helloReceived else { throw DeskError.invalid("缺少会话信息") }
            try receiveClipboard(message.payload)
        case .clipboardSettings:
            guard supportsClipboard else { throw DeskError.invalid("对端不支持自动剪贴板") }
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard preference.session == clipboardSession else { throw DeskError.invalid("剪贴板会话不匹配") }
            remoteClipboardEnabled = preference.enabled
            remoteFileApproval = preference.fileApproval == true
            remoteClipboardChunkWindow = preference.chunkWindow == true
            remoteReceivesAutomaticClipboard = preference.receivesAutomaticUpdates ?? true
            remoteClipboardFocusAware = preference.receivesAutomaticUpdates != nil
            updateClipboardSync()
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            clipboardSync?.receive(message)
        case .inputStatus:
            guard viewerSession.helloReceived, supportsInputActions else { throw DeskError.invalid("不支持的键盘状态消息") }
            inputStatus = try Wire.readJSON(InputFeedback.self, message.payload).message
        case .streamSettingsResult:
            guard viewerSession.helloReceived, supportsLiveSettings, var tuning = videoTuning else { throw DeskError.invalid("对端不支持动态画质") }
            let result = try Wire.readJSON(StreamSettingsResult.self, message.payload)
            guard try tuning.receive(result) else { return }
            viewerSession.videoRequestTimeout?.cancel()
            videoTuning = tuning
            activeVideoState = result.state
            recordVideoConfiguration(result.state, succeeded: result.error == nil)
            canvas.remoteSize = CGSize(width: result.state.width, height: result.state.height)
            resolution = "\(result.state.width) × \(result.state.height)"
            if let error = result.error { videoSettingsStatus = "调整失败：\(error)" }
            else {
                videoSettingsStatus = "已生效：\(result.state.settings.summary)"
                if viewerQualityPolicy.confirm(result.state.settings, maySave: viewerSession.pendingVideoPreferenceCanSave) {
                    saveVideoPreference(result.state.settings)
                }
            }
            sendNextVideoSettings()
        default: throw DeskError.invalid("收到当前角色不支持的消息")
        }
    }

    func chooseViewerSettings(_ settings: StreamSettings) {
        guard connected, supportsLiveSettings, var tuning = videoTuning else { return }
        guard supportsExtendedVideoSettings || settings == settings.legacyCompatible else {
            videoSettingsStatus = "共享端需更新后才能使用原分辨率和 30 Mbps"
            return
        }
        guard supportsHighRefreshVideoSettings || settings == settings.extendedCompatible else {
            videoSettingsStatus = "60 fps 与 60/100 Mbps 需两端更新后使用"
            return
        }
        do { try tuning.choose(settings) }
        catch { videoSettingsStatus = error.localizedDescription; return }
        viewerQualityPolicy.chooseManually()
        if tuning.pending?.settings == settings { viewerSession.pendingVideoPreferenceCanSave = true }
        videoTuning = tuning
        viewerSession.videoDebounceTask?.cancel()
        if tuning.pending == nil, tuning.applied.settings == settings {
            _ = viewerQualityPolicy.confirm(settings, maySave: true)
            saveVideoPreference(settings)
            return
        }
        let viewer = viewerSession
        viewer.videoDebounceTask = Task { [weak self, weak viewer] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let viewer, self.viewerSession === viewer else { return }
            self.sendNextVideoSettings()
        }
    }

    private func applyInitialVideoQualityIfReady() {
        guard connected, supportsLiveSettings, var tuning = videoTuning,
              let settings = viewerQualityPolicy.takeInitialAutomaticSettings(supportsExtended: supportsExtendedVideoSettings,
                                                                              supportsHighRefresh: supportsHighRefreshVideoSettings) else { return }
        do { try tuning.choose(settings) }
        catch { videoSettingsStatus = error.localizedDescription; return }
        videoTuning = tuning
        sendNextVideoSettings()
    }

    func setRemoteMuted(_ enabled: Bool) {
        requestSessionEffects(SessionEffectsState(muted: enabled, privacy: sessionEffects.privacy))
    }

    func setRemotePrivacy(_ enabled: Bool) {
        requestSessionEffects(SessionEffectsState(muted: sessionEffects.muted, privacy: enabled))
    }

    private func requestSessionEffects(_ desired: SessionEffectsState) {
        guard connected, supportsSessionEffects, !sessionEffectsWorking, let peer else { return }
        let viewer = viewerSession
        let request = SessionEffectsRequest(state: desired)
        viewerSession.effectsRequestID = request.id
        sessionEffectsWorking = true
        sessionEffectsStatus = "正在应用被控端设置…"
        do { peer.send(try Wire.json(.sessionEffectsRequest, request)) }
        catch { sessionEffectsWorking = false; viewerSession.effectsRequestID = nil; sessionEffectsStatus = error.localizedDescription; return }
        viewerSession.effectsRequestTimeout?.cancel()
        viewer.effectsRequestTimeout = Task { [weak self, weak peer, weak viewer] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                  viewer.effectsRequestID == request.id else { return }
            peer.close("被控端设置超过 15 秒未确认，已断开以恢复本机状态", retryable: true)
        }
    }

    private func installHostSessionEffects(for peer: Peer) {
        let host = hostSession
        let effects = HostSessionEffects()
        host.effects = effects
        effects.onStateChange = { [weak self, weak peer, weak effects, weak host] state, message in
            guard let self, let peer, let effects, let host, self.peer === peer, self.hostSession === host, host.effects === effects else { return }
            self.sessionEffects = state
            if let message { self.sessionEffectsStatus = message }
            if let result = try? Wire.json(.sessionEffectsResult, SessionEffectsResult(state: state, error: message)) { peer.send(result) }
            if !state.privacy, host.effectsTask == nil, let streamer = host.streamer {
                let token = self.generation
                host.effectsTask = Task { [weak self, weak peer, weak host] in
                    guard let self, let peer, let host, self.hostSession === host else { return }
                    defer { if self.generation == token, self.peer === peer, self.hostSession === host { host.effectsTask = nil } }
                    do { try await streamer.setExcludesCurrentApplication(false) }
                    catch {
                        guard self.generation == token, self.peer === peer, self.hostSession === host else { return }
                        self.sessionEffectsStatus = error.localizedDescription
                        peer.close("防窥已退出，但采集恢复失败，正在重建共享：\(error.localizedDescription)", retryable: true)
                    }
                }
            }
        }
    }

    private func applyHostSessionEffects(_ request: SessionEffectsRequest, peer: Peer) {
        let host = hostSession
        guard let effects = host.effects, let streamer = host.streamer else { return }
        guard host.effectsTask == nil else {
            if let reply = try? Wire.json(.sessionEffectsResult, SessionEffectsResult(id: request.id, state: effects.state,
                error: "正在处理上一项被控端设置")) { peer.send(reply) }
            return
        }
        let token = generation
        let capture = host.captureTask
        host.effectsTask = Task { [weak self, weak peer, weak host] in
            guard let self, let peer, let host, self.hostSession === host else { return }
            defer { if self.generation == token, self.peer === peer, self.hostSession === host { host.effectsTask = nil } }
            var failure: String?
            var filterRestoreFailed = false
            do {
                await capture?.value
                try Task.checkCancellation()
                _ = try await effects.apply(request.state) { try await streamer.setExcludesCurrentApplication(true) }
            } catch { failure = error.localizedDescription }
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.effects === effects, !Task.isCancelled else { return }
            if !effects.state.privacy {
                do { try await streamer.setExcludesCurrentApplication(false) }
                catch { failure = failure ?? error.localizedDescription; filterRestoreFailed = true }
            }
            guard self.generation == token, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
            self.sessionEffects = effects.state
            self.sessionEffectsStatus = failure ?? "被控端设置已生效"
            if let reply = try? Wire.json(.sessionEffectsResult, SessionEffectsResult(id: request.id, state: effects.state, error: failure)) { peer.send(reply) }
            if filterRestoreFailed { peer.close("采集过滤器恢复失败，正在重建共享：\(failure ?? "未知错误")", retryable: true) }
        }
    }

    private func sendNextVideoSettings() {
        guard connected, supportsLiveSettings, let peer, var tuning = videoTuning,
              let request = tuning.nextRequest() else { return }
        videoTuning = tuning
        viewerSession.pendingVideoPreferenceCanSave = viewerQualityPolicy.maySaveCurrentChoice
        videoSettingsStatus = "正在应用：\(request.settings.summary)"
        do { peer.send(try Wire.json(.streamSettingsRequest, request)) }
        catch { videoSettingsStatus = error.localizedDescription; peer.close(error.localizedDescription); return }
        viewerSession.videoRequestTimeout?.cancel()
        let viewer = viewerSession
        viewer.videoRequestTimeout = Task { [weak self, weak peer, weak viewer] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                  self.videoTuning?.pending?.id == request.id else { return }
            peer.close("画质调整超过 25 秒未确认，重新建立共享", retryable: true)
        }
    }

    private func saveVideoPreference(_ settings: StreamSettings) {
        guard let target,
              let record = ConnectionStore.matching(connections, address: target.address, port: target.port, preferredID: target.recordID),
              let index = connections.firstIndex(where: { $0.id == record.id }) else { return }
        connections[index].videoSettings = settings
        do { try ConnectionStore.save(connections) }
        catch { videoSettingsStatus = "画质已生效，但保存记录失败：\(error.localizedDescription)" }
    }

    func resumeSession() { recordSessionActivity() }

    private var sessionWindowFocused: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow else { return false }
        return belongsToSessionWindow(key)
    }

    private func belongsToSessionWindow(_ window: NSWindow) -> Bool {
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === mainWindow { return true }
            current = candidate.sheetParent ?? candidate.parent
        }
        return false
    }

    private func observeSessionEvent(_ event: NSEvent) -> NSEvent? {
        if mode == .viewer, event.type == .scrollWheel, let window = event.window,
           canvas.window === window, canvas.bounds.contains(canvas.convert(event.locationInWindow, from: nil)) {
            DiagnosticLog.shared.count(.scrollObserved)
        }
        guard mode == .viewer, supportsSessionPause || idlePolicy.isPaused || reconnecting,
              let window = event.window, belongsToSessionWindow(window) else { return event }
        let wasSuspended = sessionInputSuspended
        let windowWasFocused = sessionWindowFocused
        recordSessionActivity()
        let kind: RemoteInput.Kind
        switch event.type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flags
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .drag
        case .scrollWheel: kind = .scroll
        default: kind = .move
        }
        var input = RemoteInput(kind: kind)
        let keyboard = kind == .keyDown || kind == .keyUp || kind == .flags
        if keyboard { input.keyCode = event.keyCode }
        else if kind == .down || kind == .up || kind == .drag {
            input.button = min(2, max(0, event.buttonNumber))
        }
        input.flags = UInt64(event.modifierFlags.rawValue)
        let allowed = wakeInputGate.allows(input, suspended: wasSuspended || sessionInputSuspended || !connected)
        let remoteTarget = keyboard ? window.firstResponder === canvas
            : canvas.window === window && canvas.bounds.contains(canvas.convert(event.locationInWindow, from: nil))
        // AppKit must still receive the click that activates an inactive window.
        if !allowed && remoteTarget && windowWasFocused && kind == .scroll { DiagnosticLog.shared.count(.scrollSuppressed) }
        return !allowed && remoteTarget && windowWasFocused ? nil : event
    }

    private func dismissClipboardPrompt() {
        guard let clipboardFilePrompt else { return }
        suppressIdleFocusWake = true
        clipboardFilePrompt.dismiss()
        sessionWindowFocusChanged()
    }

    func sessionWindowFocusChanged() {
        focusRefreshTask?.cancel()
        focusRefreshTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            if NSApp.isActive, NSApp.keyWindow == nil, let window = self.mainWindow,
               window.isVisible, !window.isMiniaturized { return }
            let resumed = self.idlePolicy.focusChanged(now: SessionClock.now,
                focused: self.sessionWindowFocused, suppressWake: self.suppressIdleFocusWake)
            self.suppressIdleFocusWake = false
            if resumed { self.resumeIdleTransmission() }
        }
    }

    private func recordSessionActivity() {
        guard mode == .viewer, supportsSessionPause || idlePolicy.isPaused || reconnecting,
              sessionWindowFocused else { return }
        if idlePolicy.activity(now: SessionClock.now, focused: true) { resumeIdleTransmission() }
    }

    private func resumeIdleTransmission() {
        guard mode == .viewer else { return }
        pauseTransmission.choose(paused: false)
        sessionPauseStatus = "正在恢复画面…"
        publishSessionPause()
        if reconnectDeferredForIdle, autoReconnect, let target {
            reconnectDeferredForIdle = false
            freshFrameRequiredOnReconnect = true
            pauseTransmission.requireFreshFrame()
            beginConnection(target)
        } else { sendNextSessionPause() }
    }

    private func publishSessionPause() {
        if mode == .viewer {
            sessionPaused = idlePolicy.isPaused || pauseTransmission.desiredPaused || pauseTransmission.appliedPaused
            sessionPauseWorking = pauseTransmission.pending != nil || pauseTransmission.freshFrameToken != nil
        } else { sessionPaused = hostSession.paused; sessionPauseWorking = hostSession.pauseTask != nil }
        canvas.updateSystemShortcutCapture(sessionActive: mode == .viewer && connected && canControl && !sessionInputSuspended,
            accessibility: localAccessibility, inputMonitoring: localInputMonitoring)
        canvas.usesCapsLockActions = capsLockRunning && capsLockEnabled && supportsInputActions && canControl && !sessionInputSuspended
        refreshClipboardFocus()
    }

    private func sendNextSessionPause() {
        guard mode == .viewer, connected, supportsSessionPause, let peer,
              let request = pauseTransmission.nextRequest() else { return }
        publishSessionPause()
        canvas.releaseControl()
        do { peer.send(try Wire.json(.sessionPauseRequest, request)) }
        catch { peer.close(error.localizedDescription); return }
        viewerSession.pauseRequestTimeout?.cancel()
        let viewer = viewerSession
        viewer.pauseRequestTimeout = Task { [weak self, weak peer, weak viewer] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                  self.pauseTransmission.pending?.id == request.id else { return }
            peer.close("暂停/恢复超过 25 秒未确认，重新建立会话", retryable: true)
        }
    }

    private func scheduleFreshFrameTimeout(_ token: UUID, peer: Peer) {
        viewerSession.pauseRequestTimeout?.cancel()
        let viewer = viewerSession
        viewer.pauseRequestTimeout = Task { [weak self, weak peer, weak viewer] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                  self.pauseTransmission.freshFrameToken == token else { return }
            peer.close("恢复后超过 25 秒未收到新关键帧，重新建立会话", retryable: true)
        }
    }

    private func applyHostSessionPause(_ request: SessionPauseRequest, peer: Peer) {
        let host = hostSession
        guard let streamer = host.streamer else { return }
        guard host.pauseTask == nil else {
            if let reply = try? Wire.json(.sessionPauseResult, SessionPauseResult(id: request.id, paused: host.paused,
                error: "正在处理上一项暂停/恢复")) { peer.send(reply) }
            return
        }
        host.injector?.releaseAll()
        let token = generation
        let capture = host.captureTask, video = host.settingsTask
        host.pauseTask = Task { [weak self, weak peer, weak host] in
            guard let self, let peer, let host, self.hostSession === host else { return }
            defer {
                if self.generation == token, self.peer === peer, self.hostSession === host {
                    host.pauseTask = nil
                    self.publishSessionPause()
                }
            }
            await capture?.value
            await video?.value
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer, !Task.isCancelled else { return }
            var failure: String?
            do { host.paused = try await streamer.setSessionPaused(request.paused) }
            catch { failure = error.localizedDescription }
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer, !Task.isCancelled else { return }
            self.sessionPauseStatus = failure ?? (host.paused ? "控制端空闲暂停，保留加密会话" : "画面传输已恢复")
            DiagnosticLog.shared.record(host.paused ? .sessionPaused : .sessionResumed, role: .host,
                state: failure == nil ? .succeeded : .failed)
            if let reply = try? Wire.json(.sessionPauseResult, SessionPauseResult(id: request.id, paused: host.paused, error: failure)) {
                peer.send(reply)
            }
            if !host.paused, failure == nil { streamer.resumeAfterReconfiguration() }
        }
        publishSessionPause()
    }

    private func applyHostVideoSettings(_ request: StreamSettingsRequest, peer: Peer) {
        let host = hostSession
        guard let state = activeVideoState, let streamer = host.streamer else { return }
        if host.settingsRequestID == request.id { return }
        if host.settingsRequestID != nil {
            if let result = try? Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: state, error: "正在处理上一项画质调整")) { peer.send(result) }
            return
        }
        do { try request.settings.validateControlValues() }
        catch {
            if let result = try? Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: state, error: error.localizedDescription)) { peer.send(result) }
            return
        }
        if request.settings == state.settings {
            if let result = try? Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: state)) { peer.send(result) }
            return
        }
        host.settingsRequestID = request.id
        let token = generation
        let capture = host.captureTask
        let pause = host.pauseTask
        host.settingsTask = Task { [weak self, weak peer, weak host] in
            guard let self, let peer, let host, self.hostSession === host else { return }
            defer {
                if self.generation == token, self.peer === peer, self.hostSession === host, host.settingsRequestID == request.id {
                    host.settingsRequestID = nil; host.settingsTask = nil
                }
            }
            do {
                await capture?.value
                await pause?.value
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer,
                      host.settingsRequestID == request.id, !Task.isCancelled else { return }
                let updated = try await streamer.reconfigure(request.settings)
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer,
                      host.settingsRequestID == request.id, !Task.isCancelled else { return }
                self.activeVideoState = updated
                self.recordVideoConfiguration(updated)
                self.resolution = "\(updated.width) × \(updated.height)"
                self.videoSettingsStatus = "控制端已调整：\(updated.settings.summary)"
                peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: updated)))
                streamer.resumeAfterReconfiguration()
            } catch {
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.settingsRequestID == request.id,
                      !Task.isCancelled, let actual = self.activeVideoState else { return }
                self.recordDiagnosticFailure(.streamConfigured, error: error)
                if let result = try? Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: actual, error: error.localizedDescription)) { peer.send(result) }
            }
        }
    }

    private func receiveClipboard(_ data: Data) throws {
        guard data.count <= Wire.maximumClipboardBytes, let text = String(data: data, encoding: .utf8) else {
            throw DeskError.invalid("剪贴板文字过大或编码无效")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardStatus = "已接收远端剪贴板文字"
    }

    private func sendClipboard(to peer: Peer) {
        guard !ClipboardPrivacy.isSensitive() else {
            clipboardStatus = "剪贴板内容已标记为敏感，未同步到对端"
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            clipboardStatus = "剪贴板中没有文字"
            return
        }
        let data = Data(text.utf8)
        guard data.count <= Wire.maximumClipboardBytes else {
            error = "文字剪贴板最大支持 1 MB"
            return
        }
        peer.send(Message(.clipboard, data))
        clipboardStatus = "剪贴板文字已发送"
    }

    func pushClipboard() { if let peer, connected { sendClipboard(to: peer) } }
    func pullClipboard() { if connected { peer?.send(Message(.requestClipboard)); clipboardStatus = "正在获取远端剪贴板…" } }

    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clipboardEnabled")
        if supportsClipboard, let peer {
            do { try sendClipboardPreference(to: peer) }
            catch { clipboardStatus = error.localizedDescription }
        }
        updateClipboardSync()
    }

    private var automaticClipboardSendingAllowed: Bool {
        guard !sessionInputSuspended, !hostSession.paused, hostSession.pauseTask == nil else { return false }
        return mode == .viewer ? NSApp.isActive : remoteReceivesAutomaticClipboard
    }

    private func sendClipboardPreference(to peer: Peer) throws {
        let receives = !sessionInputSuspended && !hostSession.paused && (mode == .viewer ? !controlling : true)
        peer.send(try Wire.json(.clipboardSettings, ClipboardPreference(enabled: clipboardEnabled,
            session: clipboardSession, receivesAutomaticUpdates: receives)))
        lastClipboardReceivePreference = receives
    }

    func refreshClipboardFocus() {
        clipboardSync?.setAutomaticSendingAllowed(automaticClipboardSendingAllowed)
        let receives = !sessionInputSuspended && !hostSession.paused && (mode == .viewer ? !controlling : true)
        guard mode == .viewer, connected, supportsClipboard, let peer,
              lastClipboardReceivePreference != receives else { return }
        do { try sendClipboardPreference(to: peer) }
        catch { clipboardStatus = error.localizedDescription }
    }

    private func updateClipboardSync() {
        let enabled = connected && supportsClipboard && clipboardEnabled && remoteClipboardEnabled
        canvas.synchronizesClipboard = enabled
        if enabled, clipboardSync == nil, let peer, let clipboardSession {
            let sync = ClipboardSync(session: clipboardSession, allowsFileSending: remoteFileApproval,
                allowsAutomaticSending: automaticClipboardSendingAllowed, allowsChunkWindow: remoteClipboardChunkWindow) { [weak peer] in peer?.send($0) }
            clipboardSync = sync
            dataChannel?.configureClipboard(sync.receiveMessage)
            sync.onDiagnostic = { [weak self, weak sync] event in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.recordClipboardDiagnostic(event)
            }
            sync.onStatus = { [weak self, weak sync] message in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.clipboardStatus = message
            }
            sync.onFileOffer = { [weak self, weak sync] offer in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.dismissClipboardPrompt()
                self.clipboardFilePrompt = nil
                self.pendingFileOffer = offer
                guard let offer else { return }
                if self.mode == .viewer { self.canvas.releaseControl() }
                else { self.hostSession.injector?.releaseAll() }
                let prompt = ClipboardFilePrompt(offer: offer, peerName: self.mode == .viewer ? self.remoteName : "") { [weak self, weak sync] accepted in
                    self?.recordSessionActivity()
                    sync?.respondToFileOffer(id: offer.id, accept: accepted)
                }
                self.clipboardFilePrompt = prompt
                prompt.present()
            }
            clipboardStatus = remoteClipboardFocusAware
                ? "双向剪贴板已开启：控制端在 QuietDesk 前台时发送，远端在释放控制后发送；文件确认后接收"
                : "双向剪贴板已开启：控制端在 QuietDesk 前台时发送；两端升级后可按控制焦点限制远端发送，文件确认后接收"
        } else if enabled {
            clipboardSync?.allowsFileSending = remoteFileApproval
            clipboardSync?.setAutomaticSendingAllowed(automaticClipboardSendingAllowed)
        } else if !enabled {
            dataChannel?.configureClipboard(nil)
            clipboardSync?.stop(); clipboardSync = nil
            dismissClipboardPrompt(); clipboardFilePrompt = nil
            pendingFileOffer = nil
            if connected { clipboardStatus = supportsClipboard ? "自动剪贴板已关闭" : "对端版本较旧，可使用手动文字同步" }
        }
    }

    func openReceivedFiles() {
        let folder = ClipboardSync.storageURL.appendingPathComponent("received", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription; return }
        NSWorkspace.shared.open(folder)
    }

    func setAutoReconnect(_ enabled: Bool) {
        autoReconnect = enabled
        UserDefaults.standard.set(enabled, forKey: "autoReconnect")
        if !enabled, reconnecting { stop() }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do { try LaunchSettings.setEnabled(enabled) }
        catch { self.error = error.localizedDescription }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        loginEnabled = LaunchSettings.enabled
        loginNeedsApproval = LaunchSettings.needsApproval
    }

    func attachWindow(_ window: NSWindow) {
        if mainWindow !== window {
            for observer in sessionFocusObservers { NotificationCenter.default.removeObserver(observer) }
            sessionFocusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sessionWindowFocusChanged() }
                }
            }
            if windowActivityMonitor == nil {
                windowActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
                        var result: NSEvent? = event
                        MainActor.assumeIsolated {
                            if let self { result = self.observeSessionEvent(event) }
                        }
                        return result
                    }
            }
        }
        mainWindow = window
        if shouldMinimizeOnLaunch {
            shouldMinimizeOnLaunch = false
            DispatchQueue.main.async { [weak window] in window?.miniaturize(nil) }
        }
    }

    func initialLaunch(atLogin: Bool) {
        if atLogin && !loginWindowHandled {
            loginWindowHandled = true
            if minimizeAtLogin {
                if let mainWindow { mainWindow.miniaturize(nil) }
                else { shouldMinimizeOnLaunch = true }
            }
        }
        guard !initialLaunchHandled else { return }
        initialLaunchHandled = true
        if autoStartSharing {
            mode = .host
            startHosting(interactive: false)
        }
    }

    func prepareShowWindow() {
        shouldMinimizeOnLaunch = false
        loginWindowHandled = true
    }

    private func restartHostAfterFailure(_ reason: String) {
        let retry = hostingRequested
        recordDisconnect(reason)
        stop()
        hostingRequested = retry
        status = reason
        if retry { scheduleHostRetry() }
    }

    private func scheduleHostRetry() {
        guard hostingRequested, !systemSleeping else { return }
        hostRetryTask?.cancel()
        let delay = hostBackoff.next()
        let token = generation
        working = true
        status = "\(Int(delay)) 秒后重试开启共享 · \(status)"
        hostRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token, self.hostingRequested, self.mode == .host else { return }
            self.working = false
            self.startHosting(interactive: false)
        }
    }

    private func systemWillSleep() {
        systemSleeping = true
        reconnectTask?.cancel()
        hostRetryTask?.cancel()
        if mode == .host {
            let resume = hostingRequested
            if active || working { stop() }
            hostingRequested = resume
            if resume { status = "系统即将睡眠，唤醒后恢复共享" }
        } else if target != nil, active || working || reconnecting {
            let candidate = peer
            clearSession()
            candidate?.close("本机进入睡眠，等待唤醒后重新连接")
            active = true
            reconnecting = autoReconnect
            freshFrameRequiredOnReconnect = true
            status = "系统即将睡眠，连接已暂停"
        }
    }

    private func systemDidWake() {
        systemSleeping = false
        refreshPermissions(checkScreenCapture: mode == .host, retryCapsLock: true)
        if mode == .host, hostingRequested {
            hostRetryTask?.cancel()
            hostBackoff.reset()
            if active || working {
                stop()
                hostingRequested = true
            }
            startHosting(interactive: false)
        } else if let target, active || working || reconnecting {
            reconnectTask?.cancel()
            let candidate = peer
            clearSession()
            candidate?.close("系统唤醒，重新建立连接")
            guard autoReconnect else {
                stop()
                status = "系统已唤醒，请重新连接"
                return
            }
            retryBackoff.reset()
            freshFrameRequiredOnReconnect = true
            pauseTransmission.requireFreshFrame()
            active = true
            reconnecting = true
            beginConnection(target)
        }
    }

    private func beginMetrics() {
        lastMetrics = SessionClock.now
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode == .viewer,
                   (self.connected && self.supportsSessionPause || self.reconnecting && self.target != nil),
                   self.idlePolicy.tick(now: SessionClock.now) {
                    self.viewerSession.restoreCanvasFocusAfterIdle = self.controlling
                    self.pauseTransmission.choose(paused: true)
                    self.sessionPauseStatus = "10 分钟无窗口操作，正在暂停画面与自动剪贴板…"
                    if self.connected {
                        self.publishSessionPause()
                        self.sendNextSessionPause()
                    } else {
                        let candidate = self.peer
                        self.clearSession()
                        candidate?.close("空闲暂停，返回窗口后继续连接")
                        self.deferReconnectForIdle("10 分钟无窗口操作")
                    }
                }
                let seconds = max(0.01, SessionClock.now - self.lastMetrics)
                let metrics = self.dataChannel?.takeMetrics() ?? (bytes: 0, frames: 0)
                self.traffic = String(format: "%.2f Mbps", Double(metrics.bytes) * 8 / seconds / 1_000_000)
                self.frameRate = String(format: "%.0f fps", Double(metrics.frames) / seconds)
                if let measured = self.viewerSession.lastLatencyAt, SessionClock.now - measured > 15 {
                    self.latency = "— ms"
                    self.roundTripMilliseconds = nil
                }
                self.lastMetrics = SessionClock.now
            }
        }
        if let metricsTimer { RunLoop.main.add(metricsTimer, forMode: .common) }
    }

    private func clearSession() {
        performanceTimer?.cancel()
        performanceTimer = nil
        flushPerformanceDiagnostics()
        performanceDiagnostics?.setEnabled(false)
        performanceDiagnostics = nil
        performanceRole = nil
        dataChannel?.invalidate()
        dataChannel = nil
        if mode == .viewer, target != nil, sessionInputSuspended { freshFrameRequiredOnReconnect = true }
        let oldHost = hostSession
        let oldViewer = viewerSession
        oldHost.pauseTask?.cancel()
        oldHost.effectsTask?.cancel()
        oldHost.settingsTask?.cancel()
        oldHost.captureTask?.cancel()
        oldViewer.pauseRequestTimeout?.cancel()
        oldViewer.effectsRequestTimeout?.cancel()
        oldViewer.videoDebounceTask?.cancel()
        oldViewer.videoRequestTimeout?.cancel()
        oldViewer.stableTask?.cancel()
        if let effects = oldHost.effects {
            let token = generation
            effectsCleanupTask = Task { [weak self] in
                if let message = await effects.reset(), let self, self.generation == token, self.hostSession.effects == nil {
                    self.sessionEffectsStatus = message
                }
            }
        }
        if let streamer = oldHost.streamer {
            DiagnosticLog.shared.record(.captureStopped, role: .host)
            Task { await streamer.stop() }
        }
        oldHost.injector?.releaseAll()
        hostSession = HostSession()
        viewerSession = ViewerSession()
        supportsSessionPause = false
        pauseTransmission = SessionPauseTransmission(paused: idlePolicy.isPaused)
        if freshFrameRequiredOnReconnect { pauseTransmission.requireFreshFrame() }
        sessionPaused = idlePolicy.isPaused
        sessionPauseWorking = false
        sessionEffectsWorking = false
        supportsSessionEffects = false
        sessionEffects = SessionEffectsState()
        sessionEffectsStatus = ""
        flushTrafficHistory()
        trafficSession = nil
        currentTrafficDeviceID = nil
        trafficHistoryStatus = "从本版开始按设备累计；旧版设备需双方升级。"
        controlStatusUpdatesEnabled = false
        capsLockRunning = false
        capsLockStartAttempted = false
        latency = "— ms"
        roundTripMilliseconds = nil
        viewerQualityPolicy.discardUnfinishedSample()
        supportsLiveSettings = false
        supportsExtendedVideoSettings = false
        supportsHighRefreshVideoSettings = false
        videoTuning = nil
        activeVideoState = nil
        videoSettingsStatus = ""
        clipboardSync?.stop()
        clipboardSync = nil
        dismissClipboardPrompt(); clipboardFilePrompt = nil
        pendingFileOffer = nil
        canvas.synchronizesClipboard = false
        supportsClipboard = false
        remoteClipboardEnabled = false
        remoteFileApproval = false
        remoteClipboardChunkWindow = false
        remoteReceivesAutomaticClipboard = true
        remoteClipboardFocusAware = false
        lastClipboardReceivePreference = nil
        clipboardSession = nil
        peer = nil
        connected = false
        working = false
        controlling = false
        canControl = false
        supportsInputActions = false
        canvas.usesCapsLockActions = false
        canvas.capsLockMonitor.stop()
        canvas.reset()
    }

    func stop() {
        if peer != nil { DiagnosticLog.shared.record(.connectionClosed, role: diagnosticRole, state: .cancelled) }
        if mode == .host, active || working { DiagnosticLog.shared.record(.hostStopped, role: .host, state: .cancelled) }
        idlePolicy = SessionIdlePolicy(now: SessionClock.now)
        pauseTransmission = SessionPauseTransmission()
        wakeInputGate = SessionWakeInputGate()
        reconnectDeferredForIdle = false
        freshFrameRequiredOnReconnect = false
        sessionPauseStatus = ""
        hostingRequested = false
        connectionError = nil
        hostRetryTask?.cancel()
        hostPreparationTask?.cancel()
        hostPreparationTask = nil
        reconnectTask?.cancel()
        viewerSession.stableTask?.cancel()
        target = nil
        reconnecting = false
        if mode == .viewer, isFullScreen { canvas.window?.toggleFullScreen(nil) }
        generation = UUID()
        active = false
        listener?.cancel()
        listener = nil
        for candidate in pending.values { candidate.close() }
        pending.removeAll()
        peer?.close()
        clearSession()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        metricsTimer?.invalidate()
        metricsTimer = nil
        traffic = "0.00 Mbps"
        frameRate = "0 fps"
        resolution = ""
        clipboardStatus = ""
        inputStatus = ""
        status = mode == .host ? "共享已停止" : "已断开连接"
    }

    deinit {
        performanceTimer?.cancel()
        performanceDiagnostics?.setEnabled(false)
        permissionTimer?.invalidate()
        displayRefreshTask?.cancel()
        hostPreparationTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        focusRefreshTask?.cancel()
        for observer in sessionFocusObservers { NotificationCenter.default.removeObserver(observer) }
        if let windowActivityMonitor { NSEvent.removeMonitor(windowActivityMonitor) }
    }
}
