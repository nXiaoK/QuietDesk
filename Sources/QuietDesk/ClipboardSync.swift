import AppKit
import QuietDeskCore
import CryptoKit

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var fileURLs: [URL]? { get }
    var pngData: Data? { get }
    var tiffData: Data? { get }
    var text: String? { get }
    var contentMarker: String? { get }
    /// 内容由 macOS 通用剪贴板（接力/Handoff）等跨设备机制写入，而不是本机用户复制。
    var isRelayedFromOtherDevice: Bool { get }
    var isSensitive: Bool { get }
    func write(_ payload: ClipboardPayload, marker: String) -> Bool
}

extension ClipboardPasteboard {
    var isRelayedFromOtherDevice: Bool { false }
    var tiffData: Data? { nil }
    var isSensitive: Bool { false }
}

@MainActor
private final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard = NSPasteboard.general
    private static let marker = NSPasteboard.PasteboardType("local.quietdesk.clipboard-session")
    var changeCount: Int { pasteboard.changeCount }
    var fileURLs: [URL]? { pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] }
    var pngData: Data? { pasteboard.data(forType: .png) }
    var tiffData: Data? { pasteboard.data(forType: .tiff) }
    var text: String? { pasteboard.string(forType: .string) }
    var contentMarker: String? { pasteboard.string(forType: Self.marker) }
    var isSensitive: Bool { ClipboardPrivacy.isSensitive(pasteboard) }
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

    static var receivingDirectory: String {
        let path = storageURL.appendingPathComponent("received", isDirectory: true).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) + "/" : path + "/"
    }

    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(AppDataLocation.folderName())/Clipboard", isDirectory: true)
    var onStatus: ((String) -> Void)?
    var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    var onFileReceptionChanged: ((UUID?) -> Void)?
    var onDiagnostic: ((DiagnosticEvent) -> Void)?
    var allowsFileSending: Bool
    private var allowsAutomaticSending: Bool
    private var controllingRemote: Bool
    private let pasteboard: ClipboardPasteboard
    private let transfer: ClipboardTransfer
    nonisolated let receiveMessage: @Sendable (Message) -> Void
    private var timer: Timer?
    private var observedChange: Int
    // A copy made before taking control may still be waiting for activation or session resume.
    private var pendingLocalChange: Int?
    private var pendingFileOffer: (id: UUID, change: Int)?
    private var receivingFileID: UUID?
    private var receivingFileChange: Int?
    private var receivedFilesKeptLocally = false
    private var deferredLocalChange: Int?
    private var staleFileChange: Int?
    private var sharedChange: Int?
    private var sendingChange: Int?
    private var fileSendingChange: Int?
    private var imagePreparation: UUID?
    private let imageQueue = DispatchQueue(label: "quietdesk.clipboard.images", qos: .utility)
    private let convertTIFF: (Data) -> Data?
    private let validatePNG: (Data) -> Bool
    private var imageApplication: (token: UUID, completion: (Bool) -> Void)?
    private var waiters: [(Bool) -> Void] = []
    private var running = true
    private var hasSharedState = false
    private var lastSharedMarker: String?
    private let session: UUID

    init(session: UUID, allowsFileSending: Bool, allowsAutomaticSending: Bool = true, allowsChunkWindow: Bool = false,
         controllingRemote: Bool = false, handledChange: Int? = nil, pasteboard: ClipboardPasteboard? = nil, storage: URL? = nil,
         convertTIFF: @escaping (Data) -> Data? = { data in
             autoreleasepool { NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) }
         },
         validatePNG: ((Data) -> Bool)? = nil,
         send: @escaping (Message) -> Void) {
        self.session = session
        self.allowsFileSending = allowsFileSending
        self.allowsAutomaticSending = allowsAutomaticSending
        self.controllingRemote = controllingRemote
        self.convertTIFF = convertTIFF
        self.validatePNG = validatePNG ?? { data in autoreleasepool { NSBitmapImageRep(data: data) != nil } }
        let pasteboard = pasteboard ?? SystemClipboardPasteboard()
        self.pasteboard = pasteboard
        observedChange = handledChange ?? pasteboard.changeCount
        let transfer = ClipboardTransfer(storage: storage ?? Self.storageURL, requireFileApproval: true,
                                         allowsChunkWindow: allowsChunkWindow)
        self.transfer = transfer
        receiveMessage = { [weak transfer] message in transfer?.receive(message) }
        transfer.onSend = send
        transfer.onApplyWithPermit = { [weak self] payload, permit, completion in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                self.prepareApplication(payload, permit: permit, completion: completion)
            }
        }
        transfer.onStatus = { [weak self] status in DispatchQueue.main.async { self?.onStatus?(status) } }
        transfer.onFileReceptionChanged = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.receivingFileID = id
                if id != nil {
                    self.receivingFileChange = self.receivingFileChange ?? self.pendingFileOffer?.change ?? self.pasteboard.changeCount
                } else {
                    self.receivingFileChange = nil
                    if self.receivedFilesKeptLocally {
                        self.receivedFilesKeptLocally = false
                        self.onStatus?("文件接收完成，已保存到接收目录；保留了新的本机复制内容")
                    }
                }
                self.onFileReceptionChanged?(id)
                if id == nil { self.poll() }
            }
        }
        transfer.onFileOffer = { [weak self] offer in
            DispatchQueue.main.async {
                guard let self, self.running, let offer else { return }
                self.lastSharedMarker = nil
                self.cancelImageApplication()
                if self.imagePreparation != nil {
                    self.imagePreparation = nil
                    self.sendingChange = nil
                    self.settleWaiters(false)
                }
                let change = self.pasteboard.changeCount
                self.pendingFileOffer = (offer.id, change)
                self.pendingLocalChange = nil
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
                    if self.receivingFileID == nil { self.receivingFileChange = nil }
                    self.onDiagnostic?(.fileOfferRejected)
                case .timedOut, .failed:
                    self.deferredLocalChange = nil
                    if self.receivingFileID == nil { self.receivingFileChange = nil }
                // A remote cancellation can precede replacement data; keep the older local version deferred.
                case .superseded, .cancelled, .stopped:
                    if self.receivingFileID == nil { self.receivingFileChange = nil }
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

    func receive(_ message: Message) { receiveMessage(message) }

    func cancelFileReception(id: UUID) {
        guard running else { return }
        transfer.cancelFileReception(id: id)
    }

    func setAutomaticSendingAllowed(_ allowed: Bool) {
        allowsAutomaticSending = allowed
        if !allowed, imagePreparation != nil {
            pendingLocalChange = sendingChange
            imagePreparation = nil
            sendingChange = nil
            observedChange = Int.min
            settleWaiters(false)
        }
        if allowed { poll() }
    }

    /// 操作远端期间本机剪贴板的变化来自系统通用剪贴板接力、其他程序等，不是在本机复制，
    /// 记为已处理且不读取内容；进入控制前尚未发出的本机复制保留到允许发送时。
    func setControllingRemote(_ controlling: Bool) {
        guard controllingRemote != controlling else { return }
        if controlling {
            let change = pasteboard.changeCount
            pendingLocalChange = change != observedChange && change != deferredLocalChange ? change : nil
            poll()
        } else { skipChangesWhileControlling() }
        controllingRemote = controlling
    }

    /// 操作远端时按 ⌘V 是否要等剪贴板：只有本机复制等待发送或仍在发送时才等，否则按普通按键直接送达。
    var holdsPaste: Bool { running && (!controllingRemote || pendingLocalChange != nil || sendingChange != nil) }

    /// 本机剪贴板已处理到的版本。自动重连时交给新会话，断线期间在本机的复制仍在切回时发送。
    var handledChange: Int { observedChange }

    /// 本机明确发起的复制（截取远端画面）在操作远端期间也照常发送。
    func sendLocalCopy() {
        guard running else { return }
        let change = pasteboard.changeCount
        guard change != observedChange, change != deferredLocalChange else { return }
        pendingLocalChange = change
        guard allowsAutomaticSending else { return }
        sendCurrent()
    }

    func respondToFileOffer(id: UUID, accept: Bool) {
        guard running, let pendingFileOffer, pendingFileOffer.id == id else { return }
        if accept, pasteboard.changeCount != pendingFileOffer.change {
            transfer.respondToFileOffer(id: id, accept: false)
            sendCurrent()
            return
        }
        if accept { receivingFileChange = pendingFileOffer.change }
        transfer.respondToFileOffer(id: id, accept: accept)
    }

    func prepareForPaste(_ completion: @escaping (Bool) -> Void) {
        guard running, allowsAutomaticSending else { completion(false); return }
        if controllingRemote { skipChangesWhileControlling() }
        if controllingRemote, pendingLocalChange == nil {
            // 远端自己的复制粘贴不补发本机剪贴板，也不重新发起文件确认；本机正在接收的文件与之无关。
            guard let sending = sendingChange else { completion(true); return }
            if sending == fileSendingChange {
                completion(false)
                onStatus?("文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴")
                return
            }
            waiters.append(completion)
            return
        }
        guard receivingFileChange == nil else {
            completion(false)
            onStatus?("文件仍在接收，完成后请再次粘贴；新的本机复制会随后同步")
            return
        }
        guard !pasteboard.isSensitive else {
            onStatus?("剪贴板内容已标记为敏感，未同步到对端")
            completion(false)
            return
        }
        if imageApplication != nil { waiters.append(completion); return }
        let change = pasteboard.changeCount
        if change == sharedChange { completion(true); return }
        if let files = pasteboard.fileURLs, !files.isEmpty {
            if pasteboard.isRelayedFromOtherDevice {
                completion(false)
                onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
                return
            }
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
        receivingFileID = nil
        receivingFileChange = nil
        receivedFilesKeptLocally = false
        onFileReceptionChanged?(nil)
        pendingLocalChange = nil
        cancelImageApplication()
        imagePreparation = nil
        timer?.invalidate(); timer = nil
        transfer.stop()
        settleWaiters(false)
    }

    private func settleWaiters(_ result: Bool) {
        let callbacks = waiters
        waiters.removeAll()
        callbacks.forEach { $0(result) }
    }

    private func poll() {
        guard running else { return }
        if controllingRemote {
            skipChangesWhileControlling()
            guard pendingLocalChange != nil else { return }
        }
        sendLocalCopy()
    }

    private func skipChangesWhileControlling() {
        let change = pasteboard.changeCount
        if pendingLocalChange != change { pendingLocalChange = nil }
        if change != deferredLocalChange, change != pendingLocalChange { observedChange = change }
    }

    private func sendCurrent() {
        guard running, allowsAutomaticSending else { return }
        let change = pasteboard.changeCount
        guard receivingFileChange == nil else {
            if change != deferredLocalChange { pendingLocalChange = change }
            settleWaiters(false)
            return
        }
        pendingLocalChange = nil
        observedChange = change
        imagePreparation = nil
        cancelImageApplication()
        guard !pasteboard.isSensitive else {
            sendingChange = nil
            onStatus?("剪贴板内容已标记为敏感，未同步到对端")
            settleWaiters(false)
            return
        }
        let payload: ClipboardPayload
        if let files = pasteboard.fileURLs, !files.isEmpty {
            payload = .files(files)
        } else if let png = pasteboard.pngData { payload = .png(png) }
        else if let tiff = pasteboard.tiffData {
            guard UInt64(tiff.count) <= ClipboardAutomaticLimits.imageBytes else {
                onStatus?("图片超过 64 MiB，未自动同步，请保存为文件后复制")
                settleWaiters(false)
                return
            }
            let token = UUID()
            imagePreparation = token
            sendingChange = change
            let convert = convertTIFF
            let imageQueue = imageQueue
            transfer.prepareSend(deferred: { [weak self] in
                DispatchQueue.main.async { self?.deferLocalCopy(change: change) }
            }) { [weak self] preparation in
                guard let preparation else { return }
                imageQueue.async {
                    let png = convert(tiff)
                    DispatchQueue.main.async {
                        guard let self, self.running, self.imagePreparation == token else { return }
                        self.imagePreparation = nil
                        self.sendingChange = nil
                        guard self.allowsAutomaticSending, self.pasteboard.changeCount == change else {
                            self.settleWaiters(false)
                            self.poll()
                            return
                        }
                        guard let png else {
                            self.onStatus?("剪贴板图片无法转换为 PNG")
                            self.settleWaiters(false)
                            return
                        }
                        self.sendPrepared(.png(png), change: change, preparation: preparation)
                    }
                }
            }
            return
        }
        else if let text = pasteboard.text { payload = .text(Data(text.utf8)) }
        else {
            onStatus?("此剪贴板类型暂不能同步")
            settleWaiters(false)
            return
        }
        sendPrepared(payload, change: change)
    }

    private func sendPrepared(_ payload: ClipboardPayload, change: Int, preparation: UUID? = nil) {
        do {
            switch payload {
            case .text(let bytes): try ClipboardAutomaticLimits.validate(type: "text", bytes: UInt64(bytes.count))
            case .png(let bytes): try ClipboardAutomaticLimits.validate(type: "png", bytes: UInt64(bytes.count))
            case .files: break
            }
        } catch {
            onStatus?(error.localizedDescription)
            settleWaiters(false)
            return
        }
        // 文件来自通用剪贴板（另一台 Mac 复制后由系统同步过来），对端本身就是来源，转发只会形成回环。
        if case .files = payload, pasteboard.isRelayedFromOtherDevice {
            onDiagnostic?(.staleFilesSuppressed)
            onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
            settleWaiters(false)
            return
        }
        // Closing a remote prompt can restore focus without a new local file copy.
        if case .files = payload, staleFileChange == change {
            onDiagnostic?(.staleFilesSuppressed)
            settleWaiters(false)
            return
        }
        staleFileChange = nil
        let contentMarker = Self.marker(for: payload, session: session)
        let isFile: Bool
        if case .files = payload { isFile = true } else { isFile = false }
        if isFile {
            settleWaiters(false)
        }
        if (!isFile && lastSharedMarker == contentMarker) || ((hasSharedState || sendingChange != nil) && pasteboard.contentMarker == contentMarker) {
            hasSharedState = true
            lastSharedMarker = contentMarker
            sharedChange = change
            sendingChange = nil
            settleWaiters(true)
            return
        }
        if isFile, !allowsFileSending {
            onStatus?("对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            settleWaiters(false)
            return
        }
        sendingChange = change
        fileSendingChange = isFile ? change : nil
        let summary = diagnosticSummary(for: payload)
        onDiagnostic?(.sending(summary.kind, fileCount: summary.fileCount))
        transfer.send(payload, preparation: preparation, deferred: { [weak self] in
            DispatchQueue.main.async { self?.deferLocalCopy(change: change) }
        }) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(success ? .sent(summary.kind, fileCount: summary.fileCount) : .sendFailed(summary.kind, fileCount: summary.fileCount))
                guard self.sendingChange == change else { return }
                self.sendingChange = nil
                if success { self.sharedChange = change; self.hasSharedState = true; self.lastSharedMarker = contentMarker }
                self.settleWaiters(success)
            }
        }
    }

    private func deferLocalCopy(change: Int) {
        guard running, sendingChange == change else { return }
        imagePreparation = nil
        sendingChange = nil
        fileSendingChange = nil
        pendingLocalChange = change
        observedChange = Int.min
        settleWaiters(false)
    }

    private func cancelImageApplication() {
        guard let pending = imageApplication else { return }
        imageApplication = nil
        pending.completion(false)
        settleWaiters(false)
    }

    private func prepareApplication(_ payload: ClipboardPayload, permit: ClipboardApplyPermit,
                                    completion: @escaping (Bool) -> Void) {
        guard running, permit.isValid else { completion(false); return }
        if imagePreparation != nil {
            imagePreparation = nil
            sendingChange = nil
            settleWaiters(false)
        }
        cancelImageApplication()
        guard case .png(let bytes) = payload else {
            completion(permit.performIfValid { apply(payload) })
            return
        }
        let token = UUID(), change = pasteboard.changeCount, session = session
        imageApplication = (token, completion)
        let validate = validatePNG
        imageQueue.async { [weak self] in
            let valid = validate(bytes)
            let contentMarker = valid ? Self.marker(for: payload, session: session) : nil
            DispatchQueue.main.async {
                guard let self, self.imageApplication?.token == token else { return }
                self.imageApplication = nil
                guard self.running, self.pasteboard.changeCount == change else {
                    completion(false)
                    self.settleWaiters(false)
                    return
                }
                guard let contentMarker else {
                    self.onDiagnostic?(.applyFailed(.png, fileCount: 0))
                    self.onStatus?("接收的图片无效")
                    completion(false)
                    self.settleWaiters(false)
                    return
                }
                let accepted = permit.performIfValid { self.apply(payload, contentMarker: contentMarker) }
                completion(accepted)
                if !accepted {
                    self.settleWaiters(false)
                }
            }
        }
    }

    private func apply(_ payload: ClipboardPayload, contentMarker: String? = nil) -> Bool {
        guard running else { return false }
        let summary = diagnosticSummary(for: payload)
        switch payload {
        case .text(let bytes):
            guard String(data: bytes, encoding: .utf8) != nil else {
                onDiagnostic?(.applyFailed(summary.kind, fileCount: summary.fileCount))
                return false
            }
        case .png: break
        case .files:
            if let receivingFileChange, pasteboard.changeCount != receivingFileChange {
                // The transfer is complete on disk; a later local copy still owns the pasteboard.
                receivedFilesKeptLocally = true
                deferredLocalChange = nil
                staleFileChange = nil
                settleWaiters(false)
                return true
            }
        }
        let contentMarker = contentMarker ?? Self.marker(for: payload, session: session)
        guard pasteboard.write(payload, marker: contentMarker) else {
            onDiagnostic?(.applyFailed(summary.kind, fileCount: summary.fileCount))
            onStatus?("系统剪贴板写入失败")
            return false
        }
        observedChange = pasteboard.changeCount
        pendingLocalChange = nil
        imagePreparation = nil
        deferredLocalChange = nil
        staleFileChange = nil
        sharedChange = observedChange
        hasSharedState = true
        lastSharedMarker = contentMarker
        sendingChange = nil
        onDiagnostic?(.applied(summary.kind, fileCount: summary.fileCount))
        settleWaiters(true)
        return true
    }

    private func diagnosticSummary(for payload: ClipboardPayload) -> (kind: PayloadKind, fileCount: Int) {
        switch payload {
        case .text: return (.text, 0)
        case .png: return (.png, 0)
        case .files(let urls): return (.files, urls.count)
        }
    }

    nonisolated private static func marker(for payload: ClipboardPayload, session: UUID) -> String {
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
