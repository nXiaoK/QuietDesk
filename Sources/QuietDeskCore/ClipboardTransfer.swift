import Foundation
import Darwin
import CryptoKit

public enum ClipboardPayload {
    case text(Data), png(Data), files([URL])
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
    public init(enabled: Bool, session: UUID? = nil, fileApproval: Bool? = true, receivesAutomaticUpdates: Bool? = nil) {
        self.enabled = enabled; self.session = session; self.fileApproval = fileApproval
        self.receivesAutomaticUpdates = receivesAutomaticUpdates
    }
}

public struct ClipboardFileOffer: Identifiable {
    public let id: UUID
    public let names: [String]
    public let count: Int
    public let bytes: UInt64
    public let createdUptime: TimeInterval

    public init(id: UUID, names: [String], count: Int, bytes: UInt64,
                createdUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id; self.names = names; self.count = count; self.bytes = bytes
        self.createdUptime = createdUptime
    }
}

public enum ClipboardFileOfferEndReason {
    case accepted, declined, superseded, cancelled, failed, timedOut, stopped
}

private struct ClipboardBegin: Codable {
    let revision: ClipboardRevision
    let sequence: UInt64
    let type: String
    let count: Int
    let bytes: UInt64
    let names: [String]?
    let rootCount: Int?
    /// 可选：文件清单指纹（相对路径 + 类型 + 大小）。旧版本缺省为 nil，解码兼容。
    let fingerprint: String?
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
    public var onSend: ((Message) -> Void)?
    public var onReceive: ((ClipboardPayload) -> Void)?
    public var onApply: ((ClipboardPayload, @escaping (Bool) -> Void) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    public var onFileOfferEnded: ((UUID, ClipboardFileOfferEndReason) -> Void)?
    private let queue = DispatchQueue(label: "quietdesk.clipboard.files", qos: .utility)
    private let storage: URL
    private let requireFileApproval: Bool
    private let origin = UUID()
    private var clock: UInt64 = 0
    private var newest: ClipboardRevision?
    private var outgoing: Outgoing?
    private var incoming: Incoming?
    private var appliedFiles: [Part]?
    private var pendingFileOffer: (id: UUID, begin: ClipboardBegin, created: TimeInterval)?
    /// 本端最近一次发出或成功写入剪贴板的文件指纹，用于识别对端把同一批文件再回传过来。
    private var recentFiles: (fingerprint: String, at: TimeInterval)?
    private static let echoWindow: TimeInterval = 120
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private static let chunkSize = 32_768

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
        var index = -1
        var sequence: UInt64 = 0
        var remaining: UInt64 = 0
        var offset = 0
        var handle: FileHandle?
        var ending = false
        var updated = ProcessInfo.processInfo.systemUptime
        var transferred: UInt64 = 0
        var total: UInt64 = 0
        var progressAt: TimeInterval = 0
        init(revision: ClipboardRevision, parts: [Part], completion: @escaping (Bool) -> Void) {
            self.revision = revision; self.parts = parts; self.completion = completion
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
        var updated = ProcessInfo.processInfo.systemUptime
        var progressAt: TimeInterval = 0
        init(begin: ClipboardBegin, directory: URL) { self.begin = begin; self.directory = directory }
        deinit { try? handle?.close() }
    }

    public init(storage: URL, requireFileApproval: Bool = false) {
        self.storage = storage; self.requireFileApproval = requireFileApproval
    }

    public func respondToFileOffer(id: UUID, accept: Bool) {
        queue.async { [self] in
            guard !stopped, let pending = pendingFileOffer, pending.id == id else { return }
            if accept {
                do {
                    try startReceiving(pending.begin)
                    finishFileOffer(.accepted)
                }
                catch {
                    sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: error.localizedDescription))
                    discardIncoming(reason: .failed)
                    onStatus?("文件接收未启动：\(error.localizedDescription)")
                }
            } else {
                finishFileOffer(.declined)
                sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: "对端选择不接收文件"))
                onStatus?("已取消接收文件，未下载文件内容")
            }
        }
    }

    public func send(_ payload: ClipboardPayload, completion: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            guard !stopped else { completion(false); return }
            var installed = false
            do {
                onStatus?("正在准备剪贴板…")
                let (type, parts) = try plan(payload)
                if type == "files", matchesAppliedFiles(parts) {
                    completion(true)
                    onStatus?("接收的文件未变化，已跳过回传")
                    return
                }
                appliedFiles = nil
                let fingerprint = type == "files" ? Self.fingerprint(parts) : nil
                recentFiles = fingerprint.map { (fingerprint: $0, at: ProcessInfo.processInfo.systemUptime) }
                cancelOutgoing("剪贴板已被新的复制内容替换")
                discardIncoming(reason: .superseded)
                clock &+= 1
                let revision = ClipboardRevision(counter: clock, origin: origin)
                newest = revision
                let transfer = Outgoing(revision: revision, parts: parts, completion: completion)
                outgoing = transfer
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
                    names = urls.prefix(3).map { String(decoding: $0.lastPathComponent.utf8.prefix(120), as: UTF8.self) }
                    rootCount = urls.count
                } else { names = nil; rootCount = nil }
                sendJSON(.clipboardBegin, ClipboardBegin(revision: revision, sequence: 0, type: type, count: parts.count,
                    bytes: total, names: names, rootCount: rootCount, fingerprint: fingerprint))
                ensureTimer()
                onStatus?(type == "files" ? "已发送文件信息，等待对端确认接收（90 秒内）" : "正在同步剪贴板：\(parts.count) 项，\(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))")
            } catch {
                onStatus?(error.localizedDescription)
                cancelOutgoing(error.localizedDescription)
                if !installed { completion(false) }
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
                    guard let outgoing, receipt.revision == outgoing.revision, receipt.sequence == outgoing.sequence else { return }
                    outgoing.updated = ProcessInfo.processInfo.systemUptime
                    if outgoing.ending {
                        self.outgoing = nil
                        outgoing.completion(true)
                        onStatus?("剪贴板已同步")
                    } else { try advance(outgoing) }
                case .clipboardCancel:
                    let receipt = try Wire.readJSON(ClipboardReceipt.self, message.payload)
                    if outgoing?.revision == receipt.revision {
                        cancelOutgoing(receipt.reason ?? "对端取消同步", notify: false)
                        onStatus?(receipt.reason ?? "剪贴板同步已取消")
                    }
                    if incoming?.begin.revision == receipt.revision || pendingFileOffer?.begin.revision == receipt.revision {
                        discardIncoming(reason: .cancelled); onStatus?(receipt.reason ?? "剪贴板接收已取消")
                    }
                default: break
                }
            } catch {
                onStatus?("剪贴板同步失败：\(error.localizedDescription)")
                if let incoming { sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: error.localizedDescription)) }
                if let pendingFileOffer { sendJSON(.clipboardCancel, ClipboardReceipt(revision: pendingFileOffer.begin.revision, sequence: 0, reason: error.localizedDescription)) }
                discardIncoming(reason: .failed)
                cancelOutgoing(error.localizedDescription)
            }
        }
    }

    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stopped = true
            timer?.cancel(); timer = nil
            cancelOutgoing("连接结束", notify: false)
            discardIncoming(reason: .stopped)
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
            return (type, [Part(path: "content", directory: false, size: UInt64(data.count), mode: 0o600,
                                modified: Date(), url: nil, data: data)])
        case .files(let urls):
            guard !urls.isEmpty else { throw DeskError.invalid("没有可同步的文件") }
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
        if case .files = payload {
            appliedFiles = (try? plan(payload))?.1
            recentFiles = appliedFiles.map { (fingerprint: Self.fingerprint($0), at: ProcessInfo.processInfo.systemUptime) }
        } else { appliedFiles = nil; recentFiles = nil }
    }

    private static func fingerprint(_ parts: [Part]) -> String {
        let canonical = parts.map { "\($0.path.precomposedStringWithCanonicalMapping)|\($0.directory ? 1 : 0)|\($0.size)" }
            .sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func advance(_ transfer: Outgoing) throws {
        transfer.sequence &+= 1
        if transfer.remaining > 0 {
            let part = transfer.parts[transfer.index]
            let count = Int(min(UInt64(Self.chunkSize), transfer.remaining))
            let bytes: Data
            if let data = part.data { bytes = data.subdata(in: transfer.offset..<(transfer.offset + count)) }
            else { bytes = try transfer.handle?.read(upToCount: count) ?? Data() }
            guard !bytes.isEmpty, bytes.count <= count else { throw DeskError.invalid("源文件已变化或无法继续读取") }
            transfer.remaining -= UInt64(bytes.count)
            transfer.offset += bytes.count
            transfer.transferred += UInt64(bytes.count)
            let now = ProcessInfo.processInfo.systemUptime
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
        if pendingFileOffer?.begin.revision == value.revision { return }
        // 对端提供的文件与本端刚发出/刚接收的完全相同（例如经系统通用剪贴板回流），直接忽略，不弹窗也不打断本端状态。
        if value.type == "files", let fingerprint = value.fingerprint, let recent = recentFiles,
           recent.fingerprint == fingerprint, ProcessInfo.processInfo.systemUptime - recent.at < Self.echoWindow {
            sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: "对端已有相同文件，已忽略回传"))
            onStatus?("已忽略对端回传的相同文件")
            return
        }
        guard newest == nil || value.revision > newest! else {
            sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: 0, reason: "已有更新的剪贴板内容"))
            return
        }
        guard ["text", "png", "files"].contains(value.type), value.count > 0, value.sequence == 0,
              value.type == "files" || value.count == 1,
              value.names == nil || (value.names!.count <= 3 && value.names!.allSatisfy { $0.utf8.count <= 256 }),
              value.rootCount == nil || (value.rootCount! > 0 && value.rootCount! <= value.count) else {
            throw DeskError.invalid("剪贴板传输信息无效")
        }
        newest = value.revision
        cancelOutgoing("对端有更新的剪贴板内容")
        discardIncoming(reason: .superseded)
        if value.type == "files", requireFileApproval {
            let id = UUID()
            let created = ProcessInfo.processInfo.systemUptime
            pendingFileOffer = (id, value, created)
            ensureTimer()
            onFileOffer?(ClipboardFileOffer(id: id, names: value.names ?? [], count: value.rootCount ?? value.count,
                bytes: value.bytes, createdUptime: created))
            onStatus?("收到文件复制请求，确认接收后才会下载（90 秒内）")
            return
        }
        try startReceiving(value)
    }

    private func startReceiving(_ value: ClipboardBegin) throws {
        let folder = storage.appendingPathComponent("partial", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        incoming = Incoming(begin: value, directory: folder)
        ensureTimer()
        acknowledge(value.revision, 0)
        onStatus?("正在接收剪贴板：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: value.bytes), countStyle: .file))")
    }

    private func entry(_ value: ClipboardEntry) throws {
        guard pendingFileOffer?.begin.revision != value.revision else { throw DeskError.invalid("尚未确认接收文件") }
        guard let incoming, incoming.begin.revision == value.revision else { return }
        guard value.sequence == incoming.sequence + 1, incoming.remaining == 0,
              incoming.entries.count < incoming.begin.count, value.modified.isFinite,
              value.mode >= 0, value.mode <= 0o7777, incoming.received <= incoming.begin.bytes,
              value.bytes <= incoming.begin.bytes - incoming.received,
              !value.directory || value.bytes == 0 else { throw DeskError.invalid("文件传输顺序或参数无效") }
        try incoming.handle?.close(); incoming.handle = nil
        let url = try ClipboardPaths.destination(root: incoming.directory, relative: value.path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw DeskError.invalid("接收的文件路径重复") }
        if value.directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        else {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw DeskError.system("无法创建接收文件，请检查可用磁盘空间", errno) }
            incoming.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        let root = String(value.path.split(separator: "/")[0])
        if !incoming.roots.contains(root) { incoming.roots.append(root) }
        incoming.entries.append(value)
        incoming.remaining = value.bytes
        incoming.sequence = value.sequence
        incoming.updated = ProcessInfo.processInfo.systemUptime
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
        guard let incoming, incoming.begin.revision == revision else { return }
        guard sequence == incoming.sequence + 1, reader.remaining > 0, reader.remaining <= Self.chunkSize,
              UInt64(reader.remaining) <= incoming.remaining, let handle = incoming.handle else { throw DeskError.invalid("文件分块顺序或长度无效") }
        let bytes = try reader.bytes(reader.remaining)
        try handle.write(contentsOf: bytes)
        incoming.remaining -= UInt64(bytes.count)
        incoming.received += UInt64(bytes.count)
        incoming.sequence = sequence
        incoming.updated = ProcessInfo.processInfo.systemUptime
        if incoming.updated - incoming.progressAt > 0.5 {
            incoming.progressAt = incoming.updated
            onStatus?("正在接收：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: incoming.received), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: incoming.begin.bytes), countStyle: .file))")
        }
        acknowledge(revision, sequence)
    }

    private func end(_ value: ClipboardReceipt) throws {
        guard pendingFileOffer?.begin.revision != value.revision else { throw DeskError.invalid("尚未确认接收文件") }
        guard let incoming, incoming.begin.revision == value.revision else { return }
        guard value.sequence == incoming.sequence + 1, incoming.remaining == 0,
              incoming.entries.count == incoming.begin.count, incoming.received == incoming.begin.bytes else { throw DeskError.invalid("文件传输尚未完整结束") }
        try incoming.handle?.close(); incoming.handle = nil
        for entry in incoming.entries.reversed() {
            let url = try ClipboardPaths.destination(root: incoming.directory, relative: entry.path)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode & 0o777, .modificationDate: Date(timeIntervalSince1970: entry.modified)], ofItemAtPath: url.path)
        }
        let payload: ClipboardPayload
        if incoming.begin.type == "files" {
            let complete = storage.appendingPathComponent("received", isDirectory: true)
            try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = complete.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.moveItem(at: incoming.directory, to: destination)
            payload = .files(incoming.roots.map { destination.appendingPathComponent($0) })
        } else {
            let data = try Data(contentsOf: incoming.directory.appendingPathComponent("content"), options: .mappedIfSafe)
            if incoming.begin.type == "text" {
                guard String(data: data, encoding: .utf8) != nil else { throw DeskError.invalid("文字编码无效") }
                payload = .text(data)
            } else { payload = .png(data) }
            try? FileManager.default.removeItem(at: incoming.directory)
        }
        self.incoming = nil
        if let onApply {
            onApply(payload) { [weak self] accepted in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped, self.newest == value.revision else { return }
                    if accepted {
                        self.rememberAppliedFiles(payload)
                        self.acknowledge(value.revision, value.sequence)
                        self.onStatus?("剪贴板接收完成，可以粘贴")
                    } else {
                        self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: value.revision, sequence: value.sequence, reason: "无法写入对端系统剪贴板"))
                        self.onStatus?("无法写入系统剪贴板")
                    }
                }
            }
        } else {
            onReceive?(payload)
            rememberAppliedFiles(payload)
            acknowledge(value.revision, value.sequence)
            onStatus?("剪贴板接收完成，可以粘贴")
        }
    }

    private func acknowledge(_ revision: ClipboardRevision, _ sequence: UInt64) {
        sendJSON(.clipboardReceipt, ClipboardReceipt(revision: revision, sequence: sequence, reason: nil))
    }
    private func cancelOutgoing(_ reason: String, notify: Bool = true) {
        guard let outgoing else { return }
        self.outgoing = nil
        if notify { sendJSON(.clipboardCancel, ClipboardReceipt(revision: outgoing.revision, sequence: outgoing.sequence, reason: reason)) }
        outgoing.completion(false)
    }
    private func finishFileOffer(_ reason: ClipboardFileOfferEndReason) {
        guard let pending = pendingFileOffer else { return }
        pendingFileOffer = nil
        onFileOfferEnded?(pending.id, reason)
        onFileOffer?(nil)
    }
    private func discardIncoming(reason: ClipboardFileOfferEndReason) {
        finishFileOffer(reason)
        guard let incoming else { return }
        try? incoming.handle?.close(); incoming.handle = nil
        try? FileManager.default.removeItem(at: incoming.directory)
        self.incoming = nil
    }
    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let outgoing = self.outgoing, now - outgoing.updated > 90 { self.cancelOutgoing("剪贴板传输确认超时"); self.onStatus?("剪贴板同步超时，请重新复制") }
            if let incoming = self.incoming, now - incoming.updated > 90 {
                self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: incoming.begin.revision, sequence: incoming.sequence, reason: "接收超时"))
                self.discardIncoming(reason: .timedOut)
                self.onStatus?("剪贴板接收超时")
            }
            if let pending = self.pendingFileOffer, now - pending.created > 90 {
                self.sendJSON(.clipboardCancel, ClipboardReceipt(revision: pending.begin.revision, sequence: 0, reason: "文件接收请求已过期，请重新复制"))
                self.discardIncoming(reason: .timedOut)
                self.onStatus?("文件接收请求已过期，未下载文件内容")
            }
        }
        self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel() }
}
