import AppKit
import CryptoKit
import Network
import ScreenCaptureKit
import IOKit.hid
import QuietDeskCore

@MainActor
final class DeskModel: ObservableObject {
    enum Mode: String, CaseIterable { case viewer = "连接家里 Mac", host = "共享这台 Mac" }
    /// Each model keeps one role for its lifetime; the app runs a viewer and a host side by side.
    let mode: Mode
    /// The model of the other role, for the one-session-at-a-time rule and settings both roles share.
    weak var sibling: DeskModel?
    @Published var address = UserDefaults.standard.string(forKey: "remoteAddress") ?? ""
    @Published var port = UserDefaults.standard.string(forKey: "remotePort") ?? "5908"
    @Published var viewerCode = ""
    @Published private(set) var relayEnabled = UserDefaults.standard.bool(forKey: "relayEnabled")
    /// Relay nodes this Mac registers on while sharing and may connect through. The first is also kept
    /// under the single-node key, so an older version still finds a node.
    @Published private(set) var relayNodes = DeskModel.loadRelayNodes()
    var relayAddress: String { relayNodes.first ?? "" }
    /// The viewer's node choice: empty picks the node with the best measured connection.
    @Published var relayNodeChoice = UserDefaults.standard.string(forKey: "relayNodeChoice") ?? "" {
        didSet { UserDefaults.standard.set(relayNodeChoice, forKey: "relayNodeChoice") }
    }
    @Published private(set) var relayNodeMeasurements: [String: RelayNodeProbe.Measurement] = [:]
    @Published private(set) var relayProbing = false
    private var relayMeasuredAt: TimeInterval?
    @Published private(set) var relayDeviceID = UserDefaults.standard.string(forKey: "relayDeviceID") ?? ""
    @Published var targetRelayDeviceID = UserDefaults.standard.string(forKey: "targetRelayDeviceID") ?? ""
    @Published var relayStrategy = RelayConnectionStrategy(rawValue: UserDefaults.standard.string(forKey: "relayStrategy") ?? "") ?? .direct
    @Published private(set) var relayHostStatus = "未开启中继共享"
    @Published private(set) var controlTransportStatus = "尚未连接"
    @Published var hostCode = ""
    @Published private(set) var hostCodeNeedsSetup = false
    @Published var hostPort = UserDefaults.standard.string(forKey: "listenPort") ?? "5908" {
        didSet { UserDefaults.standard.set(hostPort, forKey: "listenPort") }
    }
    @Published var settings = StreamSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(settings.highRefreshCompatible) { UserDefaults.standard.set(data, forKey: "streamSettings") }
            if settings.framesPerSecond > 60, let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "higherFrameRateStreamSettings")
            } else { UserDefaults.standard.removeObject(forKey: "higherFrameRateStreamSettings") }
        }
    }
    @Published var displayID = CGMainDisplayID()
    @Published private(set) var displayFallbackNotice: String?
    @Published private(set) var screens: [(id: CGDirectDisplayID, name: String)] = []
    @Published var active = false
    @Published var working = false
    @Published var connected = false
    /// When the current viewer connection received the host's hello; an automatic reconnect starts a new one.
    @Published private(set) var connectedSince: Date?
    @Published var controlling = false
    @Published var status = "准备就绪"
    @Published var error: String?
    @Published private(set) var connectionError: String?
    var connectionFailure: String? {
        guard mode == .viewer, !active, !working, !connected else { return nil }
        return connectionError
    }
    @Published var traffic = "0.00 Mbps"
    let trafficHistory: TrafficHistoryFeed
    @Published private(set) var trafficHistoryStatus = "按网址/IP＋端口累计；旧版按设备统计单独保留。"
    @Published var frameRate = "0 fps"
    @Published var latency = "— ms"
    @Published private(set) var mediaTransportStatus = "TCP 兼容模式"
    @Published private(set) var supportsMediaTransport = false
    @Published private(set) var supportsIndependentCursor = false
    @Published private(set) var cursorStatus = "视频光标"
    @Published var lowLatencyCursorEnabled = UserDefaults.standard.object(forKey: "lowLatencyCursorEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lowLatencyCursorEnabled, forKey: "lowLatencyCursorEnabled")
            if oldValue != lowLatencyCursorEnabled { sendCursorRequest() }
        }
    }
    @Published var mediaTCPOnly = UserDefaults.standard.bool(forKey: "mediaTCPOnly") {
        didSet { UserDefaults.standard.set(mediaTCPOnly, forKey: "mediaTCPOnly") }
    }
    // Applies to both roles. Automatic and On switch live; leaving Off applies to the next video lease
    // (viewer) or the next relay registration (host), because Off never negotiates the capability.
    @Published var relayPeerAssist = RelayPeerAssistMode(rawValue: UserDefaults.standard.string(forKey: "relayPeerAssist") ?? "") ?? .automatic {
        didSet {
            UserDefaults.standard.set(relayPeerAssist.rawValue, forKey: "relayPeerAssist")
            guard oldValue != relayPeerAssist else { return }
            sibling?.relayPeerAssist = relayPeerAssist
            viewerSession.relayBridge?.setPeerAssistMode(relayPeerAssist)
            viewerSession.mediaRelayBridge?.setPeerAssistMode(relayPeerAssist)
            relayHostRegistrations.forEach { $0.setPeerAssistMode(relayPeerAssist) }
        }
    }
    @Published private(set) var relayPeerStatus = ""
    // Share of UDP video fragments that missed the reorder window over about five seconds; empty off UDP.
    @Published private(set) var mediaLoss = ""
    @Published private(set) var localNetworkQuality = false
    private var mediaLossFraction: Double?
    // Applied frame rate and bitrate next to the video size; automatic changes never exceed the chosen ceiling.
    var videoQualitySummary: String {
        guard let settings = activeVideoState?.settings else { return "" }
        return "\(settings.framesPerSecond) fps · \(settings.megabits) Mbps"
    }
    var videoQualityHelp: String {
        guard mode == .viewer, supportsMediaTransport else { return "当前编码帧率上限与目标码率" }
        let help = localNetworkQuality
            ? "局域网优先保持所选画质：\(viewerSettings.summary)。连续测得至少 80 ms 延迟才降码率：视频交付约 2 秒，TCP 心跳需连续多次测量。之后画面有活动且延迟低于 50 ms 时逐档回升；实际帧率仍受屏幕和硬件限制。"
            : "当前生效的帧率上限与目标码率，按网络丢包、延迟和编解码速度自动调整，不超过所选：\(viewerSettings.summary)"
        return automaticQualityNote.isEmpty ? help : help + "\n" + automaticQualityNote
    }
    /// Why the applied quality is below the choice, after an automatic reduction; empty otherwise.
    private(set) var automaticQualityNote = ""

    static func qualityNote(_ adjustment: MediaQualityPolicy.Adjustment?, applied: StreamSettings) -> String {
        switch adjustment {
        case .localLatency?:
            return "局域网连续测得至少 80 ms 延迟，已自动调整为 \(applied.summary)"
        case .network?:
            return "网络丢包或延迟升高，已自动调整为 \(applied.summary)"
        case .compute(let cause, let milliseconds?)? where milliseconds.isFinite && milliseconds > 0:
            let side = cause == .encoder ? "被控端编码" : "本机解码"
            return String(format: "%@每帧约 %.1f ms，最多约 %d fps，已自动调整为 %@",
                          side, milliseconds, Int(1_000 / milliseconds), applied.summary)
        case .compute?:
            return "视频解码未完成，已自动调整为 \(applied.summary)"
        case .raise?, nil:
            return ""
        }
    }
    var mediaRouteSummary: String { mediaLoss.isEmpty ? mediaTransportStatus : mediaTransportStatus + " · " + mediaLoss }
    /// UDP loss at the level adaptive quality treats as congestion; the full-screen status shows it in red.
    var mediaLossHigh: Bool { (mediaLossFraction ?? 0) >= 0.03 }
    private var mediaRouteValue = ""
    private var peerPathState = RelayPeerPathState.relay
    @Published private(set) var performanceDiagnosticsEnabled = false
    @Published var showFullScreenStatistics = UserDefaults.standard.bool(forKey: "showFullScreenStatistics") {
        didSet { UserDefaults.standard.set(showFullScreenStatistics, forKey: "showFullScreenStatistics") }
    }
    // The vertical status starts from its bottom-right default; a position saved for the old single row
    // ("fullScreenStatusPosition") is left for older versions and not reused.
    private static let fullScreenStatusPositionKey = "fullScreenStatusPositionV2"
    @Published var fullScreenStatusPosition: CGPoint? = UserDefaults.standard.data(forKey: DeskModel.fullScreenStatusPositionKey)
        .flatMap { try? JSONDecoder().decode(CGPoint.self, from: $0) } {
        didSet {
            if let fullScreenStatusPosition, let data = try? JSONEncoder().encode(fullScreenStatusPosition) {
                UserDefaults.standard.set(data, forKey: Self.fullScreenStatusPositionKey)
            } else { UserDefaults.standard.removeObject(forKey: Self.fullScreenStatusPositionKey) }
        }
    }
    // Missing means the default opacity of the text-only status.
    @Published var fullScreenStatusOpacity = UserDefaults.standard.object(forKey: "fullScreenStatusOpacity") as? Double {
        didSet { UserDefaults.standard.set(fullScreenStatusOpacity, forKey: "fullScreenStatusOpacity") }
    }
    var fullScreenStatusEffectiveOpacity: Double {
        if let value = fullScreenStatusOpacity, value.isFinite { return min(1, max(0.1, value)) }
        return FullScreenStatusPlacement.defaultOpacity
    }
    @Published var resolution = ""
    @Published var remoteName = ""
    @Published var clipboardStatus = ""
    @Published private(set) var pendingFileOffer: ClipboardFileOffer?
    @Published private(set) var receivingFileID: UUID?
    @Published private(set) var receivedFilesKeptInFolder = false
    @Published var canControl = false
    @Published private(set) var localAccessibility = false
    @Published private(set) var localInputMonitoring = false
    @Published private(set) var localScreenRecording = false
    @Published private(set) var capsLockRunning = false
    @Published var isFullScreen = false
    @Published private(set) var capsLockEnabled = UserDefaults.standard.bool(forKey: "capsLockActions")
    private var supportsInputActions = false
    @Published private(set) var supportsLiveSettings = false
    @Published private(set) var supportsExtendedVideoSettings = false
    @Published private(set) var supportsHighRefreshVideoSettings = false
    @Published private(set) var supportsHigherFrameRateVideo = false
    @Published private(set) var supportsSessionEffects = false
    @Published private(set) var supportsSessionLock = false
    // The host understands the brightness switch (displayDimmingV1) and, when it sent its hello, was a laptop
    // whose built-in display brightness could be turned down.
    @Published private(set) var supportsDisplayDimming = false
    @Published private(set) var hostDisplayDimmable = false
    // The host takes fine automatic bitrate steps live and reports delivery delay (adaptiveVideoV1).
    @Published private(set) var supportsAdaptiveVideo = false
    @Published private(set) var sessionEffects = SessionEffectsState()
    @Published private(set) var sessionEffectsWorking = false
    @Published private(set) var sessionEffectsStatus = ""
    @Published private(set) var sessionEffectsMemory = SessionEffectsMemory() {
        didSet {
            guard sessionEffectsMemory.remembered != oldValue.remembered,
                  let data = try? JSONEncoder().encode(sessionEffectsMemory.remembered) else { return }
            UserDefaults.standard.set(data, forKey: "rememberedSessionEffects")
        }
    }
    @Published private(set) var supportsDesktopActions = false
    @Published private(set) var desktopActionWorking = false
    @Published private(set) var desktopActionStatus = ""
    /// Briefly shown over the picture when the window toolbar's action is refused or unconfirmed.
    @Published private(set) var desktopActionNotice: String?
    private var desktopActionNoticeTask: Task<Void, Never>?
    var desktopActionUnavailableReason: String? {
        if !connected { return "连接后可选择远端桌面" }
        if !supportsDesktopActions { return "被控端需更新后才能使用桌面操作" }
        if !canControl { return "当前仅观看，需被控端辅助功能权限生效" }
        if sessionInputSuspended { return "画面暂停或恢复中，请稍候" }
        if unlockWorking { return "正在解锁远端，请稍候" }
        if desktopActionWorking { return "正在发送桌面操作…" }
        return nil
    }
    // Typing a saved lock screen password on the host after connecting (sessionUnlockV1).
    @Published private(set) var supportsSessionUnlock = false
    @Published private(set) var unlockWorking = false
    /// Shown over the remote picture while and after the host types the password.
    @Published private(set) var unlockNotice: String?
    @Published private(set) var unlockStatus = ""
    @Published private(set) var unlockPasswordSaved = false
    @Published private(set) var autoUnlockEnabled = false
    private var unlockNoticeTask: Task<Void, Never>?
    private var supportsSessionPause = false
    @Published private(set) var sessionPaused = false
    @Published private(set) var sessionPauseWorking = false
    @Published private(set) var sessionPauseStatus = ""
    var sessionInputSuspended: Bool { mode == .viewer && (idlePolicy.isPaused || pauseTransmission.inputSuspended) }
    @Published private(set) var activeVideoState: VideoStreamState?
    @Published private(set) var videoTuning: VideoTuningSession?
    @Published private(set) var videoSettingsStatus = ""
    var viewerSettings: StreamSettings { viewerSession.mediaQuality?.upperBound ?? videoTuning?.desired ?? activeVideoState?.settings ?? StreamSettings() }
    var viewerLongestEdges: [Int] { supportsExtendedVideoSettings ? StreamSettings.longestEdges : StreamSettings.legacyLongestEdges }
    var viewerFrameRates: [Int] {
        supportsHigherFrameRateVideo ? StreamSettings.frameRates
            : supportsHighRefreshVideoSettings ? StreamSettings.highRefreshFrameRates : StreamSettings.legacyFrameRates
    }
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
    private var relayHostRegistrations: [RelayHostRegistration] = []
    private var relayRegistrationStates: [RelayEndpoint: RelayRegistrationStatus] = [:]
    private var relaySelectedForTarget = false
    private var relayFallbackAttempted = false
    private var relayFallbackCooldown = RelayFallbackCooldown()
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
    private let snapshotQueue = DispatchQueue(label: "quietdesk.remote-snapshot", qos: .userInitiated)
    private var performanceTimer: DispatchSourceTimer?
    private var performanceConnectionID = 0
    private var performanceRole: DiagnosticLog.Role?
    private var permissionTimer: Timer?
    private var permissionGuide: PermissionGuide?
    var updatePromptBlocked: Bool { permissionGuide?.isVisible == true || error != nil || pendingFileOffer != nil }
    var hasIncomingControlConnection: Bool { mode == .host && peer != nil }
    /// This Mac is connecting to, connected to or about to reconnect to another Mac.
    var isControllingAnotherMac: Bool { mode == .viewer && (active || working || connected || reconnecting) }
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
    /// 控制端自动重连前剪贴板已处理到的版本；手动断开或关闭同步后清空。
    private var clipboardHandledChange: Int?
    private var initialLaunchHandled = false
    private var loginWindowHandled = false
    private var shouldMinimizeOnLaunch = false
    private struct Target {
        let address: String
        let port: UInt16
        let key: PairingKey
        let recordID: UUID?
        var trafficEndpoint: TrafficEndpoint
        var relay: RelayConnectionInfo?
        var relayAccessKey: Data?
        var relayCertificate: RelayNodeCertificate?
        /// Every node this connection may use, best first; `relay` is the one in use.
        var relayRoutes: [RelayRoute] = []
        var relayRoutesOrdered = false

        func using(_ route: RelayRoute) -> Target {
            var next = self
            next.relay = route.info; next.relayAccessKey = route.accessKey; next.relayCertificate = route.certificate
            if address.isEmpty, let endpoint = try? TrafficEndpoint(address: route.info.endpoint.host, port: route.info.endpoint.port) {
                next.trafficEndpoint = endpoint
            }
            return next
        }
    }
    private struct RelayRoute {
        let info: RelayConnectionInfo
        let accessKey: Data
        let certificate: RelayNodeCertificate?
    }
    private var target: Target?
    private var selectedConnectionID: UUID?
    private var savedTarget = false
    private var viewerQualityPolicy = ViewerQualityPolicy()
    private var preferredDisplayID = CGMainDisplayID()
    private var screenObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var systemSleeping = false
    private var displayRefreshTask: Task<Void, Never>?
    private var hostPreparationTask: Task<Void, Never>?
    private let trafficHistoryStore: TrafficHistoryStore
    private var trafficSession: TrafficSession?
    private var effectsCleanupTask: Task<Void, Never>?
    private var effectsCleanupsRunning = 0
    private var idlePolicy = SessionIdlePolicy(now: SessionClock.now)
    private var pauseTransmission = SessionPauseTransmission()
    private var wakeInputGate = SessionWakeInputGate()
    private var reconnectDeferredForIdle = false
    private var windowActivityMonitor: Any?
    private var sessionFocusObservers: [NSObjectProtocol] = []
    private var sessionWorkspaceObservers: [NSObjectProtocol] = []
    private var sessionLockObservers: [NSObjectProtocol] = []
    private var localScreensAsleep = false
    private var focusRefreshTask: Task<Void, Never>?
    private var suppressIdleFocusWake = false
    private var freshFrameRequiredOnReconnect = false

    init(mode: Mode, services: DeskServices) {
        self.mode = mode
        trafficHistory = services.trafficHistory
        trafficHistoryStore = services.trafficHistoryStore
        if let data = UserDefaults.standard.data(forKey: "streamSettings"),
           let saved = try? JSONDecoder().decode(StreamSettings.self, from: data),
           (try? saved.validateControlValues()) != nil {
            if let data = UserDefaults.standard.data(forKey: "higherFrameRateStreamSettings"),
               let higher = try? JSONDecoder().decode(StreamSettings.self, from: data),
               higher.framesPerSecond > 60, (try? higher.validateControlValues()) != nil,
               higher.highRefreshCompatible == saved { settings = higher }
            else { settings = saved }
        }
        if let id = UserDefaults.standard.object(forKey: "sharedDisplay") as? Int { preferredDisplayID = CGDirectDisplayID(clamping: id) }
        if let data = UserDefaults.standard.data(forKey: "rememberedSessionEffects"),
           let saved = try? JSONDecoder().decode(SessionEffectsState.self, from: data) {
            sessionEffectsMemory = SessionEffectsMemory(remembered: saved)
        }
        displayID = preferredDisplayID
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
            let allowed = self.wakeInputGate.allows(value, suspended: self.sessionInputSuspended || self.desktopActionWorking || !self.connected)
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
        canvas.onRelease = { [weak self] in
            guard let self, self.mode == .viewer, self.connected else { return }
            self.peer?.send(Message(.releaseInput))
        }
        canvas.onFocus = { [weak self] focused in
            guard let self else { return }
            self.controlling = focused
            self.refreshClipboardFocus()
        }
        canvas.onFailure = { [weak self] message in
            DiagnosticLog.shared.record(.captureFailed, role: .viewer, state: .failed)
            self?.peer?.close(message, retryable: true)
        }
        canvas.holdsPaste = { [weak self] in self?.clipboardSync?.holdsPaste == true }
        canvas.onPaste = { [weak self] input in
            guard let self, let peer = self.peer, self.connected else { return }
            self.recordSessionActivity()
            guard !self.sessionInputSuspended, !self.desktopActionWorking else { return }
            let interaction = self.canvas.interactionRevision
            self.clipboardStatus = "正在等待剪贴板同步后粘贴…"
            self.clipboardSync?.prepareForPaste { [weak self, weak peer] success in
                guard let self, let peer, self.peer === peer, self.connected else { return }
                guard success, !self.sessionInputSuspended, !self.desktopActionWorking, self.canvas.interactionRevision == interaction,
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
        canvas.onCaptureFrame = { [weak self] in self?.copyRemoteFrame() }
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

    /// An automatic change also records why it was made: 1 network, 2 raised, 3 host encoder, 4 local decoder,
    /// 5 sustained LAN latency; with the slower codec's time per frame for compute pressure.
    private func recordVideoConfiguration(_ state: VideoStreamState, succeeded: Bool = true,
                                          adjustment: MediaQualityPolicy.Adjustment? = nil) {
        var values: [DiagnosticLog.Field: Int] = [.width: state.width, .height: state.height, .fps: state.settings.framesPerSecond,
                                                   .targetBitrate: state.settings.megabits * 1_000_000,
                                                   .maximumDimension: state.settings.longestEdge]
        switch adjustment {
        case .localLatency?: values[.qualityCause] = 5
        case .network?: values[.qualityCause] = 1
        case .raise?: values[.qualityCause] = 2
        case .compute(let cause, let milliseconds)?:
            values[.qualityCause] = cause == .encoder ? 3 : 4
            if let milliseconds, milliseconds.isFinite { values[.computeMicroseconds] = Int(min(60_000, milliseconds) * 1_000) }
        case nil: break
        }
        DiagnosticLog.shared.record(.streamConfigured, role: diagnosticRole, state: succeeded ? .ready : .failed, values: values)
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

    private func makeTrafficSession(for peer: Peer, endpoint: TrafficEndpoint? = nil) -> TrafficSession {
        let history = trafficHistoryStore
        let session = TrafficSession(connectionID: peer.trafficMeter.connectionID, endpoint: endpoint,
            onDelta: { endpoint, delta in history.record(endpoint, delta: delta) },
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
            if localScreenRecording != allowed { localScreenRecording = allowed }
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

        canvas.updateSystemShortcutCapture(sessionActive: mode == .viewer && connected && canControl && !sessionInputSuspended && !desktopActionWorking,
            accessibility: accessibility, inputMonitoring: inputMonitoring, retry: retryCapsLock)
        guard mode == .viewer, capsLockEnabled else {
            canvas.capsLockMonitor.stop()
            canvas.usesCapsLockActions = false
            if capsLockRunning { capsLockRunning = false }
            capsLockStartAttempted = false
            return
        }
        guard accessibility, inputMonitoring else {
            canvas.capsLockMonitor.stop()
            canvas.usesCapsLockActions = false
            if capsLockRunning { capsLockRunning = false }
            capsLockStartAttempted = false
            let waiting = "Caps Lock 等待本机辅助功能和输入监控生效；已勾选时请完全退出后重开，无需反复添加"
            if inputStatus != waiting { inputStatus = waiting }
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
        if capsLockRunning != canvas.capsLockMonitor.isRunning { capsLockRunning = canvas.capsLockMonitor.isRunning }
        canvas.usesCapsLockActions = capsLockRunning && supportsInputActions && canControl && !sessionInputSuspended && !desktopActionWorking
        let outdated = "远端版本较旧，请更新家里 Mac 后使用 Caps Lock 切换输入法"
        if connected, !supportsInputActions, inputStatus != outdated { inputStatus = outdated }
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

    func chooseDisplay(_ id: CGDirectDisplayID) {
        preferredDisplayID = id
        UserDefaults.standard.set(Int(id), forKey: "sharedDisplay")
        displayID = id
        displayFallbackNotice = nil
    }

    private func updateDisplayFallbackNotice() {
        guard displayID != preferredDisplayID else { displayFallbackNotice = nil; return }
        let name = screens.first(where: { $0.id == displayID }).map { "「\($0.name)」" } ?? "备用显示器"
        displayFallbackNotice = "首选显示器当前不可用，正在使用\(name)；恢复后下次开启共享时自动使用首选显示器"
    }

    private func refreshDisplays() {
        let current = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, name: String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }
        screens = current
        let available = current.map { displaySnapshot($0.id) }
        if mode == .host, hostingRequested, active, let capturedDisplay = hostSession.capturedDisplay,
           !DisplaySelection.requiresRestart(captured: capturedDisplay, available: available) {
            displayID = capturedDisplay.id
        } else if let selection = DisplaySelection.select(preferred: preferredDisplayID, main: CGMainDisplayID(), available: available) {
            displayID = selection.id
        }
        updateDisplayFallbackNotice()
        if mode == .host, hostingRequested, active, let capturedDisplay = hostSession.capturedDisplay,
           DisplaySelection.requiresRestart(captured: capturedDisplay, available: available) {
            DiagnosticLog.shared.record(.displayChanged, role: .host, state: .requested)
            restartHostAfterFailure("共享显示器已变化，正在重新准备共享")
        }
    }

    private func selectShareableDisplay(_ displays: [SCDisplay]) throws -> (display: SCDisplay, snapshot: DisplaySnapshot) {
        guard let selection = DisplaySelection.select(preferred: preferredDisplayID, main: CGMainDisplayID(),
            available: displays.filter { CGDisplayIsActive($0.displayID) != 0 }.map { displaySnapshot($0.displayID) }),
              let display = displays.first(where: { $0.displayID == selection.id }) else {
            throw DeskError.invalid("当前没有可共享的显示器，等待显示器恢复")
        }
        if displayID != selection.id { displayID = selection.id }
        updateDisplayFallbackNotice()
        return (display, selection)
    }

    func relayCertificate(for endpoint: RelayEndpoint) throws -> RelayNodeCertificate? {
        try RelayCertificateStore(defaults: .standard).load(for: endpoint)
    }

    /// The relay settings serve both roles, so they change only while neither is sharing or connected.
    var relaySettingsLocked: Bool { active || working || sibling?.active == true || sibling?.working == true }

    static func loadRelayNodes() -> [String] {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: "relayNodes") ?? [defaults.string(forKey: "relayAddress") ?? ""]
        var seen = Set<String>()
        return stored.compactMap { try? RelayEndpoint(address: $0).address }.filter { seen.insert($0).inserted }
    }

    /// Validates one node and stores its access code and trusted certificate, keyed by its address.
    /// Returns the normalized address; the node list itself is saved with `saveRelayConfiguration`.
    func saveRelayNode(address: String, accessCode: String, certificate: RelayNodeCertificate?) throws -> String {
        guard !relaySettingsLocked else { throw DeskError.invalid("请先停止共享并断开连接，再修改中继设置") }
        let endpoint = try RelayEndpoint(address: address)
        let supplied = accessCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if supplied.isEmpty {
            guard try KeyStore.load(account: endpoint.credentialAccount) != nil else {
                throw DeskError.invalid("请填写节点部署者提供的中继接入码，它不是 Mac 配对码")
            }
        } else { try KeyStore.save(try PairingKey(code: supplied), account: endpoint.credentialAccount) }
        if let certificate { try certificate.validate(for: endpoint) }
        try RelayCertificateStore(defaults: .standard).save(certificate, for: endpoint)
        return endpoint.address
    }

    func saveRelayConfiguration(enabled: Bool, nodes: [String], deviceID: String) throws {
        guard !relaySettingsLocked else { throw DeskError.invalid("请先停止共享并断开连接，再修改中继设置") }
        let localID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localID.isEmpty || UUID(uuidString: localID) != nil else { throw DeskError.invalid("本机中继设备标识无效，请恢复配置或更换设备标识") }
        var seen = Set<String>()
        let endpoints = try nodes.map { try RelayEndpoint(address: $0) }.filter { seen.insert($0.address).inserted }
        if enabled {
            guard !endpoints.isEmpty else { throw DeskError.invalid("请至少添加一个自托管中继节点") }
            for endpoint in endpoints where try KeyStore.load(account: endpoint.credentialAccount) == nil {
                throw DeskError.invalid("节点 \(endpoint.address) 尚未保存接入码")
            }
            guard UUID(uuidString: localID) != nil else { throw DeskError.invalid("请先生成本机设备标识") }
        }
        let defaults = UserDefaults.standard
        defaults.set(endpoints.map(\.address), forKey: "relayNodes")
        defaults.set(endpoints.first?.address ?? "", forKey: "relayAddress")
        defaults.set(localID, forKey: "relayDeviceID")
        defaults.set(enabled, forKey: "relayEnabled")
        if !enabled { defaults.set(RelayConnectionStrategy.direct.rawValue, forKey: "relayStrategy") }
        if !endpoints.contains(where: { $0.address == relayNodeChoice }) { defaults.set("", forKey: "relayNodeChoice") }
        reloadRelayConfiguration()
        sibling?.reloadRelayConfiguration()
    }

    /// Re-reads the relay settings, which either role may have saved.
    func reloadRelayConfiguration() {
        let defaults = UserDefaults.standard
        relayEnabled = defaults.bool(forKey: "relayEnabled")
        relayNodes = Self.loadRelayNodes()
        relayDeviceID = defaults.string(forKey: "relayDeviceID") ?? ""
        relayStrategy = RelayConnectionStrategy(rawValue: defaults.string(forKey: "relayStrategy") ?? "") ?? .direct
        relayNodeChoice = defaults.string(forKey: "relayNodeChoice") ?? ""
        relayNodeMeasurements = relayNodeMeasurements.filter { relayNodes.contains($0.key) }
        relayHostStatus = relayEnabled ? "下次开启共享时连接中继" : "中继已关闭"
    }

    func measureRelayNodesIfStale() {
        guard relayEnabled, relayNodes.count > 1 else { return }
        if let relayMeasuredAt, SessionClock.now - relayMeasuredAt < 60 { return }
        measureRelayNodes()
    }

    /// Measures every configured node; the results order relayed connections and label the node picker.
    func measureRelayNodes() {
        guard !relayProbing else { return }
        let endpoints = relayNodes.compactMap { try? RelayEndpoint(address: $0) }
        guard !endpoints.isEmpty else { return }
        relayProbing = true
        Task { [weak self] in
            let results = await Self.probe(endpoints, attempts: 3, timeout: 2)
            guard let self else { return }
            self.relayProbing = false
            self.record(results)
        }
    }

    private func record(_ results: [RelayEndpoint: RelayNodeProbe.Measurement]) {
        for (endpoint, measurement) in results { relayNodeMeasurements[endpoint.address] = measurement }
        relayMeasuredAt = SessionClock.now
    }

    private static func probe(_ endpoints: [RelayEndpoint], attempts: Int, timeout: TimeInterval) async -> [RelayEndpoint: RelayNodeProbe.Measurement] {
        await withTaskGroup(of: (RelayEndpoint, RelayNodeProbe.Measurement).self) { group in
            for endpoint in endpoints {
                group.addTask { (endpoint, await RelayNodeProbe.measure(endpoint, attempts: attempts, timeout: timeout)) }
            }
            var results: [RelayEndpoint: RelayNodeProbe.Measurement] = [:]
            for await (endpoint, measurement) in group { results[endpoint] = measurement }
            return results
        }
    }

    /// Registers on every configured node, so another Mac can reach this one through whichever node suits it.
    private func startRelayRegistration(localPort: UInt16) {
        guard relayHostRegistrations.isEmpty else { return }
        guard relayEnabled else { relayHostStatus = "中继已关闭"; return }
        relayRegistrationStates = [:]
        var failures: [String] = []
        for address in relayNodes {
            do {
                let endpoint = try RelayEndpoint(address: address)
                guard let deviceID = UUID(uuidString: relayDeviceID), let access = try KeyStore.load(account: endpoint.credentialAccount) else {
                    throw DeskError.invalid("请先保存中继地址、接入码和本机设备标识")
                }
                let account = endpoint.credentialAccount + ".owner." + deviceID.uuidString.lowercased()
                let owner: PairingKey
                if let saved = try KeyStore.load(account: account) { owner = saved }
                else { owner = try PairingKey.generate(); try KeyStore.save(owner, account: account) }
                let registration = try RelayHostRegistration(endpoint: endpoint, accessKey: access.data, deviceID: deviceID,
                                                            ownerKey: owner.data, localPort: localPort,
                                                            trustedCertificate: relayCertificate(for: endpoint), peerAssist: relayPeerAssist)
                relayHostRegistrations.append(registration)
                registration.onPeerPath = { [weak self, weak registration] state in
                    DispatchQueue.main.async {
                        guard let self, let registration, self.relayHostRegistrations.contains(where: { $0 === registration }) else { return }
                        self.setPeerPath(state, role: .host)
                    }
                }
                registration.onStatus = { [weak self, weak registration] state in
                    DispatchQueue.main.async {
                        guard let self, let registration, self.hostingRequested,
                              self.relayHostRegistrations.contains(where: { $0 === registration }) else { return }
                        switch state {
                        case .connecting: DiagnosticLog.shared.record(.relayRegistration, role: .host, state: .requested)
                        case .online: DiagnosticLog.shared.record(.relayRegistration, role: .host, state: .ready)
                        case .failed(let error): DiagnosticLog.shared.record(.relayRegistration, role: .host, state: .failed, error: error)
                        }
                        self.relayRegistrationStates[endpoint] = state
                        self.publishRelayHostStatus()
                    }
                }
                relayRegistrationStates[endpoint] = .connecting
            } catch { failures.append("\(address)：\(error.localizedDescription)") }
        }
        guard !relayHostRegistrations.isEmpty else {
            relayHostStatus = "中继未启动：" + (failures.first ?? "没有可用的中继节点")
            return
        }
        publishRelayHostStatus()
        relayHostRegistrations.forEach { $0.start() }
    }

    private func publishRelayHostStatus() {
        let states = relayHostRegistrations.map { ($0.endpoint, relayRegistrationStates[$0.endpoint] ?? .connecting) }
        if states.count == 1, let (endpoint, state) = states.first {
            switch state {
            case .connecting: relayHostStatus = "正在连接中继服务…"
            case .online: relayHostStatus = "已在中继登记 · \(endpoint.host)"
            case .failed(let error): relayHostStatus = "中继不可用：\(error.localizedDescription)"
            }
            return
        }
        var online: [String] = [], failed: [String] = [], connecting = 0
        for (endpoint, state) in states {
            switch state {
            case .connecting: connecting += 1
            case .online: online.append(endpoint.host)
            case .failed(let error): failed.append("\(endpoint.host) 不可用：\(error.localizedDescription)")
            }
        }
        var parts = ["已在 \(online.count)/\(states.count) 个中继登记" + (online.isEmpty ? "" : " · " + online.joined(separator: "、"))]
        if connecting > 0 { parts.append("\(connecting) 个正在连接") }
        parts += failed
        relayHostStatus = parts.joined(separator: "；")
    }

    func startHosting(interactive: Bool = true) {
        guard !active, !working, !systemSleeping else { return }
        prepareHostCode()
        guard !hostCode.isEmpty else {
            hostingRequested = false
            status = hostCodeNeedsSetup ? "请先补录原配对码，或明确选择生成新配对码，再开启共享" : "配对码未能读取，请检查本机凭据文件"
            return
        }
        if interactive { hostBackoff.reset() }
        DiagnosticLog.shared.record(.hostStarted, role: .host, state: .requested)
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
                hostingRequested = false
                return
            }
            hostingRequested = true
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
                    let listener = try NWListener(using: MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases), on: port)
                    let admission = PendingHandshakeGate()
                    // Every relayed channel arrives from the local forwarder, so with relay enabled loopback
                    // sources get their own pending budget instead of sharing one per-address rate limit.
                    let relayAdmission = self.relayEnabled ? PendingHandshakeGate() : nil
                    listener.newConnectionHandler = { [weak self] connection in
                        let address: String?
                        if case .hostPort(let host, _) = connection.endpoint { address = host.debugDescription }
                        else { address = nil }
                        let gate = address == "127.0.0.1" ? relayAdmission ?? admission : admission
                        guard let id = gate.reserve(address: gate === admission ? address : nil, now: SessionClock.now) else {
                            connection.cancel()
                            return
                        }
                        DispatchQueue.main.async {
                            guard let self, self.generation == token, self.active else {
                                gate.release(id)
                                connection.cancel()
                                return
                            }
                            self.accept(connection, generation: token, admission: gate, id: id, listeningPort: port.rawValue, key: key)
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
                                self.startRelayRegistration(localPort: port.rawValue)
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
            hostingRequested = false
            working = false
            recordDiagnosticFailure(.hostStopped, error: error)
            status = "共享未启动：\(error.localizedDescription)"
            if interactive { self.error = error.localizedDescription }
        }
    }

    private func accept(_ connection: NWConnection, generation token: UUID, admission: PendingHandshakeGate, id: UUID, listeningPort: UInt16, key: PairingKey) {
        let diagnostics = PerformanceDiagnostics()
        let ackStretchingDisabled = (connection.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching
        let candidate = Peer(connection: connection, handshakeTimeout: peer == nil ? 15 : 5, diagnostics: diagnostics)
        let channel = makeDataChannel(for: candidate)
        let session = makeTrafficSession(for: candidate)
        let history = trafficHistoryStore
        let auxiliarySession = hostSession.media
        let relayRegistrations = relayHostRegistrations
        pending[id] = candidate
        candidate.onReady = { [weak self, weak candidate] in
            admission.release(id)
            // The node that forwarded this control channel, if any; every node carries the same device ID.
            let relayRegistration = relayRegistrations.first { $0.ownsLocalEndpoint(connection.endpoint) }
            let relayed = relayRegistration != nil
            if relayed { candidate?.setTransportDiagnosticsSupported(false) }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                guard let candidate, let auxiliarySession else { candidate?.close("媒体控制会话不存在"); return }
                auxiliarySession.acceptAuxiliary(candidate, role: role)
                DispatchQueue.main.async { self?.pending.removeValue(forKey: id) }
                return
            }
            DispatchQueue.main.async {
                guard let self, let candidate, self.pending.removeValue(forKey: id) != nil,
                      self.generation == token, self.active, self.hostingRequested else { return }
                guard self.peer == nil else { candidate.close("这台 Mac 当前已有控制连接"); return }
                // One session at a time: while this Mac controls another one it is not controlled itself.
                if self.sibling?.isControllingAnotherMac == true {
                    DiagnosticLog.shared.record(.connectionClosed, role: .host, state: .rejected)
                    candidate.close("这台 Mac 正在远程控制另一台 Mac，暂不接受控制连接", retryable: true)
                    return
                }
                DiagnosticLog.shared.record(.connectionReady, role: .host, state: .ready,
                    values: relayed ? [.relayControl: 1] : ackStretchingDisabled.map { [.tcpAckStretchingDisabled: $0 ? 1 : 0] } ?? [:])
                self.peer = candidate
                self.attachPerformanceDiagnostics(diagnostics, role: .host)
                self.dataChannel = channel
                self.trafficSession = session
                do {
                    let endpoint: TrafficEndpoint
                    if relayed, let node = relayRegistration?.endpoint { endpoint = try TrafficEndpoint(address: node.host, port: node.port) }
                    else { endpoint = try TrafficEndpoint(remoteEndpoint: connection.endpoint, listeningPort: listeningPort) }
                    try session.bind(endpoint)
                    self.trafficHistoryStatus = relayed ? "按中继节点地址＋端口累计：\(endpoint.label)"
                        : "按控制端来源 IP＋本机监听端口累计：\(endpoint.label)"
                } catch {
                    self.trafficHistoryStatus = "当前连接的来源地址不可识别，未累计此连接的历史流量。"
                    history.reportCountingError(error.localizedDescription)
                }
                self.status = "正在准备连接画面…"
                let host = self.hostSession
                host.usesRelayControl = relayed
                self.controlTransportStatus = relayed ? "中继控制" : "直连控制"
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
                        let streamer = ScreenStreamer(diagnostics: diagnostics)
                        host.streamer = streamer
                        let media = try MediaSession.host(control: candidate, key: key, port: listeningPort, settings: settings,
                                                          relayRouting: true)
                        // Video may arrive through any node, also when control came directly.
                        media.isRelayedDatagram = { endpoint in relayRegistrations.contains { $0.ownsLocalDatagramEndpoint(endpoint) } }
                        media.onRelayedDatagramAuthenticated = { endpoint, secret in
                            relayRegistrations.first { $0.ownsLocalDatagramEndpoint(endpoint) }?
                                .enablePeerAssist(localDatagramEndpoint: endpoint, secret: secret)
                        }
                        media.diagnostics = diagnostics
                        host.media = media
                        channel.configureMedia { [weak media] in media?.receive($0) ?? false }
                        channel.configureReliableData { [weak media] in media?.sendReliableData($0) }
                        media.onReliableData = { [weak candidate] message in
                            do { _ = try channel.receive(message) }
                            catch { candidate?.close(error.localizedDescription) }
                        }
                        media.onPrepareRecovery = { [weak streamer] completion in
                            guard let streamer else { completion(false); return }
                            streamer.prepareMediaRecovery(completion: completion)
                        }
                        media.onPrepareStream = { [weak self, weak streamer, weak host, weak candidate] stream, completion in
                            guard let streamer else { completion(false); return }
                            streamer.prepareMediaRecovery { ready in
                                DispatchQueue.main.async {
                                    guard let self, let host, let candidate, self.hostSession === host,
                                          self.peer === candidate, ready else { completion(false); return }
                                    host.mediaPrepared = true
                                    if host.cursorSubscribed {
                                        guard let included = streamer.currentCursorIncluded else { completion(false); return }
                                        do {
                                            candidate.send(try CursorControl(.binding, cursorID: host.cursorID,
                                                epoch: host.cursorEpoch, enabled: !included, stream: stream).message())
                                        } catch { candidate.close(error.localizedDescription); completion(false); return }
                                    }
                                    completion(true)
                                }
                            }
                        }
                        media.onProduceRecoveryFrame = { [weak streamer] in streamer?.produceMediaRecoveryFrame() }
                        media.onResumeFrames = { [weak streamer] in streamer?.resumeMediaFrames() }
                        media.onAcknowledged = { [weak streamer] in streamer?.acknowledge($0) }
                        streamer.onEncodeDuration = { [weak media] seconds in
                            media?.recordComputeTiming(encodeMilliseconds: seconds * 1000)
                        }
                        media.onBytes = { channel.recordBytes($0) }
                        media.onFrameSent = { channel.recordFrame() }
                        media.onState = { [weak self, weak host] value in
                            DispatchQueue.main.async {
                                guard let self, let host, self.hostSession === host else { return }
                                self.setMediaRoute(Self.mediaRouteLabel(value, relayed: host.usesRelayControl))
                                self.recordMediaRoute(value, role: .host, relayed: host.usesRelayControl)
                            }
                        }
                        media.start()
                        candidate.send(try Wire.json(.hello, Hello(name: Host.current().localizedName ?? "家里 Mac",
                            width: width, height: height, settings: settings, canControl: self.canControl,
                            preferredSettings: preferredSettings.extendedCompatible, deviceID: self.trafficHistoryStore.localDeviceID,
                            deviceIdentityExchange: host.deviceIdentityAdvertised ? true : nil,
                            highRefreshVideoSettings: true, preferredHighRefreshSettings: preferredSettings.highRefreshCompatible,
                            sessionEffects: true, sessionPause: true, mediaTransportV1: true, independentCursorV1: true,
                            relayTransportV1: true, relayDeviceID: relayRegistrations.first?.deviceID, sessionLockV1: true,
                            adaptiveVideoV1: true, sessionUnlockV1: true, screenLocked: ScreenLockState.isLockedOnConsole,
                            higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: preferredSettings,
                            displayDimmingV1: true, builtInDisplayDimmable: host.effects?.canDimBuiltInDisplay == true,
                            sessionTerminationV1: true, desktopActionsV1: true)))
                        candidate.setVideoPacing(VideoSendPacing(megabits: settings.megabits))
                        channel.configureAcknowledgement { [weak streamer] in streamer?.acknowledge($0) }
                        streamer.onFrame = { [weak media] packet in media?.sendVideo(packet) }
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
            Task { @MainActor in
                defer { resume() }
                guard let self, let candidate, self.generation == token, self.active, self.peer === candidate else { return }
                guard self.connected else {
                    if message.kind != .releaseInput { candidate.close("屏幕共享尚未就绪", retryable: true) }
                    return
                }
                do { try await self.handleHost(message, peer: candidate) }
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
        connect(savedRelayRoute: nil)
    }

    private func connect(savedRelayRoute: RelayConnectionInfo?) {
        guard !active, !working else { return }
        remoteName = ""
        connectionError = nil
        if sibling?.hasIncomingControlConnection == true {
            connectionError = "这台 Mac 正在被另一台 Mac 控制；对方断开后才能连接其他 Mac，共享无需关闭"
            return
        }
        do {
            let routes: [RelayRoute]
            if let savedRelayRoute {
                guard relayEnabled else { throw DeskError.invalid("此记录需要中继，请先在中继设置中启用服务") }
                routes = try relayRoutes(deviceID: savedRelayRoute.deviceID, strategy: savedRelayRoute.strategy,
                                         preferred: savedRelayRoute.endpoint)
            } else if relayEnabled, relayStrategy != .direct {
                guard let id = UUID(uuidString: targetRelayDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw DeskError.invalid("请填写被控端显示的完整中继设备标识")
                }
                routes = try relayRoutes(deviceID: id, strategy: relayStrategy, preferred: nil)
            } else { routes = [] }
            let relay = routes.first?.info
            let address = relay?.strategy == .relay ? "" : self.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (!address.isEmpty || relay != nil), !address.contains("://"), !address.contains("/") else {
                throw DeskError.invalid("请输入域名或 IP，端口填在单独的端口栏")
            }
            let key = try PairingKey(code: viewerCode)
            let port: NWEndpoint.Port
            if address.isEmpty { port = 5908 } else { port = try validPort() }
            if !address.isEmpty {
                UserDefaults.standard.set(address, forKey: "remoteAddress")
                UserDefaults.standard.set(self.port, forKey: "remotePort")
            }
            UserDefaults.standard.set(relay?.strategy.rawValue ?? RelayConnectionStrategy.direct.rawValue, forKey: "relayStrategy")
            relayStrategy = relay?.strategy ?? .direct
            UserDefaults.standard.set(targetRelayDeviceID, forKey: "targetRelayDeviceID")
            let record = ConnectionStore.matching(connections, address: address, port: port.rawValue, preferredID: selectedConnectionID, relay: relay)
            let preference = record ?? (!address.isEmpty ? ConnectionStore.matching(connections, address: address, port: port.rawValue, preferredID: selectedConnectionID) : nil)
            let endpoint: TrafficEndpoint
            if address.isEmpty, let relay { endpoint = try TrafficEndpoint(address: relay.endpoint.host, port: relay.endpoint.port) }
            else { endpoint = try TrafficEndpoint(address: address, port: port.rawValue) }
            var target = Target(address: address, port: port.rawValue, key: key, recordID: record?.id,
                                trafficEndpoint: endpoint, relay: relay, relayAccessKey: routes.first?.accessKey,
                                relayCertificate: routes.first?.certificate)
            target.relayRoutes = routes
            self.target = target
            relaySelectedForTarget = relay?.strategy == .relay || (relay != nil && address.isEmpty)
            relayFallbackAttempted = false
            relayFallbackCooldown.reset()
            idlePolicy = SessionIdlePolicy(now: SessionClock.now)
            _ = idlePolicy.attentionChanged(now: SessionClock.now, attended: sessionWindowAttended, suppressWake: true)
            pauseTransmission = SessionPauseTransmission()
            wakeInputGate = SessionWakeInputGate()
            reconnectDeferredForIdle = false
            freshFrameRequiredOnReconnect = false
            let saved = preference?.videoSettings
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

    private func configureViewerMedia(peer: Peer, settings: StreamSettings, preferred: StreamSettings, relayRouting: Bool) throws {
        guard let target, let channel = dataChannel else { return }
        let viewer = viewerSession
        let renderer = canvas.makeMediaReceiver(diagnostics: performanceDiagnostics)
        let media = try MediaSession.viewer(control: peer, key: target.key, host: viewer.transportHost ?? target.address, port: viewer.transportPort ?? target.port,
                                            settings: settings, udpEnabled: !mediaTCPOnly, relayRouting: relayRouting,
                                            relayedDatagram: viewer.usesRelayControl)
        media.diagnostics = performanceDiagnostics
        media.onDatagramLoss = { [weak self, weak viewer] fraction in
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                self.mediaLossFraction = fraction
                let label = fraction.map(Self.lossLabel) ?? ""
                if self.mediaLoss != label { self.mediaLoss = label }
            }
        }
        media.onRelayedDatagramAuthenticated = { [weak viewer] _, secret in
            DispatchQueue.main.async {
                guard let viewer else { return }
                (viewer.mediaRelayBridge ?? viewer.relayBridge)?.enablePeerAssist(secret: secret)
            }
        }
        viewer.media = media
        viewer.mediaReceiver = renderer
        canvas.onCursorPresentation = { [weak self, weak viewer] enabled, known in
            guard let self, let viewer, self.viewerSession === viewer else { return }
            self.cursorStatus = enabled ? (known ? "本地即时光标" : "本地即时光标 · 通用指针") : "视频光标"
        }
        supportsMediaTransport = true
        // Keep the saved preference for reconnects; this session's ceiling must fit the host's capabilities.
        viewer.mediaQuality = try MediaQualityPolicy(hostDefault: preferred, preferred: viewerQualityPolicy.preferred == nil ? nil : preferred,
                                                   applied: settings, bitRates: supportsAdaptiveVideo ? StreamSettings.adaptiveBitRates : viewerBitRates,
                                                   appliedSize: activeVideoState.map { ($0.width, $0.height) }, now: SessionClock.now)
        channel.configureMedia { [weak media] in media?.receive($0) ?? false }
        channel.configureReliableData { [weak media] in media?.sendReliableData($0) }
        renderer.reportDecodeTime { [weak media] milliseconds in media?.recordComputeTiming(decodeMilliseconds: milliseconds) }
        media.onVideo = { [weak renderer] frame, completion in
            guard let renderer else { completion(false); return }
            channel.mediaFrameReceived(frame.header)
            renderer.receive(frame) { succeeded in
                if succeeded { channel.recordFrame() }
                completion(succeeded)
            }
        }
        media.onCommitStream = { [weak self, weak viewer, weak renderer] stream, _ in
            renderer?.commit(stream: stream)
            channel.mediaStreamCommitted(stream)
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer, !viewer.mediaCommitted else { return }
                viewer.mediaCommitted = true
                self.sendCursorRequest()
            }
        }
        media.onBytes = { channel.recordBytes($0) }
        media.onReliableData = { [weak peer] message in
            do { _ = try channel.receive(message) }
            catch { peer?.close(error.localizedDescription) }
        }
        media.onState = { [weak self, weak viewer] value in
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                self.setMediaRoute(Self.mediaRouteLabel(value, relayed: viewer.usesRelayControl))
                self.recordMediaRoute(value, role: .viewer, relayed: viewer.usesRelayControl)
            }
        }
        media.onPathSwitch = { [weak self, weak viewer] value, cause in
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                viewer.mediaQuality?.resetObservation(now: SessionClock.now)
                self.recordMediaPathSwitch(value, cause: cause, relayed: viewer.usesRelayControl)
            }
        }
        media.onLocalNetwork = { [weak self, weak viewer] local in
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                self.localNetworkQuality = local
                viewer.mediaQuality?.setLocalNetwork(local, now: SessionClock.now)
                self.automaticQualityNote = ""
            }
        }
        media.onReduceLoad = { [weak self, weak viewer] cause in
            DispatchQueue.main.async {
                // Network reductions from the media session follow a keyframe that UDP could not deliver.
                guard let self, let viewer, self.viewerSession === viewer,
                      let next = viewer.mediaQuality?.reduceLoad(for: cause, severe: cause == .network, now: SessionClock.now) else { return }
                self.applyAutomaticMediaSettings(next)
            }
        }
        media.onSample = { [weak self, weak viewer] sample in
            DispatchQueue.main.async {
                guard let self, let viewer, self.viewerSession === viewer,
                      let next = viewer.mediaQuality?.observe(sample, now: SessionClock.now) else { return }
                self.applyAutomaticMediaSettings(next)
            }
        }
        if relayRouting {
            if !viewer.usesRelayControl, viewer.relayTargetVerified,
               let relay = target.relay, relay.strategy == .automatic, let access = target.relayAccessKey {
                media.prepareAlternateDatagramPath = { [weak self, weak viewer, weak media] completion in
                    DispatchQueue.main.async {
                        guard let self, let viewer, self.viewerSession === viewer, self.active else { completion(nil); return }
                        do {
                            viewer.mediaRelayBridge?.stop()
                            let bridge = try RelayViewerBridge(endpoint: relay.endpoint, accessKey: access, deviceID: relay.deviceID,
                                                              trustedCertificate: target.relayCertificate, peerAssist: self.relayPeerAssist)
                            viewer.mediaRelayBridge = bridge
                            self.observePeerPath(bridge, viewer: viewer)
                            bridge.onReady = { [weak self, weak viewer, weak bridge] port in
                                DispatchQueue.main.async {
                                    guard let self, let viewer, let bridge, self.viewerSession === viewer,
                                          viewer.mediaRelayBridge === bridge, self.active else { completion(nil); return }
                                    completion(MediaSession.DatagramEndpoint(host: "127.0.0.1", port: port,
                                                                             retire: { [weak bridge] in bridge?.retireDatagramPath() }))
                                }
                            }
                            bridge.onClose = { [weak self, weak viewer, weak bridge, weak media] _ in
                                DispatchQueue.main.async {
                                    guard let self, let viewer, let bridge, self.viewerSession === viewer,
                                          viewer.mediaRelayBridge === bridge else { return }
                                    viewer.mediaRelayBridge = nil
                                    media?.alternateDatagramPathClosed(); completion(nil)
                                }
                            }
                            bridge.onDatagramFailure = { [weak media] _ in media?.networkPathChanged() }
                            bridge.start()
                        } catch { completion(nil) }
                    }
                }
            }
            let controlBridge = viewer.relayBridge
            media.onDatagramPathRetired = { [weak controlBridge] in controlBridge?.retireDatagramPath() }
            media.onReliablePathFailure = { [weak self, weak viewer, weak peer] in
                DispatchQueue.main.async {
                    guard let self, let viewer, let peer, self.viewerSession === viewer, self.peer === peer,
                          !self.systemSleeping, !self.idlePolicy.isPaused, !self.pauseTransmission.desiredPaused else { return }
                    if !viewer.usesRelayControl, viewer.relayTargetVerified, target.relay?.strategy == .automatic,
                       self.autoReconnect || !viewer.mediaCommitted {
                        // A recent relay fallback failed: keep recovering over the direct route instead of alternating.
                        guard self.relayFallbackCooldown.allows(now: SessionClock.now) else { return }
                        viewer.relayFallbackRequested = true
                        peer.close("直连视频持续无法交付，改用可靠中继连接", retryable: true)
                    } else {
                        peer.close("视频持续无法交付，请检查网络或中继节点后重新连接")
                    }
                }
            }
        }
        media.start()
    }

    private static func mediaRouteLabel(_ value: String, relayed: Bool) -> String {
        guard relayed else { return value }
        switch value {
        case "UDP 视频", "TCP 视频", "TCP 兼容模式": return "中继 " + value
        default: return value
        }
    }

    private func observePeerPath(_ bridge: RelayViewerBridge, viewer: ViewerSession) {
        bridge.onPeerPath = { [weak self, weak viewer, weak bridge] state in
            DispatchQueue.main.async {
                guard let self, let viewer, let bridge, self.viewerSession === viewer,
                      viewer.relayBridge === bridge || viewer.mediaRelayBridge === bridge else { return }
                self.setPeerPath(state, role: .viewer)
            }
        }
    }

    private static func lossLabel(_ fraction: Double) -> String {
        fraction > 0 && fraction < 0.001 ? "丢包 <0.1%" : String(format: "丢包 %.1f%%", fraction * 100)
    }

    private func setMediaRoute(_ label: String) {
        mediaRouteValue = label
        mediaTransportStatus = Self.peerRouteLabel(label, peerPath: peerPathState)
    }

    // The bridge reports its outer path from real authenticated traffic; the label changes only once
    // the direct path was nominated and confirmed, and returns as soon as video is back on the node.
    private func setPeerPath(_ state: RelayPeerPathState, role: DiagnosticLog.Role) {
        guard state != peerPathState else { return }
        peerPathState = state
        relayPeerStatus = Self.peerPathDescription(state)
        if !mediaRouteValue.isEmpty { mediaTransportStatus = Self.peerRouteLabel(mediaRouteValue, peerPath: state) }
        var values: [DiagnosticLog.Field: Int] = [.peerPath: state.diagnosticCode]
        if case .direct(let kind) = state { values[.candidateKind] = kind == .host ? 1 : kind == .srflx ? 2 : 3 }
        let phase: DiagnosticLog.State
        switch state {
        case .relay: phase = .disabled
        case .checking: phase = .requested
        case .direct: phase = .ready
        case .relayFaster: phase = .rejected
        case .unreachable: phase = .failed
        }
        DiagnosticLog.shared.record(.peerPathChanged, role: role, state: phase, values: values)
    }

    private static func peerRouteLabel(_ label: String, peerPath: RelayPeerPathState) -> String {
        guard label == "中继 UDP 视频", case .direct = peerPath else { return label }
        return "直连 UDP 视频（中继打洞）"
    }

    private static func peerPathDescription(_ state: RelayPeerPathState) -> String {
        switch state {
        case .relay: return "视频经中继"
        case .checking: return "正在尝试打洞…"
        case .direct(.host): return "已打洞直连 · 网卡地址"
        case .direct(.srflx): return "已打洞直连 · 公网映射"
        case .direct(.prflx): return "已打洞直连 · 对端映射"
        case .relayFaster: return "中继延迟或丢包更低，视频保持中继"
        case .unreachable: return "未能打通或直连中断，视频经中继，稍后重试"
        }
    }

    private static func mediaPathCode(_ value: String) -> Int? {
        switch value { case "UDP 视频", "中继 UDP 视频": return 1; case "TCP 视频": return 2; case "TCP 兼容模式": return 3; default: return nil }
    }

    private func recordMediaRoute(_ value: String, role: DiagnosticLog.Role, relayed: Bool) {
        guard relayEnabled, let path = Self.mediaPathCode(value) else { return }
        DiagnosticLog.shared.record(.mediaRouteChanged, role: role, state: .ready,
                                    values: [.relayControl: relayed ? 1 : 0, .relayVideo: relayed || value == "中继 UDP 视频" ? 1 : 0, .videoPath: path])
    }

    // Route changes are rare; their cause explains UDP/TCP alternation that route snapshots alone cannot.
    private func recordMediaPathSwitch(_ value: String, cause: MediaSwitchCause, relayed: Bool) {
        guard let path = Self.mediaPathCode(value) else { return }
        var values: [DiagnosticLog.Field: Int] = [.relayControl: relayed ? 1 : 0, .videoPath: path, .switchCause: cause.diagnosticCode]
        // UDP loss just before leaving UDP explains many fallbacks; absent when the previous path was TCP.
        if let mediaLossFraction { values[.lossPermille] = Int((mediaLossFraction * 1000).rounded()) }
        DiagnosticLog.shared.record(.mediaPathSwitch, role: .viewer, state: .requested, values: values)
    }

    private func applyAutomaticMediaSettings(_ settings: StreamSettings) {
        guard connected, supportsLiveSettings, var tuning = videoTuning,
              tuning.pending == nil, tuning.desired == tuning.applied.settings else {
            viewerSession.mediaQuality?.rejectPending(now: SessionClock.now)
            return
        }
        do { try tuning.choose(settings) }
        catch { viewerSession.mediaQuality?.rejectPending(now: SessionClock.now); return }
        viewerSession.automaticVideoSettings = settings
        viewerSession.automaticVideoAdjustment = viewerSession.mediaQuality?.lastAdjustment
        videoTuning = tuning
        sendNextVideoSettings()
    }

    private func sendCursorRequest() {
        guard mode == .viewer, connected, supportsIndependentCursor, let peer,
              viewerSession.mediaCommitted, viewerSession.cursorRequestID == nil else { return }
        let viewer = viewerSession, id = UUID()
        viewer.cursorRequestID = id
        viewer.cursorRequestedEnabled = lowLatencyCursorEnabled
        cursorStatus = "正在切换光标…"
        do { peer.send(try CursorControl(.request, requestID: id, enabled: lowLatencyCursorEnabled).message()) }
        catch { peer.close(error.localizedDescription); return }
        viewer.cursorTimeout?.cancel()
        viewer.cursorTimeout = Task { [weak self, weak viewer, weak peer] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let viewer, let peer, self.viewerSession === viewer,
                  viewer.cursorRequestID == id else { return }
            peer.close("光标模式切换超时，重新建立会话", retryable: true)
        }
    }

    private func applyHostCursorRequest(_ request: CursorControl, peer: Peer) {
        let host = hostSession
        guard let id = request.requestID, host.cursorTask == nil, let streamer = host.streamer else { return }
        let capture = host.captureTask, settings = host.settingsTask, pause = host.pauseTask, effects = host.effectsTask
        let token = generation
        host.cursorTask = Task { [weak self, weak host, weak peer] in
            guard let self, let host, let peer else { return }
            defer { if self.hostSession === host { host.cursorTask = nil } }
            await capture?.value; await settings?.value; await pause?.value; await effects?.value
            guard self.hostSession === host, self.peer === peer, self.generation == token, !Task.isCancelled else { return }
            guard host.cursorEpoch < UInt32.max else { peer.close("光标模式代次已耗尽，请重新连接", retryable: true); return }
            await self.suspendMediaForConfiguration(host.media)
            guard self.hostSession === host, self.peer === peer, !Task.isCancelled else { return }
            host.cursorSampler?.stop()
            var reason: CursorControl.Reason?
            // Restore the physical cursor before any frame can include it again.
            if !request.enabled, let error = host.effects?.setIndependentCursor(false) {
                peer.close("本机光标恢复失败，正在结束共享：\(error)", retryable: true)
                return
            }
            do {
                try await streamer.setCursorIncluded(!request.enabled)
                host.cursorEnabled = request.enabled
                if host.paused { reason = .waitingForResume }
            } catch {
                guard self.hostSession === host, self.peer === peer, !Task.isCancelled else { return }
                guard let actual = streamer.currentCursorIncluded else {
                    peer.close("无法确认光标采集状态，重新建立会话", retryable: true)
                    return
                }
                host.cursorEnabled = !actual
                reason = .unavailable
            }
            guard self.hostSession === host, self.peer === peer, !Task.isCancelled else { return }
            if let error = host.effects?.setIndependentCursor(host.cursorEnabled), !host.cursorEnabled {
                peer.close("本机光标恢复失败，正在结束共享：\(error)", retryable: true)
                return
            }
            host.cursorEpoch += 1
            host.cursorSubscribed = true
            host.cursorShapeRevision = 0; host.cursorPositionSequence = 0
            do {
                peer.send(try CursorControl(.status, requestID: id, cursorID: host.cursorID,
                    epoch: host.cursorEpoch, enabled: host.cursorEnabled, reason: reason).message())
            } catch { peer.close(error.localizedDescription); return }
            self.startHostCursorSampler(host, peer: peer)
            streamer.resumeAfterReconfiguration()
            if !host.paused { host.media?.resumeAfterConfiguration() }
        }
    }

    private func startHostCursorSampler(_ host: HostSession, peer: Peer) {
        host.cursorSampler?.stop()
        guard host.cursorSubscribed, host.cursorEnabled, !host.paused, let display = host.capturedDisplay else { return }
        let epoch = host.cursorEpoch
        let sampler = HostCursorSampler(display: display)
        host.cursorSampler = sampler
        sampler.onSample = { [weak self, weak host, weak peer] sample in
            guard let self, let host, let peer, self.hostSession === host, self.peer === peer,
                  host.cursorEpoch == epoch, host.cursorEnabled, !host.paused else { return }
            guard host.cursorShapeRevision < UInt64.max, host.cursorPositionSequence < UInt64.max else {
                peer.close("光标消息序号已耗尽，请重新连接", retryable: true); return
            }
            do {
                if sample.shapeChanged {
                    host.cursorShapeRevision += 1
                    let shape = try CursorShape(cursorID: host.cursorID, epoch: epoch,
                                                revision: host.cursorShapeRevision, image: sample.image)
                    peer.send(Message(.cursorShape, shape.encode()))
                }
                host.cursorPositionSequence += 1
                let position = try CursorPosition(cursorID: host.cursorID, epoch: epoch,
                    sequence: host.cursorPositionSequence, insideDisplay: sample.insideDisplay, x: sample.x, y: sample.y)
                peer.send(Message(.cursorPosition, position.encode()))
            } catch { peer.close(error.localizedDescription) }
        }
        sampler.start()
    }

    /// The nodes a relayed connection may use: the node picked in the form, or every node with a saved
    /// access code, starting with the record's last node until a measurement orders them.
    private func relayRoutes(deviceID: UUID, strategy: RelayConnectionStrategy, preferred: RelayEndpoint?) throws -> [RelayRoute] {
        var endpoints = relayNodes.compactMap { try? RelayEndpoint(address: $0) }
        if let choice = endpoints.first(where: { $0.address == relayNodeChoice }) { endpoints = [choice] }
        else if let preferred { endpoints.removeAll { $0 == preferred }; endpoints.insert(preferred, at: 0) }
        var routes: [RelayRoute] = []
        for endpoint in endpoints {
            guard let access = try KeyStore.load(account: endpoint.credentialAccount) else { continue }
            routes.append(RelayRoute(info: try RelayConnectionInfo(endpoint: endpoint, deviceID: deviceID, strategy: strategy),
                                     accessKey: access.data, certificate: try relayCertificate(for: endpoint)))
        }
        guard !routes.isEmpty else { throw DeskError.invalid("此中继节点尚未保存接入码，请打开中继设置") }
        return routes
    }

    /// Measures the candidate nodes and connects through them best first.
    private func orderRelayRoutes(_ target: Target) {
        let token = generation
        let endpoints = target.relayRoutes.map(\.info.endpoint)
        active = true; working = true
        controlTransportStatus = "正在选择中继节点"
        status = "正在测量 \(endpoints.count) 个中继节点的连接质量…"
        Task { [weak self] in
            let results = await Self.probe(endpoints, attempts: 2, timeout: 1.2)
            guard let self, self.generation == token, self.active, self.peer == nil, !self.systemSleeping else { return }
            self.record(results)
            var ordered = target
            ordered.relayRoutes = RelayNodeProbe.ordered(endpoints, by: results).compactMap { endpoint in
                target.relayRoutes.first { $0.info.endpoint == endpoint }
            }
            ordered.relayRoutesOrdered = true
            if let best = ordered.relayRoutes.first { ordered = ordered.using(best) }
            self.target = ordered
            self.beginConnection(ordered)
        }
    }

    /// After a node could not reach the target before the desktop stream, tries the next node.
    private func failOverRelay(from target: Target, reason: String) -> Bool {
        guard relaySelectedForTarget, let current = target.relay?.endpoint,
              let index = target.relayRoutes.firstIndex(where: { $0.info.endpoint == current }),
              index + 1 < target.relayRoutes.count else { return false }
        let next = target.using(target.relayRoutes[index + 1])
        self.target = next
        status = "\(current.host) 未接通（\(reason)），改用 \(next.relay?.endpoint.host ?? "下一个节点")…"
        DiagnosticLog.shared.record(.relayRegistration, role: .viewer, state: .rejected)
        beginConnection(next)
        return true
    }

    private func beginConnection(_ target: Target) {
        guard peer == nil, !systemSleeping else { return }
        if reconnecting {
            _ = idlePolicy.tick(now: SessionClock.now, attended: sessionWindowAttended)
            if idlePolicy.isPaused { deferReconnectForIdle("离开窗口 10 分钟"); return }
        }
        if relaySelectedForTarget, let relay = target.relay, let access = target.relayAccessKey {
            if target.relayRoutes.count > 1, !target.relayRoutesOrdered { orderRelayRoutes(target); return }
            let viewer = viewerSession
            guard viewer.relayBridge == nil else { return }
            do {
                let bridge = try RelayViewerBridge(endpoint: relay.endpoint, accessKey: access, deviceID: relay.deviceID, udpEnabled: !mediaTCPOnly,
                                                  trustedCertificate: target.relayCertificate, peerAssist: relayPeerAssist)
                viewer.relayBridge = bridge; viewer.usesRelayControl = true
                observePeerPath(bridge, viewer: viewer)
                active = true; working = true
                controlTransportStatus = "正在接通中继"
                status = "正在通过 \(relay.endpoint.host) 接通目标设备…"
                let token = generation
                bridge.onReady = { [weak self, weak viewer, weak bridge] port in
                    DispatchQueue.main.async {
                        guard let self, let viewer, let bridge, self.generation == token, self.viewerSession === viewer,
                              viewer.relayBridge === bridge, self.active else { return }
                        self.beginPeerConnection(target, host: "127.0.0.1", port: port, viaRelay: true)
                    }
                }
                bridge.onClose = { [weak self, weak viewer, weak bridge] error in
                    DispatchQueue.main.async {
                        guard let self, let viewer, let bridge, self.generation == token, self.viewerSession === viewer,
                              viewer.relayBridge === bridge, self.active else { return }
                        let retryable = (error as? RelayServiceError)?.retryable ?? (error as? RelayTransportError)?.retryable ?? false
                        if let peer = self.peer {
                            if bridge.failedBeforeDesktopStream { peer.close(error.localizedDescription, retryable: retryable) }
                        } else {
                            let reason = error.localizedDescription
                            self.recordDisconnect(reason); self.clearSession()
                            if self.failOverRelay(from: target, reason: reason) { return }
                            if retryable, self.autoReconnect, self.target != nil {
                                if relay.strategy == .automatic, !target.address.isEmpty {
                                    self.relaySelectedForTarget = false; self.relayFallbackFailed()
                                }
                                self.scheduleReconnect(reason)
                            } else { self.stop(); self.status = reason; self.connectionError = reason }
                        }
                    }
                }
                bridge.start()
            } catch { stop(); status = error.localizedDescription; connectionError = error.localizedDescription }
            return
        }
        beginPeerConnection(target, host: target.address, port: target.port, viaRelay: false)
    }

    private func beginPeerConnection(_ target: Target, host: String, port: UInt16, viaRelay: Bool) {
        guard peer == nil, !systemSleeping else { return }
        let diagnostics = PerformanceDiagnostics(enabled: performanceDiagnosticsEnabled)
        let connection = NWConnection(host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!, using: SecureTransport.parameters(key: target.key, responsiveAcknowledgements: true))
        let ackStretchingDisabled = (connection.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching
        let candidate = Peer(connection: connection, handshakeTimeout: viaRelay ? 25 : 15, diagnostics: diagnostics,
                             transportDiagnosticsSupported: !viaRelay)
        attachPerformanceDiagnostics(diagnostics, role: .viewer)
        DiagnosticLog.shared.record(.connectionStarted, role: .viewer, state: .requested)
        trafficSession = makeTrafficSession(for: candidate, endpoint: target.trafficEndpoint)
        let history = trafficHistoryStore
        trafficHistoryStatus = viaRelay ? "按连接目标累计（经中继）：\(target.trafficEndpoint.label)"
            : "按连接地址＋目标端口累计：\(target.trafficEndpoint.label)"
        peer = candidate
        let channel = makeDataChannel(for: candidate)
        dataChannel = channel
        active = true
        working = true
        let viewer = viewerSession
        viewer.usesRelayControl = viaRelay; viewer.transportHost = host; viewer.transportPort = port
        viewer.helloReceived = false
        candidate.onRoundTripMilliseconds = { [weak self, weak candidate, weak viewer] milliseconds in
            DispatchQueue.main.async {
                guard let self, let candidate, let viewer, self.peer === candidate, self.viewerSession === viewer else { return }
                if let microseconds = Int(exactly: (milliseconds * 1_000).rounded()), microseconds >= 0 {
                    DiagnosticLog.shared.record(.connectionMetrics, role: .viewer, values: [.roundTripMicroseconds: microseconds])
                }
                self.latency = String(format: milliseconds < 10 ? "%.1f ms" : "%.0f ms", milliseconds)
                viewer.lastLatencyAt = SessionClock.now
                viewer.media?.recordControlRoundTrip(milliseconds: milliseconds)
                self.viewerQualityPolicy.observeRoundTrip(milliseconds)
                self.applyInitialVideoQualityIfReady()
            }
        }
        status = reconnecting ? "正在重新建立加密连接…" : "正在建立加密连接…"
        candidate.onReady = { [weak self, weak candidate] in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                DiagnosticLog.shared.record(.connectionReady, role: .viewer, state: .ready,
                    values: viaRelay ? [.relayControl: 1] : ackStretchingDisabled.map { [.tcpAckStretchingDisabled: $0 ? 1 : 0] } ?? [:])
                self.controlTransportStatus = viaRelay ? "中继控制" : "直连控制"
                self.status = viaRelay ? "中继连接已端到端加密，等待画面…" : "连接已加密，等待画面…"
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
        let relayBridge = viewer.relayBridge
        candidate.onClose = { [weak self, weak candidate, weak relayBridge, weak viewer] originalReason in
            history.requestFlush()
            let relayError = relayBridge?.failedBeforeDesktopStream == true ? relayBridge?.lastFailure : nil
            let reason = relayError?.localizedDescription ?? originalReason
            let retryable = (relayError as? RelayServiceError)?.retryable ?? (relayError as? RelayTransportError)?.retryable ?? (candidate?.closeIsRetryable == true)
            let mayTryAlternate = candidate?.closeAllowsAlternateRoute == true
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                self.recordDisconnect(reason)
                let wasConnected = self.connected
                let verifiedTarget = viewer?.relayTargetVerified == true
                let mediaFallback = viewer?.relayFallbackRequested == true
                self.clearSession()
                if viaRelay, relayError != nil, !wasConnected, self.failOverRelay(from: target, reason: reason) { return }
                if !viaRelay, mayTryAlternate || mediaFallback, target.relay?.strategy == .automatic,
                   !wasConnected || self.autoReconnect || mediaFallback,
                   !wasConnected || verifiedTarget {
                    self.relaySelectedForTarget = true
                    self.relayFallbackAttempted = true
                    // Leaving an established session is a reconnect, so idle pause still defers it.
                    if wasConnected { self.reconnecting = true }
                    self.beginConnection(target)
                } else if retryable, self.autoReconnect, self.target != nil {
                    if viaRelay, target.relay?.strategy == .automatic, !target.address.isEmpty {
                        self.relaySelectedForTarget = false; self.relayFallbackFailed()
                    }
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
        _ = idlePolicy.tick(now: SessionClock.now, attended: sessionWindowAttended)
        if idlePolicy.isPaused {
            deferReconnectForIdle(reason)
            return
        }
        if var target, target.relayRoutes.count > 1 {
            target.relayRoutesOrdered = false
            if let first = target.relayRoutes.first { target = target.using(first) }
            self.target = target
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

    // Only an automatic fallback that never reached the desktop stream starts the cooldown.
    private func relayFallbackFailed() {
        guard relayFallbackAttempted else { return }
        relayFallbackAttempted = false
        relayFallbackCooldown.failed(now: SessionClock.now)
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
        if sibling?.hasIncomingControlConnection == true {
            connectionError = "这台 Mac 正在被另一台 Mac 控制；对方断开后才能连接其他 Mac，共享无需关闭"
            return
        }
        address = record.address
        port = String(record.port)
        relayStrategy = record.relay?.strategy ?? .direct
        targetRelayDeviceID = record.relay?.deviceID.uuidString.lowercased() ?? ""
        selectedConnectionID = record.id
        viewerCode = ""
        connectionError = nil
        do {
            guard let key = try KeyStore.load(account: "remote." + record.id.uuidString) else {
                throw DeskError.invalid("此记录尚未保存到本机凭据文件。请在上方补录原配对码后连接；成功后会记住，无需读取钥匙串")
            }
            viewerCode = key.code
            connect(savedRelayRoute: record.relay)
        } catch { self.connectionError = error.localizedDescription }
    }

    func removeConnection(_ record: ConnectionRecord) {
        do {
            try KeyStore.remove(account: "remote." + record.id.uuidString)
            connections.removeAll { $0.id == record.id }
            if selectedConnectionID == record.id { selectedConnectionID = nil }
            try ConnectionStore.save(connections)
        } catch { self.error = error.localizedDescription; return }
        Self.setAutoUnlock(false, for: record.id)
        do { try KeyStore.removeSecret(account: Self.unlockAccount(record.id)) }
        catch { self.error = "连接记录已移除，但保存的锁屏密码未能删除：\(error.localizedDescription)" }
    }

    private func saveConnection(name: String) {
        guard !savedTarget, let target else { return }
        do {
            let existing = ConnectionStore.matching(connections, address: target.address, port: target.port, preferredID: target.recordID, relay: target.relay)
            var record = existing
                ?? ConnectionRecord(address: target.address, port: target.port, name: name, videoSettings: viewerQualityPolicy.preferred, relay: target.relay)
            // Relay device IDs are scoped to a node, so another node gets its own record. This session
            // authenticated with the source record's pairing code, which proves it is the same Mac, so
            // that record's lock screen password follows.
            if existing == nil, let source = target.recordID, source != record.id,
               connections.first(where: { $0.id == source })?.relay?.deviceID == target.relay?.deviceID,
               let password = try? KeyStore.loadSecret(account: Self.unlockAccount(source)) {
                try? KeyStore.saveSecret(password, account: Self.unlockAccount(record.id))
                Self.setAutoUnlock(Self.autoUnlocks(source), for: record.id)
            }
            record.address = target.address; record.port = target.port; record.relay = target.relay
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

    private func handleHost(_ message: Message, peer: Peer) async throws {
        switch message.kind {
        case .desktopActionRequest:
            applyHostDesktopAction(try Wire.readJSON(DesktopActionRequest.self, message.payload), peer: peer)
        case .sessionTermination:
            let notification = try SessionTermination.read(message.payload)
            guard notification.operation == .subscribe else { throw DeskError.invalid("结束连接消息方向无效") }
            hostSession.terminationSubscribed = true
        case .cursorControl:
            let request = try CursorControl.read(message.payload)
            guard request.operation == .request, hostSession.mediaPrepared else { throw DeskError.invalid("光标功能未协商") }
            applyHostCursorRequest(request, peer: peer)
        case .sessionPauseRequest:
            applyHostSessionPause(try Wire.readJSON(SessionPauseRequest.self, message.payload), peer: peer)
        case .sessionEffectsRequest:
            applyHostSessionEffects(try Wire.readJSON(SessionEffectsRequest.self, message.payload), peer: peer)
        case .sessionUnlockRequest:
            applyHostUnlock(try Wire.readJSON(SessionUnlockRequest.self, message.payload), peer: peer)
        case .deviceIdentity:
            guard hostSession.deviceIdentityAdvertised else {
                throw DeskError.invalid("当前连接未启用设备标识交换")
            }
            let identity = try Wire.readJSON(DeviceIdentity.self, message.payload)
            if let previous = hostSession.remoteDeviceID, previous != identity.id {
                throw DeskError.invalid("连接中的设备标识发生变化")
            }
            hostSession.remoteDeviceID = identity.id
        case .controlStatus:
            guard message.payload.isEmpty else { throw DeskError.invalid("控制权限订阅消息无效") }
            refreshPermissions()
            controlStatusUpdatesEnabled = true
            status = canControl ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（辅助功能未生效）"
            peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: canControl)))
        case .acknowledgement: break // Routed through SessionDataChannel; a late one has no frame to release.
        case .input:
            let input = try Wire.readJSON(RemoteInput.self, message.payload)
            try input.validate()
            if hostSession.desktopActionTask != nil { return }
            // Keys from the viewer must not mix into the password being typed on the lock screen.
            if hostSession.unlocker?.typing == true, [.keyDown, .keyUp, .flags].contains(input.kind) { return }
            if input.kind == .scroll {
                DiagnosticLog.shared.count(.scrollReceived)
                if !canControl || hostSession.paused || hostSession.pauseTask != nil { DiagnosticLog.shared.count(.scrollSuppressed) }
            }
            let host = hostSession
            if canControl, !host.paused, host.pauseTask == nil, let feedback = try await host.injector?.receive(input),
               self.hostSession === host, self.peer === peer, canControl, !host.paused, host.pauseTask == nil {
                peer.send(try Wire.json(.inputStatus, feedback))
            }
        case .releaseInput: hostSession.injector?.releaseAll()
        case .clipboard:
            guard clipboardEnabled else { clipboardStatus = "已忽略远端发送的剪贴板文字（剪贴板同步已关闭）"; return }
            try receiveClipboard(message.payload)
        case .requestClipboard:
            guard clipboardEnabled else { clipboardStatus = "已拒绝远端读取剪贴板（剪贴板同步已关闭）"; return }
            sendClipboard(to: peer)
        case .clipboardSettings:
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard let session = preference.session, clipboardSession == nil || clipboardSession == session else {
                throw DeskError.invalid("剪贴板会话无效")
            }
            clipboardSession = session
            let first = !supportsClipboard
            supportsClipboard = true
            applyRemoteClipboardPreference(preference)
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
        case .desktopActionResult:
            guard supportsDesktopActions else { throw DeskError.invalid("桌面操作未协商") }
            let result = try Wire.readJSON(DesktopActionResult.self, message.payload)
            guard let request = viewerSession.desktopActionRequest, request.id == result.id else { return }
            viewerSession.desktopActionTimeout?.cancel()
            viewerSession.desktopActionTimeout = nil
            viewerSession.desktopActionRequest = nil
            desktopActionWorking = false
            desktopActionStatus = result.error ?? "已向远端发送“\(request.action.title)”快捷键；请点按远端画面继续。"
            if let error = result.error { showDesktopActionNotice(error) }
            publishSessionPause()
        case .sessionTermination:
            guard viewerSession.helloReceived, viewerSession.terminationSubscribed else {
                throw DeskError.invalid("当前连接未启用结束通知")
            }
            let notification = try SessionTermination.read(message.payload)
            guard notification.operation == .ended else { throw DeskError.invalid("结束连接消息方向无效") }
            // Invalidate this attempt before the transport's EOF/failure or a relay fallback can retry it.
            recordDisconnect(SessionTermination.hostEndedReason)
            stop()
            status = SessionTermination.hostEndedReason
            connectionError = SessionTermination.hostEndedReason
        case .cursorControl:
            guard supportsIndependentCursor else { throw DeskError.invalid("光标功能未协商") }
            let control = try CursorControl.read(message.payload)
            if control.operation == .status {
                guard control.requestID == viewerSession.cursorRequestID else { return }
                let requested = viewerSession.cursorRequestedEnabled
                viewerSession.cursorRequestID = nil
                viewerSession.cursorTimeout?.cancel()
                canvas.receiveCursorStatus(control)
                cursorStatus = control.reason == .unavailable ? "切换失败，保持原光标模式"
                    : control.reason == .waitingForResume ? "恢复画面后启用光标模式" : "正在切换光标…"
                if requested != lowLatencyCursorEnabled { sendCursorRequest() }
            } else if control.operation == .binding { canvas.receiveCursorBinding(control) }
            else { throw DeskError.invalid("光标控制方向无效") }
        case .cursorShape:
            guard supportsIndependentCursor else { throw DeskError.invalid("光标功能未协商") }
            canvas.receiveCursorShape(try CursorShape.decode(message.payload))
        case .cursorPosition:
            guard supportsIndependentCursor else { throw DeskError.invalid("光标功能未协商") }
            canvas.receiveCursorPosition(try CursorPosition.decode(message.payload))
        case .hello:
            guard !viewerSession.helloReceived else { throw DeskError.invalid("重复的会话信息") }
            let hello = try Wire.readJSON(Hello.self, message.payload)
            try hello.validate()
            viewerSession.relayTargetVerified = hello.relayTransportV1 == true && target?.relay?.deviceID == hello.relayDeviceID && hello.relayDeviceID != nil
            if viewerSession.usesRelayControl, !viewerSession.relayTargetVerified {
                throw DeskError.invalid("中继目标标识不匹配或对端版本不支持，请检查设备标识并升级两端")
            }
            if reconnecting, idlePolicy.isPaused || idlePolicy.tick(now: SessionClock.now, attended: sessionWindowAttended) {
                clearSession()
                peer.close("空闲暂停，返回窗口后继续连接")
                deferReconnectForIdle("连接恢复前已达到空闲时限")
                return
            }
            viewerSession.helloReceived = true
            if hello.sessionTerminationV1 == true {
                viewerSession.terminationSubscribed = true
                peer.send(try SessionTermination(.subscribe).message())
            }
            if viewerSession.usesRelayControl { relayFallbackAttempted = false; relayFallbackCooldown.reset() }
            dataChannel?.configureVideo(canvas.makeVideoReceiver(diagnostics: performanceDiagnostics))
            connected = true
            connectedSince = Date()
            working = false
            remoteName = hello.name
            reconnecting = false
            supportsSessionPause = hello.sessionPause == true
            if !supportsSessionPause {
                idlePolicy.synchronize(paused: false, now: SessionClock.now)
                pauseTransmission = SessionPauseTransmission()
            } else if idlePolicy.tick(now: SessionClock.now, attended: sessionWindowAttended) {
                pauseTransmission.choose(paused: true)
            }
            if freshFrameRequiredOnReconnect { pauseTransmission.requireFreshFrame() }
            saveConnection(name: hello.name)
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
            supportsHigherFrameRateVideo = supportsHighRefreshVideoSettings && hello.higherFrameRateVideoV1 == true
            supportsSessionEffects = hello.sessionEffects == true
            supportsSessionLock = supportsSessionEffects && hello.sessionLockV1 == true
            supportsDisplayDimming = supportsSessionEffects && hello.displayDimmingV1 == true
            hostDisplayDimmable = supportsDisplayDimming && hello.builtInDisplayDimmable == true
            supportsAdaptiveVideo = supportsHighRefreshVideoSettings && hello.adaptiveVideoV1 == true
            supportsSessionUnlock = hello.sessionUnlockV1 == true
            supportsDesktopActions = hello.desktopActionsV1 == true
            refreshUnlockState()
            if supportsLiveSettings {
                let hostDefault = supportsHigherFrameRateVideo ? (hello.preferredHigherFrameRateSettings ?? hello.preferredHighRefreshSettings ?? hello.preferredSettings ?? hello.settings)
                    : supportsHighRefreshVideoSettings ? (hello.preferredHighRefreshSettings ?? hello.preferredSettings ?? hello.settings)
                    : supportsExtendedVideoSettings ? (hello.preferredSettings ?? hello.settings) : hello.settings
                let preferred = viewerQualityPolicy.settingsForConnection(hostDefault: hostDefault, supportsExtended: supportsExtendedVideoSettings,
                                                                         supportsHighRefresh: supportsHighRefreshVideoSettings,
                                                                         supportsHigherFrameRate: supportsHigherFrameRateVideo)
                videoTuning = try VideoTuningSession(applied: state, preferred: preferred)
                videoSettingsStatus = "当前生效：\(state.settings.summary)"
                if hello.mediaTransportV1 == true {
                    // Media adaptation replaces the old RTT shortcut; a compatibility fallback still must not be saved.
                    viewerQualityPolicy.chooseManually(savePreference: viewerQualityPolicy.maySaveCurrentChoice)
                    try configureViewerMedia(peer: peer, settings: state.settings, preferred: preferred,
                                             relayRouting: hello.relayTransportV1 == true && target?.relay != nil)
                    // A relayed session starts from a modest bitrate and climbs only as the path proves it.
                    if supportsAdaptiveVideo, viewerSession.usesRelayControl, var tuning = videoTuning,
                       let start = viewerSession.mediaQuality?.startingSettings(maximumMegabits: 10), start != tuning.desired {
                        try tuning.choose(start)
                        videoTuning = tuning
                        viewerSession.automaticVideoSettings = start
                        viewerSession.automaticVideoAdjustment = nil
                    }
                }
                applyInitialVideoQualityIfReady()
                sendNextVideoSettings()
            } else { videoSettingsStatus = "主机需更新到 0.4.0 才能动态调整画质" }
            supportsIndependentCursor = viewerSession.media != nil && hello.independentCursorV1 == true
            sendCursorRequest()
            publishSessionPause()
            sendNextSessionPause()
            if let token = pauseTransmission.freshFrameToken { scheduleFreshFrameTimeout(token, peer: peer) }
            if supportsSessionUnlock, hello.screenLocked == true, autoUnlockEnabled { scheduleAutoUnlock(peer: peer) }
            // Sent after the cursor request so the host applies it once cursor capture has settled.
            if supportsSessionEffects, let remembered = sessionEffectsMemory.connectionState {
                let supported = SessionEffectsState(muted: remembered.muted, privacy: remembered.privacy,
                                                    lockOnDisconnect: remembered.lockOnDisconnect && supportsSessionLock,
                                                    dimBuiltInDisplay: remembered.dimBuiltInDisplay && hostDisplayDimmable)
                if supported != SessionEffectsState() { requestSessionEffects(supported, automatic: true) }
            }
        case .sessionPauseResult:
            guard viewerSession.helloReceived, supportsSessionPause else { throw DeskError.invalid("当前连接未启用空闲暂停") }
            let result = try Wire.readJSON(SessionPauseResult.self, message.payload)
            let oldRequest = pauseTransmission.pending
            guard pauseTransmission.receive(result) else { return }
            viewerSession.media?.setPaused(result.paused)
            viewerSession.mediaQuality?.resetObservation(now: SessionClock.now)
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
                sessionEffectsMemory.confirmed(result)
                viewerSession.effectsRequestTimeout?.cancel()
                viewerSession.effectsRequestID = nil
                sessionEffectsWorking = false
            }
        case .sessionUnlockResult:
            guard viewerSession.helloReceived, supportsSessionUnlock else { throw DeskError.invalid("当前连接未启用自动解锁") }
            receiveUnlockResult(try Wire.readJSON(SessionUnlockResult.self, message.payload))
        case .controlStatus:
            guard viewerSession.helloReceived, controlStatusUpdatesEnabled else { throw DeskError.invalid("对端不支持控制权限更新") }
            let permission = try Wire.readJSON(ControlStatus.self, message.payload)
            if canControl != permission.canControl {
                if !permission.canControl { canvas.releaseControl() }
                canControl = permission.canControl
                canvas.canControl = permission.canControl
                canvas.usesCapsLockActions = capsLockRunning && capsLockEnabled && supportsInputActions && canControl && !sessionInputSuspended && !desktopActionWorking
                status = permission.canControl ? "已连接 · 辅助功能已生效，点击画面开始操作" : "已连接 · 仅观看（家里 Mac 的辅助功能未生效）"
            }
        case .video:
            throw DeskError.invalid("视频会话尚未就绪")
        case .clipboard:
            guard viewerSession.helloReceived else { throw DeskError.invalid("缺少会话信息") }
            guard viewerSession.clipboardPullPending else { return }
            viewerSession.clipboardPullPending = false
            viewerSession.clipboardPullTimeout?.cancel()
            viewerSession.clipboardPullTimeout = nil
            try receiveClipboard(message.payload)
        case .clipboardSettings:
            guard supportsClipboard else { throw DeskError.invalid("对端不支持自动剪贴板") }
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard preference.session == clipboardSession else { throw DeskError.invalid("剪贴板会话不匹配") }
            applyRemoteClipboardPreference(preference)
            updateClipboardSync()
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            clipboardSync?.receive(message)
        case .inputStatus:
            guard viewerSession.helloReceived, supportsInputActions else { throw DeskError.invalid("不支持的键盘状态消息") }
            inputStatus = try Wire.readJSON(InputFeedback.self, message.payload).message
        case .streamSettingsResult:
            guard viewerSession.helloReceived, supportsLiveSettings, var tuning = videoTuning else { throw DeskError.invalid("对端不支持动态画质") }
            let result = try Wire.readJSON(StreamSettingsResult.self, message.payload)
            let previous = tuning.applied.settings
            guard try tuning.receive(result, maximumFrameRate: supportsHigherFrameRateVideo ? StreamSettings.frameRates.last! : 60) else { return }
            viewerSession.videoRequestTimeout?.cancel()
            videoTuning = tuning
            activeVideoState = result.state
            // An adaptive host changed only the running encoder's bitrate, so the current stream continues.
            let bitrateOnly = supportsAdaptiveVideo && previous.longestEdge == result.state.settings.longestEdge
                && previous.framesPerSecond == result.state.settings.framesPerSecond
            viewerSession.media?.updateSettings(result.state.settings, restartsStream: !bitrateOnly)
            if result.error == nil {
                _ = viewerSession.mediaQuality?.confirmApplied(result.state.settings, now: SessionClock.now)
            } else { viewerSession.mediaQuality?.rejectPending(now: SessionClock.now) }
            try viewerSession.mediaQuality?.synchronizeApplied(result.state.settings, size: (result.state.width, result.state.height),
                                                               now: SessionClock.now)
            let adjustment = viewerSession.automaticVideoSettings == result.state.settings ? viewerSession.automaticVideoAdjustment : nil
            if viewerSession.automaticVideoSettings == result.state.settings || result.error != nil {
                viewerSession.automaticVideoSettings = nil
                viewerSession.automaticVideoAdjustment = nil
            }
            if result.error == nil { automaticQualityNote = Self.qualityNote(adjustment, applied: result.state.settings) }
            recordVideoConfiguration(result.state, succeeded: result.error == nil, adjustment: adjustment)
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
        guard supportsHigherFrameRateVideo || settings.framesPerSecond <= 60 else {
            videoSettingsStatus = "超过 60 fps 的档位需两端更新后使用"
            return
        }
        do { try tuning.choose(settings) }
        catch { videoSettingsStatus = error.localizedDescription; return }
        viewerQualityPolicy.chooseManually()
        viewerSession.automaticVideoSettings = nil
        viewerSession.automaticVideoAdjustment = nil
        _ = try? viewerSession.mediaQuality?.chooseManually(settings, now: SessionClock.now)
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
        requestSessionEffects(SessionEffectsState(muted: enabled, privacy: sessionEffects.privacy,
                                                  lockOnDisconnect: sessionEffects.lockOnDisconnect,
                                                  dimBuiltInDisplay: sessionEffects.dimBuiltInDisplay))
    }

    func setRemotePrivacy(_ enabled: Bool) {
        requestSessionEffects(SessionEffectsState(muted: sessionEffects.muted, privacy: enabled,
                                                  lockOnDisconnect: sessionEffects.lockOnDisconnect,
                                                  dimBuiltInDisplay: sessionEffects.dimBuiltInDisplay))
    }

    func setRemoteLockOnDisconnect(_ enabled: Bool) {
        guard supportsSessionLock || !enabled else { return }
        requestSessionEffects(SessionEffectsState(muted: sessionEffects.muted, privacy: sessionEffects.privacy,
                                                  lockOnDisconnect: enabled, dimBuiltInDisplay: sessionEffects.dimBuiltInDisplay))
    }

    func setRemoteDisplayDim(_ enabled: Bool) {
        guard hostDisplayDimmable || !enabled else { return }
        requestSessionEffects(SessionEffectsState(muted: sessionEffects.muted, privacy: sessionEffects.privacy,
                                                  lockOnDisconnect: sessionEffects.lockOnDisconnect, dimBuiltInDisplay: enabled))
    }

    // MARK: Lock screen password

    private static let autoUnlockKey = "autoUnlockRecords"
    private static func unlockAccount(_ record: UUID) -> String { "unlock." + record.uuidString.lowercased() }
    private static func autoUnlocks(_ record: UUID) -> Bool {
        UserDefaults.standard.stringArray(forKey: autoUnlockKey)?.contains(record.uuidString) == true
    }
    private static func setAutoUnlock(_ enabled: Bool, for record: UUID) {
        var records = Set(UserDefaults.standard.stringArray(forKey: autoUnlockKey) ?? [])
        if enabled { records.insert(record.uuidString) } else { records.remove(record.uuidString) }
        UserDefaults.standard.set(records.sorted(), forKey: autoUnlockKey)
    }

    /// The saved record of the current viewer connection; lock screen passwords are kept per record.
    var currentRecordID: UUID? {
        guard mode == .viewer, let target else { return nil }
        return ConnectionStore.matching(connections, address: target.address, port: target.port,
                                        preferredID: target.recordID, relay: target.relay)?.id
    }

    /// A saved lock screen password with the pairing code it was saved under. It is sent only over a
    /// session authenticated with that same code, so a record later reused for another Mac never releases it.
    private struct UnlockSecret: Codable { let key: String; let password: String }

    private static func fingerprint(_ key: PairingKey) -> String {
        SHA256.hash(data: key.data).map { String(format: "%02x", $0) }.joined()
    }

    /// The password saved for this record under the pairing code the current session authenticated with.
    private func currentUnlockPassword() throws -> String? {
        guard let record = currentRecordID, let key = target?.key,
              let text = try KeyStore.loadSecret(account: Self.unlockAccount(record)),
              let secret = try? JSONDecoder().decode(UnlockSecret.self, from: Data(text.utf8)),
              secret.key == Self.fingerprint(key) else { return nil }
        return secret.password
    }

    func refreshUnlockState() {
        guard let record = currentRecordID else { unlockPasswordSaved = false; autoUnlockEnabled = false; return }
        do { unlockPasswordSaved = try currentUnlockPassword() != nil }
        catch { unlockPasswordSaved = false; unlockStatus = error.localizedDescription }
        autoUnlockEnabled = unlockPasswordSaved && Self.autoUnlocks(record)
    }

    /// Saving a password also turns on unlocking for later connections to this record.
    func saveUnlockPassword(_ password: String) -> Bool {
        guard let record = currentRecordID, let key = target?.key else { unlockStatus = "连接成功后才能为此连接记录保存密码"; return false }
        do {
            try SessionUnlockRequest.validate(password)
            let secret = try JSONEncoder().encode(UnlockSecret(key: Self.fingerprint(key), password: password))
            try KeyStore.saveSecret(String(decoding: secret, as: UTF8.self), account: Self.unlockAccount(record))
            Self.setAutoUnlock(true, for: record)
            unlockStatus = "锁屏密码已保存在这台 Mac，之后连接到锁屏的被控 Mac 时自动解锁"
        } catch { unlockStatus = error.localizedDescription }
        refreshUnlockState()
        return unlockPasswordSaved
    }

    func removeUnlockPassword() {
        guard let record = currentRecordID else { return }
        do {
            try KeyStore.removeSecret(account: Self.unlockAccount(record))
            Self.setAutoUnlock(false, for: record)
            unlockStatus = "已删除此连接记录保存的锁屏密码"
        } catch { unlockStatus = error.localizedDescription }
        refreshUnlockState()
    }

    func setAutoUnlock(_ enabled: Bool) {
        guard let record = currentRecordID, unlockPasswordSaved || !enabled else { return }
        Self.setAutoUnlock(enabled, for: record)
        refreshUnlockState()
    }

    func unlockNow() { sendUnlockRequest(automatic: false) }

    /// Waits for the first picture plus a moment, so the lock screen is visible before the field fills in.
    private func scheduleAutoUnlock(peer: Peer) {
        let viewer = viewerSession
        viewer.unlockTask?.cancel()
        viewer.unlockTask = Task { [weak self, weak peer, weak viewer] in
            for _ in 0..<100 {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                if viewer.mediaCommitted || !self.supportsMediaTransport { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            // Remembered switches are requested at hello; the curtain and the dark display have to be in place before the desktop is.
            for _ in 0..<200 {
                guard let self, let viewer, self.viewerSession === viewer else { return }
                if !self.sessionEffectsWorking { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer, self.connected else { return }
            if self.sessionEffectsMemory.remembered.privacy, !self.sessionEffects.privacy {
                self.showUnlockNotice("防窥没有开启，为免被控 Mac 在本地露出桌面，未自动解锁；可在“被控端隐私与安全”中手动解锁")
                return
            }
            // Only a dimming that was tried counts; a host without a dimmable built-in display was never asked.
            if self.sessionEffectsMemory.remembered.dimBuiltInDisplay, self.hostDisplayDimmable, !self.sessionEffects.dimBuiltInDisplay {
                self.showUnlockNotice("内建屏幕亮度没有归零，为免被控 Mac 在本地露出桌面，未自动解锁；可在“被控端隐私与安全”中手动解锁")
                return
            }
            self.sendUnlockRequest(automatic: true)
        }
    }

    private func sendUnlockRequest(automatic: Bool) {
        guard mode == .viewer, connected, supportsSessionUnlock, let peer, viewerSession.unlockRequestID == nil,
              let record = currentRecordID else { return }
        let request: SessionUnlockRequest
        do {
            guard let password = try currentUnlockPassword() else {
                unlockStatus = try KeyStore.loadSecret(account: Self.unlockAccount(record)) == nil ? "此连接记录尚未保存锁屏密码"
                    : "保存的锁屏密码属于使用另一配对码的 Mac，未发送；请为这台 Mac 重新保存"
                return
            }
            request = try SessionUnlockRequest(password: password)
            peer.send(try Wire.json(.sessionUnlockRequest, request))
        } catch { unlockStatus = error.localizedDescription; return }
        let viewer = viewerSession
        viewer.unlockRequestID = request.id
        viewer.unlockAutomatic = automatic
        unlockWorking = true
        DiagnosticLog.shared.record(.sessionUnlock, role: .viewer, state: .requested)
        showUnlockNotice(automatic ? "被控 Mac 处于锁屏状态，正在自动输入密码解锁…" : "正在向被控 Mac 的锁屏界面输入密码…", persistent: true)
        viewer.unlockTimeout?.cancel()
        viewer.unlockTimeout = Task { [weak self, weak viewer] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let viewer, self.viewerSession === viewer, viewer.unlockRequestID == request.id else { return }
            viewer.unlockRequestID = nil
            self.unlockWorking = false
            self.showUnlockNotice("被控端 30 秒内没有回复解锁结果")
        }
    }

    private func receiveUnlockResult(_ result: SessionUnlockResult) {
        let viewer = viewerSession
        guard result.id == viewer.unlockRequestID else { return }
        viewer.unlockRequestID = nil
        viewer.unlockTimeout?.cancel()
        unlockWorking = false
        DiagnosticLog.shared.record(.sessionUnlock, role: .viewer,
            state: result.outcome == .unlocked ? .succeeded : result.outcome == .notLocked ? .disabled : .failed)
        switch result.outcome {
        case .unlocked:
            showUnlockNotice(viewer.unlockAutomatic ? "已自动解锁 · 连接时被控 Mac 处于锁屏状态" : "已输入锁屏密码，被控 Mac 已解锁")
        case .notLocked: showUnlockNotice(result.error ?? "被控 Mac 当前没有锁屏，未输入密码")
        case .failed: showUnlockNotice("自动解锁未完成：" + (result.error ?? "原因未知"))
        }
    }

    private func showUnlockNotice(_ text: String, persistent: Bool = false) {
        unlockNoticeTask?.cancel()
        unlockNotice = text
        unlockStatus = text
        guard !persistent else { return }
        unlockNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.unlockNotice = nil
        }
    }

    func sendDesktopAction(_ action: RemoteDesktopAction) {
        guard mode == .viewer, desktopActionUnavailableReason == nil, let peer else { return }
        canvas.releaseControl()
        let viewer = viewerSession
        let request = DesktopActionRequest(action: action)
        viewer.desktopActionRequest = request
        desktopActionWorking = true
        desktopActionStatus = "正在发送桌面操作…"
        showDesktopActionNotice(nil)
        publishSessionPause()
        do { peer.send(try Wire.json(.desktopActionRequest, request)) }
        catch {
            viewer.desktopActionRequest = nil
            desktopActionWorking = false
            desktopActionStatus = error.localizedDescription
            showDesktopActionNotice(error.localizedDescription)
            publishSessionPause()
            return
        }
        viewer.desktopActionTimeout = Task { [weak self, weak peer, weak viewer] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, let peer, let viewer, self.peer === peer, self.viewerSession === viewer,
                  viewer.desktopActionRequest?.id == request.id else { return }
            viewer.desktopActionRequest = nil
            viewer.desktopActionTimeout = nil
            self.desktopActionWorking = false
            self.desktopActionStatus = "未收到桌面操作回执，请查看远端画面；未自动重试。"
            self.showDesktopActionNotice(self.desktopActionStatus)
            self.publishSessionPause()
        }
    }

    // Success shows only on the remote picture; the full-screen panel shows desktopActionStatus instead.
    private func showDesktopActionNotice(_ text: String?) {
        desktopActionNoticeTask?.cancel()
        desktopActionNotice = text
        guard text != nil else { return }
        desktopActionNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.desktopActionNotice = nil
        }
    }

    private func applyHostDesktopAction(_ request: DesktopActionRequest, peer: Peer) {
        let host = hostSession
        if let result = host.lastDesktopActionResult, result.id == request.id {
            if let reply = try? Wire.json(.desktopActionResult, result) { peer.send(reply) }
            return
        }
        let rejection: String?
        if !canControl || host.injector == nil { rejection = "被控端尚不能接收控制输入" }
        else if host.paused || host.pauseTask != nil { rejection = "远端画面暂停或恢复中，请稍候" }
        else if host.unlockTask != nil { rejection = "远端正在解锁，请稍候" }
        else if host.desktopActionTask != nil { rejection = "正在发送上一次桌面操作，请稍候" }
        else { rejection = nil }
        if let rejection {
            if let reply = try? Wire.json(.desktopActionResult, DesktopActionResult(id: request.id, error: rejection)) { peer.send(reply) }
            return
        }
        host.injector?.releaseAll()
        let executor = host.desktopActions ?? RemoteDesktopActionExecutor()
        host.desktopActions = executor
        host.desktopActionTask = Task { [weak self, weak peer, weak host] in
            guard let self, let peer, let host, self.peer === peer, self.hostSession === host else { return }
            let error: String?
            if !self.canControl || host.paused || host.pauseTask != nil || host.unlockTask != nil || Task.isCancelled {
                error = "会话状态已变化，桌面操作已取消"
            } else {
                error = await executor.perform(request.action)
            }
            guard self.peer === peer, self.hostSession === host else { return }
            host.desktopActionTask = nil
            let result = DesktopActionResult(id: request.id, error: error)
            host.lastDesktopActionResult = result
            if let reply = try? Wire.json(.desktopActionResult, result) { peer.send(reply) }
        }
    }

    private func applyHostUnlock(_ request: SessionUnlockRequest, peer: Peer) {
        let host = hostSession
        // A second request must not replace the running task, which clearSession has to be able to cancel.
        guard host.unlockTask == nil else {
            if let reply = try? Wire.json(.sessionUnlockResult, SessionUnlockResult(id: request.id, outcome: .failed,
                error: "正在输入上一次的解锁密码")) { peer.send(reply) }
            return
        }
        let unlocker = host.unlocker ?? HostScreenUnlocker()
        host.unlocker = unlocker
        host.desktopActionTask?.cancel()
        host.desktopActions?.cancel()
        host.injector?.releaseAll()
        DiagnosticLog.shared.record(.sessionUnlock, role: .host, state: .requested)
        host.unlockTask = Task { [weak self, weak peer, weak host] in
            let result = await unlocker.unlock(request)
            host?.unlockTask = nil
            guard let self, let peer, let host, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
            DiagnosticLog.shared.record(.sessionUnlock, role: .host,
                state: result.outcome == .unlocked ? .succeeded : result.outcome == .notLocked ? .disabled : .failed)
            if let reply = try? Wire.json(.sessionUnlockResult, result) { peer.send(reply) }
        }
    }

    private func requestSessionEffects(_ desired: SessionEffectsState, automatic: Bool = false) {
        guard connected, supportsSessionEffects, !sessionEffectsWorking, let peer else { return }
        let viewer = viewerSession
        let request = SessionEffectsRequest(state: desired)
        viewerSession.effectsRequestID = request.id
        if !automatic { sessionEffectsMemory.requested(request, from: sessionEffects) }
        sessionEffectsWorking = true
        sessionEffectsStatus = automatic ? "正在开启已记住的被控端设置…" : "正在应用被控端设置…"
        do { peer.send(try Wire.json(.sessionEffectsRequest, request)) }
        catch {
            sessionEffectsWorking = false; viewerSession.effectsRequestID = nil; sessionEffectsMemory.cancel()
            sessionEffectsStatus = error.localizedDescription; return
        }
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
            if self.sessionEffects.privacy != state.privacy {
                DiagnosticLog.shared.record(.privacyCurtain, role: .host, state: state.privacy ? .enabled : .disabled)
            }
            if self.sessionEffects.dimBuiltInDisplay != state.dimBuiltInDisplay {
                DiagnosticLog.shared.record(.displayDim, role: .host, state: state.dimBuiltInDisplay ? .enabled : .disabled)
            }
            self.sessionEffects = state
            self.sessionEffectsStatus = message ?? "被控端设置已生效"
            if let result = try? Wire.json(.sessionEffectsResult, SessionEffectsResult(state: state, error: message)) { peer.send(result) }
            if !state.privacy, host.effectsTask == nil, let streamer = host.streamer {
                let token = self.generation
                let cursor = host.cursorTask
                host.effectsTask = Task { [weak self, weak peer, weak host] in
                    guard let self, let peer, let host, self.hostSession === host else { return }
                    defer { if self.generation == token, self.peer === peer, self.hostSession === host { host.effectsTask = nil } }
                    do {
                        await cursor?.value
                        guard self.generation == token, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
                        try await streamer.setExcludedWindows([])
                    }
                    catch {
                        guard self.generation == token, self.peer === peer, self.hostSession === host else { return }
                        self.sessionEffectsStatus = error.localizedDescription
                        peer.close("防窥已退出，但采集恢复失败，正在重建共享：\(error.localizedDescription)", retryable: true)
                    }
                }
            }
        }
        effects.onCoverWindowsChanged = { [weak self, weak peer, weak effects, weak host] windows in
            guard let self, let peer, let effects, let host, self.peer === peer, self.hostSession === host,
                  host.effects === effects, let streamer = host.streamer else { return }
            let token = self.generation
            let running = host.effectsTask
            Task { [weak self, weak peer, weak host] in
                await running?.value
                guard let self, let peer, let host, self.generation == token, self.peer === peer,
                      self.hostSession === host, effects.state.privacy, !Task.isCancelled else { return }
                do { try await streamer.setExcludedWindows(windows) }
                catch {
                    guard self.generation == token, self.peer === peer, self.hostSession === host else { return }
                    self.sessionEffectsStatus = "显示器变化后未能更新防窥采集：\(error.localizedDescription)"
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
        // Capture changes run in the order they were requested; the curtain never interrupts one.
        let capture = host.captureTask, cursor = host.cursorTask, pause = host.pauseTask, video = host.settingsTask
        host.effectsTask = Task { [weak self, weak peer, weak host] in
            guard let self, let peer, let host, self.hostSession === host else { return }
            defer { if self.generation == token, self.peer === peer, self.hostSession === host { host.effectsTask = nil } }
            var failure: String?
            var filterRestoreFailed = false
            do {
                await capture?.value
                await cursor?.value
                await pause?.value
                await video?.value
                try Task.checkCancellation()
                _ = try await effects.apply(request.state) { try await streamer.setExcludedWindows($0) }
            } catch { failure = error.localizedDescription }
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.effects === effects, !Task.isCancelled else { return }
            if !effects.state.privacy {
                do { try await streamer.setExcludedWindows([]) }
                catch { failure = failure ?? error.localizedDescription; filterRestoreFailed = true }
            }
            guard self.generation == token, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
            if self.sessionEffects.privacy != effects.state.privacy {
                DiagnosticLog.shared.record(.privacyCurtain, role: .host, state: effects.state.privacy ? .enabled : .disabled)
            }
            if self.sessionEffects.dimBuiltInDisplay != effects.state.dimBuiltInDisplay {
                DiagnosticLog.shared.record(.displayDim, role: .host, state: effects.state.dimBuiltInDisplay ? .enabled : .disabled)
            }
            self.sessionEffects = effects.state
            failure = failure ?? effects.cursorNotice
            self.sessionEffectsStatus = failure ?? "被控端设置已生效"
            if let reply = try? Wire.json(.sessionEffectsResult, SessionEffectsResult(id: request.id, state: effects.state, error: failure)) { peer.send(reply) }
            if filterRestoreFailed { peer.close("采集过滤器恢复失败，正在重建共享：\(failure ?? "未知错误")", retryable: true) }
        }
    }

    private func sendNextVideoSettings() {
        guard connected, supportsLiveSettings, let peer, var tuning = videoTuning,
              let request = tuning.nextRequest() else { return }
        videoTuning = tuning
        viewerSession.pendingVideoPreferenceCanSave = viewerQualityPolicy.maySaveCurrentChoice && viewerSession.automaticVideoSettings != request.settings
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
              let record = ConnectionStore.matching(connections, address: target.address, port: target.port, preferredID: target.recordID, relay: target.relay),
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

    /// The session window can be seen on this Mac: not minimized, hidden, fully covered or on another Space,
    /// with this login session on the console and its screens awake and unlocked.
    private var sessionWindowVisible: Bool {
        guard let window = mainWindow, window.isVisible, !window.isMiniaturized, !NSApp.isHidden,
              window.occlusionState.contains(.visible), !localScreensAsleep else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool != true && session?["kCGSSessionOnConsoleKey"] as? Bool != false
    }

    /// Idle time counts only while nobody attends the session: its window is unfocused or cannot be seen.
    private var sessionWindowAttended: Bool { sessionWindowFocused && sessionWindowVisible }

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
        let wasSuspended = sessionInputSuspended || desktopActionWorking
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
        let allowed = wakeInputGate.allows(input, suspended: wasSuspended || sessionInputSuspended || desktopActionWorking || !connected)
        let remoteTarget = canvas.isInputTarget(of: event)
        // AppKit must still receive the click that activates an inactive window.
        if !allowed && remoteTarget && windowWasFocused && kind == .scroll { DiagnosticLog.shared.count(.scrollSuppressed) }
        return !allowed && remoteTarget && windowWasFocused ? nil : event
    }

    private func dismissClipboardPrompt() {
        guard let clipboardFilePrompt else { return }
        suppressIdleFocusWake = true
        clipboardFilePrompt.dismiss()
        sessionAttentionChanged()
    }

    /// Re-reads whether the session window is focused and visible; called on focus, visibility, lock and display changes.
    func sessionAttentionChanged() {
        focusRefreshTask?.cancel()
        focusRefreshTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            if NSApp.isActive, NSApp.keyWindow == nil, let window = self.mainWindow,
               window.isVisible, !window.isMiniaturized { return }
            let resumed = self.idlePolicy.attentionChanged(now: SessionClock.now,
                attended: self.sessionWindowAttended, suppressWake: self.suppressIdleFocusWake)
            self.suppressIdleFocusWake = false
            if resumed { self.resumeIdleTransmission() }
        }
    }

    // Runs for every local input event, so it only checks focus: input that reaches the focused window
    // already shows someone is there, and a locked screen or sleeping display delivers none.
    private func recordSessionActivity() {
        guard mode == .viewer, supportsSessionPause || idlePolicy.isPaused || reconnecting,
              sessionWindowFocused else { return }
        if idlePolicy.activity(now: SessionClock.now, attended: true) { resumeIdleTransmission() }
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
        canvas.updateSystemShortcutCapture(sessionActive: mode == .viewer && connected && canControl && !sessionInputSuspended && !desktopActionWorking,
            accessibility: localAccessibility, inputMonitoring: localInputMonitoring)
        canvas.usesCapsLockActions = capsLockRunning && capsLockEnabled && supportsInputActions && canControl && !sessionInputSuspended && !desktopActionWorking
        canvas.pointerInputSuspended = sessionInputSuspended || desktopActionWorking
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
        host.desktopActionTask?.cancel()
        host.desktopActions?.cancel()
        host.injector?.releaseAll()
        let token = generation
        let capture = host.captureTask, video = host.settingsTask, cursor = host.cursorTask, effects = host.effectsTask
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
            await cursor?.value
            await effects?.value
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer, !Task.isCancelled else { return }
            await self.suspendMediaForConfiguration(host.media)
            guard self.generation == token, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
            var failure: String?
            do { host.paused = try await streamer.setSessionPaused(request.paused) }
            catch { failure = error.localizedDescription }
            guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer, !Task.isCancelled else { return }
            if host.cursorSubscribed {
                guard let actual = streamer.currentCursorIncluded else {
                    peer.close("无法确认恢复后的光标采集状态，重新建立会话", retryable: true)
                    return
                }
                // A verified rollback can restore the previous cursor mode. Sampling
                // must follow the actual capture mode rather than the paused request.
                if failure != nil || !host.paused { host.cursorEnabled = !actual }
                if let error = host.effects?.setIndependentCursor(host.cursorEnabled), !host.cursorEnabled {
                    peer.close("本机光标恢复失败，正在结束共享：\(error)", retryable: true)
                    return
                }
                if let message = failure { failure = "\(message)；保持已确认的光标模式" }
            }
            self.sessionPauseStatus = failure ?? (host.paused ? "控制端空闲暂停，保留加密会话" : "画面传输已恢复")
            DiagnosticLog.shared.record(host.paused ? .sessionPaused : .sessionResumed, role: .host,
                state: failure == nil ? .succeeded : .failed)
            if let reply = try? Wire.json(.sessionPauseResult, SessionPauseResult(id: request.id, paused: host.paused, error: failure)) {
                peer.send(reply)
            }
            host.media?.setPaused(host.paused)
            if host.paused { host.cursorSampler?.stop() }
            else { self.startHostCursorSampler(host, peer: peer) }
            if !host.paused {
                if failure == nil { streamer.resumeAfterReconfiguration() }
                host.media?.resumeAfterConfiguration()
            }
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
        let cursor = host.cursorTask
        let effects = host.effectsTask
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
                await cursor?.value
                await effects?.value
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer,
                      host.settingsRequestID == request.id, !Task.isCancelled else { return }
                // Automatic adaptation mostly changes bitrate; keep the stream running instead of rebuilding it.
                if let current = self.activeVideoState, request.settings.longestEdge == current.settings.longestEdge,
                   request.settings.framesPerSecond == current.settings.framesPerSecond,
                   let updated = try? streamer.updateBitrate(request.settings) {
                    self.activeVideoState = updated
                    self.recordVideoConfiguration(updated)
                    self.videoSettingsStatus = "控制端已调整：\(updated.settings.summary)"
                    peer.setVideoPacing(VideoSendPacing(megabits: updated.settings.megabits))
                    host.media?.updateSettings(updated.settings, restartsStream: false)
                    peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: updated)))
                    return
                }
                await self.suspendMediaForConfiguration(host.media)
                guard self.generation == token, self.peer === peer, self.hostSession === host, !Task.isCancelled else { return }
                let updated = try await streamer.reconfigure(request.settings)
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.streamer === streamer,
                      host.settingsRequestID == request.id, !Task.isCancelled else { return }
                self.activeVideoState = updated
                self.recordVideoConfiguration(updated)
                self.resolution = "\(updated.width) × \(updated.height)"
                self.videoSettingsStatus = "控制端已调整：\(updated.settings.summary)"
                peer.setVideoPacing(VideoSendPacing(megabits: updated.settings.megabits))
                host.media?.updateSettings(updated.settings)
                peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: updated)))
                streamer.resumeAfterReconfiguration()
                if !host.paused { host.media?.resumeAfterConfiguration() }
            } catch {
                guard self.generation == token, self.peer === peer, self.hostSession === host, host.settingsRequestID == request.id,
                      !Task.isCancelled, let actual = self.activeVideoState else { return }
                self.recordDiagnosticFailure(.streamConfigured, error: error)
                if !host.paused { host.media?.resumeAfterConfiguration() }
                if let result = try? Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: actual, error: error.localizedDescription)) { peer.send(result) }
            }
        }
    }

    private func suspendMediaForConfiguration(_ media: MediaSession?) async {
        guard let media else { return }
        await withCheckedContinuation { continuation in
            media.suspendForConfiguration { continuation.resume() }
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
    func pullClipboard() {
        guard connected, let peer else { return }
        let viewer = viewerSession
        viewer.clipboardPullTimeout?.cancel()
        viewer.clipboardPullPending = true
        peer.send(Message(.requestClipboard))
        clipboardStatus = "正在获取远端剪贴板…"
        viewer.clipboardPullTimeout = Task { [weak self, weak viewer] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, let viewer, self.viewerSession === viewer, viewer.clipboardPullPending, !Task.isCancelled else { return }
            viewer.clipboardPullPending = false
            viewer.clipboardPullTimeout = nil
            self.clipboardStatus = "未收到远端剪贴板文字（对方可能没有文字或已关闭剪贴板同步）"
        }
    }

    /// Copies the remote frame shown here as PNG. It comes from the received video, so the host's curtain is not in it.
    func copyRemoteFrame() {
        guard mode == .viewer, connected else { return }
        guard let frame = canvas.displayedFrame else { clipboardStatus = "还没有可截取的远端画面"; return }
        let snapshot = RemoteFrameSnapshot(frame: frame)
        snapshotQueue.async {
            let png = snapshot.pngData()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let png else { self.clipboardStatus = "远端画面无法转换为 PNG"; return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    let copied = pasteboard.setData(png, forType: .png)
                    self.clipboardStatus = copied
                        ? "已复制远端画面 \(snapshot.width) × \(snapshot.height) 到剪贴板" : "远端画面无法写入剪贴板"
                    if copied { self.clipboardSync?.sendLocalCopy() }
                }
            }
        }
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard clipboardEnabled != enabled else { return }
        clipboardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clipboardEnabled")
        sibling?.setClipboardEnabled(enabled)
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

    /// 远程画面获得焦点时，控制端剪贴板的新变化不算在控制端复制。
    private var clipboardControlsRemote: Bool { mode == .viewer && controlling }

    private func sendClipboardPreference(to peer: Peer) throws {
        let receives = !sessionInputSuspended && !hostSession.paused && (mode == .viewer ? !controlling : true)
        peer.send(try Wire.json(.clipboardSettings, ClipboardPreference(enabled: clipboardEnabled,
            session: clipboardSession, receivesAutomaticUpdates: receives)))
        lastClipboardReceivePreference = receives
    }

    func refreshClipboardFocus() {
        clipboardSync?.setAutomaticSendingAllowed(automaticClipboardSendingAllowed)
        clipboardSync?.setControllingRemote(clipboardControlsRemote)
        let receives = !sessionInputSuspended && !hostSession.paused && (mode == .viewer ? !controlling : true)
        guard mode == .viewer, connected, supportsClipboard, let peer,
              lastClipboardReceivePreference != receives else { return }
        do { try sendClipboardPreference(to: peer) }
        catch { clipboardStatus = error.localizedDescription }
    }

    private func applyRemoteClipboardPreference(_ preference: ClipboardPreference) {
        remoteClipboardEnabled = preference.enabled
        remoteFileApproval = preference.fileApproval == true
        remoteClipboardChunkWindow = preference.chunkWindow == true
        remoteReceivesAutomaticClipboard = preference.receivesAutomaticUpdates ?? true
        remoteClipboardFocusAware = preference.receivesAutomaticUpdates != nil
    }

    private func updateClipboardSync() {
        let enabled = connected && supportsClipboard && clipboardEnabled && remoteClipboardEnabled
        canvas.synchronizesClipboard = enabled
        if enabled, clipboardSync == nil, let peer, let clipboardSession {
            let channel = dataChannel
            let sync = ClipboardSync(session: clipboardSession, allowsFileSending: remoteFileApproval,
                allowsAutomaticSending: automaticClipboardSendingAllowed, allowsChunkWindow: remoteClipboardChunkWindow,
                controllingRemote: clipboardControlsRemote, handledChange: clipboardHandledChange) { [weak peer, weak channel] message in
                    if let channel { channel.sendReliableData(message) }
                    else { peer?.send(message) }
                }
            clipboardHandledChange = nil
            clipboardSync = sync
            sync.onFileReceptionChanged = { [weak self, weak sync] id in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.receivingFileID = id
                if id != nil { self.receivedFilesKeptInFolder = false }
            }
            sync.onReceivedFilesKept = { [weak self, weak sync] in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.receivedFilesKeptInFolder = true
            }
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
                self.receivedFilesKeptInFolder = false
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
                ? "双向剪贴板已开启：控制端复制后切回 QuietDesk 时发送，操作远端期间的复制粘贴留在远端；远端在释放控制后发送；文件确认后接收"
                : "双向剪贴板已开启：控制端复制后切回 QuietDesk 时发送，操作远端期间的复制粘贴留在远端；两端升级后可按控制焦点限制远端发送，文件确认后接收"
        } else if enabled {
            clipboardSync?.allowsFileSending = remoteFileApproval
            clipboardSync?.setAutomaticSendingAllowed(automaticClipboardSendingAllowed)
            clipboardSync?.setControllingRemote(clipboardControlsRemote)
        } else {
            dataChannel?.configureClipboard(nil)
            clipboardSync?.stop(); clipboardSync = nil
            clipboardHandledChange = nil
            dismissClipboardPrompt(); clipboardFilePrompt = nil
            pendingFileOffer = nil
            receivedFilesKeptInFolder = false
            if connected { clipboardStatus = supportsClipboard ? "自动剪贴板已关闭" : "对端版本较旧，可使用手动文字同步" }
        }
    }

    func openReceivedFiles() {
        receivedFilesKeptInFolder = false
        let folder = ClipboardSync.storageURL.appendingPathComponent("received", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { self.error = error.localizedDescription; return }
        NSWorkspace.shared.open(folder)
    }

    func dismissReceivedFilesNotice() { receivedFilesKeptInFolder = false }

    func cancelFileReception(id: UUID) {
        guard receivingFileID == id else { return }
        clipboardSync?.cancelFileReception(id: id)
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
        if mainWindow !== window, mode == .viewer {
            for observer in sessionFocusObservers { NotificationCenter.default.removeObserver(observer) }
            for observer in sessionWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            for observer in sessionLockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
            // Idle time counts only while the session window is unfocused or cannot be seen, so every change
            // to focus, visibility, screen lock or display sleep re-reads it.
            let changed: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionAttentionChanged() }
            }
            sessionFocusObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                     NSApplication.didHideNotification, NSApplication.didUnhideNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: changed)
            } + [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main, using: changed)
            }
            sessionWorkspaceObservers = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                                         NSWorkspace.sessionDidResignActiveNotification,
                                         NSWorkspace.sessionDidBecomeActiveNotification].map { name in
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWorkspace.screensDidSleepNotification { self?.localScreensAsleep = true }
                        if name == NSWorkspace.screensDidWakeNotification { self?.localScreensAsleep = false }
                        self?.sessionAttentionChanged()
                    }
                }
            }
            sessionLockObservers = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map { name in
                DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil,
                                                                    queue: .main, using: changed)
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
        if autoStartSharing, mode == .host { startHosting(interactive: false) }
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
                   self.idlePolicy.tick(now: SessionClock.now, attended: self.sessionWindowAttended) {
                    self.viewerSession.restoreCanvasFocusAfterIdle = self.controlling
                    self.pauseTransmission.choose(paused: true)
                    self.sessionPauseStatus = "离开窗口 10 分钟，正在暂停画面与自动剪贴板…"
                    if self.connected {
                        self.publishSessionPause()
                        self.sendNextSessionPause()
                    } else {
                        let candidate = self.peer
                        self.clearSession()
                        candidate?.close("空闲暂停，返回窗口后继续连接")
                        self.deferReconnectForIdle("离开窗口 10 分钟")
                    }
                }
                if self.mode == .host, self.hostSession.effects?.state.privacy != true { self.removeStrayPrivacyCovers() }
                let seconds = max(0.01, SessionClock.now - self.lastMetrics)
                let metrics = self.dataChannel?.takeMetrics() ?? (bytes: 0, frames: 0)
                // @Published notifies on every assignment; a static picture keeps the same strings each second.
                let traffic = String(format: "%.2f Mbps", Double(metrics.bytes) * 8 / seconds / 1_000_000)
                let frameRate = String(format: "%.0f fps", Double(metrics.frames) / seconds)
                if self.traffic != traffic { self.traffic = traffic }
                if self.frameRate != frameRate { self.frameRate = frameRate }
                if let measured = self.viewerSession.lastLatencyAt, SessionClock.now - measured > 15, self.latency != "— ms" {
                    self.latency = "— ms"
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
        oldHost.media?.stop()
        oldViewer.media?.stop()
        oldViewer.mediaReceiver?.stop()
        oldViewer.relayBridge?.stop()
        oldViewer.mediaRelayBridge?.stop()
        controlTransportStatus = "尚未连接"
        mediaTransportStatus = "TCP 兼容模式"
        mediaRouteValue = ""; peerPathState = .relay; relayPeerStatus = ""
        mediaLoss = ""; mediaLossFraction = nil
        automaticQualityNote = ""
        localNetworkQuality = false
        supportsMediaTransport = false
        supportsIndependentCursor = false
        cursorStatus = "视频光标"
        canvas.onCursorPresentation = nil
        oldHost.cursorTask?.cancel()
        oldHost.cursorSampler?.stop()
        oldViewer.cursorTimeout?.cancel()
        oldHost.pauseTask?.cancel()
        oldHost.effectsTask?.cancel()
        oldHost.settingsTask?.cancel()
        oldHost.captureTask?.cancel()
        oldViewer.pauseRequestTimeout?.cancel()
        oldViewer.effectsRequestTimeout?.cancel()
        oldViewer.videoDebounceTask?.cancel()
        oldViewer.videoRequestTimeout?.cancel()
        oldViewer.stableTask?.cancel()
        oldViewer.clipboardPullTimeout?.cancel()
        oldViewer.unlockTask?.cancel()
        oldViewer.unlockTimeout?.cancel()
        oldHost.unlockTask?.cancel()
        oldHost.desktopActionTask?.cancel()
        oldHost.desktopActions?.cancel()
        oldViewer.desktopActionTimeout?.cancel()
        supportsDesktopActions = false
        desktopActionWorking = false
        desktopActionStatus = ""
        desktopActionNoticeTask?.cancel()
        desktopActionNotice = nil
        supportsSessionUnlock = false
        unlockWorking = false
        unlockNoticeTask?.cancel()
        unlockNotice = nil
        unlockStatus = ""
        if let effects = oldHost.effects {
            let token = generation
            let hadCurtain = effects.state.privacy
            let hadDimmedDisplay = effects.state.dimBuiltInDisplay
            effectsCleanupsRunning += 1
            effectsCleanupTask = Task { [weak self] in
                let message = await effects.reset()
                guard let self else { return }
                self.effectsCleanupsRunning -= 1
                if hadCurtain { DiagnosticLog.shared.record(.privacyCurtain, role: .host, state: .disabled) }
                if hadDimmedDisplay {
                    DiagnosticLog.shared.record(.displayDim, role: .host, state: effects.state.dimBuiltInDisplay ? .failed : .disabled)
                }
                self.removeStrayPrivacyCovers()
                if let message, self.generation == token, self.hostSession.effects == nil { self.sessionEffectsStatus = message }
            }
        }
        if let streamer = oldHost.streamer {
            DiagnosticLog.shared.record(.captureStopped, role: .host)
            Task { await streamer.stop() }
        }
        oldHost.injector?.releaseAll()
        // Issued here, not in the async cleanup, so the lock is requested even when the app is quitting.
        if let lock = oldHost.effects?.endSession() {
            Task {
                let failure = await lock.value
                DiagnosticLog.shared.record(.screenLock, role: .host, state: failure == nil ? .succeeded : .failed)
            }
        }
        hostSession = HostSession()
        viewerSession = ViewerSession()
        supportsSessionPause = false
        pauseTransmission = SessionPauseTransmission(paused: idlePolicy.isPaused)
        if freshFrameRequiredOnReconnect { pauseTransmission.requireFreshFrame() }
        sessionPaused = idlePolicy.isPaused
        sessionPauseWorking = false
        sessionEffectsWorking = false
        supportsSessionEffects = false
        supportsSessionLock = false
        supportsDisplayDimming = false
        hostDisplayDimmable = false
        supportsAdaptiveVideo = false
        sessionEffects = SessionEffectsState()
        sessionEffectsStatus = ""
        sessionEffectsMemory.cancel()
        flushTrafficHistory()
        trafficSession = nil
        trafficHistoryStatus = "按网址/IP＋端口累计；旧版按设备统计单独保留。"
        controlStatusUpdatesEnabled = false
        capsLockRunning = false
        capsLockStartAttempted = false
        resolution = ""
        latency = "— ms"
        viewerQualityPolicy.discardUnfinishedSample()
        supportsLiveSettings = false
        supportsExtendedVideoSettings = false
        supportsHighRefreshVideoSettings = false
        supportsHigherFrameRateVideo = false
        videoTuning = nil
        activeVideoState = nil
        videoSettingsStatus = ""
        if mode == .viewer, let clipboardSync { clipboardHandledChange = clipboardSync.handledChange }
        clipboardSync?.stop()
        clipboardSync = nil
        dismissClipboardPrompt(); clipboardFilePrompt = nil
        pendingFileOffer = nil
        receivedFilesKeptInFolder = false
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
        connectedSince = nil
        working = false
        controlling = false
        canControl = false
        supportsInputActions = false
        canvas.usesCapsLockActions = false
        canvas.capsLockMonitor.stop()
        canvas.reset()
    }

    /// The curtain exists only for a live control session. Covers that no live session owns, for
    /// example after an interrupted cleanup, would otherwise leave the host's display black.
    private func removeStrayPrivacyCovers() {
        guard mode == .host, effectsCleanupsRunning == 0 else { return }
        let removed = HostSessionEffects.removeStrayCovers(keeping: hostSession.effects)
        if removed > 0 { DiagnosticLog.shared.record(.privacyCurtain, role: .host, state: .failed, values: [.eventCount: removed]) }
    }

    /// Ends only the authenticated control session. The listener and relay registrations stay available.
    func disconnectController() {
        guard mode == .host, let oldPeer = peer else { return }
        let subscribed = hostSession.terminationSubscribed
        recordDisconnect("已断开控制端")
        // Revoke input/data handlers and cancel capture before attempting the final control notification.
        // clearSession replaces the session identity so late peer callbacks cannot act on the new session.
        clearSession()
        status = active ? "已断开控制端 · 等待连接" : "共享已停止"
        oldPeer.closeAfterSessionTermination(notify: subscribed)
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
        relayHostRegistrations.forEach { $0.stop() }; relayHostRegistrations = []; relayRegistrationStates = [:]
        relayHostStatus = relayEnabled ? "中继共享已停止" : "中继已关闭"
        relaySelectedForTarget = false
        relayFallbackAttempted = false
        relayFallbackCooldown.reset()
        connectionError = nil
        hostRetryTask?.cancel()
        hostPreparationTask?.cancel()
        hostPreparationTask = nil
        reconnectTask?.cancel()
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
        clipboardHandledChange = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        metricsTimer?.invalidate()
        metricsTimer = nil
        traffic = "0.00 Mbps"
        frameRate = "0 fps"
        resolution = ""
        remoteName = ""
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
        for observer in sessionWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in sessionLockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let windowActivityMonitor { NSEvent.removeMonitor(windowActivityMonitor) }
    }
}
