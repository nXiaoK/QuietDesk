import AppKit
import QuietDeskCore

private struct FocusCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FocusCheckFailure(message) }
}

@MainActor
private func pump(for seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
}

@MainActor
private func eventually(_ message: String, seconds: TimeInterval = 5, _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { pump(for: 0.01) }
    try require(condition(), message)
}

private final class ChannelSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.withLock { value } }
    func set(_ next: T) { lock.withLock { value = next } }
}

private extension ChannelSafeBox where T == [MessageKind] {
    func append(_ kind: MessageKind) { lock.withLock { value.append(kind) } }
    func snapshot() -> [MessageKind] { lock.withLock { value } }
}

private final class ImageConversionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var background = false
    private var began = false
    let release = DispatchSemaphore(value: 0)
    var state: (began: Bool, background: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (began, background)
    }
    func convert(_ data: Data) -> Data? {
        lock.lock(); began = true; background = !Thread.isMainThread; lock.unlock()
        _ = release.wait(timeout: .now() + 5)
        return data
    }
}

@MainActor
private final class MemoryPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var payload: ClipboardPayload = .text(Data())
    private var marker: String?
    var rejectsWrites = false
    var isRelayedFromOtherDevice = false
    var isSensitive = false
    var rawTIFF: Data?
    private(set) var hasLazyItem = false
    private(set) var lazyKind: ClipboardManifestKind?
    private var lazyAsyncFetch: (@MainActor (@escaping (ClipboardPayload?) -> Void) -> Void)?
    var tiffData: Data? { reads += 1; return rawTIFF }

    var fileURLs: [URL]? {
        reads += 1
        if case .files(let urls) = payload { return urls }
        return nil
    }
    var pngData: Data? {
        reads += 1
        if case .png(let data) = payload { return data }
        return nil
    }
    var text: String? {
        reads += 1
        if case .text(let data) = payload { return String(data: data, encoding: .utf8) }
        return nil
    }
    var contentMarker: String? { reads += 1; return marker }

    func inspectCurrentKind() -> ClipboardManifestKind? {
        if hasLazyItem { return lazyKind }
        if rawTIFF != nil { return .png }
        switch payload {
        case .files(let urls): return urls.isEmpty ? nil : .files
        case .png: return .png
        case .text: return .text
        }
    }

    func copy(_ payload: ClipboardPayload) {
        self.payload = payload; rawTIFF = nil; marker = nil
        hasLazyItem = false; lazyKind = nil; lazyAsyncFetch = nil
        changeCount += 1
    }

    func discardFilePromise(marker: String) {
        guard hasLazyItem, lazyKind == .files, self.marker == marker else { return }
        copy(.files([]))
    }

    /// What installing a Finder paste fails with, as on a Mac that cannot watch Finder.
    var finderFilesError: Error?
    var providesPromisedFiles = false
    private(set) var promisedCount: Int?
    private var promisedRequest: (@MainActor () -> Bool)?

    func writeFinderFiles(names: [String], marker: String, onFailure: @escaping @MainActor (String) -> Void,
                          request: @escaping @MainActor () -> Bool) throws -> ClipboardFilePromise? {
        if let finderFilesError { throw finderFilesError }
        return nil
    }

    func writePromisedFiles(count: Int, marker: String, request: @escaping @MainActor () -> Bool) -> ClipboardFilePromise? {
        guard providesPromisedFiles, !rejectsWrites else { return nil }
        payload = .text(Data()); rawTIFF = nil; self.marker = marker
        hasLazyItem = true; lazyKind = .files; lazyAsyncFetch = nil
        promisedCount = count; promisedRequest = request
        changeCount += 1; writes += 1
        return ClipboardFilePromise(count: count, request: request)
    }

    /// What reading one of the promised file URLs starts.
    func readPromisedFiles() -> Bool { promisedRequest?() ?? false }

    func republish() {
        marker = nil
        hasLazyItem = false; lazyKind = nil; lazyAsyncFetch = nil
        changeCount += 1
    }

    func write(_ payload: ClipboardPayload, marker: String) -> Bool {
        guard !rejectsWrites else { return false }
        self.payload = payload; rawTIFF = nil; self.marker = marker
        hasLazyItem = false; lazyKind = nil; lazyAsyncFetch = nil
        changeCount += 1; writes += 1
        return true
    }

    func writeLazy(
        _ kind: ClipboardManifestKind,
        marker: String,
        fetch: @escaping @MainActor () -> ClipboardPayload?,
        asyncFetch: @escaping @MainActor (@escaping (ClipboardPayload?) -> Void) -> Void
    ) -> Bool {
        guard !rejectsWrites else { return false }
        self.payload = .text(Data())
        self.rawTIFF = nil
        self.marker = marker
        self.hasLazyItem = true
        self.lazyKind = kind
        self.lazyAsyncFetch = asyncFetch
        changeCount += 1
        writes += 1
        return true
    }

    @discardableResult
    func simulatePaste() -> ClipboardPayload? {
        if hasLazyItem, let fetch = lazyAsyncFetch {
            var resolved: ClipboardPayload?
            var finished = false
            fetch { result in
                resolved = result
                finished = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !finished, Date() < deadline {
                pump(for: 0.01)
            }
            if let resolved {
                self.payload = resolved
                self.hasLazyItem = false
                self.lazyAsyncFetch = nil
            }
            return resolved
        }
        return payload
    }

    var copiedText: String? {
        guard !hasLazyItem else { return nil }
        if case .text(let data) = payload { return String(data: data, encoding: .utf8) }
        return nil
    }
}

@MainActor
private final class ClipboardPair {
    let local = MemoryPasteboard()
    let remote = MemoryPasteboard()
    private(set) var localSync: ClipboardSync!
    private(set) var remoteSync: ClipboardSync!
    private(set) var localMessages: [MessageKind] = []
    private(set) var remoteMessages: [MessageKind] = []
    var routeLocal: ((Message) -> Bool)?
    var routeRemote: ((Message) -> Bool)?

    init(storage: URL, localAllowed: Bool = false, remoteAllowed: Bool = false, controllingLocal: Bool = false,
         allowsChunkWindow: Bool = false, allowsDecoupledFileTransfer: Bool = false,
         allowsOnDemandClipboard: Bool = false, deferLocalFileOffer: Bool = false, allowsPhysicalFilePaste: Bool = false,
         convertLocalTIFF: @escaping (Data) -> Data? = { data in NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) },
         validateRemotePNG: ((Data) -> Bool)? = nil) {
        let session = UUID()
        localSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: localAllowed,
            allowsChunkWindow: allowsChunkWindow, allowsDecoupledFileTransfer: allowsDecoupledFileTransfer,
            allowsOnDemandClipboard: allowsOnDemandClipboard, deferFileOfferUntilPaste: deferLocalFileOffer, allowsPhysicalFilePaste: allowsPhysicalFilePaste,
            controllingRemote: controllingLocal, pasteboard: local, storage: storage.appendingPathComponent("local"),
            convertTIFF: convertLocalTIFF) { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.localMessages.append(message.kind)
                    if self.routeLocal?(message) != false { self.remoteSync.receive(message) }
                }
            }
        remoteSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: remoteAllowed,
            allowsChunkWindow: allowsChunkWindow, allowsDecoupledFileTransfer: allowsDecoupledFileTransfer,
            allowsOnDemandClipboard: allowsOnDemandClipboard, deferFileOfferUntilPaste: false, allowsPhysicalFilePaste: allowsPhysicalFilePaste,
            pasteboard: remote, storage: storage.appendingPathComponent("remote"), validatePNG: validateRemotePNG) { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.remoteMessages.append(message.kind)
                    if self.routeRemote?(message) != false { self.localSync.receive(message) }
                }
            }
    }

    func stop() {
        routeLocal = nil; routeRemote = nil
        localSync.onFileOffer = nil; remoteSync.onFileOffer = nil
        localSync.stop(); remoteSync.stop()
        pump(for: 0.04)
    }
}

@MainActor
private final class FileApprovalAction: NSObject {
    private let approve: () -> Void
    init(_ approve: @escaping () -> Void) { self.approve = approve }
    @objc func click(_ sender: NSButton) { approve() }
}

private let filePasteBoardPrefix = "local.quietdesk.checks.file-paste."

@MainActor
private func copyPromisedFiles(boardName: String, destination: URL) throws {
    guard boardName.hasPrefix(filePasteBoardPrefix), UUID(uuidString: String(boardName.dropFirst(filePasteBoardPrefix.count))) != nil else {
        throw FocusCheckFailure("Expected an isolated named pasteboard")
    }
    let board = NSPasteboard(name: NSPasteboard.Name(boardName))
    let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    for url in urls {
        try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
    }
}

@main
private struct ClipboardFocusChecks {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--copy-file-urls" {
            do { try copyPromisedFiles(boardName: arguments[2], destination: URL(fileURLWithPath: arguments[3])) }
            catch { print("FAIL isolated paste consumer: \(error)"); exit(1) }
            return
        }
        var passed = 0, failed = 0
        func run(_ name: String, _ body: (URL) throws -> Void) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-focus-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                try body(folder)
                passed += 1; print("PASS \(name)")
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Overlapping background Finder reads cannot copy or prematurely restore promised names") { folder in
            let url = folder.appendingPathComponent("document")
            let original = Data("original stub".utf8)
            try original.write(to: url)
            let failed = ChannelSafeBox(false)
            let root = PromisedFinderRoot(url: url, queue: OperationQueue(), failed: { failed.set(true) }, provide: { false })
            let first = ChannelSafeBox<(@Sendable () -> Void)?>(nil)
            let second = ChannelSafeBox<(@Sendable () -> Void)?>(nil)
            root.relinquishPresentedItem(toReader: { first.set($0) })
            root.relinquishPresentedItem(toReader: { second.set($0) })
            try require(!FileManager.default.fileExists(atPath: url.path), "A background reader could copy the stub")
            first.read()?()
            try require(!FileManager.default.fileExists(atPath: url.path), "The first reader restored the stub too soon")
            second.read()?()
            try require(try Data(contentsOf: url) == original && !failed.read(), "The last reader did not restore the original")
        }

        run("Finishing background Finder reads preserves hydrated files and cancellation") { folder in
            let url = folder.appendingPathComponent("document")
            let received = Data("received bytes".utf8)
            try Data().write(to: url)
            let failed = ChannelSafeBox(false), allowed = ChannelSafeBox(false)
            let root = PromisedFinderRoot(url: url, queue: OperationQueue(), failed: { failed.set(true) }, provide: { allowed.read() })
            let restore = ChannelSafeBox<(@Sendable () -> Void)?>(nil)
            root.relinquishPresentedItem(toReader: { restore.set($0) })
            try received.write(to: url)
            restore.read()?()
            allowed.set(true)
            root.relinquishPresentedItem(toReader: { restore.set($0) })
            try require(restore.read() == nil && (try Data(contentsOf: url)) == received, "Restoring a stub displaced received bytes")
            allowed.set(false)
            root.relinquishPresentedItem(toReader: { restore.set($0) })
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: item)
            }
            restore.read()?()
            try require(!FileManager.default.fileExists(atPath: url.path) && !failed.read(), "A late reader resurrected cancelled files")
        }

        run("A Finder-capable peer without file names preserves the clipboard and asks for a fresh copy") { folder in
            let board = MemoryPasteboard()
            board.copy(.text(Data("keep this copy".utf8)))
            let messages = ChannelSafeBox<[MessageKind]>([])
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                     allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true, usesFinderFilePaste: true,
                                     pasteboard: board, storage: folder) { messages.append($0.kind) }
            defer { sync.stop() }
            var status = ""
            sync.onStatus = { status = $0 }
            let manifest = ClipboardManifest(revision: ClipboardRevision(counter: 1, origin: UUID()), kind: .files, fileRootCount: 1)
            sync.receive(try Wire.json(.clipboardManifest, manifest))
            try eventually("The failure was not reported to the receiver") { status.contains("重新复制") }
            try require(board.copiedText == "keep this copy" && board.writes == 0 && !messages.snapshot().contains(.clipboardPull),
                        "Missing names displaced the local clipboard or triggered a file request")
        }

        run("A Mac that cannot watch Finder still offers the copied files and requests them when they are read") { folder in
            let board = MemoryPasteboard()
            board.copy(.text(Data("an earlier local copy".utf8)))
            board.finderFilesError = FinderPasteUnavailable(reason: "辅助功能权限未生效")
            board.providesPromisedFiles = true
            let messages = ChannelSafeBox<[MessageKind]>([])
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                     allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true, usesFinderFilePaste: true,
                                     pasteboard: board, storage: folder) { messages.append($0.kind) }
            defer { sync.stop() }
            var status = ""
            sync.onStatus = { status = $0 }
            let manifest = ClipboardManifest(revision: ClipboardRevision(counter: 1, origin: UUID()), kind: .files,
                                             fileRootCount: 2, fileRootNames: ["报告.txt", "资料"])
            sync.receive(try Wire.json(.clipboardManifest, manifest))
            try eventually("The copied files were not offered on the pasteboard") { board.promisedCount == 2 }
            try require(board.inspectCurrentKind() == .files && status.contains("辅助功能权限未生效") && !status.contains("重新复制"),
                        "The receiver was not told why the files arrive on a pasteboard read: \(status)")
            pump(for: 0.2)
            try require(!messages.snapshot().contains(.clipboardPull), "Files were requested before anything read the pasteboard")
            try require(board.readPromisedFiles(), "Reading the offered files did not start a request")
            try eventually("The files were not requested from the peer") { messages.snapshot().contains(.clipboardPull) }
        }

        run("A Finder paste that cannot be watched reports why and leaves no placeholder files behind") { _ in
            let name = "quietdesk-check-\(UUID().uuidString).txt"
            let temporary = FileManager.default.temporaryDirectory
            func placeholders() -> [URL] {
                ((try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("QuietDesk-") && FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
            }
            do {
                _ = try FinderClipboardPaste(names: [name], promise: ClipboardFilePromise(count: 1) { false }, isTrusted: { false })
                throw FocusCheckFailure("A Finder paste was offered although Finder cannot be watched")
            } catch let unavailable as FinderPasteUnavailable {
                try require(unavailable.reason.contains("辅助功能"), "The reason does not name the missing permission: \(unavailable.reason)")
            }
            try require(placeholders().isEmpty, "A placeholder file stayed in the temporary folder")
            // A name that cannot be a single file is refused before anything is watched, whatever the permission.
            do {
                _ = try FinderClipboardPaste(names: ["a/b"], promise: ClipboardFilePromise(count: 1) { false }, isTrusted: { false })
                throw FocusCheckFailure("An invalid file name was accepted")
            } catch is DeskError {}
        }

        run("Non-Finder reads of Finder paste placeholders never receive empty files") { folder in
            final class SyntheticFinderWatcher: FinderPasteWatching {
                func stop() {}
            }
            var finishPromise: ClipboardFilePromise?
            let promise = ClipboardFilePromise(count: 2) {
                DispatchQueue.global().async {
                    guard let promise = finishPromise else { return }
                    let srcFile = folder.appendingPathComponent("src/report.txt")
                    let srcDir = folder.appendingPathComponent("src/bundle")
                    let srcNested = srcDir.appendingPathComponent("inner.bin")
                    try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
                    try? Data("full-payload".utf8).write(to: srcFile)
                    try? FileManager.default.setAttributes([
                        .posixPermissions: 0o750,
                        .modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    ], ofItemAtPath: srcFile.path)
                    try? Data([1, 2, 3, 4, 5]).write(to: srcNested)
                    promise.finish([srcFile, srcDir])
                }
                return true
            }
            finishPromise = promise
            let offered = try FinderClipboardPaste(
                names: ["report.txt", "bundle"],
                promise: promise,
                isTrusted: { true },
                watchPaste: { _ in SyntheticFinderWatcher() }
            )
            defer { offered.stop() }
            let stubURL = offered.urls[0]

            let board = NSPasteboard(name: NSPasteboard.Name(filePasteBoardPrefix + UUID().uuidString))
            defer { board.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setString(stubURL.absoluteString, forType: .fileURL)
            board.prepareForNewContents(with: .currentHostOnly)
            try require(board.writeObjects([item]), "Failed writing placeholder URL to isolated pasteboard")

            // (a) Uncoordinated Data(contentsOf:) / open(2)
            var directDesc = ""
            var directSucceeded = false
            do {
                let d = try Data(contentsOf: stubURL)
                directSucceeded = true
                directDesc = "returned \(d.count) bytes"
            } catch {
                directDesc = "error \(error)"
            }
            let fd = Darwin.open(stubURL.path, O_RDONLY)
            let openErrno = fd >= 0 ? 0 : errno
            if fd >= 0 { Darwin.close(fd) }
            print("  (a) direct: \(directDesc), open(O_RDONLY) fd=\(fd) errno=\(openErrno)")

            // (b) Coordinated read without Finder paste intent
            var coordErr: NSError?
            var coordInnerDesc = "block-not-called"
            var coordInnerFailed = false
            var coordSucceededEmpty = false
            NSFileCoordinator().coordinate(readingItemAt: stubURL, options: [], error: &coordErr) { url in
                do {
                    let d = try Data(contentsOf: url)
                    coordInnerDesc = "returned \(d.count) bytes"
                    if d.isEmpty { coordSucceededEmpty = true }
                } catch {
                    coordInnerFailed = true
                    coordInnerDesc = "inner error \(error)"
                }
            }
            print("  (b) NSFileCoordinator: coordErr=\(String(describing: coordErr)), inner=\(coordInnerDesc)")
            var afterCoordFd: Int32 = -1
            var afterCoordErrno: Int32 = 0
            try eventually("Coordinator reacquire did not restore unreadable placeholder") {
                afterCoordFd = Darwin.open(stubURL.path, O_RDONLY)
                afterCoordErrno = afterCoordFd >= 0 ? 0 : errno
                if afterCoordFd >= 0 { Darwin.close(afterCoordFd); return true }
                return afterCoordErrno == EACCES
            }

            // (c) NSPasteboard.readObjects([NSURL.self]) followed by read
            let readURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(readURLs.count == 1, "Expected 1 URL from readObjects, got \(readURLs.count)")
            var pbDesc = ""
            var pbSucceeded = false
            do {
                let d = try Data(contentsOf: readURLs[0])
                pbSucceeded = true
                pbDesc = "returned \(d.count) bytes"
            } catch {
                pbDesc = "error \(error)"
            }
            print("  (c) readObjects+read: \(pbDesc)")

            try require(!directSucceeded && fd < 0 && openErrno == EACCES, "Uncoordinated read did not fail with EACCES: \(directDesc), fd=\(fd), errno=\(openErrno)")
            try require(!coordSucceededEmpty && (coordErr != nil || coordInnerFailed) && afterCoordFd < 0 && afterCoordErrno == EACCES,
                        "Coordinated non-Finder read succeeded or restored a readable stub: inner=\(coordInnerDesc) afterFd=\(afterCoordFd) afterErrno=\(afterCoordErrno)")
            try require(!pbSucceeded, "Pasteboard readObjects URL read succeeded instead of failing: \(pbDesc)")

            // Verify Finder coordinated read after paste intent materializes both file and folder, preserving mode & mtime.
            // Run NSFileCoordinator off the main thread just as external Finder.app does, so RunLoop.main
            // remains free to service ClipboardFilePromise's @MainActor request callback without deadlocking.
            offered.recordPaste()
            let coordOutcome = ChannelSafeBox<(done: Bool, error: String?, bytes: Data?)>((false, nil, nil))
            let targetURL = offered.urls[0]
            DispatchQueue.global(qos: .userInitiated).async {
                var coordReadError: NSError?
                var bytes: Data?
                NSFileCoordinator().coordinate(readingItemAt: targetURL, options: [], error: &coordReadError) { url in
                    bytes = try? Data(contentsOf: url)
                }
                coordOutcome.set((true, coordReadError?.description, bytes))
            }
            try eventually("Coordinated Finder read did not complete") {
                coordOutcome.read().done
            }
            let outcome = coordOutcome.read()
            try require(outcome.error == nil && outcome.bytes == Data("full-payload".utf8),
                        "Coordinated Finder read did not obtain materialized file: \(String(describing: outcome.error))")
            let attrs = try FileManager.default.attributesOfItem(atPath: offered.urls[0].path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
            let mtime = attrs[.modificationDate] as? Date
            try require(perms == 0o750 && mtime == Date(timeIntervalSince1970: 1_700_000_000),
                        "Materialized file lost permissions or mtime: perms=\(String(describing: perms)) mtime=\(String(describing: mtime))")
            try require((try? Data(contentsOf: offered.urls[1].appendingPathComponent("inner.bin"))) == Data([1, 2, 3, 4, 5]),
                        "Materialized folder stub did not preserve nested content")

            // Verify ClipboardSync + SystemClipboardPasteboard status tells users to paste into a Finder folder.
            let syncPB = NSPasteboard(name: NSPasteboard.Name(filePasteBoardPrefix + UUID().uuidString))
            defer { syncPB.releaseGlobally() }
            let sysPB = SystemClipboardPasteboard(
                pasteboard: syncPB,
                isFinderTrusted: { true },
                watchFinderPaste: { _ in SyntheticFinderWatcher() }
            )
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                     allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true, usesFinderFilePaste: true,
                                     pasteboard: sysPB, storage: folder.appendingPathComponent("sync-status")) { _ in }
            defer { sync.stop() }
            var statuses: [String] = []
            sync.onStatus = { statuses.append($0) }
            let manifest = ClipboardManifest(revision: ClipboardRevision(counter: 1, origin: UUID()), kind: .files,
                                             fileRootCount: 1, fileRootNames: ["notes.txt"])
            sync.receive(try Wire.json(.clipboardManifest, manifest))
            try eventually("ClipboardSync did not publish Finder-only paste guidance") {
                statuses.contains { $0.contains("请粘贴到 Finder 的文件夹") }
            }
            let publishedURLs = sysPB.fileURLs ?? []
            try require(publishedURLs.count == 1, "Expected 1 URL written by writeFinderFiles")
            let publishedFd = Darwin.open(publishedURLs[0].path, O_RDONLY)
            let publishedErrno = publishedFd >= 0 ? 0 : errno
            if publishedFd >= 0 { Darwin.close(publishedFd) }
            try require(publishedFd < 0 && publishedErrno == EACCES, "SystemClipboardPasteboard published a readable empty stub: errno=\(publishedErrno)")
        }

        if Array(arguments.dropFirst()) == ["--finder-roots-only"] { exit(failed == 0 ? 0 : 1) }

        run("Background copies and paste preparation never read clipboard content; foreground sends only latest") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            for payload in [ClipboardPayload.text(Data("first".utf8)), .png(Data([1, 2])),
                            .files([folder.appendingPathComponent("must-not-be-read")]), .text(Data("latest".utf8))] {
                pair.local.copy(payload)
                pump(for: 0.32)
            }
            var paste: Bool?
            pair.localSync.prepareForPaste { paste = $0 }
            try require(paste == false && pair.local.reads == 0 && pair.localMessages.isEmpty,
                        "Inactive clipboard was read, transmitted or marked paste-ready")
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Latest foreground copy did not arrive") { pair.remote.copiedText == "latest" }
            try require(pair.localMessages.filter { $0 == .clipboardBegin }.count == 1, "Queued intermediate copies were sent")
            for _ in 0..<3 {
                pair.localSync.setAutomaticSendingAllowed(false)
                pair.localSync.setAutomaticSendingAllowed(true)
            }
            pump(for: 0.35)
            try require(pair.localMessages.filter { $0 == .clipboardBegin }.count == 1, "Focus changes resent an unchanged copy")
        }

        run("A fresh identical text copy resends after declining a remote file offer") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("remote.bin")
            try Data([1, 2, 3]).write(to: file)
            var events: [ClipboardSync.DiagnosticEvent] = [], offer: ClipboardFileOffer?
            pair.localSync.onDiagnostic = { events.append($0) }
            pair.localSync.onFileOffer = { offer = $0 }
            pair.local.copy(.text(Data("hello".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Initial text did not finish synchronizing") { events.contains(.sent(.text, fileCount: 0)) }
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote file did not request approval") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: false)
            try eventually("Declined file offer did not close") { offer == nil }
            pair.local.copy(.text(Data("hello".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Fresh identical text was suppressed after a remote file offer") {
                pair.localMessages.filter { $0 == .clipboardBegin }.count == 2 && pair.remote.copiedText == "hello"
            }
            try require(pair.remote.writes == 2, "Fresh text did not replace the remote files")
        }

        run("Repeated identical text copies without a remote file offer still avoid duplicate sends") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            var events: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onDiagnostic = { events.append($0) }
            pair.local.copy(.text(Data("hello".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Initial text did not finish synchronizing") { events.contains(.sent(.text, fileCount: 0)) }
            pair.local.copy(.text(Data("hello".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.65)
            try require(pair.localMessages.filter { $0 == .clipboardBegin }.count == 1 && pair.remote.writes == 1,
                        "An identical clipboard manager rewrite was sent again")
        }

        run("Remote clipboard stays unread during control, then sends latest on release without echo") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            pair.remote.copy(.text(Data("remote first".utf8)))
            pump(for: 0.35)
            pair.remote.copy(.text(Data("remote latest".utf8)))
            pump(for: 0.35)
            try require(pair.remote.reads == 0 && pair.remoteMessages.isEmpty, "Remote copied while sending was disallowed")
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote latest copy did not arrive after release") { pair.local.copiedText == "remote latest" }
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            try require(pair.localMessages.filter { $0 == .clipboardBegin }.isEmpty, "Received clipboard echoed on focus return")
        }

        run("System-relayed files never return an offer while a fresh local copy can still send") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("relayed.bin")
            try Data([1, 2, 3]).write(to: file)
            var offer: ClipboardFileOffer?, paste: Bool?
            pair.localSync.onFileOffer = { offer = $0 }
            pair.remote.isRelayedFromOtherDevice = true
            pair.remote.copy(.files([file]))
            for _ in 0..<3 {
                pair.remoteSync.setAutomaticSendingAllowed(true)
                pair.remoteSync.setAutomaticSendingAllowed(false)
            }
            pair.remoteSync.setAutomaticSendingAllowed(true)
            pair.remoteSync.prepareForPaste { paste = $0 }
            pump(for: 0.65)
            try require(paste == false && offer == nil && !pair.remoteMessages.contains(.clipboardBegin)
                        && pair.local.writes == 0, "A system-relayed file returned an offer or became paste-ready")
            pair.remote.isRelayedFromOtherDevice = false
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("A fresh local copy was suppressed after a system-relayed file") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("The fresh local file was not published") { pair.local.writes == 1 }
        }

        run("Pasting system-relayed files keeps the relay notice and sends no messages") { folder in
            let pasteboard = MemoryPasteboard()
            var messages: [MessageKind] = [], statuses: [String] = [], paste: Bool?
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, pasteboard: pasteboard, storage: folder) {
                message in DispatchQueue.main.async { messages.append(message.kind) }
            }
            defer { sync.stop() }
            sync.onStatus = { statuses.append($0) }
            pasteboard.copy(.files([folder.appendingPathComponent("relayed.bin")]))
            pasteboard.isRelayedFromOtherDevice = true
            sync.prepareForPaste { paste = $0 }
            pump(for: 0.35)
            try require(paste == false && messages.isEmpty
                        && statuses.last == "剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传",
                        "Relay notice was overwritten, a transfer began or the paste became ready")
        }

        run("A copy made here prompts the remote once on focus; copies and pastes on the remote never resend or re-offer it") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("copied-here.bin")
            try Data([1, 2]).write(to: file)
            var offer: ClipboardFileOffer?, offers = 0, statuses: [String] = []
            pair.remoteSync.onFileOffer = { value in offer = value; if value != nil { offers += 1 } }
            pair.localSync.onStatus = { statuses.append($0) }
            pair.local.copy(.files([file]))
            pair.localSync.setControllingRemote(true)
            try eventually("A copy made before taking control did not prompt the remote") { offer != nil }
            var paste: Bool?
            try require(pair.localSync.holdsPaste, "⌘V did not wait for a file still being offered")
            pair.localSync.prepareForPaste { paste = $0 }
            try require(paste == false && statuses.last == "文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴",
                        "A file still being offered let the paste through")
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: false)
            try eventually("The declined offer did not settle") { offer == nil && !pair.localSync.holdsPaste }
            let reads = pair.local.reads
            pair.local.isRelayedFromOtherDevice = true
            pair.local.copy(.text(Data("copied on the remote and relayed here".utf8)))
            pump(for: 0.35)
            paste = nil
            pair.localSync.prepareForPaste { paste = $0 }
            try require(paste == true && !pair.localSync.holdsPaste, "A paste on the remote waited for this Mac's clipboard")
            pump(for: 0.35)
            try require(offers == 1 && pair.local.reads == reads && pair.remote.writes == 0
                        && pair.localMessages.filter { $0 == .clipboardBegin }.count == 1,
                        "A copy or paste on the remote read, resent or re-offered this Mac's clipboard")
            pair.localSync.setControllingRemote(false)
            pump(for: 0.35)
            try require(pair.local.reads == reads && pair.localMessages.filter { $0 == .clipboardBegin }.count == 1,
                        "A clipboard change during control was sent after release")
            pair.local.isRelayedFromOtherDevice = false
            pair.local.copy(.text(Data("copied here after release".utf8)))
            try eventually("A new copy made here after release did not send") { pair.remote.copiedText == "copied here after release" }
        }

        run("Clipboard content from before the session never reaches the remote through a paste during control") { folder in
            let pasteboard = MemoryPasteboard()
            pasteboard.copy(.files([folder.appendingPathComponent("older.bin")]))
            pasteboard.isSensitive = true
            var messages: [MessageKind] = [], statuses: [String] = [], paste: Bool?
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, controllingRemote: true,
                                     pasteboard: pasteboard, storage: folder) { message in
                DispatchQueue.main.async { messages.append(message.kind) }
            }
            defer { sync.stop() }
            sync.onStatus = { statuses.append($0) }
            sync.prepareForPaste { paste = $0 }
            pump(for: 0.35)
            try require(paste == true && !sync.holdsPaste && messages.isEmpty && statuses.isEmpty && pasteboard.reads == 0,
                        "A paste on the remote sent, read or blocked on older or sensitive clipboard content")
            sync.setControllingRemote(false)
            pump(for: 0.35)
            try require(messages.isEmpty && pasteboard.reads == 0, "Older clipboard content was sent after release")
        }

        run("A text copy made before control holds a remote paste only until it lands") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            var held: Message?
            pair.routeLocal = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            let bytes = Data(repeating: 66, count: 260_000)
            pair.local.copy(.text(bytes))
            pair.localSync.setControllingRemote(true)
            try eventually("First chunk was not held") { held != nil }
            var ready: Bool?
            try require(pair.localSync.holdsPaste, "⌘V did not wait for the copy still being sent")
            pair.localSync.prepareForPaste { ready = $0 }
            try require(ready == nil, "The paste did not wait for the copy still being sent")
            pair.remoteSync.receive(held!)
            try eventually("The landed copy did not settle the paste") { ready != nil }
            try require(ready == true && pair.remote.copiedText == String(data: bytes, encoding: .utf8) && !pair.localSync.holdsPaste,
                        "The landed copy did not release the paste")
        }

        for kind in ["text", "png", "files"] {
            run("A local \(kind) copy survives taking control before automatic sending resumes") { folder in
                let pair = ClipboardPair(storage: folder, validateRemotePNG: { _ in true })
                defer { pair.stop() }
                let bytes = Data("copied on this Mac before activation".utf8)
                let file = folder.appendingPathComponent("copied-here.bin")
                try bytes.write(to: file)
                let payload: ClipboardPayload = kind == "files" ? .files([file]) : kind == "png" ? .png(bytes) : .text(bytes)
                var offer: ClipboardFileOffer?
                pair.remoteSync.onFileOffer = { offer = $0 }
                pair.local.copy(payload)
                pair.localSync.setControllingRemote(true)
                pump(for: 0.35)
                try require(pair.local.reads == 0 && pair.localMessages.isEmpty,
                            "Taking control read or sent clipboard content while automatic sending was disabled")
                try require(pair.localSync.holdsPaste, "The pending local copy no longer holds a remote paste")
                pair.localSync.setAutomaticSendingAllowed(true)
                var paste: Bool?
                pair.localSync.prepareForPaste { paste = $0 }
                if kind == "files" {
                    try eventually("The pending local file was not offered after activation") { offer != nil }
                    try require(paste == false && pair.remote.writes == 0 && pair.localSync.holdsPaste,
                                "A deferred file copy bypassed the receiver's approval")
                    pair.remoteSync.respondToFileOffer(id: offer!.id, accept: true)
                    try eventually("The approved file did not finish transferring") { pair.remote.writes == 1 && !pair.localSync.holdsPaste }
                    guard case .files(let received) = pair.remote.payload, let receivedFile = received.first else {
                        throw FocusCheckFailure("The file was not published on the remote pasteboard")
                    }
                    try require(try Data(contentsOf: receivedFile) == bytes, "The deferred file's contents changed")
                    pair.localSync.prepareForPaste { paste = $0 }
                } else {
                    try require(paste == nil, "A pending local copy did not wait for remote publication")
                    try eventually("The pending local \(kind) did not arrive after activation") { paste == true && pair.remote.writes == 1 }
                    switch pair.remote.payload {
                    case .text(let received), .png(let received): try require(received == bytes, "The deferred payload changed")
                    case .files: throw FocusCheckFailure("A non-file copy changed payload type")
                    }
                }
                try require(paste == true && !pair.localSync.holdsPaste,
                            "The completed deferred copy did not release the remote paste")
            }
        }

        run("A pending local copy is discarded if the clipboard changes during remote control") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            pair.local.copy(.text(Data("local copy before control".utf8)))
            pair.localSync.setControllingRemote(true)
            pair.local.copy(.text(Data("a different change during remote control".utf8)))
            pump(for: 0.35)
            pair.localSync.setAutomaticSendingAllowed(true)
            var paste: Bool?
            pair.localSync.prepareForPaste { paste = $0 }
            pump(for: 0.35)
            try require(pair.local.reads == 0 && pair.localMessages.isEmpty && pair.remote.writes == 0
                        && !pair.localSync.holdsPaste && paste == true,
                        "A replacement during control was mistaken for the earlier local copy")
        }

        run("Releasing control preserves a pending local copy until automatic sending resumes") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            pair.local.copy(.text(Data("local copy waiting for activation".utf8)))
            pair.localSync.setControllingRemote(true)
            pair.localSync.setControllingRemote(false)
            pump(for: 0.35)
            try require(pair.local.reads == 0 && pair.localMessages.isEmpty, "Releasing control read a background clipboard")
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Releasing control consumed the pending local copy") {
                pair.remote.copiedText == "local copy waiting for activation"
            }
        }

        run("A local TIFF interrupted by the automatic-sending gate retries the same version during control") { folder in
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true,
                                     convertLocalTIFF: { probe.convert($0) }, validateRemotePNG: { _ in true })
            defer { probe.release.signal(); probe.release.signal(); pair.stop() }
            let bytes = Data([1, 2, 3, 4])
            pair.local.copy(.text(Data("TIFF fallback".utf8)))
            pair.local.rawTIFF = bytes
            pair.localSync.setControllingRemote(true)
            try eventually("The local TIFF did not begin converting") { probe.state.began }
            pair.localSync.setAutomaticSendingAllowed(false)
            probe.release.signal()
            pump(for: 0.1)
            pair.localSync.setAutomaticSendingAllowed(true)
            probe.release.signal()
            var paste: Bool?
            pair.localSync.prepareForPaste { paste = $0 }
            try eventually("The interrupted TIFF was not retried after automatic sending resumed") { pair.remote.writes == 1 }
            try eventually("The retried TIFF did not settle the remote paste") { paste == true && !pair.localSync.holdsPaste }
            guard case .png(let received) = pair.remote.payload else { throw FocusCheckFailure("The retried TIFF was not a PNG") }
            try require(received == bytes && pair.localMessages.filter { $0 == .clipboardBegin }.count == 1,
                        "The interrupted image changed contents or was transferred twice")
        }

        run("A copy made explicitly here during control, such as a remote picture capture, still sends") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true, controllingLocal: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("captured here".utf8)))
            pump(for: 0.35)
            try require(!pair.localMessages.contains(.clipboardBegin), "A change during control was sent without an explicit copy")
            pair.local.copy(.text(Data("captured here".utf8)))
            pair.localSync.sendLocalCopy()
            try eventually("An explicit copy during control did not send") { pair.remote.copiedText == "captured here" }
        }

        run("An explicit local copy during control waits for automatic sending to resume") { folder in
            let pair = ClipboardPair(storage: folder, controllingLocal: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("explicit local capture while paused".utf8)))
            pair.localSync.sendLocalCopy()
            pump(for: 0.35)
            try require(pair.local.reads == 0 && pair.localMessages.isEmpty && pair.localSync.holdsPaste,
                        "An explicit local copy was read while paused or forgotten during control")
            pair.localSync.setAutomaticSendingAllowed(true)
            var paste: Bool?
            pair.localSync.prepareForPaste { paste = $0 }
            try eventually("The explicit local copy did not resume and release its paste") {
                pair.remote.copiedText == "explicit local capture while paused" && paste == true && !pair.localSync.holdsPaste
            }
        }

        run("An automatic reconnect hands over the handled version so a copy made while disconnected still sends") { folder in
            let pasteboard = MemoryPasteboard()
            let previous = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                         pasteboard: pasteboard, storage: folder.appendingPathComponent("previous")) { _ in }
            pasteboard.copy(.text(Data("copied while disconnected".utf8)))
            let handled = previous.handledChange
            previous.stop()
            var fresh: [MessageKind] = [], resumed: [MessageKind] = []
            let manual = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                       pasteboard: pasteboard, storage: folder.appendingPathComponent("manual")) { message in
                DispatchQueue.main.async { fresh.append(message.kind) }
            }
            let automatic = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                          handledChange: handled, pasteboard: pasteboard,
                                          storage: folder.appendingPathComponent("automatic")) { message in
                DispatchQueue.main.async { resumed.append(message.kind) }
            }
            defer { manual.stop(); automatic.stop() }
            manual.setAutomaticSendingAllowed(true)
            automatic.setAutomaticSendingAllowed(true)
            try eventually("A copy made while disconnected did not send after the automatic reconnect") { resumed.contains(.clipboardBegin) }
            pump(for: 0.35)
            try require(fresh.isEmpty, "A manual connection sent clipboard content from before the session")
        }

        run("In-flight paste preparation, chunks and receipts complete after focus loss") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            var held: Message?
            pair.routeLocal = { message in
                if message.kind == .clipboardChunk, held == nil {
                    held = message
                    pair.localSync.setAutomaticSendingAllowed(false)
                    return false
                }
                return true
            }
            let bytes = Data(repeating: 65, count: 260_000)
            pair.local.copy(.text(bytes))
            var ready: Bool?
            pair.localSync.prepareForPaste { ready = $0 }
            try eventually("First chunk was not held") { held != nil }
            let reads = pair.local.reads
            pair.local.copy(.text(Data("new background copy".utf8)))
            pump(for: 0.35)
            try require(pair.local.reads == reads, "New content read after focus loss")
            pair.remoteSync.receive(held!)
            try eventually("Focus loss interrupted existing paste preparation") { ready != nil }
            try require(ready == true && pair.remote.copiedText == String(data: bytes, encoding: .utf8),
                        "In-flight content or paste acknowledgement changed")
        }

        run("File prompt activation cannot send old background content or cancel an accepted file") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("older local copy".utf8)))
            let file = folder.appendingPathComponent("accepted.bin"), bytes = Data(repeating: 81, count: 120_000)
            try bytes.write(to: file)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { value in
                offer = value
                if value != nil { pair.localSync.setAutomaticSendingAllowed(true) }
            }
            pair.remote.copy(.files([file]))
            try eventually("File offer missing") { offer != nil }
            pump(for: 0.35)
            try require(pair.local.reads == 0 && pair.localMessages.filter { $0 == .clipboardBegin }.isEmpty,
                        "Prompt activation sent stale local content")
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            pair.localSync.setAutomaticSendingAllowed(false)
            try eventually("Accepted file did not finish after focus restoration") { pair.local.writes == 1 }
            guard case .files(let urls) = pair.local.payload else { throw FocusCheckFailure("Received wrong payload") }
            try require(urls.count == 1 && Data(contentsOf: urls[0]) == bytes, "Accepted file bytes changed")
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            try require(pair.local.reads == 0 && pair.localMessages.filter { $0 == .clipboardBegin }.isEmpty,
                        "Accepted file caused old clipboard content to be sent")
        }

        for kind in ["text", "png", "files", "tiff"] {
            run("An accepted file finishes while a newer local \(kind) copy waits and remains on the clipboard") { folder in
                let pair = ClipboardPair(storage: folder, remoteAllowed: true,
                                         convertLocalTIFF: { $0 }, validateRemotePNG: { _ in true })
                defer { pair.stop() }
                let original = folder.appendingPathComponent("incoming.bin"), originalBytes = Data(repeating: 81, count: 120_000)
                let next = folder.appendingPathComponent("new-local.bin"), nextBytes = Data("copied while receiving".utf8)
                try originalBytes.write(to: original); try nextBytes.write(to: next)
                var offer: ClipboardFileOffer?, returnOffer: ClipboardFileOffer?, reception: UUID?, held: Message?
                var senderEvents: [ClipboardSync.DiagnosticEvent] = [], kept = 0
                var fileResults: [(ClipboardFileResult, Bool)] = []
                pair.localSync.onFileResult = { fileResults.append(($0, $1)) }
                pair.localSync.onFileOffer = { offer = $0 }
                pair.localSync.onFileReceptionChanged = { reception = $0 }
                pair.localSync.onReceivedFilesKept = { kept += 1 }
                pair.remoteSync.onFileOffer = { returnOffer = $0 }
                pair.remoteSync.onDiagnostic = { senderEvents.append($0) }
                pair.routeRemote = { message in
                    if message.kind == .clipboardChunk, held == nil { held = message; return false }
                    return true
                }
                pair.remote.copy(.files([original]))
                pair.remoteSync.setAutomaticSendingAllowed(true)
                try eventually("Incoming file did not request approval") { offer != nil }
                pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
                try eventually("Accepted file did not begin receiving") { reception != nil && held != nil }
                if kind == "files" { pair.local.copy(.files([next])) }
                else if kind == "png" { pair.local.copy(.png(nextBytes)) }
                else {
                    pair.local.copy(.text(nextBytes))
                    if kind == "tiff" { pair.local.rawTIFF = nextBytes }
                }
                pair.localSync.setAutomaticSendingAllowed(true)
                pump(for: 0.35)
                try require(reception != nil && !pair.localMessages.contains(.clipboardBegin)
                            && !senderEvents.contains(.sendFailed(.files, fileCount: 1)) && pair.local.writes == 0,
                            "The new local copy interrupted or replaced an accepted file reception")
                pair.localSync.receive(held!)
                try eventually("Accepted file did not finish after the held chunk arrived") {
                    senderEvents.contains(.sent(.files, fileCount: 1)) && reception == nil
                }
                let received = folder.appendingPathComponent("local/received", isDirectory: true)
                let batches = try FileManager.default.contentsOfDirectory(at: received, includingPropertiesForKeys: nil)
                try require(batches.count == 1 && Data(contentsOf: batches[0].appendingPathComponent("incoming.bin")) == originalBytes,
                            "The completed file was missing or its bytes changed")
                try require(pair.local.writes == 0 && kept == 1, "Completing the file overwrote the newer local copy or lost its folder notice")
                try require(fileResults.count == 1 && fileResults[0].0.outcome == .completed && fileResults[0].1
                            && fileResults[0].0.files.count == 1 && Data(contentsOf: fileResults[0].0.files[0]) == originalBytes,
                            "Typed result lost completed file URLs or the newer-copy preservation state")
                if kind == "files" {
                    try eventually("The newer local file was not offered after receiving finished") { returnOffer != nil }
                    try require(pair.remote.writes == 0, "The newer file bypassed receiver approval")
                    pair.remoteSync.respondToFileOffer(id: returnOffer!.id, accept: true)
                    try eventually("The approved newer file was not published") { pair.remote.writes == 1 }
                    guard case .files(let urls) = pair.remote.payload, let file = urls.first else {
                        throw FocusCheckFailure("New local file was not published as a file")
                    }
                    try require(Data(contentsOf: file) == nextBytes, "The deferred local file changed bytes")
                } else {
                    try eventually("The newer local copy did not synchronize after receiving finished") { pair.remote.writes == 1 }
                    switch pair.remote.payload {
                    case .text(let bytes), .png(let bytes): try require(bytes == nextBytes, "The deferred clipboard data changed")
                    case .files: throw FocusCheckFailure("The deferred text/image became a file")
                    }
                }
                try require(pair.localMessages.filter { $0 == .clipboardBegin }.count == 1
                            && !pair.localMessages.contains(.clipboardCancel),
                            "The newer local copy was sent twice or cancelled the completed reception")
            }
        }

        run("A local copy queued immediately after file acceptance cannot race the reception notification") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("accepted.bin"), bytes = Data(repeating: 71, count: 120_000)
            try bytes.write(to: file)
            var offer: ClipboardFileOffer?, reception: UUID?, held: Message?
            var senderEvents: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onFileOffer = { offer = $0 }
            pair.localSync.onFileReceptionChanged = { reception = $0 }
            pair.remoteSync.onDiagnostic = { senderEvents.append($0) }
            pair.routeRemote = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("File offer missing before the acceptance race") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            pair.local.copy(.text(Data("copied before reception notice".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Acceptance race did not leave an active reception") { reception != nil && held != nil }
            pump(for: 0.35)
            try require(!pair.localMessages.contains(.clipboardBegin) && !senderEvents.contains(.sendFailed(.files, fileCount: 1)),
                        "A queued local send cancelled the accepted file before its main-thread notification")
            pair.localSync.receive(held!)
            try eventually("The raced reception or deferred local copy did not finish") {
                senderEvents.contains(.sent(.files, fileCount: 1)) && pair.remote.copiedText == "copied before reception notice"
            }
            let batches = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("local/received"), includingPropertiesForKeys: nil)
            try require(batches.count == 1 && Data(contentsOf: batches[0].appendingPathComponent("accepted.bin")) == bytes
                        && pair.local.copiedText == "copied before reception notice" && pair.local.writes == 0,
                        "Reception completion lost either the downloaded file or the raced local copy")
        }

        run("Manually cancelling reception releases the latest local copy without publishing a partial file") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("cancelled.bin")
            try Data(repeating: 79, count: 120_000).write(to: file)
            var offer: ClipboardFileOffer?, reception: UUID?, held: Message?
            var senderEvents: [ClipboardSync.DiagnosticEvent] = [], kept = 0
            pair.localSync.onFileOffer = { offer = $0 }
            pair.localSync.onFileReceptionChanged = { reception = $0 }
            pair.localSync.onReceivedFilesKept = { kept += 1 }
            pair.remoteSync.onDiagnostic = { senderEvents.append($0) }
            pair.routeRemote = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("File offer missing before cancellation") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("Reception missing before cancellation") { reception != nil && held != nil }
            pair.local.copy(.text(Data("local copy after cancellation".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            guard let id = reception else { throw FocusCheckFailure("New copy cancelled reception before the explicit action") }
            pair.localSync.cancelFileReception(id: id)
            try eventually("Cancelling the file did not resume the local copy") {
                reception == nil && pair.remote.copiedText == "local copy after cancellation"
                    && senderEvents.contains(.sendFailed(.files, fileCount: 1))
            }
            pair.localSync.receive(held!)
            pump(for: 0.35)
            try require(pair.local.writes == 0 && pair.local.copiedText == "local copy after cancellation" && kept == 0
                        && pair.localMessages.filter { $0 == .clipboardCancel }.count == 1
                        && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("local/received").path),
                        "Cancelled or late file data was published, or cancellation lost the local copy")
        }

        for copiedDuringReception in [false, true] {
            run(copiedDuringReception
                ? "A local copy made while receiving holds a remote paste until the accepted file finishes"
                : "Receiving an accepted file does not hold the controlled Mac's own paste") { folder in
                let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true)
                defer { pair.stop() }
                let file = folder.appendingPathComponent("incoming.bin")
                try Data(repeating: 83, count: 120_000).write(to: file)
                var offer: ClipboardFileOffer?, reception: UUID?, held: Message?
                var statuses: [String] = [], kept = 0
                var receiverEvents: [ClipboardSync.DiagnosticEvent] = []
                pair.localSync.onFileOffer = { offer = $0 }
                pair.localSync.onFileReceptionChanged = { reception = $0 }
                pair.localSync.onStatus = { statuses.append($0) }
                pair.localSync.onReceivedFilesKept = { kept += 1 }
                pair.localSync.onDiagnostic = { receiverEvents.append($0) }
                pair.routeRemote = { message in
                    if message.kind == .clipboardChunk, held == nil { held = message; return false }
                    return true
                }
                pair.remote.copy(.files([file]))
                pair.remoteSync.setAutomaticSendingAllowed(true)
                try eventually("Incoming file did not request approval") { offer != nil }
                pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
                try eventually("Accepted file did not begin receiving") { reception != nil && held != nil }
                if copiedDuringReception {
                    pair.local.copy(.text(Data("copied while receiving".utf8)))
                    pump(for: 0.35)
                }
                pair.localSync.setControllingRemote(true)
                pump(for: 0.35)
                let holds = pair.localSync.holdsPaste
                var paste: Bool?
                pair.localSync.prepareForPaste { paste = $0 }
                if copiedDuringReception {
                    try require(holds && paste == false && statuses.last?.hasPrefix("文件仍在接收") == true
                                && !pair.localMessages.contains(.clipboardBegin),
                                "A deferred local copy did not hold the remote paste while receiving")
                } else {
                    try require(!holds && paste == true && !statuses.contains { $0.hasPrefix("文件仍在接收") },
                                "Receiving a file held or rejected a paste of the controlled Mac's own clipboard")
                }
                pair.localSync.receive(held!)
                try eventually("Accepted file did not finish while controlling") { reception == nil }
                try require(receiverEvents.filter { $0 == .applied(.files, fileCount: 1) }.count == 1,
                            "A completed file reception was not recorded exactly once in diagnostics")
                if copiedDuringReception {
                    try eventually("The deferred local copy did not synchronize after receiving finished") {
                        pair.remote.copiedText == "copied while receiving" && !pair.localSync.holdsPaste
                    }
                    try require(pair.local.writes == 0 && kept == 1,
                                "The finished file replaced the newer local copy or its folder notice was not kept once")
                } else {
                    pump(for: 0.35)
                    try require(pair.local.writes == 1 && !pair.localMessages.contains(.clipboardBegin) && !pair.localSync.holdsPaste,
                                "The finished file was not published locally or was echoed back while controlling")
                    try require(kept == 0, "A file published on the clipboard reported it was kept only in the folder")
                }
            }
        }

        run("A retained file result survives later text sync until dismissed or a new file starts") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("result.bin"), bytes = Data([1, 3, 5])
            try bytes.write(to: file)
            var offer: ClipboardFileOffer?, result: ClipboardFileResult?, results = 0, starts = 0
            pair.localSync.onFileOffer = { offer = $0 }
            pair.localSync.onFileTransferStarted = { result = nil; starts += 1 }
            pair.localSync.onFileResult = { value, _ in result = value; results += 1 }
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("File offer missing") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("Completed file result missing") { result?.outcome == .completed }
            let id = result!.id
            pair.remote.copy(.text(Data("later sync".utf8)))
            try eventually("Later text did not synchronize") { pair.local.copiedText == "later sync" }
            pump(for: 1.1)
            try require(result?.id == id && results == 1 && result!.files.count == 1,
                        "A later sync or the former one-second timeout discarded the file result")
            result = nil
            pair.remote.copy(.text(Data("after dismissal".utf8)))
            try eventually("Text after dismissal did not synchronize") { pair.local.copiedText == "after dismissal" }
            try require(result == nil && results == 1, "Text resurrected a dismissed result")
            pair.remote.copy(.files([file]))
            try eventually("A new file did not reset the result state") { starts == 2 && offer != nil }
        }

        run("Stopping clipboard sync suppresses queued file results from the old session") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            var results = 0
            pair.localSync.onFileResult = { _, _ in results += 1 }
            pair.local.copy(.files([folder.appendingPathComponent("does-not-exist")]))
            pair.localSync.setAutomaticSendingAllowed(true)
            pair.localSync.stop()
            pump(for: 0.15)
            try require(results == 0, "A stopped sync published a stale file result")
        }

        run("A new local copy replaces pending file approval; stale acceptance cannot download") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("before offer".utf8)))
            let file = folder.appendingPathComponent("not-accepted.bin")
            try Data([1, 2, 3]).write(to: file)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { value in
                offer = value
                if value != nil { pair.localSync.setAutomaticSendingAllowed(true) }
            }
            pair.remote.copy(.files([file]))
            try eventually("No pending file") { offer != nil }
            let stale = offer!.id
            pair.local.copy(.text(Data("new local copy".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Local copy did not supersede file") { offer == nil && pair.remote.copiedText == "new local copy" }
            pair.localSync.respondToFileOffer(id: stale, accept: true)
            pump(for: 0.35)
            try require(pair.local.writes == 0 && !pair.remoteMessages.contains(.clipboardEntry), "Stale approval downloaded a file")
        }

        run("A remote replacement file survives cancellation gaps without sending older deferred local content") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("older background copy".utf8)))
            let first = folder.appendingPathComponent("first.bin"), second = folder.appendingPathComponent("second.bin")
            try Data([1]).write(to: first)
            let bytes = Data(repeating: 92, count: 90_000)
            try bytes.write(to: second)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { value in
                offer = value
                if value != nil { pair.localSync.setAutomaticSendingAllowed(true) }
            }
            pair.remote.copy(.files([first]))
            try eventually("First remote file offer missing") { offer != nil }
            let previous = offer!.id
            var held: Message?
            pair.routeRemote = { message in
                if message.kind == .clipboardBegin { held = message; return false }
                return true
            }
            pair.remote.copy(.files([second]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Replacement cancellation did not clear the first prompt") { held != nil && offer == nil }
            pump(for: 0.35)
            try require(pair.local.reads == 0 && !pair.localMessages.contains(.clipboardBegin),
                        "The remote cancellation gap sent older local clipboard content")
            pair.localSync.receive(held!)
            try eventually("Second remote file offer missing") { offer != nil && offer!.id != previous }
            pump(for: 0.35)
            pair.localSync.respondToFileOffer(id: previous, accept: true)
            try require(pair.local.reads == 0 && !pair.localMessages.contains(.clipboardBegin),
                        "The replacement prompt sent older local clipboard content")
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("Replacement file did not arrive") { pair.local.writes == 1 }
            guard case .files(let urls) = pair.local.payload else { throw FocusCheckFailure("Replacement file was overwritten") }
            try require(urls.count == 1 && urls[0].lastPathComponent == "second.bin" && Data(contentsOf: urls[0]) == bytes,
                        "Wrong file survived the remote replacement")
            try require(!pair.localMessages.contains(.clipboardBegin), "Older local content cancelled the replacement file")
        }

        run("Remote text replacing a file prompt cannot be overwritten by older deferred local content") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("older background copy".utf8)))
            let file = folder.appendingPathComponent("superseded.bin")
            try Data([7]).write(to: file)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { value in
                offer = value
                if value != nil { pair.localSync.setAutomaticSendingAllowed(true) }
            }
            pair.remote.copy(.files([file]))
            try eventually("File offer missing before remote text copy") { offer != nil }
            var held: Message?
            pair.routeRemote = { message in
                if message.kind == .clipboardBegin { held = message; return false }
                return true
            }
            pair.remote.copy(.text(Data("newer remote text".utf8)))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote text replacement was not held") { held != nil && offer == nil }
            pump(for: 0.35)
            try require(pair.local.reads == 0 && !pair.localMessages.contains(.clipboardBegin),
                        "The cancellation gap read or transmitted older local content")
            pair.localSync.receive(held!)
            try eventually("New remote text did not arrive") { pair.local.copiedText == "newer remote text" }
            pump(for: 0.35)
            try require(pair.remote.copiedText == "newer remote text" && !pair.localMessages.contains(.clipboardBegin),
                        "Older local content replaced the new remote text")
            try require(pair.local.writes == 1 && !FileManager.default.fileExists(atPath:
                folder.appendingPathComponent("local/received", isDirectory: true).path),
                        "Superseded file was applied")
        }

        run("Declining a prompt resumes the latest deferred local copy") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data("deferred local copy".utf8)))
            let file = folder.appendingPathComponent("declined.bin")
            try Data([4]).write(to: file)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { value in
                offer = value
                if value != nil { pair.localSync.setAutomaticSendingAllowed(true) }
            }
            pair.remote.copy(.files([file]))
            try eventually("No file to decline") { offer != nil }
            pair.localSync.respondToFileOffer(id: offer!.id, accept: false)
            try eventually("Deferred local text did not resume") { pair.remote.copiedText == "deferred local copy" }
            try require(!pair.remoteMessages.contains(.clipboardEntry), "Declining the offer downloaded files")
        }

        for failToStart in [false, true] {
            run("\(failToStart ? "Failed" : "Declined") incoming offer cannot send an older local file without a new copy") { folder in
                let storage = folder.appendingPathComponent(failToStart ? "failure" : "decline")
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                if failToStart { try Data([0]).write(to: storage.appendingPathComponent("remote")) }
                let pair = ClipboardPair(storage: storage, localAllowed: true)
                defer { pair.stop() }
                let localFile = storage.appendingPathComponent("A.bin"), oldRemoteFile = storage.appendingPathComponent("older-B.bin")
                try Data([1]).write(to: localFile)
                try Data([2]).write(to: oldRemoteFile)
                pair.remote.copy(.files([oldRemoteFile]))
                var incoming: ClipboardFileOffer?, returned: ClipboardFileOffer?
                pair.remoteSync.onFileOffer = { value in
                    incoming = value
                    if value != nil { pair.remoteSync.setAutomaticSendingAllowed(true) }
                }
                pair.localSync.onFileOffer = { returned = $0 }
                pair.local.copy(.files([localFile]))
                pair.localSync.setAutomaticSendingAllowed(true)
                try eventually("A file did not prompt only on B") { incoming != nil }
                try require(returned == nil && !pair.remoteMessages.contains(.clipboardBegin), "B offered an old copy during A's file prompt")
                pair.remoteSync.setAutomaticSendingAllowed(false)
                pair.remoteSync.respondToFileOffer(id: incoming!.id, accept: failToStart)
                try eventually("B prompt did not close after decline or failure") { incoming == nil }
                try require(pair.remote.reads == 0, "Closing the prompt read B's inactive clipboard")
                for _ in 0..<3 {
                    pair.remoteSync.setAutomaticSendingAllowed(false)
                    pair.remoteSync.setAutomaticSendingAllowed(true)
                }
                let readsAfterFocus = pair.remote.reads
                pump(for: 0.65)
                try require(pair.remote.reads == readsAfterFocus, "Timer polling repeatedly reread an unchanged stale file copy")
                var stalePaste: Bool?
                pair.remoteSync.prepareForPaste { stalePaste = $0 }
                try require(stalePaste == false && returned == nil && !pair.remoteMessages.contains(.clipboardBegin),
                            "Closing A's copy request or preparing paste sent an older B file")
                pair.remote.copy(.files([oldRemoteFile]))
                pair.remoteSync.setAutomaticSendingAllowed(true)
                try eventually("A fresh B copy of its original file did not prompt A") { returned != nil }
                pair.localSync.respondToFileOffer(id: returned!.id, accept: false)
            }
        }

        run("A genuinely new B file copy during A's pending offer can prompt A") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let a = folder.appendingPathComponent("A.bin"), b = folder.appendingPathComponent("B.bin")
            try Data([1]).write(to: a); try Data([2]).write(to: b)
            pair.remote.copy(.files([b]))
            var incoming: ClipboardFileOffer?, returned: ClipboardFileOffer?
            pair.remoteSync.onFileOffer = { incoming = $0 }
            pair.localSync.onFileOffer = { returned = $0 }
            pair.local.copy(.files([a]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("A's pending file offer missing") { incoming != nil }
            let stale = incoming!.id
            pair.remote.copy(.files([b]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("B's new file copy did not prompt A") { returned != nil && incoming == nil }
            pair.remoteSync.respondToFileOffer(id: stale, accept: true)
            try require(!pair.localMessages.contains(.clipboardEntry), "Stale acceptance sent A's superseded file")
            pair.localSync.respondToFileOffer(id: returned!.id, accept: true)
            try eventually("B's explicit file copy was not applied after A accepted") { pair.local.writes == 1 }
            guard case .files(let urls) = pair.local.payload else { throw FocusCheckFailure("Expected B's file") }
            try require(urls[0].lastPathComponent == "B.bin" && Data(contentsOf: urls[0]) == Data([2]),
                        "The explicit B file copy changed or was blocked")
        }

        run("Copies made while a background file prompt waits are not overwritten on acceptance") { folder in
            let pair = ClipboardPair(storage: folder, remoteAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("conflict.bin")
            try Data([5]).write(to: file)
            var offer: ClipboardFileOffer?
            pair.localSync.onFileOffer = { offer = $0 }
            pair.remote.copy(.files([file]))
            try eventually("No background file offer") { offer != nil }
            pair.local.copy(.text(Data("copied while waiting".utf8)))
            pair.localSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("Changed local clipboard did not reject offer") { offer == nil }
            try require(pair.local.reads == 0 && !pair.remoteMessages.contains(.clipboardEntry),
                        "Background conflict read clipboard content or downloaded a file")
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("New local content did not resume after conflict") { pair.remote.copiedText == "copied while waiting" }
        }

        run("A failed system clipboard write does not report paste readiness") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            pair.remote.rejectsWrites = true
            pair.local.copy(.text(Data("cannot apply".utf8)))
            var ready: Bool?
            pair.localSync.prepareForPaste { ready = $0 }
            try eventually("Failed write did not complete preparation") { ready != nil }
            try require(ready == false && pair.remote.writes == 0, "Rejected write acknowledged paste readiness")
        }

        run("Received files never return an offer to their sender after marker loss and focus release; modified files still send") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let project = folder.appendingPathComponent("project"), extra = folder.appendingPathComponent("extra.txt")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: project.appendingPathComponent("src/code.txt"))
            try Data("extra".utf8).write(to: extra)
            var receiving: ClipboardFileOffer?, returned: ClipboardFileOffer?
            pair.remoteSync.onFileOffer = { receiving = $0 }
            pair.localSync.onFileOffer = { returned = $0 }
            pair.local.copy(.files([project, extra]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Remote file offer missing") { receiving != nil }
            pair.remoteSync.respondToFileOffer(id: receiving!.id, accept: true)
            try eventually("Remote files were not published") { pair.remote.writes == 1 }
            guard case .files(let received) = pair.remote.payload else { throw FocusCheckFailure("Expected received files") }
            pair.remote.copy(.files(Array(received.reversed())))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            pump(for: 0.45)
            try require(returned == nil && !pair.remoteMessages.contains(.clipboardBegin),
                        "The sender received its own file approval after focus release")
            guard let copiedProject = received.first(where: { $0.lastPathComponent == "project" }) else {
                throw FocusCheckFailure("Received directory missing")
            }
            let modified = Data("modified remote content is longer".utf8)
            try modified.write(to: copiedProject.appendingPathComponent("src/code.txt"))
            pair.remote.copy(.files(received))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Modified received files were incorrectly suppressed") { returned != nil }
            pair.localSync.respondToFileOffer(id: returned!.id, accept: true)
            try eventually("Modified files did not return after explicit copying") { pair.local.writes == 1 }
            guard case .files(let roundTrip) = pair.local.payload,
                  let changed = roundTrip.first(where: { $0.lastPathComponent == "project" }) else {
                throw FocusCheckFailure("Modified round trip lost the directory")
            }
            try require(Data(contentsOf: changed.appendingPathComponent("src/code.txt")) == modified,
                        "A changed file was mistaken for unchanged received data")
        }

        run("Received text and PNG stay local after marker loss and repeated focus changes") { folder in
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FocusCheckFailure("Cannot create an in-memory PNG")
            }
            for (index, payload) in [ClipboardPayload.text(Data("clipboard text".utf8)), .png(png)].enumerated() {
                let pair = ClipboardPair(storage: folder.appendingPathComponent(String(index)), localAllowed: true)
                defer { pair.stop() }
                pair.local.copy(payload)
                pair.localSync.setAutomaticSendingAllowed(true)
                try eventually("Text or PNG did not arrive") { pair.remote.writes == 1 }
                pair.remote.republish()
                for _ in 0..<3 {
                    pair.remoteSync.setAutomaticSendingAllowed(true)
                    pair.remoteSync.setAutomaticSendingAllowed(false)
                }
                pair.remoteSync.setAutomaticSendingAllowed(true)
                pump(for: 0.35)
                try require(!pair.remoteMessages.contains(.clipboardBegin) && pair.local.writes == 0,
                            "Received text or image echoed to its source")
            }
        }

        run("A rejected clipboard write cannot mark received files as shared or suppress a later explicit copy") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("failed.bin")
            try Data([1, 2, 3]).write(to: file)
            pair.remote.rejectsWrites = true
            var receiving: ClipboardFileOffer?, returned: ClipboardFileOffer?
            var failed = false, fileResult: ClipboardFileResult?
            pair.remoteSync.onFileResult = { result, _ in fileResult = result }
            pair.remoteSync.onFileOffer = { receiving = $0 }
            pair.localSync.onFileOffer = { returned = $0 }
            pair.localSync.onStatus = { if $0.contains("无法写入") { failed = true } }
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("No file offer before rejected clipboard write") { receiving != nil }
            pair.remoteSync.respondToFileOffer(id: receiving!.id, accept: true)
            try eventually("Rejected file publication was not reported") { failed }
            try require(pair.remote.writes == 0 && !pair.remoteMessages.contains(.clipboardBegin),
                        "Rejected publication was treated as a new local file copy")
            let receivedDirectory = folder.appendingPathComponent("remote/received")
            let saved = try FileManager.default.contentsOfDirectory(at: receivedDirectory, includingPropertiesForKeys: nil)
            try require(saved.count == 1, "Expected the completed file to remain available after clipboard rejection")
            try eventually("Failed publication lost its actionable saved-file result") { fileResult?.outcome == .failed }
            try require(fileResult!.files.count == 1 && Data(contentsOf: fileResult!.files[0]) == Data([1, 2, 3]),
                        "Clipboard rejection fabricated or lost the completed file action")
            pair.remote.rejectsWrites = false
            pair.remote.copy(.files([saved[0].appendingPathComponent("failed.bin")]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("A file never published to the clipboard was incorrectly treated as an echo") { returned != nil }
            pair.localSync.respondToFileOffer(id: returned!.id, accept: false)
        }

        run("Declining a file never sends it back and a fresh copy of the same source can retry") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("retry.bin")
            try Data([6, 7]).write(to: file)
            var offer: ClipboardFileOffer?
            var offered = 0
            pair.remoteSync.onFileOffer = { value in offer = value; if value != nil { offered += 1 } }
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("First retry offer missing") { offer != nil }
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: false)
            try eventually("Decline did not clear its prompt") { offer == nil }
            pair.remoteSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            try require(pair.remote.writes == 0 && !pair.remoteMessages.contains(.clipboardBegin), "Declined files echoed")
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("A new copy could not retry the same declined source file") { offered == 2 && offer != nil }
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: false)
        }

        run("An interrupted file followed by text never publishes or echoes the cancelled file") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("cancelled.bin")
            try Data(repeating: 99, count: 150_000).write(to: file)
            var offer: ClipboardFileOffer?, held: Message?
            pair.remoteSync.onFileOffer = { offer = $0 }
            pair.routeLocal = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("No file to interrupt") { offer != nil }
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("No file chunk to interrupt") { held != nil }
            pair.local.copy(.text(Data("replacement text".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Replacement text did not supersede the interrupted file") { pair.remote.copiedText == "replacement text" }
            pair.remote.republish()
            pair.remoteSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            try require(pair.remote.writes == 1 && !pair.remoteMessages.contains(.clipboardBegin),
                        "Cancelled file or its replacement echoed to the sender")
            try require(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("remote/received").path),
                        "An interrupted file was published")
        }

        run("Clipboard diagnostics report typed lifecycle events without names, paths or contents") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            var localEvents: [ClipboardSync.DiagnosticEvent] = [], remoteEvents: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onDiagnostic = { localEvents.append($0) }
            pair.remoteSync.onDiagnostic = { remoteEvents.append($0) }
            let secret = "private clipboard contents"
            pair.local.copy(.text(Data(secret.utf8)))
            pump(for: 0.35)
            try require(localEvents.isEmpty && remoteEvents.isEmpty && pair.local.reads == 0,
                        "Diagnostics read or reported an inactive clipboard")
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Successful text synchronization was not diagnosed") { localEvents.contains(.sent(.text, fileCount: 0)) }
            try require(localEvents == [.sending(.text, fileCount: 0), .sent(.text, fileCount: 0)]
                        && remoteEvents == [.applied(.text, fileCount: 0)], "Text lifecycle diagnostics changed")
            pair.remote.rejectsWrites = true
            pair.local.copy(.text(Data("another private value".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("A send failure was not diagnosed") { localEvents.contains(.sendFailed(.text, fileCount: 0)) }
            try require(remoteEvents.contains(.applyFailed(.text, fileCount: 0)), "A failed clipboard application was not diagnosed")
            pair.remote.rejectsWrites = false
            let file = folder.appendingPathComponent("private-file-name.bin")
            let dormant = folder.appendingPathComponent("private-dormant-name.bin")
            try Data([1, 2, 3]).write(to: file); try Data([4]).write(to: dormant)
            pair.remote.copy(.files([dormant]))
            var offer: ClipboardFileOffer?
            pair.remoteSync.onFileOffer = { offer = $0 }
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("File offer diagnostics missing") { offer != nil && remoteEvents.contains(.fileOfferReceived(count: 1, totalBytes: 3)) }
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: false)
            try eventually("File rejection was not diagnosed") { remoteEvents.contains(.fileOfferRejected) && localEvents.contains(.sendFailed(.files, fileCount: 1)) }
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try require(remoteEvents.contains(.staleFilesSuppressed), "Stale file suppression was not diagnosed")
            pair.remoteSync.setAutomaticSendingAllowed(false)
            pair.local.copy(.files([file]))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Retry file offer missing") { offer != nil }
            pair.remoteSync.respondToFileOffer(id: offer!.id, accept: true)
            try eventually("Accepted file completion was not diagnosed") { localEvents.contains(.sent(.files, fileCount: 1)) }
            try require(remoteEvents.contains(.fileOfferAccepted) && remoteEvents.contains(.applied(.files, fileCount: 1)),
                        "File approval or application diagnostics missing")
            let description = String(describing: localEvents + remoteEvents)
            for privateValue in [secret, "another private value", file.lastPathComponent, dormant.lastPathComponent, folder.path] {
                try require(!description.contains(privateValue), "Diagnostic event exposed clipboard content or a file path")
            }
        }

        run("Automatic clipboard size limits reject oversized local and remote payloads before transfer") { folder in
            for (type, limit) in [("text", ClipboardAutomaticLimits.textBytes), ("png", ClipboardAutomaticLimits.imageBytes)] {
                try ClipboardAutomaticLimits.validate(type: type, bytes: limit)
                do {
                    try ClipboardAutomaticLimits.validate(type: type, bytes: limit + 1)
                    throw FocusCheckFailure("Accepted oversized \(type)")
                } catch is DeskError { }
                let pasteboard = MemoryPasteboard()
                var messages: [MessageKind] = []
                let sync = ClipboardSync(session: UUID(), allowsFileSending: true, pasteboard: pasteboard,
                    storage: folder.appendingPathComponent(type)) { message in DispatchQueue.main.async { messages.append(message.kind) } }
                defer { sync.stop() }
                let begin = "{\"revision\":{\"counter\":1,\"origin\":\"\(UUID().uuidString)\"},\"sequence\":0,\"type\":\"\(type)\",\"count\":1,\"bytes\":\(limit + 1)}"
                sync.receive(Message(.clipboardBegin, Data(begin.utf8)))
                try eventually("Oversized remote payload was not refused") { messages.contains(.clipboardCancel) }
                try require(!messages.contains(.clipboardReceipt) && pasteboard.writes == 0,
                            "Oversized remote payload was accepted or applied")
                try require(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(type + "/partial").path),
                            "Oversized payload created a partial directory")
            }
            let pair = ClipboardPair(storage: folder.appendingPathComponent("local"), localAllowed: true)
            defer { pair.stop() }
            pair.local.copy(.text(Data(repeating: 65, count: Int(ClipboardAutomaticLimits.textBytes) + 1)))
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.1)
            try require(!pair.localMessages.contains(.clipboardBegin), "Oversized local text began transferring")
        }

        run("TIFF conversion runs off the main thread and a newer copy cancels its prepared image") { folder in
            let pasteboard = MemoryPasteboard(), probe = ImageConversionProbe()
            var messages: [MessageKind] = []
            let sync = ClipboardSync(session: UUID(), allowsFileSending: true, pasteboard: pasteboard, storage: folder,
                                     convertTIFF: { probe.convert($0) }) { message in DispatchQueue.main.async { messages.append(message.kind) } }
            defer { probe.release.signal(); sync.stop() }
            pasteboard.copy(.text(Data("fallback".utf8)))
            pasteboard.rawTIFF = Data([1, 2, 3])
            sync.setAutomaticSendingAllowed(true)
            try eventually("TIFF conversion never started") { probe.state.began }
            try require(probe.state.background && messages.isEmpty, "TIFF conversion blocked the main thread or sent early")
            pasteboard.copy(.text(Data("newer text".utf8)))
            sync.setAutomaticSendingAllowed(true)
            try eventually("Newer text was not offered") { messages.contains(.clipboardBegin) }
            probe.release.signal()
            pump(for: 0.15)
            try require(messages.filter { $0 == .clipboardBegin }.count == 1, "Stale image superseded a newer copy")
        }

        run("A remote PNG begin cancels an older TIFF preparation before the remote transfer ends") { folder in
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FocusCheckFailure("Cannot create an in-memory PNG")
            }
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     convertLocalTIFF: { probe.convert($0) })
            defer { probe.release.signal(); pair.stop() }
            var held: Message?, localEvents: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onDiagnostic = { localEvents.append($0) }
            pair.routeRemote = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            pair.local.copy(.text(Data("older local copy".utf8)))
            pair.local.rawTIFF = png
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Local TIFF preparation did not start") { probe.state.began }
            pair.remote.copy(.png(png))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote PNG did not begin receiving") { held != nil }
            probe.release.signal()
            try eventually("Local TIFF preparation did not resolve") {
                pair.localMessages.contains(.clipboardBegin) || localEvents.contains(.sendFailed(.png, fileCount: 0))
            }
            try require(!pair.localMessages.contains(.clipboardBegin), "Older TIFF preparation superseded the newer remote PNG")
            pair.localSync.receive(held!)
            try eventually("Newer remote PNG did not apply after the superseded TIFF was discarded") { pair.local.writes == 1 }
            try require(pair.remote.writes == 0, "Superseded TIFF was published on the remote clipboard")
        }

        run("Preparing a remote PNG application cancels older TIFF paste waiters before conversion completes") { folder in
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FocusCheckFailure("Cannot create an in-memory PNG")
            }
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     convertLocalTIFF: { probe.convert($0) })
            defer { probe.release.signal(); pair.stop() }
            pair.local.copy(.text(Data("older TIFF copy".utf8)))
            pair.local.rawTIFF = png
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Local TIFF conversion did not start") { probe.state.began }
            var paste: Bool?
            pair.localSync.prepareForPaste { paste = $0 }
            try require(paste == nil, "TIFF paste did not wait for conversion")
            pair.remote.copy(.png(png))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote application did not cancel the old TIFF paste request") { paste == false }
            try require(pair.local.writes == 0, "Remote PNG validation bypassed the image queue")
            probe.release.signal()
            try eventually("Remote PNG did not publish after TIFF preparation cancellation") { pair.local.writes == 1 }
            try require(!pair.localMessages.contains(.clipboardBegin) && pair.remote.writes == 0,
                        "The old TIFF copy returned to the remote clipboard")
        }

        run("A remote file offer settles TIFF paste waiters before conversion completes") { folder in
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     convertLocalTIFF: { probe.convert($0) })
            defer { probe.release.signal(); pair.stop() }
            let file = folder.appendingPathComponent("remote.bin")
            try Data([7, 8, 9]).write(to: file)
            var offer: ClipboardFileOffer?, results: [Bool] = []
            pair.localSync.onFileOffer = { offer = $0 }
            pair.local.copy(.text(Data("older local TIFF".utf8)))
            pair.local.rawTIFF = Data([1, 2, 3])
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Local TIFF preparation did not start") { probe.state.began }
            pair.localSync.prepareForPaste { results.append($0) }
            try require(results.isEmpty, "TIFF paste did not wait for conversion")
            pair.remote.copy(.files([file]))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Remote file offer did not settle the TIFF paste") { offer != nil && results == [false] }
            try require(pair.localMessages.isEmpty, "Superseded TIFF preparation started a transfer")
            pair.localSync.respondToFileOffer(id: offer!.id, accept: false)
            probe.release.signal()
            pump(for: 0.15)
            try require(results == [false] && !pair.localMessages.contains(.clipboardBegin) && pair.remote.writes == 0,
                        "TIFF paste completed twice or the superseded image was sent")
        }

        run("A newer local TIFF copy cancels an older receiving PNG before conversion completes") { folder in
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FocusCheckFailure("Cannot create an in-memory PNG")
            }
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     convertLocalTIFF: { probe.convert($0) })
            defer { probe.release.signal(); pair.stop() }
            var held: Message?, remoteEvents: [ClipboardSync.DiagnosticEvent] = []
            pair.remoteSync.onDiagnostic = { remoteEvents.append($0) }
            pair.routeRemote = { message in
                if message.kind == .clipboardChunk, held == nil { held = message; return false }
                return true
            }
            pair.remote.copy(.png(png))
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("No remote PNG receiving to replace") { held != nil }
            pair.local.copy(.text(Data("newer local TIFF".utf8)))
            pair.local.rawTIFF = png
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Local TIFF did not start preparation") { probe.state.began }
            try eventually("New local TIFF did not promptly cancel the older remote transfer") {
                remoteEvents.contains(.sendFailed(.png, fileCount: 0))
            }
            pair.localSync.receive(held!)
            probe.release.signal()
            try eventually("Newer local TIFF was not sent after conversion") { pair.remote.writes == 1 }
            try require(pair.local.writes == 0, "An older remote PNG overwrote the newer local copy")
        }

        run("Received PNG validates on a background queue before publication and paste readiness") { folder in
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw FocusCheckFailure("Cannot create an in-memory PNG")
            }
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, validateRemotePNG: { bytes in
                guard let checked = probe.convert(bytes) else { return false }
                return NSBitmapImageRep(data: checked) != nil
            })
            defer { probe.release.signal(); pair.stop() }
            var events: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onDiagnostic = { events.append($0) }
            pair.local.copy(.png(png))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("PNG validation did not start") { probe.state.began }
            try require(probe.state.background && pair.remote.writes == 0 && !events.contains(.sent(.png, fileCount: 0)),
                        "PNG was decoded on main or acknowledged before validation")
            pair.remoteSync.setAutomaticSendingAllowed(true)
            var paste: Bool?
            pair.remoteSync.prepareForPaste { paste = $0 }
            try require(paste == nil, "Unvalidated PNG was reported paste-ready")
            probe.release.signal()
            try eventually("Validated PNG was not published and acknowledged") {
                pair.remote.writes == 1 && paste == true && events.contains(.sent(.png, fileCount: 0))
            }
        }

        run("Invalid received PNG is rejected without publication, success acknowledgement or paste readiness") { folder in
            let probe = ImageConversionProbe()
            let pair = ClipboardPair(storage: folder, localAllowed: true, validateRemotePNG: { bytes in
                guard let checked = probe.convert(bytes) else { return false }
                return NSBitmapImageRep(data: checked) != nil
            })
            defer { probe.release.signal(); pair.stop() }
            var localEvents: [ClipboardSync.DiagnosticEvent] = [], remoteEvents: [ClipboardSync.DiagnosticEvent] = []
            pair.localSync.onDiagnostic = { localEvents.append($0) }
            pair.remoteSync.onDiagnostic = { remoteEvents.append($0) }
            pair.local.copy(.png(Data([0, 1, 2, 3])))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Invalid PNG validation did not start") { probe.state.began }
            pair.remoteSync.setAutomaticSendingAllowed(true)
            var paste: Bool?
            pair.remoteSync.prepareForPaste { paste = $0 }
            try require(paste == nil && probe.state.background, "Invalid PNG validated on main or reported readiness early")
            probe.release.signal()
            try eventually("Invalid PNG did not fail at both ends") {
                remoteEvents.contains(.applyFailed(.png, fileCount: 0)) && localEvents.contains(.sendFailed(.png, fileCount: 0))
            }
            try require(pair.remote.writes == 0 && paste == false && !localEvents.contains(.sent(.png, fileCount: 0)),
                        "Invalid PNG was published or acknowledged as successful")
        }

        for interruption in ["new-copy", "remote-revision", "remote-cancel", "stop"] {
            run("Pending PNG validation cannot publish after \(interruption)") { folder in
                let probe = ImageConversionProbe()
                let pair = ClipboardPair(storage: folder, localAllowed: true,
                    validateRemotePNG: { probe.convert($0) != nil })
                defer { probe.release.signal(); pair.stop() }
                var begin: Message?, cancelled = false
                pair.routeLocal = { message in if message.kind == .clipboardBegin { begin = message }; return true }
                pair.remoteSync.onStatus = { if $0 == "cancel pending image" { cancelled = true } }
                pair.local.copy(.png(Data([1, 2, 3])))
                pair.localSync.setAutomaticSendingAllowed(true)
                try eventually("No pending PNG validation") { probe.state.began }
                switch interruption {
                case "new-copy":
                    pair.remote.copy(.text(Data("new local copy".utf8)))
                case "remote-revision":
                    pair.local.copy(.text(Data("new remote revision".utf8)))
                    pair.localSync.setAutomaticSendingAllowed(true)
                    try eventually("New remote revision did not apply") { pair.remote.copiedText == "new remote revision" }
                case "remote-cancel":
                    guard let begin,
                          var receipt = try JSONSerialization.jsonObject(with: begin.payload) as? [String: Any] else {
                        throw FocusCheckFailure("No PNG revision to cancel")
                    }
                    receipt["reason"] = "cancel pending image"
                    pair.remoteSync.receive(Message(.clipboardCancel, try JSONSerialization.data(withJSONObject: receipt)))
                    try eventually("Pending image cancellation was not processed") { cancelled }
                default: pair.remoteSync.stop()
                }
                probe.release.signal()
                pump(for: 0.15)
                if interruption == "remote-revision" {
                    try require(pair.remote.writes == 1 && pair.remote.copiedText == "new remote revision",
                                "Old PNG overwrote a newer remote revision")
                } else {
                    try require(pair.remote.writes == 0, "Cancelled or superseded PNG was published")
                    if interruption == "new-copy" {
                        try require(pair.remote.copiedText == "new local copy", "PNG overwrote a newer local copy")
                    }
                }
            }
        }

        run("Sensitive clipboard contents are neither read nor sent by polling or paste preparation") { folder in
            let pair = ClipboardPair(storage: folder)
            defer { pair.stop() }
            let file = folder.appendingPathComponent("private.bin")
            try Data([1]).write(to: file)
            for payload in [ClipboardPayload.text(Data("private code".utf8)), .png(Data([1])), .files([file])] {
                pair.local.copy(payload)
                pair.local.isSensitive = true
                pair.localSync.setAutomaticSendingAllowed(true)
                var paste: Bool?
                pair.localSync.prepareForPaste { paste = $0 }
                pump(for: 0.05)
                try require(paste == false && pair.local.reads == 0 && pair.localMessages.isEmpty,
                            "Sensitive contents were read, sent or marked paste-ready")
            }
            pair.local.isSensitive = false
            pair.local.copy(.text(Data("ordinary copy".utf8)))
            pair.localSync.setAutomaticSendingAllowed(true)
            try eventually("Ordinary copy did not resume after sensitive contents") { pair.remote.copiedText == "ordinary copy" }
        }

        run("Focus preference is optional, round-trips both states and rejects non-boolean input") { _ in
            let legacy = try Wire.readJSON(ClipboardPreference.self, Data("{\"enabled\":true}".utf8))
            try require(legacy.receivesAutomaticUpdates == nil && (legacy.receivesAutomaticUpdates ?? true),
                        "Legacy preference changed default sending behavior")
            for state in [false, true] {
                let preference = ClipboardPreference(enabled: true, session: UUID(), receivesAutomaticUpdates: state)
                let decoded = try Wire.readJSON(ClipboardPreference.self, JSONEncoder().encode(preference))
                try require(decoded.receivesAutomaticUpdates == state && decoded.fileApproval == true, "Focus preference changed in transit")
            }
            for value in ["1", "\"false\"", "[]"] {
                do {
                    _ = try Wire.readJSON(ClipboardPreference.self, Data("{\"enabled\":true,\"receivesAutomaticUpdates\":\(value)}".utf8))
                    throw FocusCheckFailure("Accepted a non-boolean focus preference")
                } catch is DecodingError { }
            }
            try require(MessageKind.clipboardSettings.rawValue == 11 && MessageKind.controlStatus.rawValue == 20 && Wire.version == 1,
                        "Existing protocol numbering changed")
        }

        run("Explicit dropped file transfer saves to received folder without reading or modifying either pasteboard") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     allowsChunkWindow: true, allowsDecoupledFileTransfer: true)
            defer { pair.stop() }
            let source = folder.appendingPathComponent("dropped-archive.zip")
            let expected = Data(repeating: 0x3C, count: 600_000)
            try expected.write(to: source)
            var receivedResult: (result: ClipboardFileResult, keptLocalCopy: Bool)?
            var senderCompleted = false
            pair.remoteSync.onFileOffer = { [weak remoteSync = pair.remoteSync] offer in
                if let offer { remoteSync?.respondToFileOffer(id: offer.id, accept: true) }
            }
            pair.remoteSync.onFileResult = { result, keptLocalCopy in
                receivedResult = (result, keptLocalCopy)
            }
            pair.localSync.onFileResult = { result, _ in
                if result.direction == .sending && result.outcome == .completed { senderCompleted = true }
            }
            let started = pair.localSync.sendDroppedFiles([source, source])
            try require(started, "sendDroppedFiles rejected valid local file")
            try eventually("Dropped file did not complete on both peers") {
                senderCompleted && receivedResult?.result.outcome == .completed
            }
            try require(pair.local.reads == 0 && pair.local.writes == 0
                        && pair.remote.reads == 0 && pair.remote.writes == 0,
                        "Explicit dropped file read or wrote system pasteboard (local \(pair.local.reads)/\(pair.local.writes), remote \(pair.remote.reads)/\(pair.remote.writes))")
            guard let files = receivedResult?.result.files, files.count == 1 else {
                throw FocusCheckFailure("Expected exactly one deduplicated received file")
            }
            try require((try? Data(contentsOf: files[0])) == expected, "Dropped file content mismatch")
        }

        run("Decoupled file transfer allows bidirectional text sync while a clipboard file transfer is mid-flight") { folder in
            let pair = ClipboardPair(storage: folder, localAllowed: true, remoteAllowed: true,
                                     allowsChunkWindow: true, allowsDecoupledFileTransfer: true)
            defer { pair.stop() }
            let source = folder.appendingPathComponent("large-video.mov")
            let expected = Data(repeating: 0x7E, count: 900_000)
            try expected.write(to: source)

            var fileCounter: UInt64?
            var holdFileChunks = true
            var heldChunks: [Message] = []
            var fileResult: (ClipboardFileResult, Bool)?
            pair.routeLocal = { message in
                if message.kind == .clipboardBegin,
                   let obj = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
                   obj["type"] as? String == "files",
                   let rev = obj["revision"] as? [String: Any],
                   let counter = (rev["counter"] as? NSNumber)?.uint64Value {
                    fileCounter = counter
                }
                if holdFileChunks {
                    if message.kind == .clipboardChunk {
                        var reader = ByteReader(message.payload)
                        if let counter: UInt64 = try? reader.take(), counter == fileCounter {
                            heldChunks.append(message)
                            return false
                        }
                    } else if message.kind == .clipboardEnd,
                              let obj = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
                              let rev = obj["revision"] as? [String: Any],
                              (rev["counter"] as? NSNumber)?.uint64Value == fileCounter {
                        heldChunks.append(message)
                        return false
                    }
                }
                return true
            }
            pair.remoteSync.onFileOffer = { [weak remoteSync = pair.remoteSync] offer in
                if let offer { remoteSync?.respondToFileOffer(id: offer.id, accept: true) }
            }
            pair.remoteSync.onFileResult = { result, kept in fileResult = (result, kept) }

            pair.local.copy(.files([source]))
            pair.localSync.sendLocalCopy()
            try eventually("File transfer did not enter mid-flight chunk streaming") { !heldChunks.isEmpty }

            pair.local.copy(.text(Data("text while sending file".utf8)))
            pair.localSync.sendLocalCopy()
            try eventually("Local-to-remote text blocked behind active file send") {
                pair.remote.copiedText == "text while sending file"
            }

            pair.remote.copy(.text(Data("text while receiving file".utf8)))
            pair.remoteSync.sendLocalCopy()
            try eventually("Remote-to-local text blocked behind active file receive") {
                pair.local.copiedText == "text while receiving file"
            }

            holdFileChunks = false
            for chunk in heldChunks { pair.remoteSync.receive(chunk) }
            heldChunks.removeAll()
            try eventually("Held file transfer did not finish after releasing chunks") {
                fileResult?.0.outcome == .completed
            }
            try require(fileResult?.1 == true && pair.remote.copiedText == "text while receiving file"
                        && fileResult?.0.files.count == 1
                        && (try? Data(contentsOf: fileResult!.0.files[0])) == expected,
                        "Completed background file overwrote newer text pasteboard or lost file bytes")
        }

        run("On-demand clipboard sends zero payload bytes or file offers on copy and materializes text, TIFF, and files only on paste") { folder in
            var tiffConversions = 0
            let validPNG: Data = {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )!
                return rep.representation(using: .png, properties: [:])!
            }()
            let pair = ClipboardPair(
                storage: folder,
                localAllowed: true,
                remoteAllowed: false,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                deferLocalFileOffer: true,
                convertLocalTIFF: { _ in
                    tiffConversions += 1
                    return validPNG
                }
            )
            defer { pair.stop() }

            var remoteOffer: ClipboardFileOffer?
            pair.remoteSync.onFileOffer = { remoteOffer = $0 }

            // 1. Copy text on viewer: only manifest sent, 0 payload reads, 0 chunks.
            pair.local.copy(.text(Data("paste-triggered-text".utf8)))
            try eventually("Text manifest was not installed lazily on remote") {
                pair.remote.hasLazyItem && pair.remote.lazyKind == .text
            }
            try require(pair.local.reads == 0
                        && pair.localMessages == [.clipboardManifest]
                        && pair.remote.copiedText == nil,
                        "On-demand text copy read payload or sent chunks before paste")

            // Enter remote control and press Cmd+V (prepareForPaste): materializes once, then holdsPaste becomes false.
            pair.localSync.setControllingRemote(true)
            try require(pair.localSync.holdsPaste, "Unmaterialized on-demand text copy did not hold first Cmd+V")
            var pasteReady: Bool?
            pair.localSync.prepareForPaste { pasteReady = $0 }
            try eventually("Cmd+V did not materialize on-demand text") { pasteReady == true }
            try require(pair.remote.copiedText == "paste-triggered-text" && !pair.localSync.holdsPaste,
                        "Materialized text did not arrive or continued holding subsequent Cmd+V")
            let beginsAfterFirstPaste = pair.localMessages.filter { $0 == .clipboardBegin }.count
            var secondPaste: Bool?
            pair.localSync.prepareForPaste { secondPaste = $0 }
            try require(secondPaste == true && pair.localMessages.filter { $0 == .clipboardBegin }.count == beginsAfterFirstPaste,
                        "Second Cmd+V re-transferred already materialized text")

            // 2. Copy TIFF image on viewer: 0 TIFF->PNG conversions on copy; converts only when pasted.
            pair.localSync.setControllingRemote(false)
            pair.local.copy(.text(Data()))
            pair.local.rawTIFF = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
            pair.localSync.sendLocalCopy()
            try eventually("PNG manifest for TIFF was not installed lazily on remote") {
                pair.remote.hasLazyItem && pair.remote.lazyKind == .png
            }
            try require(tiffConversions == 0, "TIFF image was converted on copy before any paste")
            pair.localSync.setControllingRemote(true)
            var imagePasteReady: Bool?
            pair.localSync.prepareForPaste { imagePasteReady = $0 }
            try eventually("Cmd+V did not materialize TIFF image") { imagePasteReady == true }
            try require(tiffConversions == 1, "TIFF conversion count was \(tiffConversions), expected 1")
            if case .png(let appliedPNG) = pair.remote.payload {
                try require(appliedPNG == validPNG, "Applied PNG bytes mismatched")
            } else {
                throw FocusCheckFailure("Remote did not receive materialized PNG")
            }

            // 3. Copy file on viewer (deferLocalFileOffer == true): 0 file prompts on copy; prompt appears only on Cmd+V.
            pair.localSync.setControllingRemote(false)
            let fileURL = folder.appendingPathComponent("deferred.txt")
            try Data("deferred-file".utf8).write(to: fileURL)
            pair.local.copy(.files([fileURL]))
            pump(for: 0.35)
            try require(remoteOffer == nil && !pair.localMessages.suffix(1).contains(.clipboardBegin),
                        "Viewer file copy triggered remote file prompt before Cmd+V")
            pair.localSync.setControllingRemote(true)
            try require(pair.localSync.holdsPaste, "Deferred file copy did not intercept first Cmd+V")
            var filePasteReady: Bool?
            pair.localSync.prepareForPaste { filePasteReady = $0 }
            try eventually("Cmd+V did not trigger deferred file offer on remote") { remoteOffer != nil }
            try require(filePasteReady == false && remoteOffer?.names == ["deferred.txt"],
                        "Deferred file offer did not require recipient confirmation")
        }

        run("On-demand clipboard supports right-click lazy paste in both directions without echo on focus switches") { folder in
            let validPNG: Data = {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )!
                return rep.representation(using: .png, properties: [:])!
            }()
            let pair = ClipboardPair(
                storage: folder,
                localAllowed: true,
                remoteAllowed: false,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                deferLocalFileOffer: true
            )
            defer { pair.stop() }

            // A -> B right-click paste: pulls on demand and marks A's copy materialized so subsequent Cmd+V doesn't re-push.
            pair.local.copy(.text(Data("right-click-from-viewer".utf8)))
            try eventually("Viewer manifest did not reach host") { pair.remote.hasLazyItem }
            pair.localSync.setControllingRemote(true)
            try require(pair.localSync.holdsPaste, "Viewer should hold paste before right-click pull completes")
            let pulledOnHost = pair.remote.simulatePaste()
            guard case .text(let hostBytes)? = pulledOnHost,
                  String(data: hostBytes, encoding: .utf8) == "right-click-from-viewer" else {
                throw FocusCheckFailure("Right-click paste on host did not pull viewer text")
            }
            try eventually("Viewer did not mark pulled copy as materialized") { !pair.localSync.holdsPaste }
            try require(pair.remoteMessages.contains(.clipboardPull), "Host did not use clipboardPull")

            // B -> A copy while controlled, then release control: 0 chunks sent on focus release, pulled only on paste on A.
            pair.remote.copy(.png(validPNG))
            pump(for: 0.35)
            let remoteChunksBeforeRelease = pair.remoteMessages.filter { $0 == .clipboardChunk }.count
            pair.localSync.setControllingRemote(false)
            pair.remoteSync.setAutomaticSendingAllowed(true)
            try eventually("Host PNG manifest did not reach viewer after releasing control") {
                pair.local.hasLazyItem && pair.local.lazyKind == .png
            }
            try require(pair.remoteMessages.filter { $0 == .clipboardChunk }.count == remoteChunksBeforeRelease,
                        "Releasing control eagerly streamed host PNG before viewer pasted")

            let pulledOnViewer = pair.local.simulatePaste()
            guard case .png(let viewerPNG)? = pulledOnViewer, viewerPNG == validPNG else {
                throw FocusCheckFailure("Local paste on viewer did not pull host PNG")
            }

            let localManifestsBeforeFocusBounce = pair.localMessages.filter { $0 == .clipboardManifest }.count
            let localBeginsBeforeFocusBounce = pair.localMessages.filter { $0 == .clipboardBegin }.count
            pair.localSync.setAutomaticSendingAllowed(false)
            pair.localSync.setAutomaticSendingAllowed(true)
            pump(for: 0.35)
            try require(pair.localMessages.filter { $0 == .clipboardManifest }.count == localManifestsBeforeFocusBounce
                        && pair.localMessages.filter { $0 == .clipboardBegin }.count == localBeginsBeforeFocusBounce,
                        "Focus bounce echoed pulled remote clipboard back to host")
        }

        run("Remote local copy while controlled invalidates viewer unmaterialized copy and reconnect re-announces unmaterialized copy") { folder in
            let pair = ClipboardPair(
                storage: folder,
                localAllowed: true,
                remoteAllowed: false,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                deferLocalFileOffer: true
            )
            defer { pair.stop() }

            pair.local.copy(.text(Data("viewer-stale-copy".utf8)))
            try eventually("Manifest did not reach remote") { pair.remote.hasLazyItem }
            let reconnectChangeWhileUnmaterialized = pair.localSync.handledChange
            try require(reconnectChangeWhileUnmaterialized != pair.local.changeCount,
                        "Unmaterialized copy handledChange would suppress re-announcement after reconnect")

            // Enter remote control; user copies something directly on remote host without pasting viewer's copy.
            pair.localSync.setControllingRemote(true)
            pair.remote.copy(.text(Data("host-own-copy".utf8)))
            try eventually("Remote copy while controlled did not invalidate viewer unmaterialized copy") {
                !pair.localSync.holdsPaste
            }
            var pasteReady: Bool?
            pair.localSync.prepareForPaste { pasteReady = $0 }
            try require(pasteReady == true && pair.remote.copiedText == "host-own-copy",
                        "Cmd+V on remote overwrote remote's newer copy with viewer's stale copy")

            // Verify reconnect handover re-announces an unmaterialized copy on the new session.
            pair.localSync.setControllingRemote(false)
            pair.local.copy(.text(Data("survives-reconnect".utf8)))
            try eventually("New manifest was not created") { pair.localSync.holdsPaste || pair.remote.hasLazyItem }
            let savedHandledChange = pair.localSync.handledChange
            let reconnectedRemote = MemoryPasteboard()
            let reconnectedSession = UUID()
            var reconnectedHostSync: ClipboardSync!
            let reconnectedViewerSync = ClipboardSync(
                session: reconnectedSession,
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                deferFileOfferUntilPaste: true,
                handledChange: savedHandledChange,
                pasteboard: pair.local,
                storage: folder.appendingPathComponent("reconnected-local")
            ) { message in
                DispatchQueue.main.async { reconnectedHostSync?.receive(message) }
            }
            reconnectedHostSync = ClipboardSync(
                session: reconnectedSession,
                allowsFileSending: true,
                allowsAutomaticSending: false,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: reconnectedRemote,
                storage: folder.appendingPathComponent("reconnected-remote")
            ) { message in
                DispatchQueue.main.async { reconnectedViewerSync.receive(message) }
            }
            defer {
                reconnectedViewerSync.stop()
                reconnectedHostSync.stop()
            }
            try eventually("Reconnected session did not re-announce unmaterialized viewer copy") {
                reconnectedRemote.hasLazyItem && reconnectedRemote.lazyKind == .text
            }
            let pulledAfterReconnect = reconnectedRemote.simulatePaste()
            guard case .text(let bytes)? = pulledAfterReconnect,
                  String(data: bytes, encoding: .utf8) == "survives-reconnect" else {
                throw FocusCheckFailure("Reconnected session failed to pull re-announced copy")
            }
        }

        run("File paste in either direction advertises only a type, waits for approval and publishes the received files") { folder in
            for reverse in [false, true] {
                let storage = folder.appendingPathComponent(reverse ? "host-source" : "viewer-source")
                let pair = ClipboardPair(storage: storage, localAllowed: !reverse, remoteAllowed: reverse,
                                         allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
                defer { pair.stop() }
                let source = reverse ? pair.remote : pair.local, sink = reverse ? pair.local : pair.remote
                let sender = reverse ? pair.remoteSync! : pair.localSync!, receiver = reverse ? pair.localSync! : pair.remoteSync!
                let sent = { reverse ? pair.remoteMessages : pair.localMessages }
                let requests = { reverse ? pair.localMessages : pair.remoteMessages }
                let originals = ["résumé.txt", "资料.bin"].map { folder.appendingPathComponent($0) }
                let contents = [Data("first root".utf8), Data(repeating: 0xE2, count: 150_000)]
                for (url, data) in zip(originals, contents) { try data.write(to: url) }
                var offer: ClipboardFileOffer?
                receiver.onFileOffer = { offer = $0 }
                source.copy(.files(originals))
                sender.sendLocalCopy()
                try eventually("No file promise appeared") { sink.inspectCurrentKind() == .files && sink.hasLazyItem }
                var ready: Bool?
                sender.prepareForPaste { ready = $0 }
                try eventually("The viewer could not forward its paste key") { ready == true }
                try require(sent() == [.clipboardManifest] && requests().isEmpty && offer == nil,
                            "Copy, format lookup or preparing the paste key started a file transfer")
                _ = sink.simulatePaste()
                _ = sink.simulatePaste()
                try eventually("The first content read did not produce the file offer") { offer != nil }
                try require(requests().filter { $0 == .clipboardPull }.count == 1 && offer?.count == 2,
                            "Repeated content reads caused a duplicate request or the offer lost a root")
                try require(!sent().contains(.clipboardEntry) && !sent().contains(.clipboardChunk),
                            "File entries or contents were transmitted before approval")
                receiver.respondToFileOffer(id: offer!.id, accept: true)
                try eventually("Approved files did not replace the promise") { !sink.hasLazyItem && sink.fileURLs?.count == 2 }
                let received = sink.fileURLs!
                try require(received.map(\.lastPathComponent) == originals.map(\.lastPathComponent)
                            && (try received.map { try Data(contentsOf: $0) }) == contents,
                            "Received file names, order or bytes differ")
            }
        }

        run("Older file promises are removed on decline, withdrawal or disconnect, while newer local copies survive") { folder in
            for ending in ["decline", "withdraw", "replace", "another session", "stop"] {
                let pair = ClipboardPair(storage: folder.appendingPathComponent(ending), localAllowed: true,
                                         allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
                defer { pair.stop() }
                let source = folder.appendingPathComponent("original.txt")
                try Data("original".utf8).write(to: source)
                var offer: ClipboardFileOffer?
                pair.remoteSync.onFileOffer = { offer = $0 }
                pair.local.copy(.files([source]))
                pair.localSync.sendLocalCopy()
                try eventually("No promise appeared") { pair.remote.hasLazyItem }
                switch ending {
                case "decline":
                    _ = pair.remote.simulatePaste()
                    try eventually("No offer to decline") { offer != nil }
                    pair.remoteSync.respondToFileOffer(id: offer!.id, accept: false)
                case "stop": pair.remoteSync.stop()
                default:
                    if ending == "replace" { pair.remote.copy(.text(Data("new local value".utf8))) }
                    if ending == "another session" {
                        try require(pair.local.write(.files([source]), marker: UUID().uuidString + ":files:previous-session"),
                                    "Unable to simulate another paired session's files")
                    } else {
                        pair.local.isSensitive = true
                        pair.local.copy(.text(Data("private".utf8)))
                    }
                    pair.localSync.sendLocalCopy()
                    try eventually("Source did not withdraw its manifest") { pair.localMessages.contains(.clipboardCancel) }
                }
                try eventually("Revoked file URL remained available") { !pair.remote.hasLazyItem }
                try require(!pair.localMessages.contains(.clipboardChunk), "File bytes escaped without approval")
                if ending == "replace" { try require(pair.remote.copiedText == "new local value", "Withdrawal erased a newer copy") }
            }
        }

        for (rootCount, approve, delay) in [(1, true, 0.0), (2, true, 13.0), (2, false, 0.0)] {
            run("One AppKit URL read copies \(rootCount) promised roots into the destination (approve: \(approve), delay: \(delay))") { folder in
                _ = NSApplication.shared.setActivationPolicy(.prohibited)
                let board = NSPasteboard(name: NSPasteboard.Name(filePasteBoardPrefix + UUID().uuidString))
                defer { board.releaseGlobally() }
                let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"), requireFileApproval: true,
                                               allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
                let wire = ChannelSafeBox<[MessageKind]>([]), requests = ChannelSafeBox<[MessageKind]>([]), sendResult = ChannelSafeBox<Bool?>(nil)
                let sink = ClipboardSync(session: UUID(), allowsFileSending: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true,
                                         pasteboard: SystemClipboardPasteboard(pasteboard: board), storage: folder.appendingPathComponent("receiver")) {
                    requests.append($0.kind); sender.receive($0)
                }
                defer { sink.stop(); sender.stop() }
                let first = folder.appendingPathComponent("empty.txt"), directory = folder.appendingPathComponent("资料")
                let roots = rootCount == 1 ? [first] : [directory, first]
                let destination = folder.appendingPathComponent("destination", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let content = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0) })
                try content.write(to: directory.appendingPathComponent("nested.bin")); try Data().write(to: first)
                let receive = sink.receiveMessage
                sender.onSend = { message in wire.append(message.kind); receive(message) }
                sender.onPullRequested = { [weak sender] request in
                    sender?.sendPulled(.files(roots), requestID: request.requestID) { sendResult.set($0) }
                }
                var prompts = 0, offeredTooLate = false
                sink.onFileOffer = { [weak sink] offer in
                    guard let offer else { return }
                    prompts += 1
                    offeredTooLate = wire.read().contains(.clipboardEntry) || wire.read().contains(.clipboardChunk)
                    let action = FileApprovalAction { sink?.respondToFileOffer(id: offer.id, accept: approve) }
                    let button = NSButton(title: approve ? "接收" : "拒绝", target: action, action: #selector(FileApprovalAction.click(_:)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withExtendedLifetime(action) { button.performClick(nil) }
                    }
                }
                sender.announceManifest(kind: .files, fileRootCount: rootCount)
                try eventually("The promised file items did not appear") { board.pasteboardItems?.count == rootCount }
                try require(board.availableType(from: [.fileURL]) == .fileURL && wire.read() == [.clipboardManifest],
                            "Looking up a file format started the download")
                let initialChange = board.changeCount
                @MainActor func paste(into target: URL) throws {
                    let consumer = Process()
                    consumer.executableURL = URL(fileURLWithPath: arguments[0])
                    consumer.arguments = ["--copy-file-urls", board.name.rawValue, target.path]
                    try consumer.run()
                    defer { if consumer.isRunning { consumer.terminate() } }
                    try eventually("A single content read did not finish", seconds: delay + 12) { !consumer.isRunning }
                    try require(consumer.terminationStatus == 0, "The separate paste consumer could not copy its file URLs")
                }
                try paste(into: destination)
                try eventually("The sender did not receive the transfer outcome") { sendResult.read() != nil }
                try require(sendResult.read() == approve && prompts == 1 && !offeredTooLate,
                            "A paste finished before approval or requested the files twice")
                let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
                try require(Set(names) == (approve ? Set(roots.map(\.lastPathComponent)) : []), "The first URL read did not copy exactly the selected roots")
                if approve {
                    try require(try Data(contentsOf: destination.appendingPathComponent("empty.txt")).isEmpty, "The empty file changed")
                    if rootCount > 1 {
                        try require(try Data(contentsOf: destination.appendingPathComponent("资料/nested.bin")) == content, "The folder lost data")
                        let again = folder.appendingPathComponent("second-paste", isDirectory: true)
                        try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
                        try paste(into: again)
                        try require(board.changeCount == initialChange && prompts == 1 && requests.read().filter { $0 == .clipboardPull }.count == 1
                                    && (try Data(contentsOf: again.appendingPathComponent("资料/nested.bin"))) == content
                                    && (try Data(contentsOf: again.appendingPathComponent("empty.txt"))).isEmpty,
                                    "A second paste replaced the original provider, asked again, or lost files")
                        _ = board.prepareForNewContents(with: .currentHostOnly)
                        try require(board.setString("new local copy", forType: .string), "Could not replace the named pasteboard")
                        sink.stop()
                        pump(for: 0.05)
                        try require(board.string(forType: .string) == "new local copy" && board.availableType(from: [.fileURL]) == nil,
                                    "Stopping the old file promise displaced the newer local copy")
                    }
                } else {
                    try require(!wire.read().contains(.clipboardChunk), "File contents followed a declined paste")
                }
            }
        }

        for boundary in ["before offer", "before approval", "after approval"] {
            run("A newer named-board copy \(boundary) protects the clipboard during the original paste") { folder in
                _ = NSApplication.shared.setActivationPolicy(.prohibited)
                let board = NSPasteboard(name: NSPasteboard.Name(filePasteBoardPrefix + UUID().uuidString))
                defer { board.releaseGlobally() }
                let receiverDirectory = folder.appendingPathComponent("receiver")
                let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"), requireFileApproval: true,
                                               allowsDecoupledFileTransfer: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
                let sink = ClipboardSync(session: UUID(), allowsFileSending: true, allowsAutomaticSending: false,
                                         allowsDecoupledFileTransfer: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true,
                                         pasteboard: SystemClipboardPasteboard(pasteboard: board), storage: receiverDirectory) { sender.receive($0) }
                defer { sink.stop(); sender.stop() }
                let source = folder.appendingPathComponent("selected.txt")
                let target = folder.appendingPathComponent("paste-destination", isDirectory: true)
                let data = Data([21, 72, 96])
                try data.write(to: source)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let result = ChannelSafeBox<Bool?>(nil), sent = ChannelSafeBox<[MessageKind]>([])
                var replacements = 0, offers = 0, keptFiles = false
                @MainActor func newLocalCopy() {
                    _ = board.prepareForNewContents(with: .currentHostOnly)
                    if board.setString("new local clipboard", forType: .string) { replacements += 1 }
                }
                let receive = sink.receiveMessage
                sender.onSend = { message in
                    sent.append(message.kind)
                    if (boundary == "before offer" && message.kind == .clipboardBegin)
                        || (boundary == "after approval" && message.kind == .clipboardChunk) {
                        DispatchQueue.main.async { newLocalCopy(); receive(message) }
                    } else { receive(message) }
                }
                sender.onPullRequested = { [weak sender] request in
                    sender?.sendPulled(.files([source]), requestID: request.requestID) { result.set($0) }
                }
                sink.onFileOffer = { [weak sink] offer in
                    guard let offer else { return }
                    offers += 1
                    if boundary == "before approval" { newLocalCopy() }
                    sink?.respondToFileOffer(id: offer.id, accept: true)
                }
                sink.onReceivedFilesKept = { keptFiles = true }
                sender.announceManifest(kind: .files, fileRootCount: 1)
                try eventually("The named board did not receive the file promise") { board.availableType(from: [.fileURL]) == .fileURL }
                let consumer = Process()
                consumer.executableURL = URL(fileURLWithPath: arguments[0])
                consumer.arguments = ["--copy-file-urls", board.name.rawValue, target.path]
                try consumer.run()
                defer { if consumer.isRunning { consumer.terminate() } }
                try eventually("The original paste did not settle", seconds: 8) { !consumer.isRunning && result.read() != nil }
                let accepted = boundary == "after approval"
                try require(replacements == 1 && board.string(forType: .string) == "new local clipboard",
                            "The file transfer replaced the newer local copy")
                try require(result.read() == accepted && offers == (boundary == "before offer" ? 0 : 1),
                            "The offer was approved using a later clipboard change")
                try require(consumer.terminationStatus == 0 && sent.read().contains(.clipboardChunk) == accepted,
                            "Files were sent across a cancelled offer")
                let output = target.appendingPathComponent(source.lastPathComponent)
                if accepted {
                    try eventually("The saved-file notice did not reach the receiver") { keptFiles }
                    let received = receiverDirectory.appendingPathComponent("received")
                    let transfers = try FileManager.default.contentsOfDirectory(at: received, includingPropertiesForKeys: nil)
                    try require(transfers.count == 1 && (try Data(contentsOf: transfers[0].appendingPathComponent(source.lastPathComponent))) == data,
                                "The accepted file was lost after the pasteboard owner changed")
                    if FileManager.default.fileExists(atPath: output.path) {
                        try require(try Data(contentsOf: output) == data, "The original paste received a partial file")
                    }
                } else {
                    try require(!FileManager.default.fileExists(atPath: output.path), "An unapproved paste created a file")
                }
            }
        }

        run("AppKit file-URL format queries leave the promise idle and content reads request it once") { folder in
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let system = SystemClipboardPasteboard(pasteboard: board)
            var reads = 0
            try require(system.writeLazy(.files, marker: "test-revision", fetch: {
                reads += 1
                return nil
            }, asyncFetch: { $0(nil) }), "Could not install file promise")
            try require(system.inspectCurrentKind() == .files && board.availableType(from: [.fileURL]) == .fileURL
                        && board.pasteboardItems?.count == 1 && reads == 0, "Inspecting file metadata requested the content")
            for _ in 0..<2 {
                _ = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            }
            try require(reads == 1, "File content was requested an unexpected number of times")
            let urls = ["one", "two"].map { folder.appendingPathComponent($0) }
            for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
            try require(system.write(.files(urls), marker: "received") && system.fileURLs == urls,
                        "AppKit could not read the materialized file URLs")
            system.discardFilePromise(marker: "test-revision")
            try require(system.fileURLs == urls, "Stale cleanup erased the received files")
        }

        run("SystemClipboardPasteboard NSPasteboardItemDataProvider pulls multi-chunk text and PNG synchronously on demand") { folder in
            let isolatedSourcePB = NSPasteboard.withUniqueName()
            let isolatedSinkPB = NSPasteboard.withUniqueName()
            defer {
                isolatedSourcePB.releaseGlobally()
                isolatedSinkPB.releaseGlobally()
            }
            let sourcePasteboard = SystemClipboardPasteboard(pasteboard: isolatedSourcePB)
            let sinkPasteboard = SystemClipboardPasteboard(pasteboard: isolatedSinkPB)
            let wireQueue = DispatchQueue(label: "checks.appkit.lazy-pasteboard.wire")

            let sourceTransfer = ClipboardTransfer(
                storage: folder.appendingPathComponent("sys-src"),
                requireFileApproval: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true
            )
            var sinkSync: ClipboardSync!
            let sourcePayloadBox = ChannelSafeBox<ClipboardPayload>(.text(Data()))
            let sentBySource = ChannelSafeBox<[MessageKind]>([])

            sourceTransfer.onSend = { msg in
                sentBySource.append(msg.kind)
                wireQueue.async { sinkSync?.receive(msg) }
            }
            sourceTransfer.onPullRequested = { [weak sourceTransfer] req in
                sourceTransfer?.sendPulled(sourcePayloadBox.read(), requestID: req.requestID)
            }

            sinkSync = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: false,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: sinkPasteboard,
                storage: folder.appendingPathComponent("sys-sink")
            ) { msg in
                wireQueue.async { sourceTransfer.receive(msg) }
            }
            defer {
                sinkSync.stop()
                sourceTransfer.stop()
            }

            // Verify inspectCurrentKind() inspects NSPasteboard.types metadata correctly.
            isolatedSourcePB.clearContents()
            isolatedSourcePB.setString("meta-check", forType: .string)
            try require(sourcePasteboard.inspectCurrentKind() == .text, "SystemClipboardPasteboard failed to detect .text")

            // 1. Multi-chunk text lazy NSPasteboardItemDataProvider synchronous pull on @MainActor.
            let expectedString = String(repeating: "QuietDesk按需粘贴测试-", count: 8_000)
            sourcePayloadBox.set(.text(Data(expectedString.utf8)))
            let baselineChange = isolatedSinkPB.changeCount
            sourceTransfer.announceManifest(kind: .text)
            try eventually("Lazy text item was not installed on isolated NSPasteboard") {
                isolatedSinkPB.changeCount != baselineChange
            }
            try require(isolatedSinkPB.types?.contains(.string) == true,
                        "Lazy NSPasteboardItem did not advertise .string for right-click Paste menu")
            try require(sentBySource.snapshot() == [.clipboardManifest],
                        "Text chunks were sent before NSPasteboard requested data")

            let materializedString = isolatedSinkPB.string(forType: .string)
            try require(materializedString == expectedString,
                        "NSPasteboardItemDataProvider synchronous text pull failed or corrupted string")
            try require(sentBySource.snapshot().contains(.clipboardChunk),
                        "Expected multi-chunk pull transfer over background wire")

            // 2. Real PNG lazy NSPasteboardItemDataProvider synchronous pull on @MainActor.
            let validPNG: Data = {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )!
                return rep.representation(using: .png, properties: [:])!
            }()
            sourcePayloadBox.set(.png(validPNG))
            let beforePNGChange = isolatedSinkPB.changeCount
            let countBeforePNGAnnounce = sentBySource.snapshot().count
            sourceTransfer.announceManifest(kind: .png)
            try eventually("Lazy PNG item was not installed on isolated NSPasteboard") {
                isolatedSinkPB.changeCount != beforePNGChange
            }
            try require(isolatedSinkPB.types?.contains(.png) == true,
                        "Lazy NSPasteboardItem did not advertise .png for right-click Paste menu")
            try require(sentBySource.snapshot().dropFirst(countBeforePNGAnnounce) == [.clipboardManifest],
                        "PNG chunks were sent before NSPasteboard requested data")

            let materializedPNG = isolatedSinkPB.data(forType: .png)
            try require(materializedPNG == validPNG,
                        "NSPasteboardItemDataProvider synchronous PNG pull failed or corrupted bytes")
        }

        run("Universal Clipboard Handoff relay never triggers LAN ping-pong loop in on-demand or eager mode") { folder in
            // 1. On-demand mode: both Macs active on LAN with Handoff enabled.
            let pair = ClipboardPair(
                storage: folder.appendingPathComponent("ondemand"),
                localAllowed: true,
                remoteAllowed: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                deferLocalFileOffer: true
            )
            defer { pair.stop() }

            pair.local.copy(.text(Data("lan-handoff-text".utf8)))
            try eventually("Initial text manifest did not reach peer") {
                pair.remote.hasLazyItem && pair.remote.lazyKind == .text
            }
            try require(pair.localMessages == [.clipboardManifest] && pair.remoteMessages.isEmpty,
                        "Unexpected messages on initial text manifest")

            // Handoff delivers the copied text to remote Mac ~300ms later with com.apple.is-remote-clipboard.
            let remoteReadsBeforeRelay = pair.remote.reads
            pair.remote.isRelayedFromOtherDevice = true
            pair.remote.copy(.text(Data("lan-handoff-text".utf8)))
            pump(for: 0.7)
            try require(pair.remoteMessages.isEmpty && pair.localMessages == [.clipboardManifest],
                        "Handoff-relayed text caused remote Mac to echo manifest or invalidate sender")
            try require(pair.remote.reads == remoteReadsBeforeRelay && pair.local.writes == 0,
                        "Handoff-relayed text was read or overwrote sender clipboard")
            try require(pair.localSync.holdsPaste,
                        "Handoff arrival on remote prematurely cancelled sender unmaterialized copy")

            // Clicking into remote canvas and pressing Cmd+V still materializes sender's copy cleanly.
            pair.remoteSync.setAutomaticSendingAllowed(false)
            pair.localSync.setControllingRemote(true)
            var pasteReady: Bool?
            pair.localSync.prepareForPaste { pasteReady = $0 }
            try eventually("Cmd+V after Handoff relay did not materialize text") { pasteReady == true }
            try require(pair.remote.copiedText == "lan-handoff-text",
                        "Materialized text was dropped due to Handoff changeCount bump")
            pair.remote.isRelayedFromOtherDevice = false

            // PNG / raw TIFF relayed via Handoff while remote can send must neither convert TIFF nor echo.
            pair.localSync.setControllingRemote(false)
            pair.remoteSync.setAutomaticSendingAllowed(true)
            let localMsgCountBeforeTIFF = pair.localMessages.count
            let remoteMsgCountBeforeTIFF = pair.remoteMessages.count
            pair.remote.isRelayedFromOtherDevice = true
            pair.remote.copy(.png(Data([1, 2, 3, 4])))
            pair.remote.rawTIFF = Data([9, 9, 9, 9])
            pump(for: 0.65)
            try require(pair.remoteMessages.count == remoteMsgCountBeforeTIFF
                        && pair.localMessages.count == localMsgCountBeforeTIFF,
                        "Handoff-relayed image triggered on-demand manifest loop")
            pair.remote.rawTIFF = nil
            pair.remote.isRelayedFromOtherDevice = false

            // Deferred file copy + Handoff arriving both before Cmd+V and during file reception keeps pasteboard ownership.
            let sourceFile = folder.appendingPathComponent("handoff-doc.txt")
            try Data("file-over-lan".utf8).write(to: sourceFile)
            var pendingOffer: ClipboardFileOffer?
            var keptLocally = false
            pair.remoteSync.onFileOffer = { pendingOffer = $0 }
            pair.remoteSync.onReceivedFilesKept = { keptLocally = true }
            pair.local.copy(.files([sourceFile]))
            try eventually("Deferred file manifest was not recorded") {
                pair.localMessages.suffix(1) == [.clipboardManifest]
            }
            // Handoff bumps remote pasteboard before Cmd+V.
            let remoteMsgsBeforeFileHandoff = pair.remoteMessages.count
            pair.remote.isRelayedFromOtherDevice = true
            pair.remote.copy(.text(Data("handoff-placeholder".utf8)))
            pump(for: 0.35)
            try require(pair.remoteMessages.count == remoteMsgsBeforeFileHandoff && pair.localSync.holdsPaste,
                        "Handoff arrival invalidated deferred file manifest")

            pair.remoteSync.setAutomaticSendingAllowed(false)
            pair.localSync.setControllingRemote(true)
            var filePasteReady: Bool?
            pair.localSync.prepareForPaste { filePasteReady = $0 }
            try eventually("Deferred file offer did not reach remote on Cmd+V") { pendingOffer != nil }
            try require(filePasteReady == false, "File paste should wait for remote approval")
            // Handoff bumps remote pasteboard again while approval prompt is open.
            pair.remote.copy(.text(Data("handoff-during-prompt".utf8)))
            pair.remoteSync.respondToFileOffer(id: pendingOffer!.id, accept: true)
            try eventually("Accepted file was not written to remote pasteboard") {
                if case .files(let urls) = pair.remote.payload { return urls.count == 1 }
                return false
            }
            try require(!keptLocally, "Handoff bump during file prompt falsely suppressed pasteboard write")
            pair.remote.isRelayedFromOtherDevice = false

            // Genuine local copy on remote Mac still invalidates sender's unmaterialized manifest.
            pair.localSync.setControllingRemote(false)
            pair.local.copy(.text(Data("viewer-next-copy".utf8)))
            try eventually("Viewer next copy manifest did not arrive") { pair.remote.hasLazyItem }
            pair.localSync.setControllingRemote(true)
            pair.remote.copy(.text(Data("genuine-remote-copy".utf8)))
            try eventually("Genuine remote copy did not invalidate viewer manifest") { !pair.localSync.holdsPaste }

            // 2. Legacy eager mode + mixed-version echo resilience + inactive Handoff before taking control.
            let eagerPair = ClipboardPair(
                storage: folder.appendingPathComponent("eager"),
                localAllowed: true,
                remoteAllowed: true
            )
            defer { eagerPair.stop() }

            eagerPair.local.copy(.text(Data("eager-lan".utf8)))
            try eventually("Eager copy did not reach remote") { eagerPair.remote.copiedText == "eager-lan" }
            let initialLocalBegins = eagerPair.localMessages.filter { $0 == .clipboardBegin }.count
            try require(initialLocalBegins == 1 && eagerPair.remoteMessages.filter { $0 == .clipboardBegin }.isEmpty,
                        "Unexpected eager transfer counts before Handoff simulation")

            // Simulate Handoff echoing back on both Macs (e.g., if peer was an older version without .currentHostOnly).
            eagerPair.remote.isRelayedFromOtherDevice = true
            eagerPair.remote.republish()
            eagerPair.local.isRelayedFromOtherDevice = true
            eagerPair.local.republish()
            pump(for: 0.7)
            try require(eagerPair.localMessages.filter { $0 == .clipboardBegin }.count == 1
                        && eagerPair.remoteMessages.filter { $0 == .clipboardBegin }.isEmpty,
                        "Handoff echo caused infinite ping-pong loop in eager mode")

            // Handoff arrives while QuietDesk is inactive, then user clicks directly into remote canvas and presses Cmd+V.
            eagerPair.localSync.setAutomaticSendingAllowed(false)
            eagerPair.local.isRelayedFromOtherDevice = true
            eagerPair.local.copy(.text(Data("relayed-while-inactive".utf8)))
            eagerPair.localSync.setControllingRemote(true)
            eagerPair.localSync.setAutomaticSendingAllowed(true)
            try require(!eagerPair.localSync.holdsPaste, "Relayed item while inactive should not hold remote Cmd+V")
            var remotePastePassThrough: Bool?
            eagerPair.localSync.prepareForPaste { remotePastePassThrough = $0 }
            try require(remotePastePassThrough == true
                        && eagerPair.localMessages.filter { $0 == .clipboardBegin }.count == 1,
                        "Cmd+V on remote canvas attempted to echo Handoff item")
        }

        run("SystemClipboardPasteboard marks writes current-host-only and suppresses relayed pasteboard items") { folder in
            let isolatedPB = NSPasteboard.withUniqueName()
            defer { isolatedPB.releaseGlobally() }
            let sysPB = SystemClipboardPasteboard(pasteboard: isolatedPB)

            let marker = "\(UUID().uuidString):text:check"
            try require(sysPB.write(.text(Data("host-only-write".utf8)), marker: marker),
                        "SystemClipboardPasteboard.write failed on isolated pasteboard")
            try require(sysPB.text == "host-only-write" && sysPB.contentMarker == marker && !sysPB.isRelayedFromOtherDevice,
                        "Written pasteboard item lost text, marker, or falsely flagged relay")

            let lazyMarker = "\(UUID().uuidString):lazy:text:\(UUID().uuidString):1"
            try require(sysPB.writeLazy(
                .text,
                marker: lazyMarker,
                fetch: { .text(Data("lazy-host-only".utf8)) },
                asyncFetch: { $0(.text(Data("lazy-host-only".utf8))) }
            ), "SystemClipboardPasteboard.writeLazy failed on isolated pasteboard")
            try require(sysPB.contentMarker == lazyMarker && !sysPB.isRelayedFromOtherDevice,
                        "Lazy pasteboard item lost marker or falsely flagged relay")
            try require(sysPB.text == "lazy-host-only", "Lazy pasteboard item did not materialize")

            let sent = ChannelSafeBox<[MessageKind]>([])
            let sync = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: sysPB,
                storage: folder.appendingPathComponent("sys-relay")
            ) { msg in
                sent.append(msg.kind)
            }
            defer { sync.stop() }

            // Simulate macOS Continuity / Universal Clipboard writing an item with com.apple.is-remote-clipboard.
            let relayedItem = NSPasteboardItem()
            relayedItem.setString("from-nearby-mac", forType: .string)
            relayedItem.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.is-remote-clipboard"))
            _ = isolatedPB.prepareForNewContents(with: .currentHostOnly)
            try require(isolatedPB.writeObjects([relayedItem]), "Failed to write simulated Handoff item")
            try require(sysPB.isRelayedFromOtherDevice, "SystemClipboardPasteboard did not detect com.apple.is-remote-clipboard")

            pump(for: 0.65)
            try require(sent.snapshot().isEmpty, "ClipboardSync announced or sent a com.apple.is-remote-clipboard item")
        }

        run("Pre-connection viewer copy pastes immediately on controlled Mac via Cmd+V or right-click without re-copying") { folder in
            @MainActor
            func makePreConnectPair(
                name: String,
                viewerPB: MemoryPasteboard,
                hostPB: MemoryPasteboard,
                viewerAllowed: Bool = true,
                hostAllowed: Bool = true,
                controllingAtInit: Bool = false,
                onDemand: Bool = true
            ) -> (viewer: ClipboardSync, host: ClipboardSync, viewerMsgs: ChannelSafeBox<[MessageKind]>, hostMsgs: ChannelSafeBox<[MessageKind]>) {
                let session = UUID()
                let viewerMsgs = ChannelSafeBox<[MessageKind]>([])
                let hostMsgs = ChannelSafeBox<[MessageKind]>([])
                var viewerSync: ClipboardSync!
                var hostSync: ClipboardSync!
                viewerSync = ClipboardSync(
                    session: session,
                    allowsFileSending: true,
                    allowsAutomaticSending: viewerAllowed,
                    allowsChunkWindow: true,
                    allowsDecoupledFileTransfer: true,
                    allowsOnDemandClipboard: onDemand,
                    deferFileOfferUntilPaste: onDemand,
                    controllingRemote: controllingAtInit,
                    syncInitialLocalClipboard: true,
                    pasteboard: viewerPB,
                    storage: folder.appendingPathComponent("\(name)-viewer"),
                    convertTIFF: { $0 },
                    validatePNG: { !$0.isEmpty }
                ) { msg in
                    viewerMsgs.append(msg.kind)
                    DispatchQueue.main.async { hostSync?.receive(msg) }
                }
                hostSync = ClipboardSync(
                    session: session,
                    allowsFileSending: true,
                    allowsAutomaticSending: hostAllowed,
                    allowsChunkWindow: true,
                    allowsDecoupledFileTransfer: true,
                    allowsOnDemandClipboard: onDemand,
                    deferFileOfferUntilPaste: false,
                    syncInitialLocalClipboard: false,
                    pasteboard: hostPB,
                    storage: folder.appendingPathComponent("\(name)-host"),
                    validatePNG: { !$0.isEmpty }
                ) { msg in
                    hostMsgs.append(msg.kind)
                    DispatchQueue.main.async { viewerSync?.receive(msg) }
                }
                return (viewerSync, hostSync, viewerMsgs, hostMsgs)
            }

            // 1. Text copied before connecting -> right-click Paste on Host works on first try; Host's own old clipboard does not echo.
            do {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.text(Data("pre-connect-right-click".utf8)))
                hostPB.copy(.text(Data("host-preexisting".utf8)))
                let p = makePreConnectPair(name: "rc", viewerPB: viewerPB, hostPB: hostPB)
                defer { p.viewer.stop(); p.host.stop() }

                try eventually("Pre-connection manifest did not reach host") {
                    hostPB.hasLazyItem && hostPB.lazyKind == .text
                }
                try require(p.viewerMsgs.snapshot() == [.clipboardManifest] && p.hostMsgs.snapshot().isEmpty,
                            "Pre-connection sync sent eager bytes or host echoed its pre-session clipboard")
                let pasted = hostPB.simulatePaste()
                guard case .text(let bytes)? = pasted,
                      String(data: bytes, encoding: .utf8) == "pre-connect-right-click" else {
                    throw FocusCheckFailure("Right-click paste on host failed to pull viewer's pre-connection text")
                }
            }

            // 2. Text copied before connecting -> user already clicked remote canvas at init (controllingAtInit: true) and presses Cmd+V at 0ms.
            do {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.text(Data("pre-connect-cmd-v-immediate".utf8)))
                let p = makePreConnectPair(
                    name: "cmdv0",
                    viewerPB: viewerPB,
                    hostPB: hostPB,
                    hostAllowed: false,
                    controllingAtInit: true
                )
                defer { p.viewer.stop(); p.host.stop() }

                try require(p.viewer.holdsPaste, "Viewer did not hold Cmd+V at 0ms for pre-connection copy while controlling")
                var pasteReady: Bool?
                p.viewer.prepareForPaste { pasteReady = $0 }
                try eventually("First Cmd+V did not materialize pre-connection text") { pasteReady == true }
                try require(hostPB.copiedText == "pre-connect-cmd-v-immediate" && !p.viewer.holdsPaste,
                            "Host did not receive pre-connection text on first Cmd+V")
            }

            // 3. Raw TIFF screenshot and Finder file copied before connecting; also verify remote copy invalidation.
            do {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.text(Data()))
                viewerPB.rawTIFF = Data([0x89, 0x50, 0x4E, 0x47])
                let p = makePreConnectPair(name: "tiff", viewerPB: viewerPB, hostPB: hostPB)
                defer { p.viewer.stop(); p.host.stop() }

                try eventually("Pre-connection TIFF manifest did not reach host") {
                    hostPB.hasLazyItem && hostPB.lazyKind == .png
                }
                try require(viewerPB.reads == 0, "Pre-connection TIFF was read/converted before paste")
                p.host.setAutomaticSendingAllowed(false)
                p.viewer.setControllingRemote(true)
                var pngPasteReady: Bool?
                p.viewer.prepareForPaste { pngPasteReady = $0 }
                try eventually("First Cmd+V did not convert and send pre-connection TIFF") { pngPasteReady == true }
                if case .png(let bytes) = hostPB.payload {
                    try require(bytes == Data([0x89, 0x50, 0x4E, 0x47]), "Pre-connection TIFF bytes mismatched")
                } else {
                    throw FocusCheckFailure("Host did not apply pre-connection PNG")
                }
            }

            do {
                let file = folder.appendingPathComponent("pre-connect-file.txt")
                try Data("hello-file".utf8).write(to: file)
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.files([file]))
                let p = makePreConnectPair(name: "file", viewerPB: viewerPB, hostPB: hostPB, hostAllowed: false)
                defer { p.viewer.stop(); p.host.stop() }

                var offer: ClipboardFileOffer?
                p.host.onFileOffer = { offer = $0 }
                try eventually("Pre-connection deferred file manifest was not announced") {
                    p.viewerMsgs.snapshot() == [.clipboardManifest]
                }
                pump(for: 0.2)
                try require(offer == nil, "Pre-connection file popped an unsolicited confirmation before Cmd+V")
                p.viewer.setControllingRemote(true)
                try require(p.viewer.holdsPaste, "Pre-connection file did not hold Cmd+V")
                var filePaste: Bool?
                p.viewer.prepareForPaste { filePaste = $0 }
                try eventually("Cmd+V did not send pre-connection file offer") { offer != nil }
                try require(filePaste == false, "File paste should await remote approval")
                p.host.respondToFileOffer(id: offer!.id, accept: true)
                try eventually("Accepted pre-connection file was not applied") {
                    if case .files(let urls) = hostPB.payload { return urls.count == 1 }
                    return false
                }
            }

            // 4. Connection finishes while viewer automatic sending is temporarily suspended (inactive / auto-unlock), then resumes; also legacy eager mode.
            do {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.text(Data("pre-connect-suspended".utf8)))
                let p = makePreConnectPair(
                    name: "suspended",
                    viewerPB: viewerPB,
                    hostPB: hostPB,
                    viewerAllowed: false,
                    hostAllowed: false,
                    controllingAtInit: true
                )
                defer { p.viewer.stop(); p.host.stop() }
                pump(for: 0.35)
                try require(viewerPB.reads == 0 && p.viewerMsgs.snapshot().isEmpty,
                            "Suspended viewer read or sent pre-connection clipboard prematurely")
                p.viewer.setAutomaticSendingAllowed(true)
                try eventually("Resumed viewer did not announce pre-connection copy") {
                    hostPB.hasLazyItem && hostPB.lazyKind == .text
                }
                var pasteReady: Bool?
                p.viewer.prepareForPaste { pasteReady = $0 }
                try eventually("Cmd+V after resume did not paste pre-connection copy") {
                    pasteReady == true && hostPB.copiedText == "pre-connect-suspended"
                }
            }

            do {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                viewerPB.copy(.text(Data("pre-connect-legacy-peer".utf8)))
                let p = makePreConnectPair(name: "legacy", viewerPB: viewerPB, hostPB: hostPB, hostAllowed: false, onDemand: false)
                defer { p.viewer.stop(); p.host.stop() }
                try eventually("Legacy peer did not receive pre-connection text") {
                    hostPB.copiedText == "pre-connect-legacy-peer"
                }
            }

            // 5. Sensitive pairing code, empty/unsupported pasteboard, or Handoff-relayed item before connecting are silently ignored without error status or blocking remote Cmd+V.
            for mode in ["sensitive", "empty", "relayed"] {
                let viewerPB = MemoryPasteboard()
                let hostPB = MemoryPasteboard()
                hostPB.copy(.text(Data("remote-native".utf8)))
                switch mode {
                case "sensitive":
                    viewerPB.copy(.text(Data("secret-pairing-code".utf8)))
                    viewerPB.isSensitive = true
                case "empty":
                    viewerPB.copy(.files([]))
                default:
                    viewerPB.copy(.text(Data("handoff-before-connect".utf8)))
                    viewerPB.isRelayedFromOtherDevice = true
                }
                var statuses: [String] = []
                let p = makePreConnectPair(
                    name: "skip-\(mode)",
                    viewerPB: viewerPB,
                    hostPB: hostPB,
                    hostAllowed: false,
                    controllingAtInit: true
                )
                p.viewer.onStatus = { statuses.append($0) }
                defer { p.viewer.stop(); p.host.stop() }

                var pastePassThrough: Bool?
                p.viewer.prepareForPaste { pastePassThrough = $0 }
                pump(for: 0.35)
                try require(pastePassThrough == true && !p.viewer.holdsPaste
                            && viewerPB.reads == 0 && p.viewerMsgs.snapshot().isEmpty && statuses.isEmpty,
                            "Pre-connection \(mode) clipboard emitted error status, read payload, or blocked remote Cmd+V")
            }
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
