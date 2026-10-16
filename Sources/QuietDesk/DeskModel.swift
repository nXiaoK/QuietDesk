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
    @Published var frameRate = "0 fps"
    @Published var latency = "— ms"
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
    @Published private(set) var activeVideoState: VideoStreamState?
    @Published private(set) var videoTuning: VideoTuningSession?
    @Published private(set) var videoSettingsStatus = ""
    var viewerSettings: StreamSettings { videoTuning?.desired ?? activeVideoState?.settings ?? StreamSettings() }
    var viewerLongestEdges: [Int] { supportsExtendedVideoSettings ? StreamSettings.longestEdges : StreamSettings.legacyLongestEdges }
    var viewerBitRates: [Int] { supportsExtendedVideoSettings ? StreamSettings.bitRates : StreamSettings.legacyBitRates }
    @Published var inputStatus = ""
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
    private var pending: [UUID: Peer] = [:]
    private var streamer: ScreenStreamer?
    private var injector: InputInjector?
    private var generation = UUID()
    private var helloReceived = false
    private var activity: NSObjectProtocol?
    private var metricsTimer: Timer?
    private var permissionTimer: Timer?
    private var capsLockStartAttempted = false
    private var controlStatusUpdatesEnabled = false
    private var byteCount = 0
    private var frames = 0
    private var lastMetrics = ProcessInfo.processInfo.systemUptime
    private var captureTask: Task<Void, Never>?
    private var lastLatencyAt: TimeInterval?
    private var reconnectTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
    private var hostRetryTask: Task<Void, Never>?
    private var retryBackoff = RetryBackoff()
    private var hostBackoff = RetryBackoff()
    private var hostingRequested = false
    private var clipboardSync: ClipboardSync?
    private var supportsClipboard = false
    private var remoteClipboardEnabled = false
    private var remoteFileApproval = false
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
    }
    private var target: Target?
    private var savedTarget = false
    private var viewerQualityPolicy = ViewerQualityPolicy()
    private var pendingVideoPreferenceCanSave = true
    private var videoDebounceTask: Task<Void, Never>?
    private var videoRequestTimeout: Task<Void, Never>?
    private var hostSettingsTask: Task<Void, Never>?
    private var hostSettingsRequestID: UUID?
    private var screenObserver: NSObjectProtocol?
    private var displayRefreshTask: Task<Void, Never>?
    private var hostPreparationTask: Task<Void, Never>?
    private var capturedDisplay: DisplaySnapshot?

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

        canvas.onInput = { [weak self] value in
            guard let self, self.connected, self.canControl else { return }
            var input = value
            if input.kind == .switchInputSource || input.kind == .toggleCapsLock {
                guard self.supportsInputActions else { return }
            }
            if self.canvas.usesCapsLockActions { input.independentCapsLock = true }
            do { self.peer?.send(try Wire.json(.input, input)) }
            catch { self.error = error.localizedDescription }
        }
        canvas.onRelease = { [weak self] in self?.peer?.send(Message(.releaseInput)) }
        canvas.onFocus = { [weak self] focused in
            guard let self else { return }
            self.controlling = focused
            self.refreshClipboardFocus()
        }
        canvas.onFailure = { [weak self] message in self?.peer?.close(message, retryable: true) }
        canvas.onPaste = { [weak self] input in
            guard let self, let peer = self.peer, self.connected else { return }
            let interaction = self.canvas.interactionRevision
            self.clipboardStatus = "正在等待剪贴板同步后粘贴…"
            self.clipboardSync?.prepareForPaste { [weak self, weak peer] success in
                guard let self, let peer, self.peer === peer, self.connected else { return }
                guard success, self.canvas.interactionRevision == interaction,
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
                guard let self, self.connected || self.capsLockEnabled else { return }
                self.refreshPermissions()
            }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    }

    func toggleFullScreen() {
        guard let window = canvas.window ?? NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    func requestInputMonitoring() {
        if mode == .viewer { canvas.releaseControl() }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func setCapsLockEnabled(_ enabled: Bool) {
        capsLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "capsLockActions")
        refreshPermissions(retryCapsLock: true)
        if !enabled { inputStatus = "Caps Lock 转发已关闭" }
    }

    func refreshPermissions(checkScreenCapture: Bool = false, retryCapsLock: Bool = false) {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = mode == .viewer && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if localAccessibility != accessibility { localAccessibility = accessibility }
        if localInputMonitoring != inputMonitoring { localInputMonitoring = inputMonitoring }
        if checkScreenCapture, mode == .host { localScreenRecording = CGPreflightScreenCaptureAccess() }

        if mode == .host, connected, canControl != accessibility {
            canControl = accessibility
            if !accessibility { injector?.releaseAll() }
            status = accessibility ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（辅助功能未生效）"
            if controlStatusUpdatesEnabled, let peer {
                do { peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: accessibility))) }
                catch { peer.close(error.localizedDescription) }
            } else if accessibility {
                status = "辅助功能已生效 · 旧版控制端需重新连接后操作"
            }
        }

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
        canvas.usesCapsLockActions = capsLockRunning && supportsInputActions && canControl
        if connected, !supportsInputActions { inputStatus = "远端版本较旧，请更新家里 Mac 后使用 Caps Lock 切换输入法" }
    }

    func prepareHostCode() {
        guard hostCode.isEmpty else { return }
        do {
            if let key = try KeyStore.load() { hostCode = key.code }
            else { try replaceKey() }
        } catch { self.error = error.localizedDescription }
    }

    func regenerateKey() {
        guard !active, !working else { return }
        do { try replaceKey() } catch { self.error = error.localizedDescription }
    }

    private func replaceKey() throws {
        let key = try PairingKey.generate()
        try KeyStore.save(key)
        hostCode = key.code
    }

    func copyHostCode() {
        prepareHostCode()
        guard !hostCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hostCode, forType: .string)
        clipboardStatus = "配对码已复制，请通过可信渠道传到公司 Mac"
    }

    func requestAccessibility() {
        if mode == .viewer { canvas.releaseControl() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
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
        DisplaySnapshot(id: id, pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                        bounds: CGDisplayBounds(id))
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
        if mode == .host, hostingRequested, active, let capturedDisplay,
           DisplaySelection.requiresRestart(captured: capturedDisplay, available: available) {
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
        guard !active, !working else { return }
        hostingRequested = true
        hostRetryTask?.cancel()
        prepareHostCode()
        do {
            let key = try PairingKey(code: hostCode)
            let port = try validPort(hostPort)
            guard CGPreflightScreenCaptureAccess() else {
                if interactive { openScreenPermission() }
                throw DeskError.invalid("请允许 QuietDesk 录制屏幕，然后完全退出并重新打开应用")
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
                    listener.newConnectionHandler = { [weak self] connection in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token, self.active else { connection.cancel(); return }
                            self.accept(connection, generation: token)
                        }
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            switch state {
                            case .ready:
                                self.working = false
                                self.hostBackoff.reset()
                                self.status = "等待连接 · TCP \(port.rawValue)"
                            case .failed(let error):
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
                    self.status = "共享未启动：\(error.localizedDescription)"
                    if self.hostingRequested { self.scheduleHostRetry() }
                    if interactive { self.error = error.localizedDescription }
                }
            }
        } catch {
            working = false
            status = "共享未启动：\(error.localizedDescription)"
            if interactive { self.error = error.localizedDescription }
        }
    }

    private func accept(_ connection: NWConnection, generation token: UUID) {
        let candidate = Peer(connection: connection)
        let id = UUID()
        pending[id] = candidate
        candidate.onReady = { [weak self, weak candidate] in
            DispatchQueue.main.async {
                guard let self, let candidate, self.pending.removeValue(forKey: id) != nil,
                      self.generation == token, self.active, self.hostingRequested else { return }
                guard self.peer == nil else { candidate.close("这台 Mac 当前已有控制连接"); return }
                self.peer = candidate
                self.status = "正在准备连接画面…"
                self.captureTask = Task { [weak self, weak candidate] in
                    guard let self, let candidate else { return }
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        guard self.generation == token, self.active, self.peer === candidate, !Task.isCancelled else { return }
                        self.refreshDisplays()
                        let (display, snapshot) = try self.selectShareableDisplay(content.displays)
                        let preferredSettings = self.settings
                        let settings = preferredSettings.legacyCompatible
                        let (width, height) = settings.dimensions(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
                        self.capturedDisplay = snapshot
                        self.connected = true
                        self.canControl = AXIsProcessTrusted()
                        self.status = self.canControl ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（未授权辅助功能）"
                        self.resolution = "\(width) × \(height)"
                        self.activeVideoState = VideoStreamState(settings: settings, width: width, height: height)
                        self.injector = InputInjector(displayID: display.displayID)
                        candidate.send(try Wire.json(.hello, Hello(name: Host.current().localizedName ?? "家里 Mac",
                            width: width, height: height, settings: settings, canControl: self.canControl,
                            preferredSettings: preferredSettings)))
                        let streamer = ScreenStreamer()
                        self.streamer = streamer
                        streamer.onFrame = { [weak self, weak candidate] packet in
                            guard let candidate else { return }
                            do {
                                candidate.send(Message(.video, try packet.encode()))
                                DispatchQueue.main.async {
                                    guard let self, self.peer === candidate else { return }
                                    self.frames += 1
                                }
                            } catch { candidate.close(error.localizedDescription) }
                        }
                        streamer.onError = { [weak candidate] in candidate?.close($0, retryable: true) }
                        streamer.onUserStop = { [weak self, weak candidate] in
                            DispatchQueue.main.async {
                                guard let self, let candidate, self.peer === candidate else { return }
                                self.recordDisconnect("用户从系统停止了屏幕共享")
                                self.stop()
                            }
                        }
                        try await streamer.start(display: display, width: width, height: height, settings: settings)
                        guard self.generation == token, self.active, self.peer === candidate, !Task.isCancelled else {
                            await streamer.stop()
                            return
                        }
                    } catch {
                        guard self.generation == token, self.active, self.peer === candidate, !Task.isCancelled else { return }
                        if self.capturedDisplay == nil { self.restartHostAfterFailure("共享准备失败：\(error.localizedDescription)") }
                        else { candidate.close(error.localizedDescription, retryable: true) }
                    }
                }
            }
        }
        candidate.onMessage = { [weak self, weak candidate] message in
            DispatchQueue.main.async {
                guard let self, let candidate, self.generation == token, self.active, self.peer === candidate else { return }
                guard self.connected else { candidate.close("屏幕共享尚未就绪", retryable: true); return }
                do { try self.handleHost(message, peer: candidate) }
                catch { candidate.close(error.localizedDescription) }
            }
        }
        candidate.onClose = { [weak self, weak candidate] reason in
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
        candidate.onTraffic = { [weak self, weak candidate] count in
            DispatchQueue.main.async {
                guard let self, let candidate, self.generation == token, self.peer === candidate else { return }
                self.byteCount += count
            }
        }
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
            let target = Target(address: address, port: port.rawValue, key: key)
            self.target = target
            let saved = connections.first(where: { $0.matches(address: address, port: port.rawValue) })?.videoSettings
            viewerQualityPolicy = ViewerQualityPolicy(preferred: saved.flatMap { (try? $0.validateControlValues()) != nil ? $0 : nil })
            savedTarget = false
            retryBackoff.reset()
            generation = UUID()
            beginMetrics()
            beginConnection(target)
        } catch { self.connectionError = error.localizedDescription }
    }

    private func beginConnection(_ target: Target) {
        let candidate = Peer(connection: NWConnection(host: NWEndpoint.Host(target.address),
            port: NWEndpoint.Port(rawValue: target.port)!, using: SecureTransport.parameters(key: target.key)))
        peer = candidate
        active = true
        working = true
        helloReceived = false
        candidate.onRoundTripMilliseconds = { [weak self, weak candidate] milliseconds in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                self.roundTripMilliseconds = milliseconds
                self.latency = String(format: milliseconds < 10 ? "%.1f ms" : "%.0f ms", milliseconds)
                self.lastLatencyAt = ProcessInfo.processInfo.systemUptime
                self.viewerQualityPolicy.observeRoundTrip(milliseconds)
                self.applyInitialVideoQualityIfReady()
            }
        }
        status = reconnecting ? "正在重新建立加密连接…" : "正在建立加密连接…"
        candidate.onReady = { [weak self, weak candidate] in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                self.status = "连接已加密，等待画面…"
            }
        }
        candidate.onMessage = { [weak self, weak candidate] message in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                do { try self.handleViewer(message, peer: candidate) }
                catch { candidate.close(error.localizedDescription) }
            }
        }
        candidate.onTraffic = { [weak self, weak candidate] count in
            DispatchQueue.main.async {
                guard let self, let candidate, self.peer === candidate else { return }
                self.byteCount += count
            }
        }
        candidate.onClose = { [weak self, weak candidate] reason in
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
        let delay = retryBackoff.next()
        let token = generation
        active = true
        working = true
        reconnecting = true
        status = "\(Int(delay)) 秒后第 \(retryBackoff.attempt) 次重连 · \(reason)"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token, let target = self.target, self.autoReconnect else { return }
            self.beginConnection(target)
        }
    }

    func quickConnect(_ record: ConnectionRecord) {
        guard !active, !working else { return }
        address = record.address
        port = String(record.port)
        connectionError = nil
        do {
            guard let key = try KeyStore.load(account: "remote." + record.id.uuidString) else {
                viewerCode = ""
                throw DeskError.invalid("此记录的配对码不在钥匙串中，请重新粘贴并连接")
            }
            viewerCode = key.code
            connect()
        } catch { self.connectionError = error.localizedDescription }
    }

    func removeConnection(_ record: ConnectionRecord) {
        do {
            try KeyStore.remove(account: "remote." + record.id.uuidString)
            connections.removeAll { $0.id == record.id }
            try ConnectionStore.save(connections)
        } catch { self.error = error.localizedDescription }
    }

    private func saveConnection(name: String) {
        guard !savedTarget, let target else { return }
        do {
            var record = connections.first { $0.matches(address: target.address, port: target.port) }
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
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        lastDisconnect = "\(time) · \(reason)"
        UserDefaults.standard.set(lastDisconnect, forKey: "lastDisconnect")
    }

    private func handleHost(_ message: Message, peer: Peer) throws {
        switch message.kind {
        case .controlStatus:
            guard message.payload.isEmpty else { throw DeskError.invalid("控制权限订阅消息无效") }
            refreshPermissions()
            controlStatusUpdatesEnabled = true
            status = canControl ? "正在共享 · 允许键盘鼠标控制" : "正在共享 · 仅观看（辅助功能未生效）"
            peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: canControl)))
        case .acknowledgement:
            guard message.payload.count == 4 else { throw DeskError.invalid("画面确认无效") }
            var reader = ByteReader(message.payload)
            streamer?.acknowledge(try reader.take() as UInt32)
        case .input:
            let input = try Wire.readJSON(RemoteInput.self, message.payload)
            try input.validate()
            if canControl, let feedback = try injector?.receive(input) {
                peer.send(try Wire.json(.inputStatus, feedback))
            }
        case .releaseInput: injector?.releaseAll()
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
            guard !helloReceived else { throw DeskError.invalid("重复的会话信息") }
            let hello = try Wire.readJSON(Hello.self, message.payload)
            try hello.validate()
            helloReceived = true
            connected = true
            working = false
            remoteName = hello.name
            reconnecting = false
            saveConnection(name: hello.name)
            stableTask?.cancel()
            stableTask = Task { [weak self, weak peer] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, let peer, self.peer === peer else { return }
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
            supportsLiveSettings = hello.liveSettings == true
            supportsExtendedVideoSettings = supportsLiveSettings && hello.extendedVideoSettings == true
            if supportsLiveSettings {
                let hostDefault = supportsExtendedVideoSettings ? (hello.preferredSettings ?? hello.settings) : hello.settings
                let preferred = viewerQualityPolicy.settingsForConnection(hostDefault: hostDefault, supportsExtended: supportsExtendedVideoSettings)
                videoTuning = try VideoTuningSession(applied: state, preferred: preferred)
                videoSettingsStatus = "当前生效：\(state.settings.summary)"
                applyInitialVideoQualityIfReady()
                sendNextVideoSettings()
            } else { videoSettingsStatus = "主机需更新到 0.4.0 才能动态调整画质" }
        case .controlStatus:
            guard helloReceived, controlStatusUpdatesEnabled else { throw DeskError.invalid("对端不支持控制权限更新") }
            let permission = try Wire.readJSON(ControlStatus.self, message.payload)
            if canControl != permission.canControl {
                if !permission.canControl { canvas.releaseControl() }
                canControl = permission.canControl
                canvas.canControl = permission.canControl
                canvas.usesCapsLockActions = capsLockRunning && capsLockEnabled && supportsInputActions && canControl
                status = permission.canControl ? "已连接 · 辅助功能已生效，点击画面开始操作" : "已连接 · 仅观看（家里 Mac 的辅助功能未生效）"
            }
        case .video:
            guard helloReceived else { throw DeskError.invalid("缺少会话信息") }
            let packet = try VideoPacket.decode(message.payload)
            try canvas.present(packet) { [weak peer] in
                var data = Data()
                data.put(packet.sequence)
                peer?.send(Message(.acknowledgement, data))
            }
            frames += 1
        case .clipboard:
            guard helloReceived else { throw DeskError.invalid("缺少会话信息") }
            try receiveClipboard(message.payload)
        case .clipboardSettings:
            guard supportsClipboard else { throw DeskError.invalid("对端不支持自动剪贴板") }
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard preference.session == clipboardSession else { throw DeskError.invalid("剪贴板会话不匹配") }
            remoteClipboardEnabled = preference.enabled
            remoteFileApproval = preference.fileApproval == true
            remoteReceivesAutomaticClipboard = preference.receivesAutomaticUpdates ?? true
            remoteClipboardFocusAware = preference.receivesAutomaticUpdates != nil
            updateClipboardSync()
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            clipboardSync?.receive(message)
        case .inputStatus:
            guard helloReceived, supportsInputActions else { throw DeskError.invalid("不支持的键盘状态消息") }
            inputStatus = try Wire.readJSON(InputFeedback.self, message.payload).message
        case .streamSettingsResult:
            guard helloReceived, supportsLiveSettings, var tuning = videoTuning else { throw DeskError.invalid("对端不支持动态画质") }
            let result = try Wire.readJSON(StreamSettingsResult.self, message.payload)
            guard try tuning.receive(result) else { return }
            videoRequestTimeout?.cancel()
            videoTuning = tuning
            activeVideoState = result.state
            canvas.remoteSize = CGSize(width: result.state.width, height: result.state.height)
            resolution = "\(result.state.width) × \(result.state.height)"
            if let error = result.error { videoSettingsStatus = "调整失败：\(error)" }
            else {
                videoSettingsStatus = "已生效：\(result.state.settings.summary)"
                if viewerQualityPolicy.confirm(result.state.settings, maySave: pendingVideoPreferenceCanSave) {
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
        do { try tuning.choose(settings) }
        catch { videoSettingsStatus = error.localizedDescription; return }
        viewerQualityPolicy.chooseManually()
        if tuning.pending?.settings == settings { pendingVideoPreferenceCanSave = true }
        videoTuning = tuning
        videoDebounceTask?.cancel()
        if tuning.pending == nil, tuning.applied.settings == settings {
            _ = viewerQualityPolicy.confirm(settings, maySave: true)
            saveVideoPreference(settings)
            return
        }
        videoDebounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.sendNextVideoSettings()
        }
    }

    private func applyInitialVideoQualityIfReady() {
        guard connected, supportsLiveSettings, var tuning = videoTuning,
              let settings = viewerQualityPolicy.takeInitialAutomaticSettings(supportsExtended: supportsExtendedVideoSettings) else { return }
        do { try tuning.choose(settings) }
        catch { videoSettingsStatus = error.localizedDescription; return }
        videoTuning = tuning
        sendNextVideoSettings()
    }

    private func sendNextVideoSettings() {
        guard connected, supportsLiveSettings, let peer, var tuning = videoTuning,
              let request = tuning.nextRequest() else { return }
        videoTuning = tuning
        pendingVideoPreferenceCanSave = viewerQualityPolicy.maySaveCurrentChoice
        videoSettingsStatus = "正在应用：\(request.settings.summary)"
        do { peer.send(try Wire.json(.streamSettingsRequest, request)) }
        catch { videoSettingsStatus = error.localizedDescription; peer.close(error.localizedDescription); return }
        videoRequestTimeout?.cancel()
        videoRequestTimeout = Task { [weak self, weak peer] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, let peer, self.peer === peer, self.videoTuning?.pending?.id == request.id else { return }
            peer.close("画质调整超过 25 秒未确认，重新建立共享", retryable: true)
        }
    }

    private func saveVideoPreference(_ settings: StreamSettings) {
        guard let target, let index = connections.firstIndex(where: { $0.matches(address: target.address, port: target.port) }) else { return }
        connections[index].videoSettings = settings
        do { try ConnectionStore.save(connections) }
        catch { videoSettingsStatus = "画质已生效，但保存记录失败：\(error.localizedDescription)" }
    }

    private func applyHostVideoSettings(_ request: StreamSettingsRequest, peer: Peer) {
        guard let state = activeVideoState, let streamer else { return }
        if hostSettingsRequestID == request.id { return }
        if hostSettingsRequestID != nil {
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
        hostSettingsRequestID = request.id
        let token = generation
        let capture = captureTask
        hostSettingsTask = Task { [weak self, weak peer] in
            guard let self, let peer else { return }
            defer {
                if self.generation == token, self.peer === peer, self.hostSettingsRequestID == request.id {
                    self.hostSettingsRequestID = nil; self.hostSettingsTask = nil
                }
            }
            do {
                await capture?.value
                guard self.generation == token, self.peer === peer, self.streamer === streamer,
                      self.hostSettingsRequestID == request.id, !Task.isCancelled else { return }
                let updated = try await streamer.reconfigure(request.settings)
                guard self.generation == token, self.peer === peer, self.streamer === streamer,
                      self.hostSettingsRequestID == request.id, !Task.isCancelled else { return }
                self.activeVideoState = updated
                self.resolution = "\(updated.width) × \(updated.height)"
                self.videoSettingsStatus = "控制端已调整：\(updated.settings.summary)"
                peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: updated)))
                streamer.resumeAfterReconfiguration()
            } catch {
                guard self.generation == token, self.peer === peer, self.hostSettingsRequestID == request.id,
                      !Task.isCancelled, let actual = self.activeVideoState else { return }
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
        mode == .viewer ? NSApp.isActive : remoteReceivesAutomaticClipboard
    }

    private func sendClipboardPreference(to peer: Peer) throws {
        let receives = mode == .viewer ? !controlling : true
        peer.send(try Wire.json(.clipboardSettings, ClipboardPreference(enabled: clipboardEnabled,
            session: clipboardSession, receivesAutomaticUpdates: receives)))
        lastClipboardReceivePreference = receives
    }

    func refreshClipboardFocus() {
        clipboardSync?.setAutomaticSendingAllowed(automaticClipboardSendingAllowed)
        guard mode == .viewer, connected, supportsClipboard, let peer,
              lastClipboardReceivePreference != !controlling else { return }
        do { try sendClipboardPreference(to: peer) }
        catch { clipboardStatus = error.localizedDescription }
    }

    private func updateClipboardSync() {
        let enabled = connected && supportsClipboard && clipboardEnabled && remoteClipboardEnabled
        canvas.synchronizesClipboard = enabled
        if enabled, clipboardSync == nil, let peer, let clipboardSession {
            let sync = ClipboardSync(session: clipboardSession, allowsFileSending: remoteFileApproval,
                allowsAutomaticSending: automaticClipboardSendingAllowed) { [weak peer] in peer?.send($0) }
            clipboardSync = sync
            sync.onStatus = { [weak self, weak sync] message in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.clipboardStatus = message
            }
            sync.onFileOffer = { [weak self, weak sync] offer in
                guard let self, let sync, self.clipboardSync === sync else { return }
                self.clipboardFilePrompt?.dismiss()
                self.clipboardFilePrompt = nil
                self.pendingFileOffer = offer
                guard let offer else { return }
                if self.mode == .viewer { self.canvas.releaseControl() }
                else { self.injector?.releaseAll() }
                let prompt = ClipboardFilePrompt(offer: offer, peerName: self.mode == .viewer ? self.remoteName : "") { [weak sync] accepted in
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
            clipboardSync?.stop(); clipboardSync = nil
            clipboardFilePrompt?.dismiss(); clipboardFilePrompt = nil
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
        guard hostingRequested else { return }
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

    private func beginMetrics() {
        byteCount = 0
        frames = 0
        lastMetrics = ProcessInfo.processInfo.systemUptime
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = max(0.01, ProcessInfo.processInfo.systemUptime - self.lastMetrics)
                self.traffic = String(format: "%.2f Mbps", Double(self.byteCount) * 8 / seconds / 1_000_000)
                self.frameRate = String(format: "%.0f fps", Double(self.frames) / seconds)
                if let measured = self.lastLatencyAt, ProcessInfo.processInfo.systemUptime - measured > 15 {
                    self.latency = "— ms"
                    self.roundTripMilliseconds = nil
                }
                self.byteCount = 0
                self.frames = 0
                self.lastMetrics = ProcessInfo.processInfo.systemUptime
            }
        }
        if let metricsTimer { RunLoop.main.add(metricsTimer, forMode: .common) }
    }

    private func clearSession() {
        controlStatusUpdatesEnabled = false
        capsLockRunning = false
        capsLockStartAttempted = false
        latency = "— ms"
        roundTripMilliseconds = nil
        lastLatencyAt = nil
        viewerQualityPolicy.discardUnfinishedSample()
        videoDebounceTask?.cancel()
        videoRequestTimeout?.cancel()
        hostSettingsTask?.cancel()
        hostSettingsTask = nil
        hostSettingsRequestID = nil
        supportsLiveSettings = false
        supportsExtendedVideoSettings = false
        videoTuning = nil
        activeVideoState = nil
        videoSettingsStatus = ""
        stableTask?.cancel()
        clipboardSync?.stop()
        clipboardSync = nil
        clipboardFilePrompt?.dismiss(); clipboardFilePrompt = nil
        pendingFileOffer = nil
        canvas.synchronizesClipboard = false
        supportsClipboard = false
        remoteClipboardEnabled = false
        remoteFileApproval = false
        remoteReceivesAutomaticClipboard = true
        remoteClipboardFocusAware = false
        lastClipboardReceivePreference = nil
        clipboardSession = nil
        captureTask?.cancel()
        captureTask = nil
        capturedDisplay = nil
        if let streamer { Task { await streamer.stop() } }
        streamer = nil
        injector?.releaseAll()
        injector = nil
        peer = nil
        connected = false
        working = false
        controlling = false
        canControl = false
        supportsInputActions = false
        canvas.usesCapsLockActions = false
        canvas.capsLockMonitor.stop()
        canvas.reset()
        helloReceived = false
    }

    func stop() {
        hostingRequested = false
        connectionError = nil
        hostRetryTask?.cancel()
        hostPreparationTask?.cancel()
        hostPreparationTask = nil
        reconnectTask?.cancel()
        stableTask?.cancel()
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
        permissionTimer?.invalidate()
        displayRefreshTask?.cancel()
        hostPreparationTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
