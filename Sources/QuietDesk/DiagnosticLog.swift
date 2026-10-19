import Foundation
import Darwin
import QuietDeskCore

final class DiagnosticLog: @unchecked Sendable {
    enum Event: String, Codable {
        case applicationStarted, applicationStopped
        case connectionStarted, connectionReady, connectionClosed, connectionFailed, connectionMetrics, reconnectScheduled, inputFailed
        case hostStarted, hostStopped, captureStarted, captureStopped, captureFailed
        case streamConfigured, displayChanged, sessionPaused, sessionResumed, sessionEffectsChanged
        case clipboardOffered, clipboardOfferReceived, clipboardAccepted, clipboardRejected
        case clipboardCompleted, clipboardFailed, clipboardEchoSuppressed
        case permissionChanged, exportRequested, exportCompleted, exportFailed, counters
        case performanceDiagnosticsChanged, performanceWindow
        case relayRegistration, mediaRouteChanged
        case updateCheck, updatePreferenceChanged, updateDownload, updateInstall, updateCancelled
    }
    enum Role: String, Codable { case viewer, host }
    enum State: String, Codable {
        case requested, ready, succeeded, failed, cancelled, enabled, disabled
        case accepted, rejected, local, remote
    }
    enum Field: String {
        case width, height, logicalWidth, logicalHeight, pixelWidth, pixelHeight
        case fps, targetBitrate, roundTripMicroseconds, fileCount, totalBytes, statusCode
        case payloadType, accessibilityGranted, inputMonitoringGranted, screenRecordingGranted
        case eventCount, scrollObserved, scrollSent, scrollReceived, scrollSuppressed, entriesDropped
        case pendingBytes, retryAttempt, maximumDimension
        case tcpAckStretchingDisabled
        case relayControl, relayVideo, videoPath
    }
    enum Counter: String {
        case scrollObserved, scrollSent, scrollReceived, scrollSuppressed
    }
    enum Failure: LocalizedError {
        case storageUnavailable, exportFailed, unsafeDestination
        var errorDescription: String? {
            switch self {
            case .storageUnavailable: return "本地诊断日志无法写入，请检查可用空间和文件访问权限。"
            case .exportFailed: return "日志导出失败，请更换保存位置并检查可用空间和文件访问权限。"
            case .unsafeDestination: return "请选择日志目录以外的普通文件作为导出位置。"
            }
        }
    }

    static let shared = DiagnosticLog(directory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/\(AppDataLocation.folderName())", isDirectory: true))

    private struct SafeError: Codable {
        let domain: String
        let code: Int
        init(_ error: Error) {
            let value = error as NSError
            let domains = [NSCocoaErrorDomain: "cocoa", NSPOSIXErrorDomain: "posix", NSOSStatusErrorDomain: "osStatus",
                           NSURLErrorDomain: "url", "NWErrorDomain": "network", "AVFoundationErrorDomain": "avFoundation"]
            domain = domains[value.domain] ?? "other"
            code = value.code
        }
    }
    private struct Metadata: Codable {
        let appVersion: String
        let appBuild: String
        let buildRevision: String?
        let macOS: String
        let architecture: String
        init() {
            func version(_ key: String) -> String {
                let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
                guard value.utf8.count <= 32, value.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0)
                }) else { return "unknown" }
                return value
            }
            appVersion = version("CFBundleShortVersionString")
            appBuild = version("CFBundleVersion")
            if let revision = Bundle.main.object(forInfoDictionaryKey: "QuietDeskBuildRevision") as? String,
               (7...40).contains(revision.utf8.count), revision.utf8.allSatisfy({
                   (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
               }) { buildRevision = revision }
            else { buildRevision = nil }
            let system = ProcessInfo.processInfo.operatingSystemVersion
            macOS = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            #if arch(arm64)
            architecture = "arm64"
            #elseif arch(x86_64)
            architecture = "x86_64"
            #else
            architecture = "other"
            #endif
        }
    }
    private struct Entry: Codable {
        let timestamp: Date
        let event: Event
        var role: Role?
        var state: State?
        var values: [String: Int]?
        var error: SafeError?
        var environment: Metadata?
        var performance: PerformanceSummary?
        var connectionID: Int?
    }

    private let directory: URL
    private let maximumFileBytes: Int
    private let retainedFileCount: Int
    private let pendingLimit: Int
    private let queue = DispatchQueue(label: "quietdesk.diagnostic-log", qos: .utility)
    private let lock = NSLock()
    private var pendingEntries = 0
    private var droppedEntries = 0
    private var counts: [Counter: Int] = [:]
    private var timer: DispatchSourceTimer?
    private var failure: Failure?
    private let encoder: JSONEncoder

    init(directory: URL, maximumFileBytes: Int = 1_048_576, retainedFileCount: Int = 4,
         pendingLimit: Int = 256, counterInterval: TimeInterval = 10) {
        self.directory = directory.standardizedFileURL
        self.maximumFileBytes = min(1_048_576, max(512, maximumFileBytes))
        self.retainedFileCount = min(4, max(1, retainedFileCount))
        self.pendingLimit = max(1, min(256, pendingLimit))
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0.05, counterInterval), repeating: max(0.05, counterInterval))
        timer.setEventHandler { [weak self] in self?.flushCounters() }
        self.timer = timer
        timer.resume()
    }

    // Only enumerated events, numeric measurements and sanitized error codes may enter the log.
    func record(_ event: Event, role: Role? = nil, state: State? = nil,
                values: [Field: Int] = [:], error: Error? = nil) {
        enqueue(Entry(timestamp: Date(), event: event, role: role, state: state,
                      values: values.isEmpty ? nil : Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
                      error: error.map(SafeError.init), environment: event == .applicationStarted ? Metadata() : nil))
    }

    func recordPerformance(_ summary: PerformanceSummary, role: Role, connectionID: Int) {
        enqueue(Entry(timestamp: Date(), event: .performanceWindow, role: role,
                      performance: summary, connectionID: connectionID))
    }

    private func enqueue(_ entry: Entry) {
        lock.lock()
        guard pendingEntries < pendingLimit else {
            droppedEntries = min(Int.max - 1, droppedEntries) + 1
            lock.unlock()
            return
        }
        pendingEntries += 1
        lock.unlock()
        queue.async { [self] in
            append(entry)
            lock.lock(); pendingEntries -= 1; lock.unlock()
        }
    }

    // High-frequency input is aggregated without queueing one write for every event.
    func count(_ counter: Counter, amount: Int = 1) {
        guard amount > 0 else { return }
        lock.lock()
        let old = counts[counter] ?? 0
        counts[counter] = old > Int.max - amount ? Int.max : old + amount
        lock.unlock()
    }

    @discardableResult func flush() -> Failure? {
        queue.sync { flushCounters(); return failure }
    }

    func export(to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try validateDestination(destination)
                    flushCounters()
                    append(Entry(timestamp: Date(), event: .exportRequested))
                    if let failure { throw failure }
                    try prepareDirectory()
                    let header = Entry(timestamp: Date(), event: .exportCompleted, environment: Metadata())
                    var data = try encoder.encode(header); data.append(0x0A)
                    try withLogLock { _ in
                        for index in (0..<retainedFileCount).reversed() {
                            let source = file(index)
                            guard try regularFileSize(source) != nil else { continue }
                            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                            guard descriptor >= 0 else { throw Failure.exportFailed }
                            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                            defer { try? handle.close() }
                            var info = stat()
                            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.exportFailed }
                            let oversized = info.st_size > maximumFileBytes
                            if oversized { try handle.seek(toOffset: UInt64(info.st_size - off_t(maximumFileBytes))) }
                            var tail = try handle.read(upToCount: maximumFileBytes) ?? Data()
                            if oversized {
                                if let newline = tail.firstIndex(of: 0x0A) { tail.removeSubrange(...newline) }
                                else { tail.removeAll() }
                            }
                            data.append(tail)
                        }
                    }
                    try data.write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    continuation.resume()
                } catch let error as Failure { continuation.resume(throwing: error) }
                catch { continuation.resume(throwing: Failure.exportFailed) }
            }
        }
    }

    private func flushCounters() {
        lock.lock()
        var values = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
        counts.removeAll(keepingCapacity: true)
        if droppedEntries > 0 { values[Field.entriesDropped.rawValue] = droppedEntries; droppedEntries = 0 }
        lock.unlock()
        if !values.isEmpty { append(Entry(timestamp: Date(), event: .counters, values: values)) }
    }

    private func append(_ entry: Entry) {
        do {
            var data = try encoder.encode(entry); data.append(0x0A)
            guard data.count <= maximumFileBytes else { throw Failure.storageUnavailable }
            try prepareDirectory()
            try withLogLock { locked in
                if locked, let size = try regularFileSize(file(0)), size > maximumFileBytes - data.count { try rotate() }
                let descriptor = open(file(0).path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
                guard descriptor >= 0 else { throw Failure.storageUnavailable }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      fchmod(descriptor, mode_t(0o600)) == 0 else { throw Failure.storageUnavailable }
                try handle.write(contentsOf: data)
            }
            failure = nil
        } catch { failure = .storageUnavailable }
    }

    private func withLogLock<T>(_ body: (Bool) throws -> T) rethrows -> T {
        let descriptor = open(directory.appendingPathComponent(".quietdesk-log.lock").path,
                              O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { return try body(false) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else { return try body(false) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { return try body(false) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(true)
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "quietdesk-current.jsonl" : "quietdesk-\(index).jsonl")
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.storageUnavailable }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func regularFileSize(_ url: URL) throws -> Int? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.storageUnavailable }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return size
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    private func rotate() throws {
        let manager = FileManager.default
        let oldest = file(retainedFileCount - 1)
        if try regularFileSize(oldest) != nil { try manager.removeItem(at: oldest) }
        guard retainedFileCount > 1 else { return }
        for index in stride(from: retainedFileCount - 2, through: 0, by: -1) {
            let source = file(index)
            if try regularFileSize(source) != nil { try manager.moveItem(at: source, to: file(index + 1)) }
        }
    }

    private func validateDestination(_ destination: URL) throws {
        let target = destination.standardizedFileURL
        let resolved = target.resolvingSymlinksInPath().path
        let logPath = directory.resolvingSymlinksInPath().path
        guard target.isFileURL, resolved != logPath, !resolved.hasPrefix(logPath + "/") else { throw Failure.unsafeDestination }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw Failure.unsafeDestination }
    }

    deinit { timer?.cancel() }
}
