import AppKit
import CryptoKit
import Darwin
import Foundation
import QuietDeskCore
import Security

final class UpdateInstaller: @unchecked Sendable {
    struct Expectation: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let version: String
        let build: Int
        let minimumSystemVersion: String
        let archiveURL: URL
        let archiveSize: Int64
        let sha256: String
        let repository: String

        init(bundleIdentifier: String, version: String, build: Int, minimumSystemVersion: String,
             archiveURL: URL, archiveSize: Int64, sha256: String, repository: String = "nXiaoK/QuietDesk") {
            self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
            self.minimumSystemVersion = minimumSystemVersion; self.archiveURL = archiveURL
            self.archiveSize = archiveSize; self.sha256 = sha256; self.repository = repository
        }
    }

    struct PreparedUpdate: Sendable {
        let applicationURL: URL
        let stagingDirectory: URL
        let expectation: Expectation
        var manualInstallationReason: String? = nil
    }

    struct InstallationResult: Codable, Sendable {
        let version: String
        let build: Int
        let succeeded: Bool
        let message: String
        let restartObserved: Bool
    }

    enum Failure: LocalizedError {
        case invalid(String)
        case busy
        var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            case .busy: return "已有更新任务正在进行，请稍后重试。"
            }
        }
    }

    struct InstallPlan: Codable {
        let parentPID: Int32
        let applicationURL: URL
        let stagedApplicationURL: URL
        let stagingDirectory: URL
        let backupURL: URL
        let resultURL: URL
        let readyURL: URL
        let acknowledgementURL: URL
        let expectation: Expectation
        let currentTeamIdentifier: String?
    }

    private static let installArgument = "--quietdesk-install-update-v1"
    private static let maximumArchiveSize: Int64 = 64 * 1024 * 1024
    private let applicationURL: URL
    private let replacementDirectory: URL?
    let updatesDirectory: URL
    private let lock = NSLock()
    private var busy = false
    private var transfer: ArchiveTransfer?
    private var cancelled = false
    private var pendingInstallation: (process: Process, planURL: URL, readyURL: URL)?

    init(applicationURL: URL = Bundle.main.bundleURL, cachesURL: URL? = nil, replacementDirectory: URL? = nil) {
        self.applicationURL = applicationURL.standardizedFileURL
        self.replacementDirectory = replacementDirectory.map(Self.canonicalSystemLocation)
        let root = Self.canonicalSystemLocation(cachesURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.folderName(), isDirectory: true)
        )
        updatesDirectory = root.appendingPathComponent("Updates", isDirectory: true)
    }

    static var currentApplicationUsesAdHocSignature: Bool {
        (try? signingInformation(Bundle.main.bundleURL).adHoc) ?? false
    }

    func downloadAndStage(expectation: Expectation,
                          progress: @escaping @Sendable (Int64, Int64?) -> Void,
                          onVerifying: @escaping @Sendable () -> Void = {}) async throws -> PreparedUpdate {
        try begin()
        defer { end() }
        try Self.validateExpectation(expectation)
        try Self.secureDirectory(updatesDirectory)
        let cache = updatesDirectory.appendingPathComponent("\(expectation.version)-\(expectation.build)", isDirectory: true)
        try Self.secureDirectory(cache)
        let archive = cache.appendingPathComponent("archive-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: archive)
            if (try? FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: cache)
            }
        }
        let download = ArchiveTransfer(expectation: expectation, destination: archive, progress: progress)
        setTransfer(download)
        try checkCancellation()
        try await withTaskCancellationHandler(operation: { try await download.run() }, onCancel: { download.cancel() })
        try checkCancellation()
        onVerifying()
        try Self.validateZIP(archive)
        var manualReason = installationAvailability()
        let replacement: URL
        if manualReason != nil {
            replacement = cache
        } else {
            do {
                replacement = try replacementDirectory ?? Self.canonicalSystemLocation(FileManager.default.url(for: .itemReplacementDirectory,
                    in: .userDomainMask, appropriateFor: applicationURL, create: true))
            } catch {
                replacement = cache
                manualReason = "无法在应用所在磁盘暂存更新，请手动安装已校验的新版应用。"
            }
        }
        let staging = replacement.appendingPathComponent("QuietDesk-update-\(UUID().uuidString)", isDirectory: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: staging) } }
        try Self.secureDirectory(staging)
        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        try checkCancellation()
        let entries = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard entries.count == 1, entries[0].lastPathComponent == "QuietDesk.app" else {
            throw Failure.invalid("更新归档必须只包含 QuietDesk.app。")
        }
        let app = entries[0]
        try Self.validateApplication(app, expectation: expectation,
                                     currentTeamIdentifier: try Self.signingInformation(applicationURL).team)
        try Self.removeQuarantine(app)
        try checkCancellation()
        retained = true
        return PreparedUpdate(applicationURL: app, stagingDirectory: staging, expectation: expectation,
                              manualInstallationReason: manualReason)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = transfer
        lock.unlock()
        current?.cancel()
    }

    func abortPendingInstallation() {
        lock.lock()
        cancelled = true
        let pending = pendingInstallation
        pendingInstallation = nil
        lock.unlock()
        guard let pending else { return }
        if pending.process.isRunning { pending.process.terminate(); pending.process.waitUntilExit() }
        try? FileManager.default.removeItem(at: pending.planURL)
        try? FileManager.default.removeItem(at: pending.readyURL)
    }

    func discard(_ prepared: PreparedUpdate) {
        guard prepared.applicationURL.deletingLastPathComponent() == prepared.stagingDirectory,
              prepared.applicationURL.lastPathComponent == "QuietDesk.app" else { return }
        try? FileManager.default.removeItem(at: prepared.stagingDirectory)
    }

    func installationAvailability() -> String? {
        if applicationURL.path.contains("/AppTranslocation/") {
            return "请先将 QuietDesk 移到“应用程序”，再安装更新。"
        }
        do {
            if try applicationURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true {
                return "当前应用位于只读磁盘。请先移到“应用程序”，再安装更新。"
            }
        } catch { return "无法确认应用所在磁盘是否可写，请手动安装。" }
        if !FileManager.default.isWritableFile(atPath: applicationURL.deletingLastPathComponent().path) {
            return "当前账户无法替换此位置的应用，请手动安装。"
        }
        return nil
    }

    func launchInstaller(for prepared: PreparedUpdate) async throws {
        try begin()
        defer { end() }
        if let reason = prepared.manualInstallationReason { throw Failure.invalid(reason) }
        if let reason = installationAvailability() { throw Failure.invalid(reason) }
        try Self.secureDirectory(updatesDirectory)
        guard prepared.applicationURL.deletingLastPathComponent() == prepared.stagingDirectory else {
            throw Failure.invalid("更新暂存路径无效。")
        }
        try Self.validateApplication(prepared.applicationURL, expectation: prepared.expectation,
                                     currentTeamIdentifier: try Self.signingInformation(applicationURL).team)
        let token = UUID().uuidString
        let plan = InstallPlan(parentPID: getpid(), applicationURL: applicationURL,
                               stagedApplicationURL: prepared.applicationURL, stagingDirectory: prepared.stagingDirectory,
                               backupURL: applicationURL.deletingLastPathComponent()
                                .appendingPathComponent(".QuietDesk-update-backup-\(token).app"),
                               resultURL: updatesDirectory.appendingPathComponent("install-result.json"),
                               readyURL: updatesDirectory.appendingPathComponent("installer-\(token).ready"),
                               acknowledgementURL: updatesDirectory.appendingPathComponent("installer-\(token).ack"),
                               expectation: prepared.expectation,
                               currentTeamIdentifier: try Self.signingInformation(applicationURL).team)
        let planURL = updatesDirectory.appendingPathComponent("install-plan.json")
        try Self.writePrivate(plan, to: planURL)
        try? FileManager.default.removeItem(at: plan.resultURL)
        var accepted = false
        var child: Process?
        defer {
            if !accepted {
                if let child, clearPending(child), child.isRunning { child.terminate(); child.waitUntilExit() }
                try? FileManager.default.removeItem(at: planURL)
                try? FileManager.default.removeItem(at: plan.readyURL)
            }
        }
        guard let executable = Bundle(url: applicationURL)?.executableURL else {
            throw Failure.invalid("找不到当前应用的可执行文件。")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.installArgument, planURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        child = process
        try startInstaller(process, planURL: planURL, readyURL: plan.readyURL)
        for _ in 0..<100 {
            try checkCancellation()
            if FileManager.default.fileExists(atPath: plan.readyURL.path) {
                try confirmPending(process)
                accepted = true
                return
            }
            guard process.isRunning else { throw Failure.invalid("安装进程无法启动，请手动安装。") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.invalid("安装进程未准备就绪，应用将保持运行。请稍后重试。")
    }

    func consumeResult() -> InstallationResult? {
        let planURL = updatesDirectory.appendingPathComponent("install-plan.json")
        guard let plan = try? Self.readPrivate(InstallPlan.self, from: planURL),
              (try? Self.validateExpectation(plan.expectation)) != nil,
              plan.expectation.bundleIdentifier == Bundle(url: applicationURL)?.bundleIdentifier,
              plan.applicationURL.path == applicationURL.path,
              plan.resultURL == updatesDirectory.appendingPathComponent("install-result.json"),
              plan.acknowledgementURL.deletingLastPathComponent() == updatesDirectory,
              plan.acknowledgementURL.lastPathComponent.hasPrefix("installer-"),
              plan.acknowledgementURL.pathExtension == "ack",
              plan.stagingDirectory.lastPathComponent.hasPrefix("QuietDesk-update-"),
              plan.stagedApplicationURL.path == plan.stagingDirectory.appendingPathComponent("QuietDesk.app").path,
              plan.backupURL.deletingLastPathComponent() == applicationURL.deletingLastPathComponent(),
              plan.backupURL.lastPathComponent.hasPrefix(".QuietDesk-update-backup-"),
              plan.backupURL.pathExtension == "app",
              let result = try? Self.readPrivate(InstallationResult.self, from: plan.resultURL),
              result.version == plan.expectation.version, result.build == plan.expectation.build,
              let infoData = try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any],
              !result.succeeded || (info["CFBundleShortVersionString"] as? String == result.version &&
                info["CFBundleVersion"] as? String == String(result.build)) else { return nil }
        guard !FileManager.default.fileExists(atPath: plan.acknowledgementURL.path) else { return nil }
        // The staged app has already moved away, so its URL's directory hint may
        // differ from a URL constructed now. Compare its path above, and only
        // consume the result after the helper can observe our acknowledgement.
        guard (try? Self.writePrivate(Data(), to: plan.acknowledgementURL)) != nil else { return nil }
        if result.succeeded {
            try? FileManager.default.removeItem(at: plan.backupURL)
        }
        if (try? Self.validatePrivate(plan.stagingDirectory, directory: true)) != nil {
            try? FileManager.default.removeItem(at: plan.stagingDirectory)
        }
        let cache = updatesDirectory.appendingPathComponent("\(plan.expectation.version)-\(plan.expectation.build)")
        if (try? Self.validatePrivate(cache, directory: true)) != nil { try? FileManager.default.removeItem(at: cache) }
        try? FileManager.default.removeItem(at: plan.resultURL)
        try? FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: plan.acknowledgementURL)
        return result
    }

    static func runInstallerIfRequested(applicationURL: URL = Bundle.main.bundleURL, cachesURL: URL? = nil) -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == installArgument else { return false }
        _ = setsid()
        signal(SIGHUP, SIG_IGN)
        guard arguments.count == 3 else { return true }
        let runner = UpdateInstaller(applicationURL: applicationURL, cachesURL: cachesURL)
        let planURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard planURL == runner.updatesDirectory.appendingPathComponent("install-plan.json"),
              let plan = try? readPrivate(InstallPlan.self, from: planURL),
              (try? validatePlan(plan, planURL: planURL, currentApplicationURL: applicationURL)) != nil,
              plan.parentPID == getppid() else { return true }
        defer {
            try? FileManager.default.removeItem(at: plan.readyURL)
            // Startup can consume the result while /usr/bin/open is returning.
            // Do not leave a late result/ack behind after that startup removed
            // its plan, even if it outran the helper's observation loop.
            if !FileManager.default.fileExists(atPath: planURL.path) {
                try? FileManager.default.removeItem(at: plan.resultURL)
                try? FileManager.default.removeItem(at: plan.acknowledgementURL)
            }
        }
        do {
            try writePrivate(Data(), to: plan.readyURL)
            try performInstallation(plan, planURL: planURL)
        } catch {
            let result = InstallationResult(version: plan.expectation.version, build: plan.expectation.build,
                                            succeeded: false, message: error.localizedDescription, restartObserved: false)
            try? writePrivate(result, to: plan.resultURL)
            if FileManager.default.fileExists(atPath: plan.applicationURL.path),
               !FileManager.default.fileExists(atPath: plan.backupURL.path),
               kill(plan.parentPID, 0) != 0, errno == ESRCH,
               (try? validateCodeSignature(plan.applicationURL)) != nil {
                try? run("/usr/bin/open", [plan.applicationURL.path])
            }
        }
        return true
    }

    static func performInstallation(_ plan: InstallPlan, planURL: URL, waitTimeout: TimeInterval = 30,
                                    restartTimeout: TimeInterval = 15,
                                    renameItem: (URL, URL) throws -> Void = renameItem,
                                    reopen: (URL) throws -> Void = { try run("/usr/bin/open", [$0.path]) }) throws {
        let deadline = Date().addingTimeInterval(waitTimeout)
        while kill(plan.parentPID, 0) == 0 || errno == EPERM {
            guard Date() < deadline else { throw Failure.invalid("等待旧应用退出超时；更新未安装。") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try validatePlan(plan, planURL: planURL, currentApplicationURL: plan.applicationURL)
        try validateApplication(plan.stagedApplicationURL, expectation: plan.expectation,
                                currentTeamIdentifier: plan.currentTeamIdentifier)
        try validateTree(plan.applicationURL)
        try validateNoLinks(plan.applicationURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: plan.backupURL.path) else {
            throw Failure.invalid("更新备份位置已经存在；更新未安装。")
        }
        try renameItem(plan.applicationURL, plan.backupURL)
        do {
            try renameItem(plan.stagedApplicationURL, plan.applicationURL)
        } catch {
            do { try renameItem(plan.backupURL, plan.applicationURL) }
            catch { throw Failure.invalid("替换失败且无法恢复原应用；旧版备份已保留，请手动恢复。") }
            throw error
        }
        do {
            try validateApplication(plan.applicationURL, expectation: plan.expectation,
                                    currentTeamIdentifier: plan.currentTeamIdentifier)
        } catch {
            do {
                try renameItem(plan.applicationURL, plan.stagedApplicationURL)
                try renameItem(plan.backupURL, plan.applicationURL)
            } catch { throw Failure.invalid("新包校验失败且无法恢复原应用；旧版备份已保留，请手动恢复。") }
            throw Failure.invalid("新包安装后校验失败，已恢复旧版本。")
        }
        // Publish before open: the new process may reach consumeResult before open returns.
        let installed = InstallationResult(version: plan.expectation.version, build: plan.expectation.build,
                                           succeeded: true, message: "已更新到 \(plan.expectation.version)", restartObserved: false)
        try writePrivate(installed, to: plan.resultURL)
        do { try reopen(plan.applicationURL) }
        catch {
            let result = InstallationResult(version: installed.version, build: installed.build, succeeded: true,
                                            message: "更新已安装，但自动重新启动失败。旧版备份已保留，请手动打开 QuietDesk。",
                                            restartObserved: false)
            try writePrivate(result, to: plan.resultURL)
            return
        }
        let restartDeadline = Date().addingTimeInterval(restartTimeout)
        var observed = false
        repeat {
            observed = FileManager.default.fileExists(atPath: plan.acknowledgementURL.path) ||
                !FileManager.default.fileExists(atPath: planURL.path) ||
                NSRunningApplication.runningApplications(withBundleIdentifier: plan.expectation.bundleIdentifier)
                    .contains { $0.processIdentifier != plan.parentPID && $0.processIdentifier != getpid() &&
                        $0.bundleURL?.standardizedFileURL == plan.applicationURL }
            if observed { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < restartDeadline
        if observed {
            try? FileManager.default.removeItem(at: plan.backupURL)
            try? FileManager.default.removeItem(at: plan.stagingDirectory)
            if FileManager.default.fileExists(atPath: plan.acknowledgementURL.path) ||
                !FileManager.default.fileExists(atPath: planURL.path) {
                for file in [plan.resultURL, planURL, plan.acknowledgementURL] { try? FileManager.default.removeItem(at: file) }
            } else {
                try writePrivate(InstallationResult(version: installed.version, build: installed.build, succeeded: true,
                                                    message: installed.message, restartObserved: true), to: plan.resultURL)
            }
        } else {
            try writePrivate(InstallationResult(version: installed.version, build: installed.build, succeeded: true,
                                                message: "更新已安装，但未观察到新应用启动。旧版备份已保留，请手动打开 QuietDesk。",
                                                restartObserved: false), to: plan.resultURL)
        }
    }

    static func validatePlan(_ plan: InstallPlan, planURL: URL, currentApplicationURL: URL) throws {
        let root = planURL.deletingLastPathComponent()
        try validatePrivate(root, directory: true)
        let paths = [planURL, plan.applicationURL, plan.stagedApplicationURL, plan.stagingDirectory,
                     plan.backupURL, plan.resultURL, plan.readyURL, plan.acknowledgementURL]
        // Foundation rewrites /private/var to /var when standardizing a URL.
        // Compare physical paths so canonical system staging directories remain valid.
        guard paths.allSatisfy({ $0.isFileURL && $0.path == canonicalSystemLocation($0.standardizedFileURL).path }),
              planURL.lastPathComponent == "install-plan.json",
              plan.parentPID > 1, plan.parentPID != getpid(),
              plan.applicationURL.path == currentApplicationURL.standardizedFileURL.path,
              plan.applicationURL.pathExtension == "app",
              plan.expectation.bundleIdentifier == Bundle(url: currentApplicationURL)?.bundleIdentifier,
              plan.stagedApplicationURL.path == plan.stagingDirectory.appendingPathComponent("QuietDesk.app").path,
              plan.stagingDirectory != plan.applicationURL,
              plan.stagingDirectory.lastPathComponent.hasPrefix("QuietDesk-update-"),
              !plan.stagingDirectory.path.hasPrefix(plan.applicationURL.path + "/"),
              plan.backupURL.deletingLastPathComponent() == plan.applicationURL.deletingLastPathComponent(),
              plan.backupURL.lastPathComponent.hasPrefix(".QuietDesk-update-backup-"),
              plan.backupURL.pathExtension == "app",
              plan.resultURL == root.appendingPathComponent("install-result.json"),
              plan.readyURL.deletingLastPathComponent() == root, plan.readyURL.lastPathComponent.hasPrefix("installer-"),
              plan.readyURL.pathExtension == "ready",
              plan.acknowledgementURL.deletingLastPathComponent() == root,
              plan.acknowledgementURL.lastPathComponent.hasPrefix("installer-"),
              plan.acknowledgementURL.pathExtension == "ack" else { throw Failure.invalid("安装计划路径无效。") }
        try validateExpectation(plan.expectation)
        try validatePrivate(plan.stagingDirectory, directory: true)
        try validateNoLinks(plan.applicationURL)
        try validateNoLinks(plan.stagedApplicationURL)
        let oldVolume = try plan.applicationURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let newVolume = try plan.stagedApplicationURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard oldVolume != nil, oldVolume == newVolume else { throw Failure.invalid("更新暂存位置与应用不在同一磁盘。") }
        let oldTeam = try signingInformation(currentApplicationURL).team
        guard oldTeam == plan.currentTeamIdentifier else { throw Failure.invalid("当前应用签名身份与安装计划不符。") }
    }

    static func validateApplication(_ url: URL, expectation: Expectation, currentTeamIdentifier: String?) throws {
        try validateTree(url)
        let infoData = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let bundle = Bundle(url: url), info["CFBundleIdentifier"] as? String == expectation.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == expectation.version,
              info["CFBundleVersion"] as? String == String(expectation.build),
              let minimum = info["LSMinimumSystemVersion"] as? String,
              systemSupports(minimum),
              let executableName = info["CFBundleExecutable"] as? String,
              !executableName.isEmpty, ![".", ".."].contains(executableName),
              !executableName.contains("/"), !executableName.contains("\\"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executableName)").path) else {
            throw Failure.invalid("新版应用的标识、版本、系统要求或可执行文件不符。")
        }
        var supportsARM: Int32 = 0
        var length = MemoryLayout.size(ofValue: supportsARM)
        _ = sysctlbyname("hw.optional.arm64", &supportsARM, &length, nil, 0)
        let architecture = NSNumber(value: supportsARM == 1 ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64)
        guard bundle.executableArchitectures?.contains(architecture) == true else {
            throw Failure.invalid("新版应用不支持这台 Mac 的处理器。")
        }
        try validateCodeSignature(url)
        if let currentTeamIdentifier, try signingInformation(url).team != currentTeamIdentifier {
            throw Failure.invalid("新版应用的开发团队与当前应用不一致，请手动安装。")
        }
    }

    static func validateZIP(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func bad() -> Failure { .invalid("更新 ZIP 包结构不安全或不受支持。") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw bad() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { throw bad() }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        guard data.count >= 22, data.count <= maximumArchiveSize else { throw bad() }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(i) == 0x06054b50, i + 22 + (try u16(i + 20)) == data.count { end = i; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0,
              try u16(end + 8) == u16(end + 10), try u16(end + 10) > 0,
              try u16(end + 10) < 65_535 else { throw bad() }
        let count = try u16(end + 10)
        let centralSize = Int(try u32(end + 12)), centralStart = Int(try u32(end + 16))
        guard centralStart >= 0, centralSize > 0, centralStart + centralSize == end else { throw bad() }
        var cursor = centralStart
        var paths = Set<String>()
        var filePaths = Set<String>()
        var localRanges: [Range<Int>] = []
        var expanded: UInt64 = 0
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw bad() }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let nameLength = try u16(cursor + 28), extraLength = try u16(cursor + 30), commentLength = try u16(cursor + 32)
            let local = Int(try u32(cursor + 42)), compressed = Int(try u32(cursor + 20))
            let attributes = try u32(cursor + 38)
            let mode = mode_t(attributes >> 16)
            guard flags & (1 | 64) == 0, [0, 8].contains(method), nameLength > 0,
                  try u16(cursor + 34) == 0,
                  cursor + 46 + nameLength + extraLength + commentLength <= end,
                  local >= 0, local + 30 < centralStart, try u32(local) == 0x04034b50 else { throw bad() }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let path = String(data: rawName, encoding: .utf8), !path.contains("\0"), !path.contains("\\"),
                  !path.hasPrefix("/"), !path.contains(":") else { throw bad() }
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !pieces.contains("."), !pieces.contains(".."),
                  !pieces.dropLast().contains(""),
                  pieces.first == "QuietDesk.app" || pieces.first == "__MACOSX" else { throw bad() }
            let kind = mode & S_IFMT
            guard kind == 0 || kind == S_IFREG || kind == S_IFDIR,
                  kind != S_IFDIR || path.hasSuffix("/"),
                  kind != S_IFREG || !path.hasSuffix("/") else { throw bad() }
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(normalized).inserted else { throw bad() }
            if !path.hasSuffix("/") { filePaths.insert(normalized) }
            let localNameLength = try u16(local + 26), localExtraLength = try u16(local + 28)
            let payloadEnd = local + 30 + localNameLength + localExtraLength + compressed
            guard try u16(local + 6) == flags, try u16(local + 8) == method,
                  localNameLength == nameLength, payloadEnd <= centralStart,
                  data.subdata(in: local + 30..<local + 30 + localNameLength) == rawName else { throw bad() }
            if flags & 8 == 0 {
                guard try u32(local + 14) == u32(cursor + 16),
                      try u32(local + 18) == u32(cursor + 20),
                      try u32(local + 22) == u32(cursor + 24) else { throw bad() }
            }
            var localEnd = payloadEnd
            if flags & 8 != 0 {
                let descriptor = try u32(payloadEnd) == 0x08074b50 ? payloadEnd + 4 : payloadEnd
                guard descriptor + 12 <= centralStart,
                      try u32(descriptor) == u32(cursor + 16),
                      try u32(descriptor + 4) == u32(cursor + 20),
                      try u32(descriptor + 8) == u32(cursor + 24) else { throw bad() }
                localEnd = descriptor + 12
            }
            if method == 0 { guard try u32(cursor + 20) == u32(cursor + 24) else { throw bad() } }
            localRanges.append(local..<localEnd)
            expanded += UInt64(try u32(cursor + 24))
            guard expanded <= UInt64(maximumArchiveSize) * 8 else { throw bad() }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        let sortedRanges = localRanges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sortedRanges.count {
            guard !sortedRanges[index - 1].overlaps(sortedRanges[index]) else { throw bad() }
        }
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !filePaths.contains(parent) else { throw bad() }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard cursor == end, paths.contains(where: { $0.hasPrefix("quietdesk.app/") }) else { throw bad() }
    }

    private static func validateExpectation(_ value: Expectation) throws {
        _ = try UpdateVersion(value.version)
        guard value.build > 0, value.archiveSize > 0, value.archiveSize <= maximumArchiveSize,
              value.sha256.utf8.count == 64, value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              systemSupports(value.minimumSystemVersion), !value.bundleIdentifier.isEmpty else { throw Failure.invalid("更新清单字段无效。") }
        try UpdateURLPolicy.validateArchiveURL(value.archiveURL, bundleIdentifier: value.bundleIdentifier,
                                              allowLoopbackForTesting: true, repository: value.repository)
    }

    private static func systemSupports(_ string: String) -> Bool {
        guard let required = try? UpdateSystemVersion(string) else { return false }
        let current = ProcessInfo.processInfo.operatingSystemVersion
        guard let system = try? UpdateSystemVersion("\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)") else { return false }
        return required <= system
    }

    private static func signingInformation(_ url: URL) throws -> (team: String?, adHoc: Bool) {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { throw Failure.invalid("无法读取应用代码签名。") }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String, flags & SecCodeSignatureFlags.adhoc.rawValue != 0)
    }

    private static func validateCodeSignature(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw Failure.invalid("新版应用代码签名无效，请手动下载更新。")
        }
    }

    private static func validateTree(_ root: URL) throws {
        try validateNoLinks(root)
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid("应用包不是目录。") }
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in traversalFailed = true; return false }) else { throw Failure.invalid("无法读取应用包。") }
        var expanded: Int64 = 0
        for case let url as URL in enumerator {
            guard lstat(url.path, &value) == 0 else { throw Failure.invalid("无法检查更新文件。") }
            let kind = value.st_mode & S_IFMT
            guard kind == S_IFDIR || (kind == S_IFREG && value.st_nlink == 1) else {
                throw Failure.invalid("更新应用包含不支持的链接或特殊文件。")
            }
            if kind == S_IFREG {
                guard value.st_size >= 0, value.st_size <= maximumArchiveSize * 8 - expanded else {
                    throw Failure.invalid("解压后的更新应用过大。")
                }
                expanded += value.st_size
            }
        }
        guard !traversalFailed else { throw Failure.invalid("无法完整检查更新应用。") }
    }

    private static func validateNoLinks(_ url: URL) throws {
        // URL parent operations can rewrite /private/var back to its /var alias.
        // Walk lexical path strings after resolving trusted system-created roots.
        var cursor = url.path
        var value = stat()
        while cursor != "/" {
            guard lstat(cursor, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else {
                throw Failure.invalid("更新路径包含链接或不存在。")
            }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
    }

    private static func canonicalSystemLocation(_ url: URL) -> URL {
        // Cocoa deliberately preserves the /var and /tmp aliases; realpath also
        // resolves those system roots before strict link checks inspect ancestors.
        var path = url.path
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: path), path != "/" {
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(path, nil) else { return url }
        defer { free(resolved) }
        return suffix.reversed().reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appendingPathComponent($1) }
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try validateNoLinks(url)
        guard chmod(url.path, 0o700) == 0 else { throw Failure.invalid("无法保护更新目录。") }
        try validatePrivate(url, directory: true)
    }

    private static func validatePrivate(_ url: URL, directory: Bool) throws {
        try validateNoLinks(url)
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == getuid(),
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_mode & 0o077 == 0, directory || value.st_nlink == 1 else { throw Failure.invalid("更新文件权限不安全。") }
    }

    private static func writePrivate<T: Encodable>(_ value: T, to url: URL) throws {
        try writePrivate(JSONEncoder().encode(value), to: url)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try validatePrivate(url.deletingLastPathComponent(), directory: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".update-write-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid("无法写入安装计划。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try renameItem(temporary, url)
    }

    private static func readPrivate<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try validateNoLinks(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.invalid("无法读取安装计划。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0, value.st_nlink == 1, value.st_size <= 16_384,
              let data = try handle.read(upToCount: 16_385), data.count <= 16_384 else {
            throw Failure.invalid("安装计划过大或文件权限不安全。")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func renameItem(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            if errno == EPERM || errno == EACCES {
                throw Failure.invalid("macOS 拒绝替换应用。请在“系统设置 > 隐私与安全性 > App 管理”中允许 QuietDesk，或手动安装。")
            }
            throw Failure.invalid("无法替换应用；旧版备份将保留。")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.invalid("系统更新工具执行失败，请手动安装。") }
    }

    private static func removeQuarantine(_ root: URL) throws {
        let entries = [root] + ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
        for url in entries {
            if removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
                throw Failure.invalid("无法清除更新包隔离属性，请手动安装。")
            }
        }
    }

    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !busy, pendingInstallation == nil else { throw Failure.busy }
        busy = true
        cancelled = false
    }
    private func end() { lock.lock(); busy = false; transfer = nil; lock.unlock() }
    private func setTransfer(_ value: ArchiveTransfer) { lock.lock(); transfer = value; lock.unlock() }
    private func startInstaller(_ child: Process, planURL: URL, readyURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        // Register under the same lock used by shutdown, including process.run:
        // quitting before the readiness file arrives must still stop this child.
        try child.run()
        pendingInstallation = (child, planURL, readyURL)
    }
    private func confirmPending(_ child: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !Task.isCancelled, pendingInstallation?.process === child else { throw CancellationError() }
    }
    private func clearPending(_ child: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pendingInstallation?.process === child else { return false }
        pendingInstallation = nil
        return true
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }
}

// A data delegate writes and hashes each received chunk once, without holding the ZIP
// in memory. Bytes, cancellation and the size limit follow the actual response stream.
private final class ArchiveTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectation: UpdateInstaller.Expectation
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var total: Int64?
    private var stopped = false
    private var failure: Error?

    init(expectation: UpdateInstaller.Expectation, destination: URL,
         progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.expectation = expectation; self.destination = destination; self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                self.continuation = nil; lock.unlock()
                continuation.resume(throwing: UpdateInstaller.Failure.invalid("无法创建更新下载文件。")); return
            }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 300
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: expectation.archiveURL)
            request.setValue("QuietDesk/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request); self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() { lock.lock(); stopped = true; let task = task; lock.unlock(); task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, UpdateURLPolicy.allowsRedirect(to: url, bundleIdentifier: expectation.bundleIdentifier,
                                                                   allowLoopbackForTesting: true) else {
            failure = UpdateInstaller.Failure.invalid("更新下载被重定向到不安全地址。")
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= expectation.archiveSize else {
            failure = UpdateInstaller.Failure.invalid("更新下载失败或大小不符。")
            completionHandler(.cancel); return
        }
        total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        progress(0, total)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= expectation.archiveSize else {
            failure = UpdateInstaller.Failure.invalid("更新下载超过清单声明大小。")
            dataTask.cancel(); return
        }
        do { try file?.write(contentsOf: data); hasher.update(data: data); progress(received, total) }
        catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close(); file = nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let cancelled = stopped
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if cancelled || (error as? URLError)?.code == .cancelled && failure == nil { continuation?.resume(throwing: CancellationError()) }
        else if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if received != expectation.archiveSize || digest != expectation.sha256 {
            continuation?.resume(throwing: UpdateInstaller.Failure.invalid("更新下载的大小或 SHA-256 校验失败。"))
        } else { continuation?.resume() }
    }
}
