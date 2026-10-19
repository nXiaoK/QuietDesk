import AppKit
import SwiftUI
import Security
import Combine
import QuietDeskCore

struct UpdateSessionContext {
    var mainWindowVisible = false
    var applicationActive = false
    var isControlling = false
    var isFullScreen = false
    var hasHostConnection = false
    var isSharing = false
    var hasActiveConnection = false
    var autoStartSharing = false
    var hasOtherPrompt = false
}

protocol UpdateInstalling: Sendable {
    func consumeResult() -> UpdateInstaller.InstallationResult?
    func downloadAndStage(expectation: UpdateInstaller.Expectation,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void,
                          onVerifying: @escaping @Sendable () -> Void) async throws -> UpdateInstaller.PreparedUpdate
    func installationAvailability() -> String?
    func launchInstaller(for prepared: UpdateInstaller.PreparedUpdate) async throws
    func abortPendingInstallation()
    func discard(_ prepared: UpdateInstaller.PreparedUpdate)
    func cancel()
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
    private let launchedAt: Date
    @Published private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var scheduler: Task<Void, Never>?
    private var panel: NSWindow?
    private var consentAlert: NSAlert?
    private var contextSubscription: AnyCancellable?
    private let installer: any UpdateInstalling
    private var prepared: UpdateInstaller.PreparedUpdate?
    private var started = false
    private var installationHandedOff = false
    var interfacePromptVisible = false {
        didSet { if interfacePromptVisible { dismissConsent() } }
    }

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:], defaults: UserDefaults = .standard,
         launchedAt: Date = Date(), sessionContext: @escaping () -> UpdateSessionContext = { .init() },
         mainWindow: @escaping () -> NSWindow? = { nil }, releaseControl: @escaping () -> Void = {},
         contextChanges: AnyPublisher<Void, Never>? = nil,
         installer: any UpdateInstalling = UpdateInstaller(),
         terminateApplication: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
         loadFeed: @escaping @Sendable (URL, String) async throws -> Data = { try await UpdateFeedLoader.fetch($0, $1) }) {
        self.defaults = defaults
        self.launchedAt = launchedAt
        self.sessionContext = sessionContext
        self.mainWindow = mainWindow
        self.releaseControl = releaseControl
        self.terminateApplication = terminateApplication
        self.loadFeed = loadFeed
        self.installer = installer
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
        autoCheckPreference = defaults.object(forKey: "autoCheckUpdates") as? Bool
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
            self.objectWillChange.send()
            if self.consentAlert != nil { self.tick() }
        }
    }

    var busy: Bool { operation != nil || state == .installing }
    var menuTitle: String { manifest.map { "新版本 \($0.version) 可用…" } ?? (manualReleaseURL != nil ? "新版本需要手动更新…" : "检查更新…") }
    var session: UpdateSessionContext { sessionContext() }
    var showBanner: Bool {
        let context = session
        return !bannerDismissed && (manifest != nil || manualReleaseURL != nil || completionNotice != nil) && !context.isControlling && !context.isFullScreen
            && !context.isSharing && !context.hasActiveConnection
    }
    var installBlocked: Bool { session.hasHostConnection }
    var bannerTitle: String { completionNotice ?? menuTitle.replacingOccurrences(of: "…", with: "") }

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

    func tick(now: Date = Date()) {
        let context = session
        let window = mainWindow()
        let consentWindow = consentAlert?.window
        let otherPrompt = context.hasOtherPrompt || interfacePromptVisible || panel?.isVisible == true
            || (window?.attachedSheet != nil && window?.attachedSheet !== consentWindow)
            || (NSApp.modalWindow != nil && NSApp.modalWindow !== consentWindow)
        let canPresentConsent = UpdateCheckPolicy.shouldPresentConsent(updaterEnabled: enabled, autoCheckPreference: autoCheckPreference,
            mainWindowVisible: context.mainWindowVisible, applicationActive: context.applicationActive,
            isControlling: context.isControlling, isFullScreen: context.isFullScreen,
            hasHostConnection: context.hasHostConnection, hasOtherPrompt: otherPrompt)
        if !canPresentConsent { dismissConsent() }
        if canPresentConsent, consentAlert == nil, let window {
            let alert = NSAlert()
            alert.messageText = "自动检查更新？"
            alert.informativeText = "QuietDesk 每天最多访问一次 GitHub 获取最新版本信息，不会自动下载或安装。可以随时在菜单栏中修改。"
            alert.addButton(withTitle: "自动检查")
            alert.addButton(withTitle: "不检查")
            consentAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.consentAlert === alert else { return }
                self.consentAlert = nil
                if response == .alertFirstButtonReturn { self.setAutomaticChecks(true) }
                else if response == .alertSecondButtonReturn { self.setAutomaticChecks(false) }
            }
        }
        if UpdateCheckPolicy.shouldAutomaticallyCheck(updaterEnabled: enabled, autoCheckPreference: autoCheckPreference,
            now: now, launchedAt: launchedAt, lastCheck: defaults.object(forKey: "lastUpdateCheck") as? Date) {
            check(manual: false, now: now)
        }
    }

    func setAutomaticChecks(_ value: Bool) {
        dismissConsent()
        autoCheckPreference = value
        defaults.set(value, forKey: "autoCheckUpdates")
        DiagnosticLog.shared.record(.updatePreferenceChanged, state: value ? .enabled : .disabled)
    }

    func check(manual: Bool = true, now: Date = Date()) {
        guard enabled, let feedURL else { return }
        if manual { present() }
        guard !busy, state != .ready else { return }
        let id = UUID(); operationID = id
        state = .checking; message = "正在检查更新…"; completionNotice = nil
        if !manual { defaults.set(now, forKey: "lastUpdateCheck") }
        DiagnosticLog.shared.record(.updateCheck, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.operation = nil } }
            do {
                let data = try await self.loadFeed(feedURL, self.currentVersion)
                try Task.checkCancellation()
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
                    self.needsManualInstall = false; self.manualReleaseURL = nil; self.requiredSystemVersion = nil
                    if assessment != .inconsistentBuild && !UpdateCheckPolicy.shouldOffer(version: update.version,
                        skippedVersion: self.defaults.string(forKey: "skippedUpdateVersion"), manual: manual) {
                        self.manifest = nil; self.state = .idle; self.message = ""
                        return
                    }
                    switch assessment {
                    case .available:
                        self.manifest = update; self.state = .available; self.bannerDismissed = false
                        self.message = "新版本 \(update.version) 可用"
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
                guard !Task.isCancelled else { return }
                self.state = .failed
                self.message = (error as? UpdateFeedError)?.localizedDescription
                    ?? ((error as NSError).domain == NSURLErrorDomain ? "无法连接更新服务器，请检查网络后重试。" : "更新信息校验失败，请稍后重试或在 GitHub 手动下载。")
                DiagnosticLog.shared.record(.updateCheck, state: .failed, error: error)
            }
        }
    }

    func present() {
        guard enabled || completionNotice != nil else { return }
        dismissConsent()
        releaseControl()
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "QuietDesk 更新"
            window.contentMinSize = NSSize(width: 520, height: 480)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateView(controller: self))
            window.center()
            panel = window
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func later() { panel?.close(); bannerDismissed = true }
    func dismissBanner() { bannerDismissed = true }
    func skip() {
        guard !busy, prepared == nil, let update = manifest else { return }
        defaults.set(update.version, forKey: "skippedUpdateVersion")
        manifest = nil; manualReleaseURL = nil; needsManualInstall = false; requiredSystemVersion = nil; state = .idle; later()
    }
    func openRelease() {
        if let url = manualReleaseURL ?? manifest?.releaseNotesURL { NSWorkspace.shared.open(url) }
    }
    func download() {
        guard let update = manifest, !busy, state != .ready, !needsManualInstall, requiredSystemVersion == nil else { return }
        let id = UUID(); operationID = id
        state = .downloading; receivedBytes = 0; totalBytes = nil; message = "正在下载更新…"
        let expected = UpdateInstaller.Expectation(bundleIdentifier: update.bundleIdentifier, version: update.version,
            build: update.build, minimumSystemVersion: update.minimumSystemVersion, archiveURL: update.archive.url,
            archiveSize: update.archive.size, sha256: update.archive.sha256, repository: repository)
        DiagnosticLog.shared.record(.updateDownload, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.operation = nil } }
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
                self.needsManualInstall = staged.manualInstallationReason != nil
                self.message = staged.manualInstallationReason ?? "更新已通过校验，可以安装并重新启动。"
                DiagnosticLog.shared.record(.updateDownload, state: .succeeded)
            } catch {
                guard !Task.isCancelled, self.operationID == id else { return }
                self.state = .failed
                self.message = (error as? UpdateInstaller.Failure)?.localizedDescription ?? "更新下载失败，请检查网络后重试。"
                DiagnosticLog.shared.record(.updateDownload, state: .failed, error: error)
            }
        }
    }
    func install() {
        guard state == .ready, let prepared, !busy, !needsManualInstall else { return }
        guard !installBlocked else { message = "这台 Mac 正被远程控制，请先停止共享后安装。"; return }
        if let reason = installer.installationAvailability() { needsManualInstall = true; message = reason; return }
        let id = UUID(); operationID = id
        state = .installing; message = "正在准备安装，QuietDesk 即将重新启动…"
        DiagnosticLog.shared.record(.updateInstall, state: .requested)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == id { self.operation = nil } }
            do {
                try await self.installer.launchInstaller(for: prepared)
                guard !Task.isCancelled, self.operationID == id else {
                    self.installer.abortPendingInstallation()
                    return
                }
                guard !self.installBlocked else {
                    self.installer.abortPendingInstallation()
                    self.state = .ready; self.message = "安装已暂停；请停止共享后重试。"
                    return
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
        guard !installationHandedOff, operation != nil || prepared != nil else { return }
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
        if !installationHandedOff { cancel() }
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
