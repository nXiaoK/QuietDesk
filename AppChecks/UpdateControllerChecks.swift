import AppKit
import Foundation
import CryptoKit
import QuietDeskCore

private struct UpdateControllerCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func requireUpdate(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw UpdateControllerCheckFailure(message) }
}

// Persist only inside the checks directory while exercising controller restarts.
private final class UpdateCheckDefaults: UserDefaults {
    private let file: URL
    private var values: [String: Any]
    private(set) var writeFailed = false
    init(file: URL) {
        self.file = file
        values = (try? Data(contentsOf: file)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        } ?? [:]
        super.init(suiteName: "local.quietdesk.checks.updater.memory")!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) {
        values[key] = value
        do {
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file, options: .atomic)
        } catch { writeFailed = true }
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
}

private actor UpdateCheckFeed {
    enum Response: Sendable {
        case data(Data)
        case failure
        case delayed(Data)
    }
    private var responses: [Response]
    private(set) var requests = 0
    init(_ responses: [Response]) { self.responses = responses }
    func fetch(_ url: URL, _ version: String) async throws -> Data {
        requests += 1
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        switch responses.removeFirst() {
        case .data(let data): return data
        case .failure: throw URLError(.notConnectedToInternet)
        case .delayed(let data): try await Task.sleep(for: .seconds(2)); return data
        }
    }
}

private func requireRequests(_ feed: UpdateCheckFeed, _ expected: Int, _ message: String) async throws {
    let actual = await feed.requests
    try requireUpdate(actual == expected, message)
}

// No filesystem installation or application termination is performed by this fixture.
private final class UpdateCheckInstaller: UpdateInstalling, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var verifying: (@Sendable () -> Void)?
    private var downloads = 0
    private var launches = 0
    private var discards = 0
    private var aborts = 0
    private var result: UpdateInstaller.InstallationResult?
    var manualReason: String?
    var ignoresLaunchCancellation = false
    var launchDelay: Duration = .milliseconds(150)
    var downloadCount: Int { lock.withLock { downloads } }
    var launchCount: Int { lock.withLock { launches } }
    var discardCount: Int { lock.withLock { discards } }
    var abortCount: Int { lock.withLock { aborts } }

    init(directory: URL, result: UpdateInstaller.InstallationResult? = nil) {
        self.directory = directory; self.result = result
    }
    func consumeResult() -> UpdateInstaller.InstallationResult? {
        lock.withLock { defer { result = nil }; return result }
    }
    func downloadAndStage(expectation: UpdateInstaller.Expectation,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void,
                          onVerifying: @escaping @Sendable () -> Void) async throws -> UpdateInstaller.PreparedUpdate {
        lock.withLock { downloads += 1; verifying = onVerifying }
        progress(8, nil)
        try await Task.sleep(for: .milliseconds(150))
        progress(16, 16)
        onVerifying()
        try await Task.sleep(for: .milliseconds(50))
        return .init(applicationURL: directory.appendingPathComponent("QuietDesk.app"),
                     stagingDirectory: directory, expectation: expectation, manualInstallationReason: manualReason)
    }
    func emitLateVerification() { lock.withLock { verifying }?() }
    func installationAvailability() -> String? { manualReason }
    func launchInstaller(for prepared: UpdateInstaller.PreparedUpdate) async throws {
        lock.withLock { launches += 1 }
        if ignoresLaunchCancellation {
            await Task.detached { try? await Task.sleep(for: .milliseconds(150)) }.value
        } else { try await Task.sleep(for: launchDelay) }
    }
    func abortPendingInstallation() { lock.withLock { aborts += 1 } }
    func discard(_ prepared: UpdateInstaller.PreparedUpdate) { lock.withLock { discards += 1 } }
    func cancel() {}
}

@main
@MainActor
private struct UpdateControllerChecks {
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QUIETDESK_UPDATE_CONTROLLER_CHECK_ROOT"] ?? "work/update-controller-checks", isDirectory: true)
        var passed = 0, failed = 0
        func run(_ name: String, _ body: (URL) async throws -> Void) async {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                try await body(directory)
                passed += 1; print("PASS \(name)")
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("Updater checks run with an independent bundle and isolated local data") { _ in
            try requireUpdate(Bundle.main.bundleIdentifier == "local.quietdesk.checks.updater", "Checks did not use their independent bundle identifier")
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            try requireUpdate(library.path.hasPrefix(root.path + "/home/"), "Checks did not isolate Foundation data paths")
        }

        await run("Unasked update consent sends no automatic requests and manual checks preserve it") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            controller.tick(now: fixture.now)
            await drain()
            try await requireRequests(fixture.feed, 0, "Unasked preference performed an automatic request")
            try requireUpdate(controller.autoCheckPreference == nil, "Unasked preference became an implicit choice")
            controller.check(manual: true, now: fixture.now)
            controller.later()
            try await settled(controller)
            try requireUpdate(controller.manifest?.version == "0.8.0", "Manual request could not find a version")
            try requireUpdate(controller.autoCheckPreference == nil && fixture.defaults.object(forKey: "autoCheckUpdates") == nil, "Manual request changed consent")
        }

        await run("First consent queues behind other prompts and withdraws without choosing when a host connects") { directory in
            let fixture = try Fixture(directory: directory, responses: [])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "合成更新询问检查"
            window.orderFront(nil)
            var context = UpdateSessionContext(mainWindowVisible: true, applicationActive: true, hasOtherPrompt: true)
            let controller = fixture.controller(context: { context }, window: window)
            defer { controller.shutdown(); controller.later(); window.orderOut(nil) }
            controller.tick(now: fixture.now)
            await drain()
            try requireUpdate(window.attachedSheet == nil, "Consent overlapped an existing prompt")
            context.hasOtherPrompt = false
            controller.tick(now: fixture.now)
            await drain()
            try requireUpdate(window.attachedSheet != nil, "Consent did not resume after another prompt closed")
            context.hasHostConnection = true
            controller.tick(now: fixture.now)
            await drain()
            try requireUpdate(window.attachedSheet == nil && controller.autoCheckPreference == nil,
                              "Consent remained in a host session or dismissal saved a choice")
            context.hasHostConnection = false
            controller.tick(now: fixture.now)
            await drain()
            guard let sheet = window.attachedSheet else { throw UpdateControllerCheckFailure("Consent was not requeued") }
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            await drain()
            try requireUpdate(controller.autoCheckPreference == false, "Explicit consent choice was not persisted")
            try await requireRequests(fixture.feed, 0, "Consent dismissal performed a network request")
        }

        await run("Automatic checks respect a skipped version and manual checks still offer it") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest()), .data(try signedManifest())])
            fixture.defaults.set(true, forKey: "autoCheckUpdates")
            fixture.defaults.set("0.8.0", forKey: "skippedUpdateVersion")
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            controller.tick(now: fixture.now)
            try await settled(controller)
            try requireUpdate(controller.manifest == nil, "Skipped version was offered automatically")
            controller.check(manual: true)
            controller.later()
            try await settled(controller)
            try requireUpdate(controller.manifest?.version == "0.8.0", "Manual check hid the skipped version")
            try requireUpdate(fixture.defaults.string(forKey: "skippedUpdateVersion") == "0.8.0", "Checking silently changed the skip")
            controller.skip()
            try requireUpdate(controller.manifest == nil && controller.state == .idle, "Skip did not dismiss the version")
        }

        await run("Checking, dismissing, failure and cancellation never manufacture or change a skip") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest()), .failure, .delayed(try signedManifest())])
            fixture.defaults.set("0.7.1", forKey: "skippedUpdateVersion")
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            controller.later()
            try requireUpdate(fixture.defaults.string(forKey: "skippedUpdateVersion") == "0.7.1", "Later changed skipped version")
            controller.check(manual: false)
            try await settled(controller)
            try requireUpdate(controller.state == .failed, "Network failure was not reported")
            try requireUpdate(fixture.defaults.string(forKey: "skippedUpdateVersion") == "0.7.1", "Failure changed skipped version")
            controller.check(manual: false)
            await drain()
            controller.cancel()
            await drain()
            try requireUpdate(!controller.busy && fixture.defaults.string(forKey: "skippedUpdateVersion") == "0.7.1", "Cancellation changed skip or retained operation")
        }

        await run("One update check runs at a time and a cancelled check cannot overwrite its replacement") { directory in
            let fixture = try Fixture(directory: directory, responses: [.delayed(try signedManifest()), .data(try signedManifest(version: "0.8.1", build: 32))])
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            for _ in 0..<10 { controller.check(manual: false) }
            await drain()
            try await requireRequests(fixture.feed, 1, "Concurrent triggers started multiple requests")
            controller.cancel()
            try await settled(controller)
            controller.check(manual: false)
            try await settled(controller)
            await drain()
            try await requireRequests(fixture.feed, 2, "Replacement request did not start")
            try requireUpdate(controller.manifest?.version == "0.8.1" && controller.state == .available, "Cancelled result changed newer request")
        }

        await run("Progress uses received bytes, unknown lengths remain unknown and late callbacks preserve ready state") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            let installer = UpdateCheckInstaller(directory: directory)
            let controller = fixture.controller(installer: installer)
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            await drain()
            try requireUpdate(controller.state == .downloading && controller.receivedBytes == 8 && controller.totalBytes == nil,
                              "Unknown response length was estimated or real bytes were lost")
            try await settled(controller)
            try requireUpdate(controller.state == .ready && controller.receivedBytes == 16 && controller.totalBytes == 16,
                              "Verified download did not become ready with its byte count")
            installer.emitLateVerification()
            await drain()
            try requireUpdate(controller.state == .ready, "Late callback regressed ready state")
            controller.cancel()
            try requireUpdate(controller.state == .available && installer.discardCount == 1, "Cancelling ready update retained staging")
            try requireUpdate(fixture.defaults.string(forKey: "skippedUpdateVersion") == nil, "Cancelling ready update skipped it")
        }

        await run("Cancellation keeps the task exclusive until cleanup and allows a fresh download afterwards") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            let installer = UpdateCheckInstaller(directory: directory)
            let controller = fixture.controller(installer: installer)
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            await drain()
            controller.cancel()
            controller.download()
            try requireUpdate(installer.downloadCount == 1, "Replacement started before cancellation cleanup")
            try await settled(controller)
            controller.download()
            try await settled(controller)
            try requireUpdate(installer.downloadCount == 2 && controller.state == .ready, "Download did not recover after cancellation")
        }

        await run("Connected hosts may download but cannot launch or hand off installation") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            let installer = UpdateCheckInstaller(directory: directory)
            var context = UpdateSessionContext(hasHostConnection: true)
            var terminations = 0
            let controller = fixture.controller(context: { context }, installer: installer, terminate: { terminations += 1 })
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            try await settled(controller)
            controller.install()
            try requireUpdate(installer.launchCount == 0 && controller.state == .ready, "Connected host started installer")
            context.hasHostConnection = false
            installer.ignoresLaunchCancellation = true
            controller.install()
            await drain()
            context.hasHostConnection = true
            try await settled(controller)
            try requireUpdate(installer.launchCount == 1 && installer.abortCount > 0 && terminations == 0 && controller.state == .ready,
                              "Host connection arriving during readiness caused an application exit")
            context.hasHostConnection = false
            controller.install()
            await drain()
            controller.cancel()
            try await settled(controller)
            try requireUpdate(terminations == 0 && controller.state == .available, "Cancelled installer still handed off")
        }

        await run("A ready installer handoff requests a single normal application termination and preserves staging") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            let installer = UpdateCheckInstaller(directory: directory)
            installer.launchDelay = .milliseconds(400)
            var terminations = 0
            let controller = fixture.controller(installer: installer, terminate: { terminations += 1 })
            defer { controller.shutdown() }
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            try await settled(controller)
            controller.install()
            let deadline = Date().addingTimeInterval(5)
            while terminations == 0 && Date() < deadline { await drain() }
            try requireUpdate(terminations == 1, "Installer handoff did not request application termination")
            controller.install()
            controller.shutdown()
            try requireUpdate(terminations == 1 && installer.launchCount == 1 && installer.discardCount == 0 && installer.abortCount == 0,
                              "Handoff was duplicated or shutdown removed files needed by the installer")
        }

        await run("Manual installation and newer system requirements do not start the installer") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest()),
                .data(try signedManifest(minimumSystemVersion: "999.0"))])
            let installer = UpdateCheckInstaller(directory: directory)
            installer.manualReason = "合成的只读磁盘。"
            let controller = fixture.controller(installer: installer)
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            try await settled(controller)
            controller.install()
            try requireUpdate(controller.needsManualInstall && installer.launchCount == 0, "Manual-only staged update started installation")
            controller.cancel()
            controller.check(manual: false)
            try await settled(controller)
            controller.download()
            try requireUpdate(controller.requiredSystemVersion == "999.0" && !controller.needsManualInstall && installer.downloadCount == 1,
                              "Unsupported macOS offered an installable download")
        }

        await run("Installation results restore a one-time notice without cancellation side effects") { directory in
            let fixture = try Fixture(directory: directory, responses: [])
            let installer = UpdateCheckInstaller(directory: directory, result: .init(version: "0.8.0", build: 31,
                succeeded: true, message: "已更新到 0.8.0。", restartObserved: true))
            let controller = fixture.controller(installer: installer)
            controller.start()
            try requireUpdate(controller.completionNotice == "已更新到 0.8.0。" && controller.state == .upToDate,
                              "Startup did not consume the installer result")
            controller.shutdown()
            try requireUpdate(controller.message == "已更新到 0.8.0。" && controller.state == .upToDate,
                              "Idle shutdown manufactured an update cancellation")
            let restarted = fixture.controller(installer: installer)
            restarted.start()
            try requireUpdate(restarted.completionNotice == nil, "Installer result was presented twice")
            restarted.shutdown()
        }

        await run("Daily update check time persists across controller and defaults instances") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest()), .data(try signedManifest())])
            fixture.defaults.set(true, forKey: "autoCheckUpdates")
            let first = fixture.controller()
            first.tick(now: fixture.now)
            try await settled(first)
            first.shutdown()
            try requireUpdate(!fixture.defaults.writeFailed, "Preferences could not persist")
            let restartedDefaults = UpdateCheckDefaults(file: directory.appendingPathComponent("defaults.plist"))
            let second = fixture.controller(defaults: restartedDefaults)
            defer { second.shutdown(); second.later() }
            second.tick(now: fixture.now.addingTimeInterval(86_399))
            await drain()
            try await requireRequests(fixture.feed, 1, "Restart bypassed the daily limit")
            second.tick(now: fixture.now.addingTimeInterval(86_400))
            try await settled(second)
            try await requireRequests(fixture.feed, 2, "Daily boundary did not re-enable check")
        }

        await run("Automatic update banners wait through control, fullscreen and shared sessions") { directory in
            let fixture = try Fixture(directory: directory, responses: [.data(try signedManifest())])
            var context = UpdateSessionContext()
            let controller = fixture.controller(context: { context })
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            try requireUpdate(controller.showBanner, "Available update had no banner in idle context")
            context.isControlling = true
            try requireUpdate(!controller.showBanner, "Controlling session showed automatic banner")
            context.isControlling = false; context.isFullScreen = true
            try requireUpdate(!controller.showBanner, "Fullscreen session showed automatic banner")
            context.isFullScreen = false; context.isSharing = true; context.hasHostConnection = true
            try requireUpdate(!controller.showBanner && controller.installBlocked, "Connected host offered banner or installation")
            context.isSharing = false; context.hasHostConnection = false; context.hasActiveConnection = true
            try requireUpdate(!controller.showBanner, "Active connection showed automatic banner")
            context.hasActiveConnection = false
            try requireUpdate(controller.showBanner && !controller.installBlocked, "Banner or installation did not recover after session")
            controller.dismissBanner()
            try requireUpdate(!controller.showBanner && controller.menuTitle.contains("0.8.0"), "Dismissing banner hid the menu update")
        }

        await run("Feed network and authentication failures are reported without changing preferences") { directory in
            let key = signingKey
            var bad = try signedManifest()
            bad[bad.count / 2] ^= 1
            let fixture = try Fixture(directory: directory, responses: [.failure, .data(bad), .data(try signedManifest(key: Curve25519.Signing.PrivateKey()))])
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            for _ in 0..<3 {
                controller.check(manual: false)
                try await settled(controller)
                try requireUpdate(controller.state == .failed && !controller.message.isEmpty, "Feed failure was hidden")
                try requireUpdate(controller.manifest == nil && controller.autoCheckPreference == nil, "Failure changed manifest or consent")
            }
            try requireUpdate(key.publicKey.rawRepresentation.count == 32, "Fixture signing key changed")
        }

        await run("Authenticated future schemas offer a safe manual update instead of installation") { directory in
            let payload = try JSONSerialization.data(withJSONObject: ["schema": 2,
                "releaseNotesURL": "https://github.com/nXiaoK/QuietDesk/releases/latest"])
            let fixture = try Fixture(directory: directory, responses: [.data(try signedPayload(payload))])
            let controller = fixture.controller()
            defer { controller.shutdown(); controller.later() }
            controller.check(manual: false)
            try await settled(controller)
            try requireUpdate(controller.state == .available && controller.needsManualInstall, "Future schema did not offer manual update")
            try requireUpdate(controller.manifest == nil && controller.manualReleaseURL?.host == "github.com", "Future schema was treated as installable")
        }

        await run("Empty keys, production loopback and unsafe feed credentials disable the updater") { directory in
            let fixture = try Fixture(directory: directory, responses: [])
            var empty = fixture.info; empty["QuietDeskUpdatePublicKeys"] = []
            var production = fixture.info; production["CFBundleIdentifier"] = "local.quietdesk.app"
            production["QuietDeskUpdateFeedURL"] = "http://127.0.0.1:1234/QuietDesk-update.json"
            var credentials = fixture.info
            credentials["QuietDeskUpdateFeedURL"] = "https://user:secret@github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json"
            for info in [empty, production, credentials] {
                let controller = fixture.controller(info: info)
                controller.tick(now: fixture.now)
                controller.check(manual: false)
                try requireUpdate(!controller.enabled && !controller.busy, "Unsafe or unconfigured feed was enabled")
                controller.shutdown()
            }
            try await requireRequests(fixture.feed, 0, "Disabled updater made a request")
        }

        await run("Production feed loading validates responses, size bounds, redirects, cookies and timeout") { directory in
            guard let base = ProcessInfo.processInfo.environment["QUIETDESK_UPDATE_CONTROLLER_CHECK_FEED"],
                  let endpoint = URL(string: base) else { throw UpdateControllerCheckFailure("Missing loopback fixture") }
            let fixture = try Fixture(directory: directory, responses: [])
            let document = root.appendingPathComponent("http-root/feed.json")
            try signedManifest().write(to: document, options: .atomic)
            @MainActor func controller(_ path: String) -> UpdateController {
                var info = fixture.info
                info["QuietDeskUpdateFeedURL"] = endpoint.appendingPathComponent(path).absoluteString
                return UpdateController(info: info, defaults: fixture.defaults,
                    launchedAt: fixture.now.addingTimeInterval(-120))
            }
            for path in ["valid", "cookies"] {
                let update = controller(path)
                update.check(manual: false)
                try await settled(update)
                try requireUpdate(update.state == .available && update.manifest?.version == "0.8.0", "Production loader rejected valid response or sent cookies")
                update.shutdown()
            }
            for path in ["missing", "oversized-header", "oversized-stream", "redirect"] {
                let update = controller(path)
                let started = Date()
                update.check(manual: false)
                try await settled(update)
                try requireUpdate(update.state == .failed && update.manifest == nil, "Production loader accepted " + path)
                if path == "missing" { try requireUpdate(update.message.contains("暂无更新信息"), "404 lost its explicit result") }
                if path == "redirect" { try requireUpdate(Date().timeIntervalSince(started) < 3, "Insecure redirect was followed") }
                update.shutdown()
            }
            let slow = controller("slow")
            let started = Date()
            slow.check(manual: false)
            try await settled(slow, timeout: 20)
            let duration = Date().timeIntervalSince(started)
            try requireUpdate(slow.state == .failed && duration >= 13 && duration < 20, "Production loader did not enforce its 15-second timeout")
            slow.shutdown()
        }

        print("\(passed) passed, \(failed) failed (synthetic update state only)")
        exit(failed == 0 ? 0 : 1)
    }

    private static let signingKey = Curve25519.Signing.PrivateKey()
    private static let identifier = "local.quietdesk.checks.updater"

    @MainActor
    private struct Fixture {
        let defaults: UpdateCheckDefaults
        let feed: UpdateCheckFeed
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let info: [String: Any]
        init(directory: URL, responses: [UpdateCheckFeed.Response]) throws {
            defaults = UpdateCheckDefaults(file: directory.appendingPathComponent("defaults.plist"))
            feed = UpdateCheckFeed(responses)
            info = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "30",
                "QuietDeskUpdateFeedURL": "https://github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json",
                "QuietDeskUpdatePublicKeys": [["id": "checks", "key": signingKey.publicKey.rawRepresentation.base64EncodedString()]]]
        }
        func controller(defaults otherDefaults: UserDefaults? = nil, info otherInfo: [String: Any]? = nil,
                        context: @escaping () -> UpdateSessionContext = { .init() },
                        installer: any UpdateInstalling = UpdateInstaller(), terminate: @escaping () -> Void = {},
                        window: NSWindow? = nil) -> UpdateController {
            UpdateController(info: otherInfo ?? info, defaults: otherDefaults ?? defaults,
                launchedAt: now.addingTimeInterval(-120), sessionContext: context, mainWindow: { window },
                installer: installer, terminateApplication: terminate,
                loadFeed: { [feed] url, version in try await feed.fetch(url, version) })
        }
    }

    private static func signedManifest(version: String = "0.8.0", build: Int = 31,
                                       minimumSystemVersion: String = "14.0",
                                       key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let manifest = UpdateManifest(bundleIdentifier: identifier, version: version, build: build,
            minimumSystemVersion: minimumSystemVersion, publishedAt: "2026-10-19T08:00:00Z", revision: "",
            releaseNotesURL: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/tag/v\(version)")!, notes: "合成状态，仅用于更新器检查。",
            archive: UpdateArchive(url: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/download/v\(version)/QuietDesk.zip")!,
                                   size: 16, sha256: String(repeating: "a", count: 64)))
        return try signedPayload(JSONEncoder().encode(manifest), key: key)
    }
    private static func signedPayload(_ payload: Data, key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let signing = key ?? signingKey
        return try JSONEncoder().encode(SignedUpdateEnvelope(keyID: "checks", payload: payload.base64EncodedString(),
            signature: signing.signature(for: UpdateManifestVerifier.signingPrefix + payload).base64EncodedString()))
    }
    private static func drain() async { try? await Task.sleep(for: .milliseconds(30)) }
    private static func settled(_ controller: UpdateController, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.busy && Date() < deadline { await drain() }
        try requireUpdate(!controller.busy, "Update task did not settle")
    }
}
