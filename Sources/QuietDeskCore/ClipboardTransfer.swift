import Foundation
import Darwin

public enum ClipboardPayload: Sendable {
    case text(Data), png(Data), files([URL])
}

public enum ClipboardAutomaticLimits {
    public static let textBytes: UInt64 = 16 * 1_024 * 1_024
    public static let imageBytes: UInt64 = 64 * 1_024 * 1_024

    public static func validate(type: String, bytes: UInt64) throws {
        if type == "text", bytes > textBytes { throw DeskError.invalid("文字超过 16 MiB，未自动同步，请保存为文件后复制") }
        if type == "png", bytes > imageBytes { throw DeskError.invalid("图片超过 64 MiB，未自动同步，请保存为文件后复制") }
    }
}

public struct ClipboardRevision: Codable, Equatable, Comparable {
    public let counter: UInt64
    public let origin: UUID
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.origin.uuidString < rhs.origin.uuidString : lhs.counter < rhs.counter
    }
}

public struct ClipboardPreference: Codable {
    public let enabled: Bool
    public let session: UUID?
    public let fileApproval: Bool?
    public let receivesAutomaticUpdates: Bool?
    public let chunkWindow: Bool?
    public let decoupledFileTransfer: Bool?
    public init(enabled: Bool, session: UUID? = nil, fileApproval: Bool? = true, receivesAutomaticUpdates: Bool? = nil,
                chunkWindow: Bool? = true, decoupledFileTransfer: Bool? = true) {
        self.enabled = enabled; self.session = session; self.fileApproval = fileApproval
        self.receivesAutomaticUpdates = receivesAutomaticUpdates
        self.chunkWindow = chunkWindow
        self.decoupledFileTransfer = decoupledFileTransfer
    }
}

public struct ClipboardFileOffer: Identifiable {
    public let id: UUID
    public let names: [String]
    public let count: Int
    public let entryCount: Int
    public let bytes: UInt64
    public let createdUptime: TimeInterval
    public let isExplicitDrop: Bool

    public init(id: UUID, names: [String], count: Int, bytes: UInt64, entryCount: Int? = nil,
                createdUptime: TimeInterval = SessionClock.now, isExplicitDrop: Bool = false) {
        self.id = id; self.names = names; self.count = count; self.bytes = bytes
        self.entryCount = entryCount ?? count
        self.createdUptime = createdUptime
        self.isExplicitDrop = isExplicitDrop
    }
}

public enum ClipboardFileOfferEndReason {
    case accepted, declined, superseded, cancelled, failed, timedOut, stopped
}

public final class ClipboardApplyPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public var isValid: Bool { lock.withLock { valid } }

    public func performIfValid(_ apply: () -> Bool) -> Bool {
        lock.withLock {
            guard valid else { return false }
            valid = false
            return apply()
        }
    }

    fileprivate func invalidate() { lock.withLock { valid = false } }
}

private struct ClipboardBegin: Codable {
    let revision: ClipboardRevision
    let sequence: UInt64
    let type: String
    let count: Int
    let bytes: UInt64
    let names: [String]?
    let rootCount: Int?
    let chunkWindow: Bool?
    let independentFileLane: Bool?
    let explicitDrop: Bool?

    init(revision: ClipboardRevision, sequence: UInt64, type: String, count: Int, bytes: UInt64,
         names: [String]?, rootCount: Int?, chunkWindow: Bool?,
         independentFileLane: Bool? = nil, explicitDrop: Bool? = nil) {
        self.revision = revision
        self.sequence = sequence
        self.type = type
        self.count = count
        self.bytes = bytes
        self.names = names
        self.rootCount = rootCount
        self.chunkWindow = chunkWindow
        self.independentFileLane = independentFileLane
        self.explicitDrop = explicitDrop
    }
}

private struct ClipboardEntry: Codable {
    let revision: ClipboardRevision
    let sequence: UInt64
    let path: String
    let directory: Bool
    let bytes: UInt64
    let mode: Int
    let modified: Double
}

private struct ClipboardReceipt: Codable {
    let revision: ClipboardRevision
    let sequence: UInt64
    let reason: String?
}

public enum ClipboardPaths {
    public static func destination(root: URL, relative: String) throws -> URL {
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeskError.invalid("文件路径无效")
        }
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw DeskError.invalid("文件路径超出接收目录") }
        return url
    }
}

// File I/O, protocol ordering and mutable state are confined to queue.
public final class ClipboardTransfer {
    public static let maximumFileEntries = 200_000

    public static func previewName(_ name: String) -> String {
        String(decoding: name.utf8.prefix(120), as: UTF8.self)
    }

    public var onSend: ((Message) -> Void)?
    public var onReceive: ((ClipboardPayload) -> Void)?
    public var onExplicitFilesReceived: (([URL]) -> Void)?
    public var onApply: ((ClipboardPayload, @escaping (Bool) -> Void) -> Void)?
    public var onApplyWithPermit: ((ClipboardPayload, ClipboardApplyPermit, @escaping (Bool) -> Void) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    public var onFileOfferEnded: ((UUID, ClipboardFileOfferEndReason) -> Void)?
    public var onFileReceptionChanged: ((UUID?) -> Void)?
    public var onFileTransferStarted: (() -> Void)?
    public var onFileResult: ((ClipboardFileResult) -> Void)?
    private let queue = DispatchQueue(label: "quietdesk.clipboard.files", qos: .utility)
    private let storage: URL
    private let requireFileApproval: Bool
    private let allowsChunkWindow: Bool
    private let allowsDecoupledFileTransfer: Bool
    private let availableCapacity: (URL) throws -> UInt64
    private var partialStorage: ClipboardPartialStorage?
    private let origin = UUID()
    private var clock: UInt64 = 0
    private var newest: ClipboardRevision?
    private var newestFile: ClipboardRevision?
    private var outgoing: Outgoing?
    private var fileOutgoing: Outgoing?
    private var incoming: Incoming?
    private var fileIncoming: Incoming?
    private var receivingFileID: UUID?
    private var appliedFiles: [Part]?
    private var pendingFileOffer: (id: UUID, begin: ClipboardBegin, created: TimeInterval)?
    private var applying: (revision: ClipboardRevision, permit: ClipboardApplyPermit, files: [URL])?
    private var applyingFile: (revision: ClipboardRevision, permit: ClipboardApplyPermit, files: [URL])?
    private var sendPreparation: UUID?
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private static let chunkSize = 32_768
    private static let windowChunkSize = 262_144
    private static let maximumInFlightMessages: UInt64 = 16
    private static let decoupledFileWindowMessages: UInt64 = 64

    private struct Part {
        let path: String
        let directory: Bool
        let size: UInt64
        let mode: Int
        let modified: Date
        let url: URL?
        let data: Data?
    }
    private final class Outgoing {
        let revision: ClipboardRevision
        let parts: [Part]
        let completion: (Bool) -> Void
        let windowed: Bool
        let isFile: Bool
        let independentFileLane: Bool
        let explicitDrop: Bool
        let maxWindowMessages: UInt64
        var index = -1
        var sequence: UInt64 = 0
        var acknowledged: UInt64?
        var remaining: UInt64 = 0
        var offset = 0
        var handle: FileHandle?
        var ending = false
        var updated = SessionClock.now
        var transferred: UInt64 = 0
        var total: UInt64 = 0
        var progressAt: TimeInterval = 0
        init(revision: ClipboardRevision, parts: [Part], windowed: Bool, isFile: Bool,
             independentFileLane: Bool = false, explicitDrop: Bool = false,
             completion: @escaping (Bool) -> Void) {
            self.revision = revision; self.parts = parts; self.completion = completion
            self.windowed = windowed; self.isFile = isFile
            self.independentFileLane = independentFileLane
            self.explicitDrop = explicitDrop
            if windowed {
                self.maxWindowMessages = independentFileLane
                    ? ClipboardTransfer.decoupledFileWindowMessages
                    : ClipboardTransfer.maximumInFlightMessages
            } else {
                self.maxWindowMessages = 1
            }
        }
        deinit { try? handle?.close() }
    }
    private final class Incoming {
        let begin: ClipboardBegin
        let directory: URL
        var sequence: UInt64 = 0
        var entries: [ClipboardEntry] = []
        var roots: [String] = []
        var remaining: UInt64 = 0
        var received: UInt64 = 0
        var handle: FileHandle?
        var updated = SessionClock.now
        var progressAt: TimeInterval = 0
        init(begin: ClipboardBegin, directory: URL) { self.begin = begin; self.directory = directory }
        deinit { try? handle?.close() }
    }

    public init(storage: URL, requireFileApproval: Bool = false, allowsChunkWindow: Bool = false,
                allowsDecoupledFileTransfer: Bool = false,
                availableCapacity: ((URL) throws -> UInt64)? = nil) {
        self.storage = storage; self.requireFileApproval = requireFileApproval
        self.allowsChunkWindow = allowsChunkWindow
        self.allowsDecoupledFileTransfer = allowsDecoupledFileTransfer
        self.availableCapacity = availableCapacity ?? ClipboardPartialStorage.availableCapacity
        queue.async { try? ClipboardPartialStorage.removeAbandoned(storage: storage) }
    }

    public func respondToFileOffer(id: UUID, accept: Bool) {
        queue.async { [self] in
            guard !stopped, let pending = pendingFileOffer, pending.id == id else { return }
            let fileLane = pending.begin.independentFileLane == true
            if accept {
                do {
                    try startReceiving(pending.begin)
                    finishFileOffer(.accepted)
                }
                catch {
                    sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: error.localizedDescription))
                    if fileLane {
                        discardFileIncoming(reason: .failed, message: "文件接收未启动：\(error.localizedDescription)")
                    } else {
                        discardIncoming(reason: .failed, message: "文件接收未启动：\(error.localizedDescription)")
                    }
                    onStatus?("文件接收未启动：\(error.localizedDescription)")
                }
            } else {
                finishFileOffer(.declined)
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: "对端选择不接收文件"))
                onFileResult?(ClipboardFileResult(direction: .receiving, outcome: .cancelled,
                    message: "已取消接收文件，未下载文件内容"))
                onStatus?("已取消接收文件，未下载文件内容")
            }
        }
    }

    public func cancelFileReception(id: UUID) {
        queue.async { [self] in
            guard !stopped, receivingFileID == id else { return }
            if let activeFile = fileIncoming, activeFile.begin.type == "files" {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: activeFile.begin.revision, sequence: activeFile.sequence,
                                                           reason: "接收端已中断文件接收"))
                discardFileIncoming(reason: .cancelled, message: "已中断文件接收，未保留未完成的文件")
                onStatus?("已中断文件接收，未保留未完成的文件")
            } else if let activeIncoming = incoming, activeIncoming.begin.type == "files" {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: activeIncoming.begin.revision, sequence: activeIncoming.sequence,
                                                           reason: "接收端已中断文件接收"))
                discardIncoming(reason: .cancelled, message: "已中断文件接收，未保留未完成的文件")
                onStatus?("已中断文件接收，未保留未完成的文件")
            }
        }
    }

    // Opting in leaves an accepted file reception intact and calls deferred instead of completion.
    // When decoupled file transfer is active, clipboard preparation runs on the independent clipboard lane without touching files.
    public func prepareSend(deferred: (() -> Void)? = nil, completion: @escaping (UUID?) -> Void) {
        queue.async { [self] in
            guard !stopped else { completion(nil); return }
            if allowsDecoupledFileTransfer {
                let reason = "剪贴板已被新的复制内容替换"
                cancelOutgoing(reason)
                if let incoming {
                    sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: reason))
                } else if let applying {
                    sendJSON(.clipboardCancel, ClipboardReceipt(revision: applying.revision, sequence: 0, reason: reason))
                }
                discardClipboardIncoming()
                let preparation = UUID()
                sendPreparation = preparation
                completion(preparation)
                return
            }
            if receivingFileID != nil, let deferred { deferred(); return }
            let reason = "剪贴板已被新的复制内容替换"
            cancelOutgoing(reason)
            if let incoming {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: reason))
            } else if let pendingFileOffer {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: pendingFileOffer.begin.revision, sequence: 0, reason: reason))
            } else if let applying {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: applying.revision, sequence: 0, reason: reason))
            }
            discardIncoming(reason: .superseded)
            let preparation = UUID()
            sendPreparation = preparation
            completion(preparation)
        }
    }

    /// Sends files explicitly (e.g., dragged onto the remote canvas) without reading or overwriting the system pasteboard.
    public func sendExplicitFiles(_ urls: [URL], completion: @escaping (Bool) -> Void = { _ in }) {
        performSend(.files(urls), preparation: nil, explicitDrop: allowsDecoupledFileTransfer,
                    deferred: nil, completion: completion)
    }

    // As with prepareSend, deferral replaces completion and neither retains the payload nor schedules a retry.
    public func send(_ payload: ClipboardPayload, preparation: UUID? = nil, deferred: (() -> Void)? = nil,
                     completion: @escaping (Bool) -> Void = { _ in }) {
        performSend(payload, preparation: preparation, explicitDrop: false, deferred: deferred, completion: completion)
    }

    private func performSend(_ payload: ClipboardPayload, preparation: UUID?, explicitDrop: Bool,
                             deferred: (() -> Void)?, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !stopped else { completion(false); return }
            let isFile: Bool
            if case .files = payload { isFile = true } else { isFile = false }
            let useFileLane = isFile && allowsDecoupledFileTransfer
            if !allowsDecoupledFileTransfer {
                if receivingFileID != nil, let deferred { deferred(); return }
            } else if isFile, !explicitDrop, receivingFileID != nil, let deferred {
                deferred()
                return
            }
            guard preparation == nil || preparation == sendPreparation else { completion(false); return }
            var installed = false
            do {
                onStatus?(explicitDrop ? "正在准备拖拽文件…" : "正在准备剪贴板…")
                let (type, parts) = try plan(payload)
                if type == "files", !explicitDrop, matchesAppliedFiles(parts) {
                    completion(true)
                    onStatus?("接收的文件未变化，已跳过回传")
                    return
                }
                if !explicitDrop, (!allowsDecoupledFileTransfer || isFile) {
                    appliedFiles = nil
                }
                if useFileLane {
                    let reason = "文件传输已被新的文件发送替换"
                    cancelFileOutgoing(reason)
                    if let fileIncoming {
                        sendJSON(.clipboardCancel, ClipboardReceipt(revision: fileIncoming.begin.revision, sequence: fileIncoming.sequence, reason: reason))
                    } else if let pendingFileOffer {
                        sendJSON(.clipboardCancel, ClipboardReceipt(revision: pendingFileOffer.begin.revision, sequence: 0, reason: reason))
                    } else if let applyingFile {
                        sendJSON(.clipboardCancel, ClipboardReceipt(revision: applyingFile.revision, sequence: 0, reason: reason))
                    }
                    discardFileIncoming(reason: .superseded)
                } else if allowsDecoupledFileTransfer {
                    let reason = "剪贴板已被新的复制内容替换"
                    cancelOutgoing(reason)
                    if let incoming {
                        sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: reason))
                    } else if let applying {
                        sendJSON(.clipboardCancel, ClipboardReceipt(revision: applying.revision, sequence: 0, reason: reason))
                    }
                    discardClipboardIncoming()
                } else {
                    cancelOutgoing("剪贴板已被新的复制内容替换")
                    discardIncoming(reason: .superseded)
                }
                if isFile { onFileTransferStarted?() }
                clock &+= 1
                let revision = ClipboardRevision(counter: clock, origin: origin)
                if useFileLane { newestFile = revision } else { newest = revision }
                let transfer = Outgoing(revision: revision, parts: parts, windowed: allowsChunkWindow, isFile: isFile,
                                        independentFileLane: useFileLane, explicitDrop: useFileLane && explicitDrop,
                                        completion: completion)
                if useFileLane { fileOutgoing = transfer } else { outgoing = transfer }
                installed = true
                var total: UInt64 = 0
                for part in parts {
                    let sum = total.addingReportingOverflow(part.size)
                    guard !sum.overflow else { throw DeskError.invalid("文件总大小溢出") }
                    total = sum.partialValue
                }
                transfer.total = total
                let names: [String]?
                let rootCount: Int?
                if case .files(let urls) = payload {
                    names = urls.prefix(3).map { Self.previewName($0.lastPathComponent) }
                    rootCount = urls.count
                } else { names = nil; rootCount = nil }
                sendJSON(.clipboardBegin, ClipboardBegin(revision: revision, sequence: 0, type: type, count: parts.count,
                    bytes: total, names: names, rootCount: rootCount, chunkWindow: transfer.windowed ? true : nil,
                    independentFileLane: useFileLane ? true : nil,
                    explicitDrop: (useFileLane && explicitDrop) ? true : nil))
                ensureTimer()
                onStatus?(type == "files"
                    ? "已发送文件信息，等待对端确认接收（90 秒内）"
                    : "正在同步剪贴板：\(parts.count) 项，\(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))")
            } catch {
                onStatus?(error.localizedDescription)
                if useFileLane {
                    cancelFileOutgoing(error.localizedDescription, outcome: .failed)
                } else {
                    cancelOutgoing(error.localizedDescription, outcome: .failed)
                }
                if !installed {
                    if isFile { onFileResult?(ClipboardFileResult(direction: .sending, outcome: .failed, message: error.localizedDescription)) }
                    completion(false)
                }
            }
        }
    }

    public func receive(_ message: Message) {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                switch message.kind {
                case .clipboardBegin: try begin(Wire.readJSON(ClipboardBegin.self, message.payload))
                case .clipboardEntry: try entry(Wire.readJSON(ClipboardEntry.self, message.payload))
                case .clipboardChunk: try chunk(message.payload)
                case .clipboardEnd: try end(Wire.readJSON(ClipboardReceipt.self, message.payload))
                case .clipboardReceipt:
                    let receipt = try Wire.readJSON(ClipboardReceipt.self, message.payload)
                    let matchedFile = (fileOutgoing?.revision == receipt.revision)
                    guard let activeOutgoing = matchedFile ? fileOutgoing : (outgoing?.revision == receipt.revision ? outgoing : nil) else { return }
                    guard receipt.sequence <= activeOutgoing.sequence else { throw DeskError.invalid("剪贴板确认序号超出发送范围") }
                    if let acknowledged = activeOutgoing.acknowledged {
                        guard receipt.sequence > acknowledged else { return }
                        guard activeOutgoing.windowed || receipt.sequence == activeOutgoing.sequence else { return }
                    } else {
                        guard receipt.sequence == 0 else { throw DeskError.invalid("剪贴板开始确认无效") }
                    }
                    activeOutgoing.acknowledged = receipt.sequence
                    activeOutgoing.updated = SessionClock.now
                    if activeOutgoing.ending, receipt.sequence == activeOutgoing.sequence {
                        if matchedFile { self.fileOutgoing = nil } else { self.outgoing = nil }
                        activeOutgoing.completion(true)
                        if activeOutgoing.isFile {
                            onFileResult?(ClipboardFileResult(direction: .sending, outcome: .completed,
                                message: activeOutgoing.explicitDrop ? "拖拽文件已发送，对端已保存" : "文件已发送，对端已确认接收"))
                        }
                        onStatus?(activeOutgoing.explicitDrop ? "拖拽文件已发送" : "剪贴板已同步")
                    } else { try fillWindow(activeOutgoing) }
                case .clipboardCancel:
                    let receipt = try Wire.readJSON(ClipboardReceipt.self, message.payload)
                    if applyingFile?.revision == receipt.revision {
                        discardFileIncoming(reason: .cancelled, message: receipt.reason ?? "文件接收已取消")
                        onStatus?(receipt.reason ?? "文件接收已取消")
                    }
                    if applying?.revision == receipt.revision {
                        if allowsDecoupledFileTransfer {
                            discardClipboardIncoming()
                        } else {
                            discardIncoming(reason: .cancelled, message: receipt.reason ?? "剪贴板接收已取消")
                        }
                        onStatus?(receipt.reason ?? "剪贴板接收已取消")
                    }
                    if fileOutgoing?.revision == receipt.revision {
                        cancelFileOutgoing(receipt.reason ?? "对端取消接收文件", notify: false)
                        onStatus?(receipt.reason ?? "文件发送已取消")
                    }
                    if outgoing?.revision == receipt.revision {
                        cancelOutgoing(receipt.reason ?? "对端取消同步", notify: false)
                        onStatus?(receipt.reason ?? "剪贴板同步已取消")
                    }
                    if fileIncoming?.begin.revision == receipt.revision {
                        discardFileIncoming(reason: .cancelled, message: receipt.reason ?? "文件接收已取消")
                        onStatus?(receipt.reason ?? "文件接收已取消")
                    } else if pendingFileOffer?.begin.revision == receipt.revision {
                        if pendingFileOffer?.begin.independentFileLane == true {
                            discardFileIncoming(reason: .cancelled, message: receipt.reason ?? "文件接收已取消")
                        } else {
                            discardIncoming(reason: .cancelled, message: receipt.reason ?? "剪贴板接收已取消")
                        }
                        onStatus?(receipt.reason ?? "剪贴板接收已取消")
                    } else if incoming?.begin.revision == receipt.revision {
                        if allowsDecoupledFileTransfer, incoming?.begin.type != "files" {
                            discardClipboardIncoming()
                        } else {
                            discardIncoming(reason: .cancelled, message: receipt.reason ?? "剪贴板接收已取消")
                        }
                        onStatus?(receipt.reason ?? "剪贴板接收已取消")
                    }
                default: break
                }
            } catch {
                onStatus?("剪贴板同步失败：\(error.localizedDescription)")
                if let incoming { sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: error.localizedDescription)) }
                if let fileIncoming { sendJSON(.clipboardCancel, ClipboardReceipt(revision: fileIncoming.begin.revision, sequence: fileIncoming.sequence, reason: error.localizedDescription)) }
                if let pendingFileOffer { sendJSON(.clipboardCancel, ClipboardReceipt(revision: pendingFileOffer.begin.revision, sequence: 0, reason: error.localizedDescription)) }
                discardFileIncoming(reason: .failed, message: "文件接收失败：\(error.localizedDescription)")
                discardIncoming(reason: .failed, message: "文件接收失败：\(error.localizedDescription)")
                cancelFileOutgoing(error.localizedDescription, outcome: .failed)
                cancelOutgoing(error.localizedDescription, outcome: .failed)
            }
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stopped = true
            timer?.cancel(); timer = nil
            cancelFileOutgoing("连接结束", notify: false, outcome: nil)
            cancelOutgoing("连接结束", notify: false, outcome: nil)
            discardFileIncoming(reason: .stopped)
            discardIncoming(reason: .stopped)
            partialStorage = nil
            completion?()
        }
    }

    private func sendJSON<T: Encodable>(_ kind: MessageKind, _ value: T) {
        do { onSend?(try Wire.json(kind, value)) } catch { onStatus?(error.localizedDescription) }
    }

    private func plan(_ payload: ClipboardPayload) throws -> (String, [Part]) {
        switch payload {
        case .text(let data), .png(let data):
            let type: String
            if case .text = payload { type = "text" } else { type = "png" }
            try ClipboardAutomaticLimits.validate(type: type, bytes: UInt64(data.count))
            return (type, [Part(path: "content", directory: false, size: UInt64(data.count), mode: 0o600,
                                modified: Date(), url: nil, data: data)])
        case .files(let urls):
            guard !urls.isEmpty else { throw DeskError.invalid("没有可同步的文件") }
            guard urls.count <= Self.maximumFileEntries else { throw DeskError.invalid("文件数量超过 200000 项，请先压缩后再复制") }
            var parts: [Part] = []
            var roots = Set<String>()
            var pending: [(URL, String)] = []
            for url in urls.reversed() {
                guard url.isFileURL, roots.insert(url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                    throw DeskError.invalid("所选文件有重复名称，请先放入不同文件夹")
                }
                pending.append((url, url.lastPathComponent))
            }
            while let (next, relative) = pending.popLast() {
                var url = next
                url.removeAllCachedResourceValues()
                _ = try ClipboardPaths.destination(root: storage, relative: relative)
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                    throw DeskError.invalid("暂不支持符号链接或特殊文件，请先压缩再复制：\(url.lastPathComponent)")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let directory = values.isDirectory == true
                parts.append(Part(path: relative, directory: directory, size: directory ? 0 : UInt64(max(0, values.fileSize ?? 0)),
                                  mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600,
                                  modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0), url: url, data: nil))
                guard parts.count <= Self.maximumFileEntries else { throw DeskError.invalid("文件数量超过 200000 项，请先压缩后再复制") }
                if directory {
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    pending.append(contentsOf: children.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { ($0, relative + "/" + $0.lastPathComponent) })
                }
            }
            return ("files", parts)
        }
    }

    private func matchesAppliedFiles(_ parts: [Part]) -> Bool {
        guard let appliedFiles, appliedFiles.count == parts.count else { return false }
        let current = parts.sorted { $0.path < $1.path }
        let applied = appliedFiles.sorted { $0.path < $1.path }
        return zip(current, applied).allSatisfy { left, right in
            left.path == right.path && left.url?.standardizedFileURL == right.url?.standardizedFileURL
                && left.directory == right.directory && left.size == right.size
                && left.mode == right.mode && left.modified == right.modified
        }
    }

    private func rememberAppliedFiles(_ payload: ClipboardPayload) {
        if case .files = payload { appliedFiles = (try? plan(payload))?.1 }
        else if !allowsDecoupledFileTransfer { appliedFiles = nil }
    }

    private func fillWindow(_ transfer: Outgoing) throws {
        guard let acknowledged = transfer.acknowledged else { return }
        let credit = transfer.maxWindowMessages
        while !transfer.ending, transfer.sequence - acknowledged < credit { try advance(transfer) }
    }

    private func advance(_ transfer: Outgoing) throws {
        transfer.sequence &+= 1
        if transfer.remaining > 0 {
            let part = transfer.parts[transfer.index]
            let count = Int(min(UInt64(transfer.windowed ? Self.windowChunkSize : Self.chunkSize), transfer.remaining))
            let bytes: Data
            if let data = part.data { bytes = data.subdata(in: transfer.offset..<(transfer.offset + count)) }
            else { bytes = try transfer.handle?.read(upToCount: count) ?? Data() }
            guard !bytes.isEmpty, bytes.count <= count else { throw DeskError.invalid("源文件已变化或无法继续读取") }
            transfer.remaining -= UInt64(bytes.count)
            transfer.offset += bytes.count
            transfer.transferred += UInt64(bytes.count)
            let now = SessionClock.now
            if now - transfer.progressAt > 0.5 {
                transfer.progressAt = now
                onStatus?("正在发送：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.transferred), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.total), countStyle: .file))")
            }
            var payload = Data()
            payload.put(transfer.revision.counter)
            var uuid = transfer.revision.origin.uuid
            withUnsafeBytes(of: &uuid) { payload.append(contentsOf: $0) }
            payload.put(transfer.sequence)
            payload.append(bytes)
            onSend?(Message(.clipboardChunk, payload))
            return
        }
        if transfer.index >= 0 { try validateSource(transfer.parts[transfer.index]) }
        try transfer.handle?.close(); transfer.handle = nil
        transfer.index += 1
        if transfer.index < transfer.parts.count {
            let part = transfer.parts[transfer.index]
            if !part.directory, let url = part.url {
                try validateSource(part)
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                guard descriptor >= 0 else { throw DeskError.system("无法读取源文件", errno) }
                transfer.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            }
            transfer.remaining = part.size
            transfer.offset = 0
            sendJSON(.clipboardEntry, ClipboardEntry(revision: transfer.revision, sequence: transfer.sequence,
                path: part.path, directory: part.directory, bytes: part.size, mode: part.mode, modified: part.modified.timeIntervalSince1970))
        } else {
            transfer.ending = true
            sendJSON(.clipboardEnd, ClipboardReceipt(revision: transfer.revision, sequence: transfer.sequence, reason: nil))
        }
    }

    private func validateSource(_ part: Part) throws {
        guard let url = part.url, !part.directory else { return }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.size] as? NSNumber)?.uint64Value == part.size,
              values[.modificationDate] as? Date == part.modified else {
            throw DeskError.invalid("源文件在等待确认或复制期间发生变化，请重新复制")
        }
    }

    private func begin(_ value: ClipboardBegin) throws {
        clock = max(clock, value.revision.counter)
        guard value.independentFileLane != true || (allowsDecoupledFileTransfer && value.type == "files") else {
            throw DeskError.invalid("对端未协商独立文件传输通道")
        }
        guard value.explicitDrop != true || value.independentFileLane == true else {
            throw DeskError.invalid("拖拽文件传输标记无效")
        }
        if pendingFileOffer?.begin.revision == value.revision { return }
        let useFileLane = value.independentFileLane == true || (allowsDecoupledFileTransfer && value.type == "files")
        if useFileLane {
            guard newestFile == nil || value.revision > newestFile! else {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: "已有更新的文件传输"))
                return
            }
        } else {
            guard newest == nil || value.revision > newest! else {
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: "已有更新的剪贴板内容"))
                return
            }
        }
        guard ["text", "png", "files"].contains(value.type), value.count > 0, value.sequence == 0,
              value.type == "files" || value.count == 1,
              value.names == nil || (value.names!.count <= 3 && value.names!.allSatisfy { $0.utf8.count <= 256 }),
              value.type != "files" || value.names == nil || value.names!.count <= min(3, value.rootCount ?? value.count),
              value.rootCount == nil || (value.rootCount! > 0 && value.rootCount! <= value.count) else {
            throw DeskError.invalid("剪贴板传输信息无效")
        }
        do {
            if value.type == "files", value.count > Self.maximumFileEntries {
                throw DeskError.invalid("文件数量超过 200000 项，请先压缩后再复制")
            }
            try ClipboardAutomaticLimits.validate(type: value.type, bytes: value.bytes)
        }
        catch {
            sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: error.localizedDescription))
            if value.type == "files" {
                onFileResult?(ClipboardFileResult(direction: .receiving, outcome: .failed, message: error.localizedDescription))
            }
            onStatus?(error.localizedDescription)
            return
        }
        guard value.chunkWindow != true || allowsChunkWindow else { throw DeskError.invalid("对端未协商剪贴板传输窗口") }
        if useFileLane {
            newestFile = value.revision
            cancelFileOutgoing("对端有更新的文件传输")
            discardFileIncoming(reason: .superseded)
        } else if allowsDecoupledFileTransfer {
            newest = value.revision
            cancelOutgoing("对端有更新的剪贴板内容")
            discardClipboardIncoming()
        } else {
            newest = value.revision
            cancelOutgoing("对端有更新的剪贴板内容")
            discardIncoming(reason: .superseded)
        }
        if value.type == "files" { onFileTransferStarted?() }
        if value.type == "files", requireFileApproval {
            let id = UUID()
            let created = SessionClock.now
            pendingFileOffer = (id, value, created)
            ensureTimer()
            onFileOffer?(ClipboardFileOffer(id: id, names: value.names ?? [], count: value.rootCount ?? value.count,
                bytes: value.bytes, entryCount: value.count, createdUptime: created,
                isExplicitDrop: value.explicitDrop == true))
            onStatus?(value.explicitDrop == true ? "收到拖拽文件传输请求，确认接收后才会下载（90 秒内）" : "收到文件复制请求，确认接收后才会下载（90 秒内）")
            return
        }
        do { try startReceiving(value) }
        catch {
            sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: error.localizedDescription))
            if value.type == "files" {
                onFileResult?(ClipboardFileResult(direction: .receiving, outcome: .failed,
                    message: "文件接收未启动：\(error.localizedDescription)"))
            }
            throw error
        }
    }

    private func startReceiving(_ value: ClipboardBegin) throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard value.bytes <= (try availableCapacity(storage)) else {
            throw DeskError.invalid("接收目录可用磁盘空间不足，未下载文件内容")
        }
        if partialStorage == nil { partialStorage = try ClipboardPartialStorage(storage: storage) }
        guard let partialStorage else { throw DeskError.invalid("接收目录未准备好") }
        let folder = partialStorage.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let useFileLane = value.independentFileLane == true || (allowsDecoupledFileTransfer && value.type == "files")
        if useFileLane {
            fileIncoming = Incoming(begin: value, directory: folder)
        } else {
            incoming = Incoming(begin: value, directory: folder)
        }
        if value.type == "files" {
            let id = UUID()
            receivingFileID = id
            onFileReceptionChanged?(id)
        }
        ensureTimer()
        acknowledge(value.revision, 0)
        onStatus?(value.explicitDrop == true
            ? "正在接收拖拽文件：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: value.bytes), countStyle: .file))"
            : "正在接收剪贴板：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: value.bytes), countStyle: .file))")
    }

    private func entry(_ value: ClipboardEntry) throws {
        guard pendingFileOffer?.begin.revision != value.revision else { throw DeskError.invalid("尚未确认接收文件") }
        let activeIncoming = (fileIncoming?.begin.revision == value.revision) ? fileIncoming
            : (incoming?.begin.revision == value.revision ? incoming : nil)
        guard let activeIncoming else { return }
        guard value.sequence == activeIncoming.sequence + 1, activeIncoming.remaining == 0,
              activeIncoming.entries.count < activeIncoming.begin.count, value.modified.isFinite,
              value.mode >= 0, value.mode <= 0o7777, activeIncoming.received <= activeIncoming.begin.bytes,
              value.bytes <= activeIncoming.begin.bytes - activeIncoming.received,
              !value.directory || value.bytes == 0 else { throw DeskError.invalid("文件传输顺序或参数无效") }
        try activeIncoming.handle?.close(); activeIncoming.handle = nil
        let url = try ClipboardPaths.destination(root: activeIncoming.directory, relative: value.path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw DeskError.invalid("接收的文件路径重复") }
        let root = String(value.path.split(separator: "/")[0])
        if activeIncoming.roots.last != root {
            guard !activeIncoming.roots.contains(root), value.path == root,
                  activeIncoming.begin.rootCount == nil || activeIncoming.roots.count < activeIncoming.begin.rootCount!,
                  activeIncoming.begin.names == nil || activeIncoming.roots.count >= activeIncoming.begin.names!.count
                    || Self.previewName(root) == activeIncoming.begin.names![activeIncoming.roots.count] else {
                throw DeskError.invalid("文件内容与确认信息不一致")
            }
            activeIncoming.roots.append(root)
        }
        if value.directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        else {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw DeskError.system("无法创建接收文件，请检查可用磁盘空间", errno) }
            activeIncoming.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        activeIncoming.entries.append(value)
        activeIncoming.remaining = value.bytes
        activeIncoming.sequence = value.sequence
        activeIncoming.updated = SessionClock.now
        acknowledge(value.revision, value.sequence)
    }

    private func chunk(_ data: Data) throws {
        var reader = ByteReader(data)
        let counter: UInt64 = try reader.take()
        let uuidBytes = try reader.bytes(16)
        let uuid = uuidBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        let revision = ClipboardRevision(counter: counter, origin: UUID(uuid: uuid))
        let sequence: UInt64 = try reader.take()
        guard pendingFileOffer?.begin.revision != revision else { throw DeskError.invalid("尚未确认接收文件") }
        let activeIncoming = (fileIncoming?.begin.revision == revision) ? fileIncoming
            : (incoming?.begin.revision == revision ? incoming : nil)
        guard let activeIncoming else { return }
        let maximumChunk = activeIncoming.begin.chunkWindow == true ? Self.windowChunkSize : Self.chunkSize
        guard sequence == activeIncoming.sequence + 1, reader.remaining > 0, reader.remaining <= maximumChunk,
              UInt64(reader.remaining) <= activeIncoming.remaining, let handle = activeIncoming.handle else { throw DeskError.invalid("文件分块顺序或长度无效") }
        let bytes = try reader.bytes(reader.remaining)
        try handle.write(contentsOf: bytes)
        activeIncoming.remaining -= UInt64(bytes.count)
        activeIncoming.received += UInt64(bytes.count)
        activeIncoming.sequence = sequence
        activeIncoming.updated = SessionClock.now
        if activeIncoming.updated - activeIncoming.progressAt > 0.5 {
            activeIncoming.progressAt = activeIncoming.updated
            onStatus?("正在接收：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: activeIncoming.received), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: activeIncoming.begin.bytes), countStyle: .file))")
        }
        acknowledge(revision, sequence)
    }

    private func end(_ value: ClipboardReceipt) throws {
        guard pendingFileOffer?.begin.revision != value.revision else { throw DeskError.invalid("尚未确认接收文件") }
        let matchedFileLane = (fileIncoming?.begin.revision == value.revision)
        guard let activeIncoming = matchedFileLane ? fileIncoming
                : (incoming?.begin.revision == value.revision ? incoming : nil) else { return }
        guard value.sequence == activeIncoming.sequence + 1, activeIncoming.remaining == 0,
              activeIncoming.entries.count == activeIncoming.begin.count,
              activeIncoming.received == activeIncoming.begin.bytes else { throw DeskError.invalid("文件传输尚未完整结束") }
        if activeIncoming.begin.type == "files", let rootCount = activeIncoming.begin.rootCount {
            guard activeIncoming.roots.count == rootCount else { throw DeskError.invalid("文件传输尚未完整结束") }
        }
        try activeIncoming.handle?.close(); activeIncoming.handle = nil
        for entry in activeIncoming.entries.reversed() {
            let url = try ClipboardPaths.destination(root: activeIncoming.directory, relative: entry.path)
            let mode = (entry.mode & 0o777) | (entry.directory ? 0o700 : 0o600)
            try FileManager.default.setAttributes([.posixPermissions: mode, .modificationDate: Date(timeIntervalSince1970: entry.modified)], ofItemAtPath: url.path)
        }
        let payload: ClipboardPayload
        if activeIncoming.begin.type == "files" {
            let complete = storage.appendingPathComponent("received", isDirectory: true)
            try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = complete.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: activeIncoming.directory, to: destination)
            payload = .files(activeIncoming.roots.map { destination.appendingPathComponent($0) })
        } else {
            let data = try Data(contentsOf: activeIncoming.directory.appendingPathComponent("content"), options: .mappedIfSafe)
            if activeIncoming.begin.type == "text" {
                guard String(data: data, encoding: .utf8) != nil else { throw DeskError.invalid("文字编码无效") }
                payload = .text(data)
            } else { payload = .png(data) }
            try? FileManager.default.removeItem(at: activeIncoming.directory)
        }
        if matchedFileLane { self.fileIncoming = nil } else { self.incoming = nil }
        let files: [URL]
        if case .files(let urls) = payload { files = urls } else { files = [] }
        if activeIncoming.begin.type == "files", activeIncoming.begin.explicitDrop == true {
            if let onExplicitFilesReceived {
                onExplicitFilesReceived(files)
            } else if onApplyWithPermit == nil && onApply == nil {
                onReceive?(payload)
            }
            acknowledge(value.revision, value.sequence)
            onStatus?("拖拽文件接收完成，已保存到接收目录")
            onFileResult?(ClipboardFileResult(direction: .receiving, outcome: .completed,
                message: "拖拽文件接收完成", files: files))
            finishFileReception()
            return
        }
        if onApplyWithPermit != nil || onApply != nil {
            let permit = onApplyWithPermit == nil ? nil : ClipboardApplyPermit()
            if let permit {
                if matchedFileLane { applyingFile = (value.revision, permit, files) }
                else { applying = (value.revision, permit, files) }
            }
            let completion: (Bool) -> Void = { [weak self] accepted in
                guard let self else { return }
                self.queue.async {
                    let expectedRevision = matchedFileLane ? self.newestFile : self.newest
                    guard !self.stopped, expectedRevision == value.revision else { return }
                    if let permit {
                        if matchedFileLane {
                            guard self.applyingFile?.permit === permit else { return }
                            permit.invalidate(); self.applyingFile = nil
                        } else {
                            guard self.applying?.permit === permit else { return }
                            permit.invalidate(); self.applying = nil
                        }
                    }
                    if accepted {
                        self.rememberAppliedFiles(payload)
                        self.acknowledge(value.revision, value.sequence)
                        self.onStatus?("剪贴板接收完成，可以粘贴")
                    } else {
                        self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: value.sequence, reason: "无法写入对端系统剪贴板"))
                        self.onStatus?("无法写入系统剪贴板")
                    }
                    if !files.isEmpty {
                        self.onFileResult?(ClipboardFileResult(direction: .receiving, outcome: accepted ? .completed : .failed,
                            message: accepted ? "文件接收完成" : "文件已保存，但无法写入系统剪贴板", files: files))
                    }
                    if matchedFileLane || !files.isEmpty {
                        self.finishFileReception()
                    }
                }
            }
            if let onApplyWithPermit, let permit { onApplyWithPermit(payload, permit, completion) }
            else { onApply?(payload, completion) }
        } else {
            onReceive?(payload)
            rememberAppliedFiles(payload)
            acknowledge(value.revision, value.sequence)
            onStatus?("剪贴板接收完成，可以粘贴")
            if !files.isEmpty {
                onFileResult?(ClipboardFileResult(direction: .receiving, outcome: .completed,
                    message: "文件接收完成", files: files))
            }
            if matchedFileLane || !files.isEmpty {
                finishFileReception()
            }
        }
    }

    private func acknowledge(_ revision: ClipboardRevision, _ sequence: UInt64) {
        sendJSON(.clipboardReceipt, ClipboardReceipt(revision: revision, sequence: sequence, reason: nil))
    }

    private func cancelOutgoing(_ reason: String, notify: Bool = true, outcome: ClipboardFileResult.Outcome? = .cancelled) {
        guard let outgoing else { return }
        self.outgoing = nil
        if notify { sendJSON(.clipboardCancel, ClipboardReceipt(revision: outgoing.revision, sequence: outgoing.sequence, reason: reason)) }
        outgoing.completion(false)
        if outgoing.isFile, let outcome {
            onFileResult?(ClipboardFileResult(direction: .sending, outcome: outcome, message: reason))
        }
    }

    private func cancelFileOutgoing(_ reason: String, notify: Bool = true, outcome: ClipboardFileResult.Outcome? = .cancelled) {
        guard let fileOutgoing else { return }
        self.fileOutgoing = nil
        if notify { sendJSON(.clipboardCancel, ClipboardReceipt(revision: fileOutgoing.revision, sequence: fileOutgoing.sequence, reason: reason)) }
        fileOutgoing.completion(false)
        if let outcome {
            onFileResult?(ClipboardFileResult(direction: .sending, outcome: outcome, message: reason))
        }
    }

    private func finishFileOffer(_ reason: ClipboardFileOfferEndReason) {
        guard let pending = pendingFileOffer else { return }
        pendingFileOffer = nil
        onFileOfferEnded?(pending.id, reason)
        onFileOffer?(nil)
    }

    private func discardClipboardIncoming() {
        sendPreparation = nil
        applying?.permit.invalidate(); applying = nil
        if let incoming {
            try? incoming.handle?.close(); incoming.handle = nil
            try? FileManager.default.removeItem(at: incoming.directory)
            self.incoming = nil
        }
    }

    private func discardFileIncoming(reason: ClipboardFileOfferEndReason, message: String? = nil) {
        let wasFile = fileIncoming != nil || pendingFileOffer != nil || receivingFileID != nil || applyingFile != nil
        let files = applyingFile?.files ?? []
        applyingFile?.permit.invalidate(); applyingFile = nil
        finishFileOffer(reason)
        finishFileReception()
        if let fileIncoming {
            try? fileIncoming.handle?.close(); fileIncoming.handle = nil
            try? FileManager.default.removeItem(at: fileIncoming.directory)
            self.fileIncoming = nil
        }
        guard wasFile, reason != .stopped else { return }
        let outcome: ClipboardFileResult.Outcome = reason == .failed || reason == .timedOut ? .failed : .cancelled
        onFileResult?(ClipboardFileResult(direction: .receiving, outcome: outcome,
            message: message ?? (reason == .superseded ? "文件接收已被新的文件替换" : "文件接收已取消"), files: files))
    }

    private func discardIncoming(reason: ClipboardFileOfferEndReason, message: String? = nil) {
        let wasFile = incoming?.begin.type == "files" || pendingFileOffer != nil || receivingFileID != nil
        let files = applying?.files ?? []
        sendPreparation = nil
        applying?.permit.invalidate(); applying = nil
        finishFileOffer(reason)
        finishFileReception()
        if let incoming {
            try? incoming.handle?.close(); incoming.handle = nil
            try? FileManager.default.removeItem(at: incoming.directory)
            self.incoming = nil
        }
        guard wasFile, reason != .stopped else { return }
        let outcome: ClipboardFileResult.Outcome = reason == .failed || reason == .timedOut ? .failed : .cancelled
        onFileResult?(ClipboardFileResult(direction: .receiving, outcome: outcome,
            message: message ?? (reason == .superseded ? "文件接收已被新的复制内容替换" : "文件接收已取消"), files: files))
    }

    private func finishFileReception() {
        guard receivingFileID != nil else { return }
        receivingFileID = nil
        onFileReceptionChanged?(nil)
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = SessionClock.now
            if let outgoing = self.outgoing, now - outgoing.updated > 90 {
                self.cancelOutgoing("剪贴板传输确认超时", outcome: .failed)
                self.onStatus?("剪贴板同步超时，请重新复制")
            }
            if let fileOutgoing = self.fileOutgoing, now - fileOutgoing.updated > 90 {
                self.cancelFileOutgoing("文件传输确认超时", outcome: .failed)
                self.onStatus?("文件传输超时，请重试")
            }
            if let incoming = self.incoming, now - incoming.updated > 90 {
                self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: "接收超时"))
                if self.allowsDecoupledFileTransfer, incoming.begin.type != "files" {
                    self.discardClipboardIncoming()
                } else {
                    self.discardIncoming(reason: .timedOut, message: "文件接收超时，请在发送端重新复制")
                }
                self.onStatus?("剪贴板接收超时")
            }
            if let fileIncoming = self.fileIncoming, now - fileIncoming.updated > 90 {
                self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: fileIncoming.begin.revision, sequence: fileIncoming.sequence, reason: "接收超时"))
                self.discardFileIncoming(reason: .timedOut, message: "文件接收超时，请在发送端重试")
                self.onStatus?("文件接收超时")
            }
            if let pending = self.pendingFileOffer, now - pending.created > 90 {
                self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: "文件接收请求已过期，请重新复制"))
                if pending.begin.independentFileLane == true {
                    self.discardFileIncoming(reason: .timedOut, message: "文件接收请求已过期，未下载文件内容")
                } else {
                    self.discardIncoming(reason: .timedOut, message: "文件接收请求已过期，未下载文件内容")
                }
                self.onStatus?("文件接收请求已过期，未下载文件内容")
            }
        }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
}
