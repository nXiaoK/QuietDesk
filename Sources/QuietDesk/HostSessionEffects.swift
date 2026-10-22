import AppKit
import Carbon
import CoreAudio
import Darwin
import QuietDeskCore

@MainActor
protocol SessionAudioControlling: AnyObject {
    var isMuted: Bool { get }
    var onChange: ((Bool, String?) -> Void)? { get set }
    func enable() async throws
    func restoreAndStop() async throws
}

@MainActor
protocol SessionPrivacyCover: AnyObject {
    /// True once the curtain is opaque; prepared covers are not yet a curtain.
    var isVisible: Bool { get }
    /// Window-server numbers of the cover windows, so capture can leave out only these windows.
    var windowIDs: [CGWindowID] { get }
    var onExit: (() -> Void)? { get set }
    /// Covers were added or removed for a new screen arrangement while the curtain is up.
    var onWindowsChanged: (([CGWindowID]) -> Void)? { get set }
    /// Orders the covers in nearly transparent and returns their window numbers.
    func prepare() throws -> [CGWindowID]
    /// Makes prepared covers opaque, after capture has been told to leave them out.
    func reveal()
    func hide()
}

@MainActor
protocol SessionScreenLocking: AnyObject {
    /// Why this Mac cannot lock itself, or nil when a lock method is available.
    var unavailableReason: String? { get }
    /// Starts the lock right away; returns a failure when no method could be started.
    func lock() -> String?
    /// Waits briefly until the system reports a locked session.
    func confirmLocked() async -> String?
}

@MainActor
protocol SessionDisplayDimming: AnyObject {
    /// Why the built-in display cannot be dimmed now, or nil when it can.
    var unavailableReason: String? { get }
    var isDimmed: Bool { get }
    /// Dimming ended without a request, for example after the brightness was raised on this Mac.
    var onEnded: ((String) -> Void)? { get set }
    func dim() async throws
    /// Puts the original brightness back unless it was raised meanwhile; returns why that failed.
    func restore() -> String?
    /// A session lock was just requested: should the app go away now, the brightness comes back after the lock.
    func holdForLock()
}

@MainActor
final class HostSessionEffects {
    private(set) var state = SessionEffectsState()
    var onStateChange: ((SessionEffectsState, String?) -> Void)?
    /// The curtain's windows changed while it is up; capture should leave out the new set.
    var onCoverWindowsChanged: (([CGWindowID]) -> Void)?
    private var revision = UUID()
    private var applying = false
    private var resetsInProgress = 0
    private let audio: SessionAudioControlling
    private let privacy: SessionPrivacyCover
    private let screenLock: SessionScreenLocking
    private let dimmer: SessionDisplayDimming
    private var locksOnDisconnect = false
    private var lockTask: Task<String?, Never>?
    private var audioRestoreTask: Task<String?, Never>?
    private var audioRestoreID: UUID?

    convenience init() {
        self.init(audio: SessionAudioClient(), privacy: SessionPrivacyWindows(), screenLock: SystemScreenLock(),
                  dimmer: BuiltInDisplayDimmer())
    }

    init(audio: SessionAudioControlling, privacy: SessionPrivacyCover, screenLock: SessionScreenLocking, dimmer: SessionDisplayDimming) {
        self.audio = audio; self.privacy = privacy; self.screenLock = screenLock; self.dimmer = dimmer
        audio.onChange = { [weak self] muted, error in
            guard let self else { return }
            let state = SessionEffectsState(muted: muted, privacy: self.privacy.isVisible, lockOnDisconnect: self.locksOnDisconnect,
                                            dimBuiltInDisplay: self.dimmer.isDimmed)
            // A helper exit that changes nothing must not replace the failure the viewer was just sent.
            guard state != self.state || error != nil else { return }
            self.state = state
            self.onStateChange?(self.state, error)
        }
        privacy.onExit = { [weak self] in
            guard let self else { return }
            self.state = self.actualState
            self.onStateChange?(self.state, "本机已退出防窥")
        }
        privacy.onWindowsChanged = { [weak self] windows in self?.onCoverWindowsChanged?(windows) }
        dimmer.onEnded = { [weak self] reason in
            guard let self else { return }
            self.state = self.actualState
            self.onStateChange?(self.state, reason)
        }
    }

    /// Whether this Mac is a laptop whose built-in display brightness can be turned down right now.
    var canDimBuiltInDisplay: Bool { dimmer.unavailableReason == nil }

    private var actualState: SessionEffectsState {
        SessionEffectsState(muted: audio.isMuted, privacy: privacy.isVisible, lockOnDisconnect: locksOnDisconnect,
                            dimBuiltInDisplay: dimmer.isDimmed)
    }

    /// `preparePrivacy` receives the cover windows that capture must leave out before they turn opaque.
    func apply(_ desired: SessionEffectsState, preparePrivacy: @MainActor ([CGWindowID]) async throws -> Void) async throws -> SessionEffectsState {
        guard !applying, resetsInProgress == 0 else { throw DeskError.invalid("正在处理上一项会话操作，请稍后重试") }
        try Task.checkCancellation()
        applying = true
        defer { applying = false }
        let token = UUID()
        revision = token
        if !desired.lockOnDisconnect { locksOnDisconnect = false }
        if !desired.privacy { privacy.hide(); state = actualState }
        var dimRestoreFailure: String?
        if !desired.dimBuiltInDisplay, dimmer.isDimmed { dimRestoreFailure = dimmer.restore(); state = actualState }
        do {
            if desired.privacy, !state.privacy {
                let windows = try privacy.prepare()
                do {
                    try await preparePrivacy(windows)
                    try Task.checkCancellation()
                    guard revision == token else { throw CancellationError() }
                } catch {
                    // Covers that capture may still include must never turn opaque.
                    privacy.hide()
                    throw error
                }
                privacy.reveal()
                state = actualState
            }
            if desired.muted != audio.isMuted {
                if desired.muted { try await audio.enable() }
                else if let error = await restoreAudio() { throw DeskError.invalid(error) }
            }
            try Task.checkCancellation()
            guard revision == token else { throw CancellationError() }
            if desired.lockOnDisconnect, !locksOnDisconnect {
                if let reason = screenLock.unavailableReason { throw DeskError.invalid(reason) }
                locksOnDisconnect = true
            }
            // Last, so a display that cannot be dimmed does not hold back the other switches.
            if desired.dimBuiltInDisplay, !dimmer.isDimmed {
                if let reason = dimmer.unavailableReason { throw DeskError.invalid(reason) }
                try await dimmer.dim()
                // A reset that ran meanwhile found nothing to restore yet, so the brightness comes back here.
                guard revision == token, !Task.isCancelled else { _ = dimmer.restore(); throw CancellationError() }
            }
            if let dimRestoreFailure { throw DeskError.invalid(dimRestoreFailure) }
            state = actualState
            return state
        } catch {
            if error is CancellationError, revision == token { _ = await reset() }
            if revision == token { state = actualState }
            throw error
        }
    }

    /// Starts a requested lock synchronously, so it is issued even while the app is quitting.
    /// Without a lock the curtain comes down and the brightness comes back right here rather than after
    /// the asynchronous reset. Later calls return the same confirmation.
    @discardableResult
    func endSession() -> Task<String?, Never>? {
        if locksOnDisconnect, lockTask == nil {
            locksOnDisconnect = false
            let lock = screenLock
            let failure = lock.lock()
            lockTask = Task { @MainActor in
                if let failure { return failure }
                return await lock.confirmLocked()
            }
        }
        if lockTask == nil {
            if !privacy.windowIDs.isEmpty { privacy.hide(); state = actualState }
            // A failure leaves the display marked dark; reset tries again and reports it.
            if dimmer.isDimmed { _ = dimmer.restore(); state = actualState }
        } else if dimmer.isDimmed { dimmer.holdForLock() }
        return lockTask
    }

    /// Closes cover windows that `live` does not own, such as covers left by an interrupted cleanup.
    /// Returns how many were removed.
    @discardableResult
    static func removeStrayCovers(keeping live: HostSessionEffects?) -> Int {
        SessionPrivacyWindows.removeStray(keeping: live?.privacy as? SessionPrivacyWindows)
    }

    func reset() async -> String? {
        resetsInProgress += 1
        defer { resetsInProgress -= 1 }
        let token = UUID()
        revision = token
        // The lock screen has to cover the display before the curtain comes down or the brightness comes back.
        let lockError = await endSession()?.value
        privacy.hide()
        let dimError = dimmer.restore()
        state = actualState
        let error = await restoreAudio()
        if revision == token { state = actualState }
        let errors = [lockError, dimError, error].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "；")
    }

    private func restoreAudio() async -> String? {
        if let audioRestoreTask { return await audioRestoreTask.value }
        let id = UUID()
        audioRestoreID = id
        let audio = self.audio
        let task = Task<String?, Never> { @MainActor in
            do { try await audio.restoreAndStop(); return nil }
            catch { return error.localizedDescription }
        }
        audioRestoreTask = task
        let result = await task.value
        if audioRestoreID == id { audioRestoreTask = nil; audioRestoreID = nil }
        return result
    }

    static func runWatchdogIfRequested() -> Bool {
        if DisplayDimWatchdog.runIfRequested() { return true }
        guard CommandLine.arguments.contains(SessionAudioClient.watchdogArgument) else { return false }
        let watchdog = SessionAudioWatchdog()
        watchdog.run()
        return true
    }

}

@MainActor
private final class SystemScreenLock: SessionScreenLocking {
    private typealias LockImmediately = @convention(c) () -> Int32
    // The system's own lock entry point, resolved at run time; the ⌃⌘Q shortcut is the fallback.
    private static let lockImmediately: LockImmediately? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockImmediately.self)
    }()
    private var postedShortcut = false

    var unavailableReason: String? {
        Self.lockImmediately != nil || AXIsProcessTrusted() ? nil : "被控端无法自动锁屏：系统锁屏接口不可用，且未授权辅助功能"
    }

    func lock() -> String? {
        if let lockImmediately = Self.lockImmediately { _ = lockImmediately(); return nil }
        return postLockShortcut() ? nil : "自动锁屏失败：系统锁屏接口不可用，且未授权辅助功能"
    }

    func confirmLocked() async -> String? {
        if await waitForLock(seconds: 1.5) { return nil }
        if !postedShortcut, postLockShortcut(), await waitForLock(seconds: 1.5) { return nil }
        return "已请求自动锁屏，但系统未进入锁屏状态"
    }

    private func postLockShortcut() -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return false }
        postedShortcut = true
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down) else { return false }
            event.flags = [.maskControl, .maskCommand]
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private func waitForLock(seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline, !Self.isLocked { try? await Task.sleep(for: .milliseconds(100)) }
        return Self.isLocked
    }

    private static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }
}

@MainActor
private final class SessionPrivacyWindows: SessionPrivacyCover {
    // Barely visible, so the window server lists the cover before capture is told to leave it out.
    private static let preparedAlpha: CGFloat = 0.01
    var onExit: (() -> Void)?
    var onWindowsChanged: (([CGWindowID]) -> Void)?
    var isVisible: Bool { revealed && !windows.isEmpty }
    var windowIDs: [CGWindowID] { windows.values.map { CGWindowID($0.windowNumber) }.sorted() }
    // One cover per display, kept across arrangement changes so the shared display's window ID stays put.
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var revealed = false
    private var preparedIDs: [CGWindowID] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.windows.isEmpty else { return }
                    let screens = NSScreen.screens
                    guard !screens.isEmpty else { self.hide(); self.onExit?(); return }
                    if self.arrange(screens), self.revealed { self.onWindowsChanged?(self.windowIDs) }
                }
            }
    }

    static func removeStray(keeping owner: SessionPrivacyWindows?) -> Int {
        var removed = 0
        for case let window as PrivacyCoverWindow in NSApp.windows where window.isVisible && (window.owner == nil || window.owner !== owner) {
            window.orderOut(nil); window.close()
            removed += 1
        }
        return removed
    }

    func prepare() throws -> [CGWindowID] {
        guard windows.isEmpty else { return windowIDs }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw DeskError.invalid("当前没有可覆盖的显示器") }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x51445056, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let cover = Unmanaged<SessionPrivacyWindows>.fromOpaque(context).takeUnretainedValue()
                cover.hide()
                cover.onExit?()
            }
            return noErr
        }, 1, &event, context, &hotKeyHandler)
        guard handlerStatus == noErr else { throw DeskError.system("无法安装本机防窥退出快捷键", handlerStatus) }
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x51445056, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
            throw DeskError.system("本机 ⌃⌥Esc 已被占用，防窥未开启", status)
        }
        revealed = false
        arrange(screens)
        preparedIDs = windowIDs
        return preparedIDs
    }

    func reveal() {
        guard !windows.isEmpty else { return }
        revealed = true
        windows.values.forEach { $0.alphaValue = 1 }
        // A display added while capture was being prepared brought a cover capture has not seen yet.
        if windowIDs != preparedIDs { onWindowsChanged?(windowIDs) }
    }

    /// Returns whether a cover was added or removed; existing covers only follow their display's frame.
    @discardableResult
    private func arrange(_ screens: [NSScreen]) -> Bool {
        var next: [CGDirectDisplayID: NSWindow] = [:]
        var changed = false
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if let window = windows.removeValue(forKey: id) {
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
                next[id] = window
            } else {
                next[id] = makeWindow(screen)
                changed = true
            }
        }
        for window in windows.values { window.orderOut(nil); window.close(); changed = true }
        windows = next
        return changed
    }

    private func makeWindow(_ screen: NSScreen) -> NSWindow {
        let window = PrivacyCoverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        // Declared non-opaque on purpose: an opaque full-screen window marks every window below it as
        // occluded, and browsers and Electron apps then stop drawing, freezing what the viewer sees.
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.alphaValue = revealed ? 1 : Self.preparedAlpha
        window.owner = self
        window.orderFrontRegardless()
        return window
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
        revealed = false
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler); self.hotKeyHandler = nil }
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}

@MainActor
private final class PrivacyCoverWindow: NSWindow {
    /// Nil once the cover object that placed this window is gone, which makes the window a stray.
    weak var owner: SessionPrivacyWindows?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Delivers each pipe read as soon as it returns, until EOF or a read error.
/// FileHandle.read(upToCount:) waits for the full count or EOF, which would hold back short replies.
func readAvailableChunks(from handle: FileHandle, _ deliver: (Data) -> Void) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return }
        deliver(Data(buffer[..<count]))
    }
}

private enum SessionAudioCommand: String, Codable { case prepare, mute, restore }
private struct SessionAudioRequest: Codable { let id: UUID; let command: SessionAudioCommand }
private struct SessionAudioReply: Codable {
    let id: UUID?
    let muted: Bool
    let snapshots: [SessionMuteSnapshot]
    let error: String?
}

@MainActor
final class SessionAudioExitBarrier {
    private struct Completion { let error: String? }
    private var active = Set<UUID>()
    private var completed: [UUID: Completion] = [:]
    private var waiters: [UUID: [CheckedContinuation<String?, Never>]] = [:]

    func begin(_ token: UUID) { active.insert(token) }

    func wait(for token: UUID) async -> String? {
        if let completion = completed[token] { return completion.error }
        guard active.contains(token) else { return "静音恢复子进程退出屏障不可用" }
        return await withCheckedContinuation { waiters[token, default: []].append($0) }
    }

    func finish(_ token: UUID, error: String?) {
        guard active.remove(token) != nil else { return }
        completed[token] = Completion(error: error)
        waiters.removeValue(forKey: token)?.forEach { $0.resume(returning: error) }
    }
}

@MainActor
private final class SessionAudioClient: SessionAudioControlling {
    static let watchdogArgument = "--quietdesk-session-audio-watchdog-v1"
    private static let readerQueue = DispatchQueue(label: "quietdesk.session-audio.reader")
    private(set) var isMuted = false
    var onChange: ((Bool, String?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var processID = UUID()
    private var closing = false
    private var snapshots: [SessionMuteSnapshot] = []
    private var restoreTask: Task<Void, Error>?
    private let exitBarrier = SessionAudioExitBarrier()
    private var processHasExited = false
    private var outputHasEnded = false
    private struct Pending {
        let continuation: CheckedContinuation<SessionAudioReply, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [UUID: Pending] = [:]

    func enable() async throws {
        guard !closing else { throw DeskError.invalid("正在恢复上一项会话静音，请稍后重试") }
        if process == nil { try start() }
        let token = processID
        let prepared = try await request(.prepare)
        guard process != nil, processID == token, !closing else { throw CancellationError() }
        snapshots = prepared.snapshots
        _ = try await request(.mute)
    }

    func restoreAndStop() async throws {
        if let restoreTask { return try await restoreTask.value }
        guard process != nil else {
            if !snapshots.isEmpty {
                var recovery = SessionMuteTransaction(recovering: snapshots)
                try recovery.restore(using: CoreAudioMuteDeviceIO())
                snapshots.removeAll(); isMuted = false
            }
            return
        }
        closing = true
        let token = processID
        let writer = input
        let task = Task<Void, Error> { @MainActor in
            var requestError: String?
            if self.processID == token, self.process != nil {
                do {
                    _ = try await self.request(.restore)
                    if self.processID == token { self.snapshots.removeAll() }
                } catch { requestError = error.localizedDescription }
            }
            try? writer?.close()
            if self.processID == token {
                self.input = nil
                if requestError != nil { self.stopProcess() }
            }
            let exitError = await self.exitBarrier.wait(for: token)
            let errors = [requestError, exitError].compactMap { $0 }
            if !errors.isEmpty { throw DeskError.invalid(Array(Set(errors)).sorted().joined(separator: "；")) }
        }
        restoreTask = task
        try await task.value
    }

    private func start() throws {
        guard let executable = Bundle.main.executableURL else { throw DeskError.invalid("无法找到静音恢复子进程") }
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = executable
        process.arguments = [Self.watchdogArgument]
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.nullDevice
        guard fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw DeskError.invalid("无法保护会话静音子进程管道")
        }
        let token = UUID()
        processID = token
        exitBarrier.begin(token)
        processHasExited = false
        outputHasEnded = false
        closing = false
        restoreTask = nil
        buffer.removeAll()
        output = outgoing.fileHandleForReading
        input = incoming.fileHandleForWriting
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processID == token else { return }
                self.processHasExited = true
                self.finishExitIfReady()
            }
        }
        self.process = process
        do { try process.run() }
        catch {
            self.process = nil
            try? output?.close(); try? input?.close()
            output = nil; input = nil
            exitBarrier.finish(token, error: error.localizedDescription)
            throw error
        }
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        let reader = outgoing.fileHandleForReading
        Self.readerQueue.async { [weak self] in
            readAvailableChunks(from: reader) { data in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, token: token) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishReading(token) } }
        }
    }

    private func request(_ command: SessionAudioCommand) async throws -> SessionAudioReply {
        guard process != nil, let input else { throw DeskError.invalid("静音恢复子进程不可用") }
        let id = UUID()
        var data = try JSONEncoder().encode(SessionAudioRequest(id: id, command: command))
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let self, self.pending[id] != nil else { return }
                self.fail(DeskError.invalid("静音恢复子进程响应超时"))
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            do { try input.write(contentsOf: data) }
            catch { fail(error) }
        }
    }

    private func receive(_ data: Data, token: UUID) {
        guard processID == token else { return }
        buffer.append(data)
        guard buffer.count <= 65_536 else { fail(DeskError.invalid("静音恢复子进程回复过大")); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            do {
                let reply = try JSONDecoder().decode(SessionAudioReply.self, from: line)
                isMuted = reply.muted
                if let id = reply.id, let request = pending.removeValue(forKey: id) {
                    request.timeout.cancel()
                    if let error = reply.error { request.continuation.resume(throwing: DeskError.invalid(error)) }
                    else { request.continuation.resume(returning: reply) }
                } else if reply.id == nil { onChange?(reply.muted, reply.error) }
            } catch { fail(error); return }
        }
    }

    private func finishReading(_ token: UUID) {
        guard processID == token else { return }
        outputHasEnded = true
        finishExitIfReady()
    }

    private func fail(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.timeout.cancel(); request.continuation.resume(throwing: error) }
        closing = true
        try? input?.close(); input = nil
        stopProcess()
    }

    private func stopProcess() {
        guard let process, process.isRunning else { return }
        let token = processID
        process.terminate()
        Task { [weak self, weak process] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let process, self.processID == token, self.process === process,
                  process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private func finishExitIfReady() {
        guard processHasExited, outputHasEnded, process != nil else { return }
        let token = processID
        try? output?.close(); try? input?.close()
        output = nil; input = nil; process = nil
        restoreTask = nil
        let expected = closing
        closing = false
        var message: String?
        if !snapshots.isEmpty {
            var recovery = SessionMuteTransaction(recovering: snapshots)
            do { try recovery.restore(using: CoreAudioMuteDeviceIO()); isMuted = false; snapshots.removeAll() }
            catch { isMuted = recovery.isMuted; message = "会话静音恢复失败：\(error.localizedDescription)" }
        } else { isMuted = false }
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: DeskError.invalid("静音恢复子进程已结束"))
        }
        if !expected, message == nil { message = "静音恢复子进程已结束，会话静音已取消" }
        onChange?(isMuted, message)
        exitBarrier.finish(token, error: message)
    }
}

private struct CoreAudioMuteDeviceIO: SessionMuteDeviceIO {
    func currentOutputDeviceUIDs() throws -> [String] {
        try [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice].compactMap { selector in
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device), "读取默认音频输出失败")
            guard device != kAudioObjectUnknown else { return nil }
            address.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "读取音频设备标识失败")
            guard let uid else { throw DeskError.invalid("音频设备没有稳定标识") }
            return uid.takeRetainedValue() as String
        }
    }

    func muteValue(for deviceUID: String) throws -> Bool {
        let device = try deviceID(for: deviceUID)
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { throw DeskError.invalid("当前音频输出设备没有系统静音属性") }
        var muted: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted), "读取音频静音状态失败")
        return muted != 0
    }

    func canSetMute(for deviceUID: String) throws -> Bool {
        let device = try deviceID(for: deviceUID)
        var address = muteAddress, settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address) else { return false }
        try check(AudioObjectIsPropertySettable(device, &address, &settable), "检查音频静音能力失败")
        return settable.boolValue
    }

    func setMuted(_ muted: Bool, for deviceUID: String) throws {
        let device = try deviceID(for: deviceUID)
        var address = muteAddress, value: UInt32 = muted ? 1 : 0
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), "修改音频静音失败")
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func deviceID(for uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let uidValue = uid as CFString
        var qualifier = Unmanaged.passUnretained(uidValue).toOpaque()
        var result = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withExtendedLifetime(uidValue) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &qualifier, &size, &result)
        }
        try check(status, "查找音频输出设备失败")
        guard result != kAudioObjectUnknown else { throw DeskError.invalid("原音频输出设备暂时不可用，无法恢复静音") }
        return result
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw DeskError.system(message, status) }
    }
}

private final class SessionAudioWatchdog {
    private let io = CoreAudioMuteDeviceIO()
    private let queue = DispatchQueue(label: "quietdesk.session-audio-watchdog")
    private var transaction: SessionMuteTransaction?
    private let outputLock = NSLock()
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var listenedSelectors: [AudioObjectPropertySelector] = []

    func run() {
        _ = fcntl(FileHandle.standardOutput.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer {
            for _ in 0..<3 {
                do { try queue.sync { try transaction?.restore(using: io) }; break }
                catch { Thread.sleep(forTimeInterval: 0.1) }
            }
            removeListeners()
        }
        while let line = readLine(strippingNewline: true) {
            guard line.utf8.count <= 4096, let data = line.data(using: .utf8),
                  let request = try? JSONDecoder().decode(SessionAudioRequest.self, from: data) else { return }
            let reply = queue.sync { () -> SessionAudioReply in
                var error: String?
                do {
                    switch request.command {
                    case .prepare:
                        guard transaction?.isMuted != true else { throw DeskError.invalid("上一项会话静音尚未恢复") }
                        transaction = try SessionMuteTransaction.prepare(using: io)
                        try installListeners()
                    case .mute:
                        guard transaction != nil else { throw DeskError.invalid("会话静音尚未准备") }
                        try transaction?.mute(using: io)
                    case .restore: try transaction?.restore(using: io)
                    }
                } catch let failure { error = failure.localizedDescription }
                return SessionAudioReply(id: request.id, muted: transaction?.isMuted ?? false,
                    snapshots: transaction?.snapshots ?? [], error: error)
            }
            send(reply)
            if request.command == .restore { return }
        }
    }

    private func installListeners() throws {
        guard routeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.transaction?.isMuted == true else { return }
            var message = "音频输出设备已变化，会话静音已取消"
            do { try self.transaction?.restore(using: self.io) }
            catch { message += "；恢复失败：\(error.localizedDescription)" }
            self.send(SessionAudioReply(id: nil, muted: self.transaction?.isMuted ?? false,
                snapshots: self.transaction?.snapshots ?? [], error: message))
        }
        routeListener = listener
        do {
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
                guard status == noErr else { throw DeskError.system("监听音频输出设备变化失败", status) }
                listenedSelectors.append(selector)
            }
        } catch { removeListeners(); throw error }
    }

    private func removeListeners() {
        guard let routeListener else { return }
        for selector in listenedSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, routeListener)
        }
        listenedSelectors.removeAll()
        self.routeListener = nil
    }

    private func send(_ reply: SessionAudioReply) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(10)
        outputLock.lock(); defer { outputLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
