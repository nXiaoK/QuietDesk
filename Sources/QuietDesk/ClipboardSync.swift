import AppKit
import QuietDeskCore
import CryptoKit

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var fileURLs: [URL]? { get }
    var pngData: Data? { get }
    var text: String? { get }
    var contentMarker: String? { get }
    /// 内容由 macOS 通用剪贴板（接力/Handoff）等跨设备机制写入，而不是本机用户复制。
    var isRelayedFromOtherDevice: Bool { get }
    func write(_ payload: ClipboardPayload, marker: String) -> Bool
}

extension ClipboardPasteboard {
    var isRelayedFromOtherDevice: Bool { false }
}

@MainActor
private final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard = NSPasteboard.general
    private static let marker = NSPasteboard.PasteboardType("local.quietdesk.clipboard-session")
    var changeCount: Int { pasteboard.changeCount }
    var fileURLs: [URL]? { pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] }
    var pngData: Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    var text: String? { pasteboard.string(forType: .string) }
    var contentMarker: String? { pasteboard.string(forType: Self.marker) }
    // Universal Clipboard 写入的条目带有该类型；QuietDesk 不应把它当成本机新复制再转发给对端。
    private static let relayedTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    ]
    var isRelayedFromOtherDevice: Bool {
        guard let types = pasteboard.types else { return false }
        return !Self.relayedTypes.isDisjoint(with: types)
    }

    func write(_ payload: ClipboardPayload, marker: String) -> Bool {
        var items: [NSPasteboardItem] = []
        switch payload {
        case .text(let bytes):
            guard let text = String(data: bytes, encoding: .utf8) else { return false }
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { return false }
            items = [item]
        case .png(let bytes):
            let item = NSPasteboardItem()
            guard item.setData(bytes, forType: .png) else { return false }
            items = [item]
        case .files(let urls):
            guard !urls.isEmpty else { return false }
            for url in urls {
                let item = NSPasteboardItem(), writer = url as NSURL
                for type in writer.writableTypes(for: pasteboard) {
                    if let value = writer.pasteboardPropertyList(forType: type),
                       !item.setPropertyList(value, forType: type) { return false }
                }
                guard item.setString(url.absoluteString, forType: .fileURL) else { return false }
                items.append(item)
            }
        }
        for item in items {
            guard item.setString(marker, forType: Self.marker) else { return false }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }
}

@MainActor
final class ClipboardSync {
    enum PayloadKind: String { case text, png, files }
    enum DiagnosticEvent: Equatable {
        case sending(PayloadKind, fileCount: Int)
        case sent(PayloadKind, fileCount: Int)
        case sendFailed(PayloadKind, fileCount: Int)
        case applied(PayloadKind, fileCount: Int)
        case applyFailed(PayloadKind, fileCount: Int)
        case fileOfferReceived(count: Int, totalBytes: UInt64)
        case fileOfferAccepted, fileOfferRejected, staleFilesSuppressed
    }

    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuietDesk/Clipboard", isDirectory: true)
    var onStatus: ((String) -> Void)?
    var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    var onDiagnostic: ((DiagnosticEvent) -> Void)?
    var allowsFileSending: Bool
    private var allowsAutomaticSending: Bool
    private let pasteboard: ClipboardPasteboard
    private let transfer: ClipboardTransfer
    private var timer: Timer?
    private var observedChange: Int
    private var pendingFileOffer: (id: UUID, change: Int)?
    private var deferredLocalChange: Int?
    private var staleFileChange: Int?
    private var sharedChange: Int?
    private var sendingChange: Int?
    private var waiters: [(Bool) -> Void] = []
    private var running = true
    private var hasSharedState = false
    private var lastSharedMarker: String?
    private let session: UUID

    init(session: UUID, allowsFileSending: Bool, allowsAutomaticSending: Bool = true,
         pasteboard: ClipboardPasteboard? = nil, storage: URL? = nil,
         send: @escaping (Message) -> Void) {
        self.session = session
        self.allowsFileSending = allowsFileSending
        self.allowsAutomaticSending = allowsAutomaticSending
        let pasteboard = pasteboard ?? SystemClipboardPasteboard()
        self.pasteboard = pasteboard
        observedChange = pasteboard.changeCount
        transfer = ClipboardTransfer(storage: storage ?? Self.storageURL, requireFileApproval: true)
        transfer.onSend = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                send(message)
            }
        }
        transfer.onApply = { [weak self] payload, completion in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                completion(self.apply(payload))
            }
        }
        transfer.onStatus = { [weak self] status in DispatchQueue.main.async { self?.onStatus?(status) } }
        transfer.onFileOffer = { [weak self] offer in
            DispatchQueue.main.async {
                guard let self, self.running, let offer else { return }
                let change = self.pasteboard.changeCount
                self.pendingFileOffer = (offer.id, change)
                self.deferredLocalChange = change
                self.staleFileChange = change
                self.onDiagnostic?(.fileOfferReceived(count: offer.count, totalBytes: offer.bytes))
                self.onFileOffer?(offer)
            }
        }
        transfer.onFileOfferEnded = { [weak self] id, reason in
            DispatchQueue.main.async {
                guard let self, self.running, let pending = self.pendingFileOffer, pending.id == id else { return }
                self.pendingFileOffer = nil
                switch reason {
                case .accepted:
                    self.observedChange = pending.change
                    self.onDiagnostic?(.fileOfferAccepted)
                case .declined:
                    self.deferredLocalChange = nil
                    self.onDiagnostic?(.fileOfferRejected)
                case .timedOut, .failed: self.deferredLocalChange = nil
                // A remote cancellation can precede replacement data; keep the older local version deferred.
                case .superseded, .cancelled, .stopped: break
                }
                self.onFileOffer?(nil)
                self.poll()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func receive(_ message: Message) { transfer.receive(message) }

    func setAutomaticSendingAllowed(_ allowed: Bool) {
        allowsAutomaticSending = allowed
        if allowed { poll() }
    }

    func respondToFileOffer(id: UUID, accept: Bool) {
        guard running, let pendingFileOffer, pendingFileOffer.id == id else { return }
        if accept, pasteboard.changeCount != pendingFileOffer.change {
            transfer.respondToFileOffer(id: id, accept: false)
            sendCurrent()
            return
        }
        transfer.respondToFileOffer(id: id, accept: accept)
    }

    func prepareForPaste(_ completion: @escaping (Bool) -> Void) {
        guard running, allowsAutomaticSending else { completion(false); return }
        let change = pasteboard.changeCount
        if change == sharedChange { completion(true); return }
        if let files = pasteboard.fileURLs, !files.isEmpty {
            guard staleFileChange != change else {
                onDiagnostic?(.staleFilesSuppressed)
                completion(false)
                onStatus?("此文件复制早于远端请求，请在本机重新复制后再粘贴")
                return
            }
            if sendingChange != change { sendCurrent() }
            if change == sharedChange { completion(true); return }
            completion(false)
            onStatus?(allowsFileSending ? "文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴" : "对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            return
        }
        waiters.append(completion)
        if sendingChange != change { sendCurrent() }
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        transfer.stop()
        let callbacks = waiters; waiters.removeAll()
        callbacks.forEach { $0(false) }
    }

    private func poll() {
        guard running, allowsAutomaticSending else { return }
        let change = pasteboard.changeCount
        guard change != observedChange, change != deferredLocalChange else { return }
        sendCurrent()
    }

    private func sendCurrent() {
        guard running, allowsAutomaticSending else { return }
        let change = pasteboard.changeCount
        observedChange = change
        let payload: ClipboardPayload
        if let files = pasteboard.fileURLs, !files.isEmpty {
            payload = .files(files)
        } else if let png = pasteboard.pngData { payload = .png(png) }
        else if let text = pasteboard.text { payload = .text(Data(text.utf8)) }
        else {
            onStatus?("此剪贴板类型暂不能同步")
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
            return
        }
        // 文件来自通用剪贴板（另一台 Mac 复制后由系统同步过来），对端本身就是来源，转发只会形成回环。
        if case .files = payload, pasteboard.isRelayedFromOtherDevice {
            onDiagnostic?(.staleFilesSuppressed)
            onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
            return
        }
        // Closing a remote prompt can restore focus without a new local file copy.
        if case .files = payload, staleFileChange == change {
            onDiagnostic?(.staleFilesSuppressed)
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
            return
        }
        staleFileChange = nil
        let contentMarker = marker(for: payload)
        let isFile: Bool
        if case .files = payload { isFile = true } else { isFile = false }
        if isFile {
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
        }
        if (!isFile && lastSharedMarker == contentMarker) || ((hasSharedState || sendingChange != nil) && pasteboard.contentMarker == contentMarker) {
            hasSharedState = true
            lastSharedMarker = contentMarker
            sharedChange = change
            sendingChange = nil
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(true) }
            return
        }
        if isFile, !allowsFileSending {
            onStatus?("对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
            return
        }
        sendingChange = change
        let summary = diagnosticSummary(for: payload)
        onDiagnostic?(.sending(summary.kind, fileCount: summary.fileCount))
        transfer.send(payload) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(success ? .sent(summary.kind, fileCount: summary.fileCount) : .sendFailed(summary.kind, fileCount: summary.fileCount))
                guard self.sendingChange == change else { return }
                self.sendingChange = nil
                if success { self.sharedChange = change; self.hasSharedState = true; self.lastSharedMarker = contentMarker }
                let callbacks = self.waiters; self.waiters.removeAll()
                callbacks.forEach { $0(success) }
            }
        }
    }

    private func apply(_ payload: ClipboardPayload) -> Bool {
        guard running else { return false }
        let summary = diagnosticSummary(for: payload)
        switch payload {
        case .text(let bytes):
            guard String(data: bytes, encoding: .utf8) != nil else {
                onDiagnostic?(.applyFailed(summary.kind, fileCount: summary.fileCount))
                return false
            }
        case .png(let bytes):
            guard NSBitmapImageRep(data: bytes) != nil else {
                onDiagnostic?(.applyFailed(summary.kind, fileCount: summary.fileCount))
                onStatus?("接收的图片无效")
                return false
            }
        case .files: break
        }
        let contentMarker = marker(for: payload)
        guard pasteboard.write(payload, marker: contentMarker) else {
            onDiagnostic?(.applyFailed(summary.kind, fileCount: summary.fileCount))
            onStatus?("系统剪贴板写入失败")
            return false
        }
        observedChange = pasteboard.changeCount
        deferredLocalChange = nil
        staleFileChange = nil
        sharedChange = observedChange
        hasSharedState = true
        lastSharedMarker = contentMarker
        sendingChange = nil
        onDiagnostic?(.applied(summary.kind, fileCount: summary.fileCount))
        let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(true) }
        return true
    }

    private func diagnosticSummary(for payload: ClipboardPayload) -> (kind: PayloadKind, fileCount: Int) {
        switch payload {
        case .text: return (.text, 0)
        case .png: return (.png, 0)
        case .files(let urls): return (.files, urls.count)
        }
    }

    private func marker(for payload: ClipboardPayload) -> String {
        let data: Data
        let type: String
        switch payload {
        case .text(let value): data = value; type = "text"
        case .png(let value): data = value; type = "png"
        case .files(let urls):
            data = Data(urls.map { $0.standardizedFileURL.path.precomposedStringWithCanonicalMapping }.joined(separator: "\0").utf8)
            type = "files"
        }
        return session.uuidString + ":" + type + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    deinit { timer?.invalidate() }
}
