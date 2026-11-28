import AppKit
import SwiftUI
import Security
import Combine
import QuietDeskCore

struct UpdateSessionContext: Equatable {
    var mainWindowVisible = false
    var applicationActive = false
    var isControlling = false
    var isFullScreen = false
    var hasHostConnection = false
    var isSharing = false
    var isHostDesktopSharing = false
    var isMappingHosting = false
    var hasActiveConnection = false
    var autoStartSharing = false
    var hasOtherPrompt = false
    var hostConnectionID: UUID? = nil
    var isHostQualityProbeSession = false
    var isHostConnectionPreparing = false
}

protocol UpdateInstalling: Sendable {
    func consumeResult() -> UpdateInstaller.InstallationResult?
    func downloadAndStage(expectation: UpdateInstaller.Expectation,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void,
                          onVerifying: @escaping @Sendable () -> Void) async throws -> UpdateInstaller.PreparedUpdate
    func installationAvailability() -> String?
    func launchInstaller(for prepared: UpdateInstaller.PreparedUpdate) async throws
    func launchInstaller(for prepared: UpdateInstaller.PreparedUpdate, options: UpdateInstaller.LaunchOptions) async throws
    func abortPendingInstallation()
    func discard(_ prepared: UpdateInstaller.PreparedUpdate)
    func cancel()
}

extension UpdateInstalling {
    func launchInstaller(for prepared: UpdateInstaller.PreparedUpdate, options: UpdateInstaller.LaunchOptions) async throws {
        try await launchInstaller(for: prepared)
    }
}

extension UpdateInstaller: UpdateInstalling {}

@MainActor
final class UpdateController: ObservableObject {
    enum State { case idle, checking, upToDate, available, failed, downloading, verifying, ready, installing }
    @Published private(set) var state: State = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published private(set) var message = ""
    @Published private(set) var bannerDismissed = false
    @Published private(set) var autoCheckPreference: Bool?
    @Published private(set) var autoInstallPreference = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var needsManualInstall = false
    @Published private(set) var manualReleaseURL: URL?
    @Published private(set) var completionNotice: String?
    @Published private(set) var requiredSystemVersion: String?

    let currentVersion: String
    let currentBuild: Int
    let enabled: Bool
    let usesAdHocSignature: Bool
    var onRestoreLaunchOptions: ((UpdateInstaller.LaunchOptions) -> Void)?
    var preferredHostScreen: (@MainActor () -> NSScreen?)?
    var onPrepareHostUpdateRestart: (@MainActor (String) async -> Void)?
    private let feedURL: URL?
    private let publicKeys: [UpdatePublicKey]
    private let bundleIdentifier: String
    private let repository: String
    private let defaults: UserDefaults
    private let sessionContext: () -> UpdateSessionContext
    private let mainWindow: () -> NSWindow?
    private let releaseControl: () -> Void
    private let terminateApplication: @MainActor () -> Void
    private let loadFeed: @Sendable (URL, String) async throws -> Data
    private let clock: () -> Date
    private let launchedAt: Date
    private let postSessionCooldown: TimeInterval
    @Published private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var scheduler: Task<Void, Never>?
    private var panel: NSWindow?
    private var consentAlert: NSAlert?
    private var contextSubscription: AnyCancellable?
    private var lastObservedSession: UpdateSessionContext
    private var wasRemoteControlActive: Bool
    private var lastRemoteSessionEndedAt: Date?
    private var lastFailedAutomaticCheckAt: Date?
    private var lastHandledHostConnectionID: UUID?
    private var lastHostConnectCheckAt: Date?
    private var promptedHostConnectionID: UUID?
    private var unidentifiedHostConnectionID: UUID?
    private var panelPresentedForHost = false
    private var deferredAutoInstallVersion: String?
    private var pendingImmediateInstallVersion: String?
    private var pendingHostDisconnectInstallVersion: String?
    private var pendingHostDisconnectInstallConnectionID: UUID?
    private var currentDownloadIsAutomatic = false
    private var pausedDownloadForRemoteSession = false
    private var autoDownloadFailures = 0
    private var autoDownloadRetryAfter: Date?
    private let installer: any UpdateInstalling
    private var prepared: UpdateInstaller.PreparedUpdate?
    private var started = false
    private var installationHandedOff = false
    private var preparingHostUpdateRestart = false
    var interfacePromptVisible = false {
        didSet { if interfacePromptVisible { dismissConsent() } }
    }

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], defaults: UserDefaults = .standard,
         launchedAt: Date = Date(), postSessionCooldown: TimeInterval = UpdateAutoInstallPolicy.postSessionCooldown,
         clock: @escaping () -> Date = Date.init,
         sessionContext: @escaping () -> UpdateSessionContext = { .init() },
         mainWindow: @escaping () -> NSWindow? = { nil }, releaseControl: @escaping () -> Void = {},
         contextChanges: AnyPublisher<Void, Never>? = nil,
         installer: any UpdateInstalling = UpdateInstaller(),
         terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
         loadFeed: @escaping @Sendable (URL, String) async throws -> Data = { try await UpdateFeedLoader.fetch($0, $1) }) {
        self.defaults = defaults
        self.launchedAt = launchedAt
        self.postSessionCooldown = postSessionCooldown
        self.clock = clock
        self.sessionContext = sessionContext
        self.mainWindow = mainWindow
        self.releaseControl = releaseControl
        self.terminateApplication = terminateApplication
        self.loadFeed = loadFeed
        self.installer = installer
        let initialSession = sessionContext()
        self.lastObservedSession = initialSession
        self.wasRemoteControlActive = UpdateAutoInstallPolicy.isRemoteControlActive(
            isControlling: initialSession.isControlling,
            isFullScreen: initialSession.isFullScreen,
            hasHostConnection: initialSession.hasHostConnection,
            hasActiveConnection: initialSession.hasActiveConnection
        )
        bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        currentVersion = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        currentBuild = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        let keysData = (info["QuietDeskUpdatePublicKeys"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        publicKeys = keysData.flatMap { try? JSONDecoder().decode([UpdatePublicKey].self, from: $0) } ?? []
        let candidate = (info["QuietDeskUpdateFeedURL"] as? String).flatMap(URL.init(string:))
        let parts = candidate?.path.split(separator: "/") ?? []
        let identifier = bundleIdentifier
        let safeURL = candidate.map { (try? UpdateURLPolicy.validateFeedURL($0, bundleIdentifier: identifier,
            allowLoopbackForTesting: true)) != nil } ?? false
        let github = safeURL && candidate?.host?.lowercased() == "github.com" && parts.count == 6
        feedURL = safeURL ? candidate : nil
        repository = github ? "\(parts[0])/\(parts[1])" : "nXiaoK/QuietDesk"
        enabled = feedURL != nil && !publicKeys.isEmpty && !bundleIdentifier.isEmpty
        let storedAutoCheck = defaults.object(forKey: "autoCheckUpdates") as? Bool
        let storedAutoInstall = (defaults.object(forKey: "autoInstallUpdates") as? Bool) ?? false
        autoCheckPreference = (storedAutoInstall && storedAutoCheck == nil) ? true : storedAutoCheck
        autoInstallPreference = storedAutoInstall
        lastCheckedAt = defaults.object(forKey: "lastUpdateCheck") as? Date
        lastFailedAutomaticCheckAt = defaults.object(forKey: "lastFailedUpdateCheck") as? Date
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signingInfo: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
           let flags = (signingInfo as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber {
            usesAdHocSignature = flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
        } else { usesAdHocSignature = false }
        contextSubscription = contextChanges?.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self else { return }
            let current = self.session
            if current != self.lastObservedSession {
                self.lastObservedSession = current
                let now = self.clock()
                let emitted = self.observeRemoteSessionTransition(current, now: now)
                if !self.handleIncomingHostConnectionIfNeeded(current, now: now), !emitted {
                    self.objectWillChange.send()
                }
            }
            if self.consentAlert != nil { self.tick() }
        }
    }

    var busy: Bool { operation != nil || state == .installing }
    var session: UpdateSessionContext { sessionContext() }
    var isRemoteControlActive: Bool {
        let context = session
        return UpdateAutoInstallPolicy.isRemoteControlActive(
            isControlling: context.isControlling,
            isFullScreen: context.isFullScreen,
            hasHostConnection: context.hasHostConnection,
            hasActiveConnection: context.hasActiveConnection
        )
    }
    var menuTitle: String {
        if let update = manifest {
            switch state {
            case .downloading: return "正在下载更新 \(update.version)…"
            case .verifying: return "正在校验更新 \(update.version)…"
            case .installing: return "正在安装更新 \(update.version)…"
            case .ready: return "更新 \(update.version) 已就绪…"
            default: return "新版本 \(update.version) 可用…"
            }
        }
        return manualReleaseURL != nil ? "新版本需要手动更新…" : "检查更新…"
    }
    var showBanner: Bool {
        let context = session
        return !bannerDismissed && (manifest != nil || manualReleaseURL != nil || completionNotice != nil)
            && !context.isControlling && !context.isFullScreen
            && !context.isSharing && !context.hasActiveConnection
    }
    var installBlocked: Bool { session.hasHostConnection }
    var autoInstallBlockReason: UpdateAutoInstallBlockReason? {
        guard manifest != nil, state == .available || state == .ready else { return nil }
        switch currentAutoInstallDecision(now: clock(), context: session) {
        case .proceed: return nil
        case .blocked(let reason): return reason
        }
    }
    var autoInstallDeferredBySession: Bool {
        autoInstallBlockReason?.isRemoteOrTransientSessionDeferral == true
    }
    var bannerTitle: String {
        if let completionNotice { return completionNotice }
        if autoInstallDeferredBySession, let version = manifest?.version {
            return state == .ready ? "新版本 \(version) 已就绪（将在空闲时自动安装）" : "新版本 \(version) 可用（将在空闲时自动更新）"
        }
        return menuTitle.replacingOccurrences(of: "…", with: "")
    }

    func start() {
        if !started {
            started = true
            if let result = installer.consumeResult() {
                completionNotice = result.message
                message = result.message
                state = result.succeeded ? .upToDate : .failed
                if !result.succeeded {
                    needsManualInstall = true
                    manualReleaseURL = URL(string: "https://github.com/\(repository)/releases/latest")
                }
                DiagnosticLog.shared.record(.updateInstall, state: result.succeeded ? .succeeded : .failed)
                if result.succeeded, let launchOptions = result.launchOptions {
                    onRestoreLaunchOptions?(launchOptions)
                }
            }
        }
        guard enabled, scheduler == nil else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func tick(now: Date? = nil) {
        let currentNow = now ?? clock()
        let context = session
        _ = observeRemoteSessionTransition(context, now: currentNow)
        _ = handleIncomingHostConnectionIfNeeded(context, now: currentNow)
        let window = mainWindow()
        let consentWindow = consentAlert?.window
        let otherPrompt = hasBlockingInterfacePrompt(context: context, window: window, consentWindow: consentWindow, includeUpdatePanel: true)
        let canPresentConsent = UpdateCheckPolicy.shouldPresentConsent(
            updaterEnabled: enabled, autoCheckPreference: autoCheckPreference,
            mainWindowVisible: context.mainWindowVisible, applicationActive: context.applicationActive,
            isControlling: context.isControlling, isFullScreen: context.isFullScreen,
            hasHostConnection: context.hasHostConnection, hasOtherPrompt: otherPrompt
        )
        if !canPresentConsent { dismissConsent() }
        if canPresentConsent, consentAlert == nil, let window {
            let alert = NSAlert()
            alert.messageText = "自动检查并更新？"
            alert.informativeText = "QuietDesk 每天访问 GitHub 检查签名版本信息。远控连入时也会检查，连入触发的检查至少间隔 60 秒。开启自动更新后，仅在未处于远程控制或活动连接时自动下载并安装。随时可在偏好设置或菜单栏修改。"
            alert.addButton(withTitle: "自动检查")
            alert.addButton(withTitle: "不检查")
            alert.addButton(withTitle: "开启自动更新")
            consentAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.consentAlert === alert else { return }
                self.consentAlert = nil
                if response == .alertFirstButtonReturn { self.setAutomaticChecks(true) }
                else if response == .alertSecondButtonReturn { self.setAutomaticChecks(false) }
                else if response == .alertThirdButtonReturn { self.setAutomaticInstall(true) }
            }
        }
        let canCheckOnSchedule = !context.hasHostConnection
            || (!context.isHostConnectionPreparing && !context.isHostQualityProbeSession && !hasOfferForRemoteHost
                && UpdateCheckPolicy.shouldCheckOnHostSessionConnect(
                    updaterEnabled: enabled, autoCheckPreference: autoCheckPreference, isBenchmarkProbe: false,
                    now: currentNow, lastHostConnectCheck: lastHostConnectCheckAt
                ))
        if canCheckOnSchedule && UpdateCheckPolicy.shouldAutomaticallyCheck(
            updaterEnabled: enabled, autoCheckPreference: autoCheckPreference,
            now: currentNow, launchedAt: launchedAt,
            lastCheck: defaults.object(forKey: "lastUpdateCheck") as? Date,
            lastFailedCheck: lastFailedAutomaticCheckAt
        ) {
            check(manual: false, now: currentNow)
        } else {
            evaluateAutomaticProgress(now: currentNow, context: context)
        }
    }

    func setAutomaticChecks(_ value: Bool) {
        dismissConsent()
        autoCheckPreference = value
        defaults.set(value, forKey: "autoCheckUpdates")
        DiagnosticLog.shared.record(.updatePreferenceChanged, state: value ? .enabled : .disabled)
        if !value && autoInstallPreference {
            autoInstallPreference = false
            defaults.set(false, forKey: "autoInstallUpdates")
            DiagnosticLog.shared.record(.autoUpdatePreferenceChanged, state: .disabled)
        }
    }

    func setAutomaticInstall(_ value: Bool, checkImmediatelyIfIdle: Bool = true) {
        dismissConsent()
        if value && autoCheckPreference != true {
            autoCheckPreference = true
            defaults.set(true, forKey: "autoCheckUpdates")
            DiagnosticLog.shared.record(.updatePreferenceChanged, state: .enabled)
        }
        autoInstallPreference = value
        defaults.set(value, forKey: "autoInstallUpdates")
        DiagnosticLog.shared.record(.autoUpdatePreferenceChanged, state: value ? .enabled : .disabled)
        deferredAutoInstallVersion = nil
        autoDownloadFailures = 0
        autoDownloadRetryAfter = nil
        guard value else { return }
        let currentNow = clock()
        let context = session
        _ = observeRemoteSessionTransition(context, now: currentNow)
        if manifest != nil {
            evaluateAutomaticProgress(now: currentNow, context: context)
        } else if checkImmediatelyIfIdle, enabled, !busy, state != .ready, !isRemoteControlActive {
            let lastCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
            if lastCheck == nil || currentNow.timeIntervalSince(lastCheck!) >= UpdateCheckPolicy.failureRetryInterval {
                check(manual: false, now: currentNow)
            }
        }
    }

    func check(manual: Bool = true, presentWindow: Bool? = nil, now: Date? = nil) {
        check(manual: manual, presentWindow: presentWindow, now: now, offeringToHost: nil)
    }

    private func check(manual: Bool, presentWindow: Bool?, now: Date?, offeringToHost hostID: UUID?) {
        let checkTime = now ?? clock()
        guard enabled, let feedURL else { return }
        if presentWindow ?? manual { present() }
        guard !busy, state != .ready else { return }
        if manual {
            deferredAutoInstallVersion = nil
            autoDownloadFailures = 0
            autoDownloadRetryAfter = nil
        }
        let id = UUID(); operationID = id
        state = .checking; message = "正在检查更新…"; completionNotice = nil
        DiagnosticLog.shared.record(.updateCheck, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            var shouldEvaluateAutoProgress = false
            defer {
                if self.operationID == id { self.operation = nil }
                if shouldEvaluateAutoProgress {
                    self.evaluateAutomaticProgress(now: now ?? self.clock())
                }
            }
            do {
                let data = try await self.loadFeed(feedURL, self.currentVersion)
                try Task.checkCancellation()
                if !manual {
                    self.defaults.set(checkTime, forKey: "lastUpdateCheck")
                    self.lastCheckedAt = checkTime
                    self.lastFailedAutomaticCheckAt = nil
                    self.defaults.removeObject(forKey: "lastFailedUpdateCheck")
                }
                let result = try UpdateManifestVerifier.verify(data, publicKeys: self.publicKeys,
                    bundleIdentifier: self.bundleIdentifier, allowLoopbackForTesting: self.bundleIdentifier != "local.quietdesk.app",
                    repository: self.repository)
                switch result {
                case .requiresManualUpdate(_, let url):
                    self.manifest = nil; self.manualReleaseURL = url; self.needsManualInstall = true
                    self.requiredSystemVersion = nil; self.bannerDismissed = false
                    self.state = .available; self.message = "此版本需要手动更新，请前往 GitHub 下载。"
                case .supported(let update):
                    let system = ProcessInfo.processInfo.operatingSystemVersion
                    let assessment = try update.assess(currentVersion: self.currentVersion, currentBuild: self.currentBuild,
                        systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
                    if self.manifest?.version != update.version {
                        self.autoDownloadFailures = 0
                        self.autoDownloadRetryAfter = nil
                    }
                    self.needsManualInstall = false; self.manualReleaseURL = nil; self.requiredSystemVersion = nil
                    if assessment != .inconsistentBuild && !UpdateCheckPolicy.shouldOffer(version: update.version,
                        skippedVersion: self.defaults.string(forKey: "skippedUpdateVersion"), manual: manual) {
                        self.manifest = nil; self.state = .idle; self.message = ""
                        DiagnosticLog.shared.record(.updateCheck, state: .succeeded)
                        return
                    }
                    switch assessment {
                    case .available:
                        self.manifest = update; self.state = .available; self.bannerDismissed = false
                        self.message = "新版本 \(update.version) 可用"
                        if let hostID { self.presentForRemoteHostSession(hostID) }
                        shouldEvaluateAutoProgress = self.autoInstallPreference
                    case .requiresNewerSystem(let required):
                        self.manifest = update; self.state = .available; self.bannerDismissed = false
                        self.requiredSystemVersion = required
                        self.message = "新版本需要 macOS \(required)，请先升级系统。"
                    case .upToDate:
                        self.manifest = nil; self.state = .upToDate; self.message = "已是最新版本。"
                    case .inconsistentBuild:
                        throw UpdateFeedError.inconsistentBuild
                    }
                }
                DiagnosticLog.shared.record(.updateCheck, state: .succeeded)
            } catch {
                if !manual {
                    self.lastFailedAutomaticCheckAt = checkTime
                    self.defaults.set(checkTime, forKey: "lastFailedUpdateCheck")
                }
                guard !Task.isCancelled else { return }
                self.state = .failed
                self.message = (error as? UpdateFeedError)?.localizedDescription
                    ?? ((error as NSError).domain == NSURLErrorDomain ? "无法连接更新服务器，请检查网络后重试。" : "更新信息校验失败，请稍后重试或在 GitHub 手动下载。")
                DiagnosticLog.shared.record(.updateCheck, state: .failed, error: error)
            }
        }
    }

    func present() {
        panelPresentedForHost = false
        present(on: nil, forRemoteHost: false)
    }

    private func present(on screen: NSScreen?, forRemoteHost: Bool) {
        guard enabled || completionNotice != nil else { return }
        dismissConsent()
        releaseControl()
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "QuietDesk 更新"
            window.contentMinSize = NSSize(width: 520, height: 440)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateView(controller: self))
            window.center()
            panel = window
        }
        if forRemoteHost, let window = panel {
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            if let screen {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func later() {
        if let version = manifest?.version {
            deferredAutoInstallVersion = version
        }
        pendingImmediateInstallVersion = nil
        clearPendingHostDisconnectInstall()
        panelPresentedForHost = false
        panel?.close()
        bannerDismissed = true
    }
    func dismissBanner() { bannerDismissed = true }
    func skip() {
        guard !busy, prepared == nil, let update = manifest else { return }
        defaults.set(update.version, forKey: "skippedUpdateVersion")
        deferredAutoInstallVersion = nil
        pendingImmediateInstallVersion = nil
        clearPendingHostDisconnectInstall()
        panelPresentedForHost = false
        manifest = nil; manualReleaseURL = nil; needsManualInstall = false; requiredSystemVersion = nil; state = .idle
        panel?.close(); bannerDismissed = true
    }
    func openRelease() {
        if let url = manualReleaseURL ?? manifest?.releaseNotesURL { NSWorkspace.shared.open(url) }
    }

    func downloadAndInstall() {
        guard let update = manifest else { return }
        deferredAutoInstallVersion = nil
        clearPendingHostDisconnectInstall()
        pendingImmediateInstallVersion = update.version
        if state == .ready {
            install(automatic: false)
        } else {
            download(automatic: false)
        }
    }

    func downloadAndInstallDisconnectingHost() {
        guard let update = manifest, !busy, !needsManualInstall, requiredSystemVersion == nil else { return }
        deferredAutoInstallVersion = nil
        pendingHostDisconnectInstallVersion = update.version
        pendingHostDisconnectInstallConnectionID = session.hostConnectionID
        pendingImmediateInstallVersion = nil
        if state == .ready { installDisconnectingHost() }
        else { download(automatic: false) }
    }

    func download(automatic: Bool = false, now: Date? = nil) {
        guard let update = manifest, !busy, state != .ready, !needsManualInstall, requiredSystemVersion == nil else { return }
        if !automatic {
            deferredAutoInstallVersion = nil
            autoDownloadFailures = 0
            autoDownloadRetryAfter = nil
        }
        let id = UUID(); operationID = id
        currentDownloadIsAutomatic = automatic
        pausedDownloadForRemoteSession = false
        state = .downloading; receivedBytes = 0; totalBytes = nil
        message = automatic ? "正在后台下载更新 \(update.version)…" : "正在下载更新…"
        let expected = UpdateInstaller.Expectation(bundleIdentifier: update.bundleIdentifier, version: update.version,
            build: update.build, minimumSystemVersion: update.minimumSystemVersion, archiveURL: update.archive.url,
            archiveSize: update.archive.size, sha256: update.archive.sha256, repository: repository)
        DiagnosticLog.shared.record(.updateDownload, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            var triggerInstallAfterReady = false
            var triggerHostInstallAfterReady = false
            var triggerAutoEvaluate = false
            defer {
                if self.operationID == id {
                    self.operation = nil
                    self.currentDownloadIsAutomatic = false
                }
                if triggerHostInstallAfterReady {
                    self.installDisconnectingHost(confirmedConnectionID: self.pendingHostDisconnectInstallConnectionID, now: now)
                } else if triggerInstallAfterReady {
                    self.install(automatic: false, now: now)
                } else if triggerAutoEvaluate {
                    self.evaluateAutomaticProgress(now: now ?? self.clock())
                }
            }
            do {
                let staged = try await self.installer.downloadAndStage(expectation: expected, progress: { [weak self] received, total in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.state == .downloading else { return }
                        self.receivedBytes = received; self.totalBytes = total
                    }
                }, onVerifying: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.state == .downloading else { return }
                        self.state = .verifying; self.message = "正在校验并暂存更新…"
                    }
                })
                guard !Task.isCancelled, self.operationID == id else { self.installer.discard(staged); return }
                self.prepared = staged; self.state = .ready
                self.autoDownloadFailures = 0
                self.autoDownloadRetryAfter = nil
                self.needsManualInstall = staged.manualInstallationReason != nil
                self.message = staged.manualInstallationReason ?? "更新已通过校验，可以安装并重新启动。"
                DiagnosticLog.shared.record(.updateDownload, state: .succeeded)
                if !self.needsManualInstall {
                    if self.pendingHostDisconnectInstallVersion == update.version {
                        triggerHostInstallAfterReady = true
                    } else if self.pendingImmediateInstallVersion == update.version {
                        self.pendingImmediateInstallVersion = nil
                        if !self.installBlocked {
                            triggerInstallAfterReady = true
                        }
                    } else if self.autoInstallPreference {
                        triggerAutoEvaluate = true
                    }
                } else {
                    self.pendingImmediateInstallVersion = nil
                    self.clearPendingHostDisconnectInstall()
                }
            } catch {
                guard !Task.isCancelled, self.operationID == id else { return }
                self.pendingImmediateInstallVersion = nil
                self.clearPendingHostDisconnectInstall()
                self.state = .failed
                if automatic, (error as NSError).domain == NSURLErrorDomain {
                    self.autoDownloadFailures += 1
                    self.autoDownloadRetryAfter = (now ?? self.clock()).addingTimeInterval(
                        UpdateAutoInstallPolicy.downloadRetryDelay(attempt: self.autoDownloadFailures)
                    )
                } else {
                    self.autoDownloadRetryAfter = nil
                }
                self.message = (error as? UpdateInstaller.Failure)?.localizedDescription ?? "更新下载失败，请检查网络后重试。"
                DiagnosticLog.shared.record(.updateDownload, state: .failed, error: error)
            }
        }
    }

    func install(automatic: Bool = false, now: Date? = nil) {
        performInstall(automatic: automatic, allowHostDisconnect: false, now: now)
    }

    func installDisconnectingHost(now: Date? = nil) {
        installDisconnectingHost(confirmedConnectionID: session.hostConnectionID, now: now)
    }

    private func installDisconnectingHost(confirmedConnectionID: UUID?, now: Date?) {
        clearPendingHostDisconnectInstall()
        performInstall(automatic: false, allowHostDisconnect: true, confirmedConnectionID: confirmedConnectionID, now: now)
    }

    private func clearPendingHostDisconnectInstall() {
        pendingHostDisconnectInstallVersion = nil
        pendingHostDisconnectInstallConnectionID = nil
    }

    private func hasOriginalHostConfirmation(_ connectionID: UUID?) -> Bool {
        guard let connectionID else { return true }
        let context = session
        return !context.hasHostConnection || context.hostConnectionID == connectionID
    }

    private func performInstall(automatic: Bool, allowHostDisconnect: Bool, confirmedConnectionID: UUID? = nil, now: Date?) {
        guard state == .ready, let prepared, !busy, !needsManualInstall else { return }
        let confirmationExpired = "远控会话已更换，请重新确认断开并更新。"
        if automatic {
            switch currentAutoInstallDecision(now: now ?? clock()) {
            case .proceed:
                break
            case .blocked(let reason):
                if let note = UpdateAutoInstallPolicy.deferralMessage(for: reason, version: manifest?.version, readyToInstall: true) {
                    message = note
                }
                return
            }
        } else if allowHostDisconnect {
            guard hasOriginalHostConfirmation(confirmedConnectionID) else { message = confirmationExpired; return }
        } else {
            guard !installBlocked else { message = "这台 Mac 正被远程控制，请先停止共享后安装。"; return }
        }
        if let reason = installer.installationAvailability() { needsManualInstall = true; message = reason; return }
        let preInstallContext = session
        let launchOptions = UpdateInstaller.LaunchOptions(
            automatic: automatic,
            openInBackground: automatic && (!preInstallContext.applicationActive || !preInstallContext.mainWindowVisible),
            minimizeWindowOnLaunch: automatic && !preInstallContext.mainWindowVisible,
            resumeHostSharing: allowHostDisconnect || preInstallContext.isHostDesktopSharing || preInstallContext.isSharing,
            resumeMappingHosting: preInstallContext.isMappingHosting
        )
        let id = UUID(); operationID = id
        state = .installing
        message = automatic ? "正在自动安装更新，QuietDesk 即将重新启动…" : "正在准备安装，QuietDesk 即将重新启动…"
        DiagnosticLog.shared.record(.updateInstall, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.operation = nil } }
            do {
                try await self.installer.launchInstaller(for: prepared, options: launchOptions)
                guard !Task.isCancelled, self.operationID == id else {
                    self.installer.abortPendingInstallation()
                    return
                }
                if automatic {
                    if case .blocked(let reason) = self.currentAutoInstallDecision(now: now ?? self.clock()) {
                        self.installer.abortPendingInstallation()
                        self.state = .ready
                        self.message = UpdateAutoInstallPolicy.deferralMessage(for: reason, version: self.manifest?.version, readyToInstall: true)
                            ?? "检测到远程连接，自动安装已推迟，将在空闲后继续。"
                        return
                    }
                } else if allowHostDisconnect {
                    guard self.hasOriginalHostConfirmation(confirmedConnectionID) else {
                        self.installer.abortPendingInstallation()
                        self.state = .ready; self.message = confirmationExpired
                        return
                    }
                } else {
                    guard !self.installBlocked else {
                        self.installer.abortPendingInstallation()
                        self.state = .ready; self.message = "安装已暂停；请停止共享后重试。"
                        return
                    }
                }
                self.dismissConsent()
                if let sheet = self.panel?.attachedSheet { self.panel?.endSheet(sheet, returnCode: .abort) }
                self.panel?.close()
                if allowHostDisconnect {
                    // The ready installer now depends on a normal application exit.
                    self.preparingHostUpdateRestart = true
                    await self.onPrepareHostUpdateRestart?(prepared.expectation.version)
                }
                self.installationHandedOff = true
                self.terminateApplication()
            } catch {
                guard !Task.isCancelled, self.operationID == id else { return }
                self.state = .ready; self.needsManualInstall = true
                self.message = (error as? UpdateInstaller.Failure)?.localizedDescription ?? "无法启动安装进程，请手动安装。"
                DiagnosticLog.shared.record(.updateInstall, state: .failed, error: error)
            }
        }
    }

    func revealPreparedApplication() {
        if let prepared { NSWorkspace.shared.activateFileViewerSelecting([prepared.applicationURL]) }
    }

    func cancel() {
        guard !installationHandedOff, !preparingHostUpdateRestart, operation != nil || prepared != nil else { return }
        if let version = manifest?.version {
            deferredAutoInstallVersion = version
        }
        pendingImmediateInstallVersion = nil
        clearPendingHostDisconnectInstall()
        pausedDownloadForRemoteSession = false
        operation?.cancel()
        installer.cancel(); installer.abortPendingInstallation()
        if let prepared { installer.discard(prepared); self.prepared = nil }
        needsManualInstall = manualReleaseURL != nil && requiredSystemVersion == nil
        state = manifest == nil && manualReleaseURL == nil ? .idle : .available
        message = "更新已取消，可以稍后重试。"
        DiagnosticLog.shared.record(.updateCancelled, state: .cancelled)
    }

    func shutdown() {
        scheduler?.cancel(); scheduler = nil
        dismissConsent()
        dismissRemoteHostOffer()
        if !installationHandedOff { cancel() }
    }

    private func evaluateAutomaticProgress(now: Date, context: UpdateSessionContext? = nil) {
        guard enabled, autoInstallPreference, !busy else { return }
        let currentContext = context ?? session
        _ = observeRemoteSessionTransition(currentContext, now: now)
        let canRetryFailedDownload: Bool = {
            guard state == .failed, manifest != nil, let retryAt = autoDownloadRetryAfter else { return false }
            return now >= retryAt
        }()
        guard state == .ready || (state == .available && manifest != nil) || canRetryFailedDownload else { return }

        switch currentAutoInstallDecision(now: now, context: currentContext) {
        case .proceed:
            if state == .ready {
                if panel?.isVisible == true {
                    message = "更新已通过校验，点击“安装并重新启动”或关闭窗口后将自动安装。"
                } else {
                    install(automatic: true, now: now)
                }
            } else {
                download(automatic: true, now: now)
            }
        case .blocked(let reason):
            if state == .available || state == .ready,
               let note = UpdateAutoInstallPolicy.deferralMessage(for: reason, version: manifest?.version, readyToInstall: state == .ready),
               message != note {
                message = note
            }
        }
    }

    private func currentAutoInstallDecision(now: Date, context: UpdateSessionContext? = nil) -> UpdateAutoInstallDecision {
        let currentContext = context ?? session
        let blockingPrompt = hasBlockingInterfacePrompt(
            context: currentContext,
            window: mainWindow(),
            consentWindow: consentAlert?.window,
            includeUpdatePanel: false
        )
        return UpdateAutoInstallPolicy.evaluate(
            updaterEnabled: enabled,
            autoInstallEnabled: autoInstallPreference,
            isControlling: currentContext.isControlling,
            isFullScreen: currentContext.isFullScreen,
            hasHostConnection: currentContext.hasHostConnection,
            hasActiveConnection: currentContext.hasActiveConnection,
            hasBlockingPrompt: blockingPrompt,
            needsManualInstall: needsManualInstall,
            requiresNewerSystem: requiredSystemVersion != nil,
            deferredByUser: manifest != nil && deferredAutoInstallVersion == manifest?.version,
            now: now,
            lastRemoteSessionEndedAt: lastRemoteSessionEndedAt,
            cooldown: postSessionCooldown
        )
    }

    private func hasBlockingInterfacePrompt(context: UpdateSessionContext, window: NSWindow?, consentWindow: NSWindow?, includeUpdatePanel: Bool) -> Bool {
        context.hasOtherPrompt || interfacePromptVisible
            || (includeUpdatePanel && panel?.isVisible == true)
            || (panel?.attachedSheet != nil)
            || (window?.attachedSheet != nil && window?.attachedSheet !== consentWindow)
            || (NSApp.modalWindow != nil && NSApp.modalWindow !== consentWindow)
    }

    @discardableResult
    private func handleIncomingHostConnectionIfNeeded(_ context: UpdateSessionContext, now: Date) -> Bool {
        guard context.hasHostConnection else {
            lastHandledHostConnectionID = nil
            unidentifiedHostConnectionID = nil
            dismissRemoteHostOffer()
            return false
        }
        if context.isHostConnectionPreparing {
            if promptedHostConnectionID != context.hostConnectionID { dismissRemoteHostOffer() }
            return false
        }

        // Callers that do not carry the authenticated ID still get one check per connected interval.
        if context.hostConnectionID == nil, unidentifiedHostConnectionID == nil {
            unidentifiedHostConnectionID = UUID()
        }
        guard let id = context.hostConnectionID ?? unidentifiedHostConnectionID else { return false }
        if promptedHostConnectionID != id || context.isHostQualityProbeSession { dismissRemoteHostOffer() }
        if context.isHostQualityProbeSession {
            lastHandledHostConnectionID = id
            return false
        }
        guard enabled, autoCheckPreference == true, lastHandledHostConnectionID != id, !busy else { return false }
        lastHandledHostConnectionID = id
        if hasOfferForRemoteHost {
            presentForRemoteHostSession(id)
            return false
        }
        guard state != .ready, UpdateCheckPolicy.shouldCheckOnHostSessionConnect(
            updaterEnabled: enabled, autoCheckPreference: autoCheckPreference,
            isBenchmarkProbe: context.isHostQualityProbeSession, now: now, lastHostConnectCheck: lastHostConnectCheckAt
        ) else { return false }
        lastHostConnectCheckAt = now
        check(manual: false, presentWindow: false, now: now, offeringToHost: id)
        return true
    }

    private var hasOfferForRemoteHost: Bool {
        guard state == .available || state == .ready, let update = manifest, requiredSystemVersion == nil else { return false }
        return UpdateCheckPolicy.shouldOffer(version: update.version,
            skippedVersion: defaults.string(forKey: "skippedUpdateVersion"), manual: false)
    }

    private func presentForRemoteHostSession(_ id: UUID) {
        let context = session
        guard enabled, autoCheckPreference == true, context.hasHostConnection,
              !context.isHostConnectionPreparing, !context.isHostQualityProbeSession,
              id == (context.hostConnectionID ?? unidentifiedHostConnectionID),
              id != promptedHostConnectionID, hasOfferForRemoteHost else { return }
        promptedHostConnectionID = id
        if panel?.isVisible != true { panelPresentedForHost = true }
        present(on: preferredHostScreen?() ?? NSScreen.main, forRemoteHost: true)
    }

    private func dismissRemoteHostOffer() {
        promptedHostConnectionID = nil
        guard panelPresentedForHost else { return }
        panelPresentedForHost = false
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .abort) }
        panel?.close()
    }

    @discardableResult
    private func observeRemoteSessionTransition(_ context: UpdateSessionContext, now: Date) -> Bool {
        let activeNow = UpdateAutoInstallPolicy.isRemoteControlActive(
            isControlling: context.isControlling,
            isFullScreen: context.isFullScreen,
            hasHostConnection: context.hasHostConnection,
            hasActiveConnection: context.hasActiveConnection
        )
        if wasRemoteControlActive && !activeNow {
            lastRemoteSessionEndedAt = now
        } else if activeNow {
            lastRemoteSessionEndedAt = nil
        }
        wasRemoteControlActive = activeNow
        if activeNow && currentDownloadIsAutomatic && state == .downloading && !pausedDownloadForRemoteSession {
            pausedDownloadForRemoteSession = true
            operation?.cancel()
            installer.cancel()
            state = .available
            message = "检测到远程连接，已暂停后台下载，将在会话结束后自动继续。"
            return true
        }
        return false
    }

    private func dismissConsent() {
        guard let alert = consentAlert else { return }
        consentAlert = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
    }
}

enum UpdateFeedError: LocalizedError {
    case noManifest, invalidResponse, oversized, insecureRedirect, inconsistentBuild
    var errorDescription: String? {
        switch self {
        case .noManifest: return "暂无更新信息，请稍后重试。"
        case .inconsistentBuild: return "更新版本与构建号不一致，请稍后重试。"
        default: return "更新信息无效或未通过校验，请稍后重试。"
        }
    }
}

private final class UpdateFeedLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowsLoopback: Bool
    init(allowsLoopback: Bool) { self.allowsLoopback = allowsLoopback }
    static func fetch(_ url: URL, _ version: String) async throws -> Data {
        let policy = UpdateFeedLoader(allowsLoopback: url.scheme == "http")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("QuietDesk/\(version)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        guard let response = response as? HTTPURLResponse else { throw UpdateFeedError.invalidResponse }
        if response.statusCode == 404 { throw UpdateFeedError.noManifest }
        guard response.statusCode == 200 else { throw UpdateFeedError.invalidResponse }
        guard response.expectedContentLength <= Int64(UpdateManifestVerifier.maximumEnvelopeBytes) else { throw UpdateFeedError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < UpdateManifestVerifier.maximumEnvelopeBytes else { throw UpdateFeedError.oversized }
            data.append(byte)
        }
        return data
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.user == nil, url.password == nil,
              url.scheme == "https" || (allowsLoopback && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
        else { completionHandler(nil); return }
        completionHandler(request)
    }
}
