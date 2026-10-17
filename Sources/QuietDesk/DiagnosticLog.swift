import Foundation

final class DiagnosticLog: @unchecked Sendable {
    enum Event: String, Codable {
        case applicationStarted, applicationStopped
        case connectionStarted, connectionReady, connectionClosed, connectionFailed, connectionMetrics, reconnectScheduled, inputFailed
        case hostStarted, hostStopped, captureStarted, captureStopped, captureFailed
        case streamConfigured, displayChanged, sessionPaused, sessionResumed, sessionEffectsChanged
        case clipboardOffered, clipboardOfferReceived, clipboardAccepted, clipboardRejected
        case clipboardCompleted, clipboardCancelled, clipboardFailed, clipboardEchoSuppressed
        case permissionChanged, exportRequested, exportCompleted, exportFailed, counters
    }
    enum Role: String, Codable { case viewer, host }
    enum State: String, Codable {
        case requested, ready, succeeded, failed, cancelled, enabled, disabled, retryable, permanent
        case accepted, rejected, local, remote
    }
    enum Field: String {
        case width, height, logicalWidth, logicalHeight, pixelWidth, pixelHeight
        case fps, targetBitrate, roundTripMicroseconds, fileCount, totalBytes, statusCode
        case payloadType, accessibilityGranted, inputMonitoringGranted, screenRecordingGranted
        case eventCount, scrollObserved, scrollSent, scrollReceived, scrollSuppressed, entriesDropped
        case pendingBytes, scaleTimes1000, retryAttempt, maximumDimension
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
        .appendingPathComponent("Logs/QuietDesk", isDirectory: true))

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
        lock.lock()
        guard pendingEntries < pendingLimit else {
            droppedEntries = min(Int.max - 1, droppedEntries) + 1
            lock.unlock()
            return
        }
        pendingEntries += 1
        lock.unlock()
        let entry = Entry(timestamp: Date(), event: event, role: role, state: state,
                          values: values.isEmpty ? nil : Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
                          error: error.map(SafeError.init), environment: event == .applicationStarted ? Metadata() : nil)
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
                    for index in (0..<retainedFileCount).reversed() {
                        let source = file(index)
                        guard try regularFileSize(source) != nil else { continue }
                        data.append(try Data(contentsOf: source, options: .mappedIfSafe))
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
            if let size = try regularFileSize(file(0)), size + data.count > maximumFileBytes { try rotate() }
            if try regularFileSize(file(0)) == nil {
                guard FileManager.default.createFile(atPath: file(0).path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw Failure.storageUnavailable
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(0).path)
            let handle = try FileHandle(forWritingTo: file(0))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            failure = nil
        } catch { failure = .storageUnavailable }
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
            guard size <= maximumFileBytes else { throw Failure.storageUnavailable }
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
