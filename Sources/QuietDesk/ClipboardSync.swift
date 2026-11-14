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
    func inspectCurrentKind() -> ClipboardManifestKind?
    func write(_ payload: ClipboardPayload, marker: String) -> Bool
    func writeLazy(
        _ kind: ClipboardManifestKind,
        marker: String,
        fetch: @escaping @MainActor () -> ClipboardPayload?,
        asyncFetch: @escaping @MainActor (@escaping (ClipboardPayload?) -> Void) -> Void
    ) -> Bool
}

extension ClipboardPasteboard {
    var isRelayedFromOtherDevice: Bool { false }
    var tiffData: Data? { nil }
    var isSensitive: Bool { false }
    func inspectCurrentKind() -> ClipboardManifestKind? {
        if let files = fileURLs, !files.isEmpty { return .files }
        if pngData != nil || tiffData != nil { return .png }
        if text != nil { return .text }
        return nil
    }
    func writeLazy(
        _ kind: ClipboardManifestKind,
        marker: String,
        fetch: @escaping @MainActor () -> ClipboardPayload?,
        asyncFetch: @escaping @MainActor (@escaping (ClipboardPayload?) -> Void) -> Void
    ) -> Bool {
        false
    }
}

private final class LazyClipboardItemProvider: NSObject, NSPasteboardItemDataProvider {
    private var fetch: (@MainActor () -> ClipboardPayload?)?
    private var cachedPayload: ClipboardPayload?
    private var didFetch = false
    var onFinished: (() -> Void)?

    init(fetch: @escaping @MainActor () -> ClipboardPayload?) {
        self.fetch = fetch
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let resolve: @MainActor () -> ClipboardPayload? = {
            if !self.didFetch {
                self.didFetch = true
                self.cachedPayload = self.fetch?()
            }
            return self.cachedPayload
        }
        let payload: ClipboardPayload?
        if Thread.isMainThread {
            payload = MainActor.assumeIsolated { resolve() }
        } else {
            payload = DispatchQueue.main.sync { MainActor.assumeIsolated { resolve() } }
        }
        guard let payload else { return }
        switch (type, payload) {
        case (.string, .text(let bytes)):
            if let string = String(data: bytes, encoding: .utf8) {
                item.setString(string, forType: .string)
            }
        case (.png, .png(let bytes)):
            item.setData(bytes, forType: .png)
        default:
            break
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        let cleanup = {
            self.fetch = nil
            self.cachedPayload = nil
            self.onFinished?()
            self.onFinished = nil
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }
}

@MainActor
final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard: NSPasteboard
    private var activeLazyProvider: LazyClipboardItemProvider?
    private static let marker = NSPasteboard.PasteboardType("local.quietdesk.clipboard-session")

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

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

    func inspectCurrentKind() -> ClipboardManifestKind? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        let typeSet = Set(types)
        if typeSet.contains(.fileURL) {
            return .files
        }
        if typeSet.contains(.png) || typeSet.contains(.tiff) {
            return .png
        }
        if typeSet.contains(.string) {
            return .text
        }
        return nil
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
        activeLazyProvider = nil
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.writeObjects(items)
    }

    func writeLazy(
        _ kind: ClipboardManifestKind,
        marker: String,
        fetch: @escaping @MainActor () -> ClipboardPayload?,
        asyncFetch: @escaping @MainActor (@escaping (ClipboardPayload?) -> Void) -> Void
    ) -> Bool {
        guard kind == .text || kind == .png else { return false }
        let item = NSPasteboardItem()
        guard item.setString(marker, forType: Self.marker) else { return false }
        let promisedType: NSPasteboard.PasteboardType = (kind == .png) ? .png : .string
        let provider = LazyClipboardItemProvider(fetch: fetch)
        provider.onFinished = { [weak self, weak provider] in
            MainActor.assumeIsolated {
                if self?.activeLazyProvider === provider {
                    self?.activeLazyProvider = nil
                }
            }
        }
        guard item.setDataProvider(provider, forTypes: [promisedType]) else { return false }
        activeLazyProvider = provider
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let wrote = pasteboard.writeObjects([item])
        if !wrote { activeLazyProvider = nil }
        return wrote
    }
}

private final class OnDemandSourceGate: @unchecked Sendable {
    enum Decision {
        case accept
        case rejectBusy
        case rejectStale
    }

    private let lock = NSLock()
    private var expectedRevision: ClipboardRevision?
    private var expectedKind: ClipboardManifestKind?
    private var pullingRemotely = false

    func setExpected(revision: ClipboardRevision?, kind: ClipboardManifestKind?) {
        lock.withLock {
            expectedRevision = revision
            expectedKind = revision == nil ? nil : kind
        }
    }

    func clear(matching revision: ClipboardRevision? = nil) {
        lock.withLock {
            if let revision, expectedRevision != revision { return }
            expectedRevision = nil
            expectedKind = nil
        }
    }

    func matches(revision: ClipboardRevision) -> Bool {
        lock.withLock { expectedRevision == revision }
    }

    func setPullingRemotely(_ active: Bool) {
        lock.withLock { pullingRemotely = active }
    }

    func evaluate(_ request: ClipboardPullRequest) -> Decision {
        lock.withLock {
            if pullingRemotely { return .rejectBusy }
            guard expectedRevision == request.revision, expectedKind == request.kind else {
                return .rejectStale
            }
            return .accept
        }
    }
}

private final class PNGValidatorBox: @unchecked Sendable {
    let validate: (Data) -> Bool
    init(_ validate: @escaping (Data) -> Bool) {
        self.validate = validate
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
    static let keptFilesNotice = "接收的文件已保存到接收目录，未放入剪贴板；保留了新的本机复制内容"
    var onStatus: ((String) -> Void)?
    var onFileTransferStarted: (() -> Void)?
    var onFileResult: ((ClipboardFileResult, Bool) -> Void)?
    var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    var onFileReceptionChanged: ((UUID?) -> Void)?
    /// 接收完成时本机已有更新的复制，文件只留在接收目录；之后的同步状态会覆盖状态行，提示需单独保留。
    var onReceivedFilesKept: (() -> Void)?
    var onDiagnostic: ((DiagnosticEvent) -> Void)?
    private struct LocalOnDemandCopy {
        let token: UUID
        let change: Int
        let kind: ClipboardManifestKind
        var revision: ClipboardRevision?
        var materializedOnPeer: Bool
        var cachedPNG: Data?
    }

    private struct TrackedRemoteManifest {
        let revision: ClipboardRevision
        let kind: ClipboardManifestKind
        var change: Int
        let installedOnPasteboard: Bool
    }

    var allowsFileSending: Bool
    private let allowsDecoupledFileTransfer: Bool
    private let allowsOnDemandClipboard: Bool
    private let deferFileOfferUntilPaste: Bool
    private let sourceGate = OnDemandSourceGate()
    private var localOnDemandCopy: LocalOnDemandCopy?
    private var trackedRemoteManifest: TrackedRemoteManifest?
    private var allowsAutomaticSending: Bool
    private var controllingRemote: Bool
    private let pasteboard: ClipboardPasteboard
    private let transfer: ClipboardTransfer
    nonisolated let receiveMessage: @Sendable (Message) -> Void
    private var timer: Timer?
    private var observedChange: Int
    // A copy made before taking control may still be waiting for activation or session resume.
    private var pendingLocalChange: Int?
    private var pendingFileOffer: (id: UUID, change: Int, explicitDrop: Bool)?
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
         allowsDecoupledFileTransfer: Bool = false, allowsOnDemandClipboard: Bool = false,
         deferFileOfferUntilPaste: Bool = false,
         controllingRemote: Bool = false, handledChange: Int? = nil, pasteboard: ClipboardPasteboard? = nil, storage: URL? = nil,
         convertTIFF: @escaping (Data) -> Data? = { data in
             autoreleasepool { NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) }
         },
         validatePNG: ((Data) -> Bool)? = nil,
         send: @escaping (Message) -> Void) {
        self.session = session
        self.allowsFileSending = allowsFileSending
        self.allowsDecoupledFileTransfer = allowsDecoupledFileTransfer
        self.allowsOnDemandClipboard = allowsOnDemandClipboard
        self.deferFileOfferUntilPaste = deferFileOfferUntilPaste && allowsOnDemandClipboard
        self.allowsAutomaticSending = allowsAutomaticSending
        self.controllingRemote = controllingRemote
        self.convertTIFF = convertTIFF
        let resolvedValidatePNG = validatePNG ?? { data in autoreleasepool { NSBitmapImageRep(data: data) != nil } }
        self.validatePNG = resolvedValidatePNG
        let pasteboard = pasteboard ?? SystemClipboardPasteboard()
        self.pasteboard = pasteboard
        observedChange = handledChange ?? pasteboard.changeCount
        let transfer = ClipboardTransfer(storage: storage ?? Self.storageURL, requireFileApproval: true,
                                         allowsChunkWindow: allowsChunkWindow,
                                         allowsDecoupledFileTransfer: allowsDecoupledFileTransfer,
                                         allowsOnDemandClipboard: allowsOnDemandClipboard)
        self.transfer = transfer
        receiveMessage = { [weak transfer] message in transfer?.receive(message) }
        transfer.onSend = send
        let validatorBox = PNGValidatorBox(resolvedValidatePNG)
        transfer.validatePulledPNG = { data in validatorBox.validate(data) }
        transfer.onManifest = { [weak self] manifest in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.handleRemoteManifest(manifest)
            }
        }
        transfer.onManifestInvalidated = { [weak self, gate = sourceGate] revision in
            gate.clear(matching: revision)
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if self.localOnDemandCopy?.revision == revision {
                    self.localOnDemandCopy = nil
                    self.sharedChange = nil
                    self.lastSharedMarker = nil
                }
            }
        }
        transfer.onPullRequested = { [weak self, weak transfer, gate = sourceGate] request in
            switch gate.evaluate(request) {
            case .rejectBusy:
                transfer?.rejectPull(request, reason: "对端正在处理另一项粘贴请求")
                return
            case .rejectStale:
                transfer?.rejectPull(request, reason: "剪贴板内容已更新或不可用")
                return
            case .accept:
                DispatchQueue.main.async {
                    guard let self, self.running else {
                        transfer?.rejectPull(request, reason: "对端剪贴板会话已关闭")
                        return
                    }
                    self.fulfillPullRequest(request)
                }
            }
        }
        transfer.onExplicitFilesReceived = { [weak self] files in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(.applied(.files, fileCount: files.count))
            }
        }
        transfer.onApplyWithPermit = { [weak self] payload, permit, completion in
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                self.prepareApplication(payload, permit: permit, completion: completion)
            }
        }
        transfer.onStatus = { [weak self] status in DispatchQueue.main.async { self?.onStatus?(status) } }
        transfer.onFileTransferStarted = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onFileTransferStarted?()
            }
        }
        transfer.onFileResult = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onFileResult?(result, result.direction == .receiving && self.receivedFilesKeptLocally)
            }
        }
        transfer.onFileReceptionChanged = { [weak self] id in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.receivingFileID = id
                if id != nil {
                    if self.receivingFileChange == nil, self.pendingFileOffer?.explicitDrop != true {
                        self.receivingFileChange = self.pendingFileOffer?.change ?? self.pasteboard.changeCount
                    }
                } else {
                    self.receivingFileChange = nil
                    if self.receivedFilesKeptLocally {
                        self.receivedFilesKeptLocally = false
                        self.onStatus?("文件接收完成")
                        self.onReceivedFilesKept?()
                    }
                }
                self.onFileReceptionChanged?(id)
                if id == nil { self.poll() }
            }
        }
        transfer.onFileOffer = { [weak self] offer in
            DispatchQueue.main.async {
                guard let self, self.running, let offer else { return }
                if self.allowsDecoupledFileTransfer {
                    let change = self.pasteboard.changeCount
                    self.pendingFileOffer = (offer.id, change, offer.isExplicitDrop)
                    if !offer.isExplicitDrop {
                        self.staleFileChange = change
                    }
                    self.onDiagnostic?(.fileOfferReceived(count: offer.count, totalBytes: offer.bytes))
                    self.onFileOffer?(offer)
                    return
                }
                self.lastSharedMarker = nil
                self.cancelImageApplication()
                if self.imagePreparation != nil {
                    self.imagePreparation = nil
                    self.sendingChange = nil
                    self.settleWaiters(false)
                }
                let change = self.pasteboard.changeCount
                self.pendingFileOffer = (offer.id, change, offer.isExplicitDrop)
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
                    if !self.allowsDecoupledFileTransfer {
                        self.observedChange = pending.change
                    } else if !pending.explicitDrop,
                              (self.pasteboard.changeCount == pending.change || self.pasteboard.isRelayedFromOtherDevice),
                              self.pendingLocalChange == nil {
                        self.observedChange = self.pasteboard.changeCount
                    }
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
            if pasteboard.isRelayedFromOtherDevice {
                pendingLocalChange = nil
                if change != deferredLocalChange { observedChange = change }
            } else {
                pendingLocalChange = change != observedChange && change != deferredLocalChange ? change : nil
            }
            poll()
        } else { skipChangesWhileControlling() }
        controllingRemote = controlling
    }

    private var hasActivePasteboardFileSend: Bool {
        guard let fileSendingChange else { return false }
        return !allowsDecoupledFileTransfer || fileSendingChange == observedChange
    }

    private var hasUnmaterializedOnDemandCopy: Bool {
        guard allowsOnDemandClipboard, let copy = localOnDemandCopy, !copy.materializedOnPeer else { return false }
        return pasteboard.changeCount == copy.change
    }

    /// 操作远端时按 ⌘V 是否要等剪贴板：只有本机复制等待发送、仍在发送或尚未按需物化到远端时才等，否则按普通按键直接送达。
    var holdsPaste: Bool {
        running && (!controllingRemote || pendingLocalChange != nil || sendingChange != nil || hasActivePasteboardFileSend || hasUnmaterializedOnDemandCopy)
    }

    /// 本机剪贴板已处理到的版本。自动重连时交给新会话；若按需清单尚未物化到对端，重连后重新通告该版本。
    var handledChange: Int {
        if hasUnmaterializedOnDemandCopy, let copy = localOnDemandCopy {
            return copy.change &- 1
        }
        return observedChange
    }

    /// 显式发送拖拽的文件（不读取也不改写系统剪贴板）。
    @discardableResult
    func sendDroppedFiles(_ urls: [URL]) -> Bool {
        guard running else { return false }
        let normalized = Self.normalizeDroppedFileURLs(urls)
        guard !normalized.isEmpty else {
            onStatus?("没有可发送的本地文件")
            return false
        }
        guard allowsFileSending else {
            onStatus?("对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            return false
        }
        onDiagnostic?(.sending(.files, fileCount: normalized.count))
        transfer.sendExplicitFiles(normalized) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(success
                    ? .sent(.files, fileCount: normalized.count)
                    : .sendFailed(.files, fileCount: normalized.count))
            }
        }
        return true
    }

    nonisolated static func normalizeDroppedFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL && !url.path.isEmpty {
            let standardized = url.standardizedFileURL
            let key = standardized.path.precomposedStringWithCanonicalMapping
            if seen.insert(key).inserted {
                result.append(standardized)
            }
        }
        return result
    }

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
        guard running, var pending = pendingFileOffer, pending.id == id else { return }
        if pasteboard.changeCount != pending.change, pasteboard.isRelayedFromOtherDevice {
            pending.change = pasteboard.changeCount
            pendingFileOffer = pending
        }
        if !allowsDecoupledFileTransfer, accept, pasteboard.changeCount != pending.change {
            transfer.respondToFileOffer(id: id, accept: false)
            sendCurrent()
            return
        }
        if accept, !pending.explicitDrop { receivingFileChange = pending.change }
        transfer.respondToFileOffer(id: id, accept: accept)
    }

    func prepareForPaste(_ completion: @escaping (Bool) -> Void) {
        guard running, allowsAutomaticSending else { completion(false); return }
        if controllingRemote {
            skipChangesWhileControlling()
            if pendingLocalChange != nil, pasteboard.isRelayedFromOtherDevice {
                let relayedChange = pasteboard.changeCount
                pendingLocalChange = nil
                if relayedChange != deferredLocalChange { observedChange = relayedChange }
            }
        }
        if controllingRemote, pendingLocalChange == nil, !hasUnmaterializedOnDemandCopy {
            // 远端自己的复制粘贴不补发本机剪贴板，也不重新发起文件确认；本机正在接收的文件与之无关。
            if let sending = sendingChange {
                if !allowsDecoupledFileTransfer, sending == fileSendingChange {
                    completion(false)
                    onStatus?("文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴")
                    return
                }
                waiters.append(completion)
                return
            }
            if hasActivePasteboardFileSend {
                completion(false)
                onStatus?("文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴")
                return
            }
            completion(true)
            return
        }
        if !allowsDecoupledFileTransfer, receivingFileChange != nil {
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
            if receivingFileChange != nil {
                completion(false)
                onStatus?("文件仍在接收，完成后请再次粘贴；新的本机复制会随后同步")
                return
            }
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
            let activeFileSend = allowsDecoupledFileTransfer ? fileSendingChange : sendingChange
            if activeFileSend != change { sendCurrentEager() }
            if change == sharedChange { completion(true); return }
            completion(false)
            onStatus?(allowsFileSending ? "文件需在接收端确认；传输完成后请再次按 ⌘V 粘贴" : "对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            return
        }
        waiters.append(completion)
        if sendingChange != change { sendCurrentEager() }
    }

    func stop() {
        running = false
        receivingFileID = nil
        receivingFileChange = nil
        receivedFilesKeptLocally = false
        onFileReceptionChanged?(nil)
        pendingLocalChange = nil
        localOnDemandCopy = nil
        trackedRemoteManifest = nil
        sourceGate.clear()
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
        checkTrackedRemoteManifestInvalidation()
        if controllingRemote {
            skipChangesWhileControlling()
            guard pendingLocalChange != nil else { return }
        }
        sendLocalCopy()
    }

    private func skipChangesWhileControlling() {
        let change = pasteboard.changeCount
        if pendingLocalChange != change { pendingLocalChange = nil }
        if localOnDemandCopy != nil, localOnDemandCopy?.change != change {
            localOnDemandCopy = nil
            sourceGate.clear()
        }
        if change != deferredLocalChange, change != pendingLocalChange { observedChange = change }
    }

    private func checkTrackedRemoteManifestInvalidation() {
        guard allowsOnDemandClipboard, let tracked = trackedRemoteManifest,
              pasteboard.changeCount != tracked.change else { return }
        if pasteboard.isRelayedFromOtherDevice {
            trackedRemoteManifest?.change = pasteboard.changeCount
            return
        }
        trackedRemoteManifest = nil
        transfer.invalidateRemoteManifest(tracked.revision)
    }

    private func sendCurrent() {
        if allowsOnDemandClipboard, waiters.isEmpty {
            announceOnDemandCurrent()
            return
        }
        sendCurrentEager()
    }

    private func announceOnDemandCurrent() {
        guard running, allowsAutomaticSending else { return }
        let change = pasteboard.changeCount
        if !allowsDecoupledFileTransfer, receivingFileChange != nil {
            if change != deferredLocalChange { pendingLocalChange = change }
            return
        }
        if pasteboard.isRelayedFromOtherDevice {
            if trackedRemoteManifest != nil {
                trackedRemoteManifest?.change = change
            }
            if receivingFileChange != nil, receivingFileChange == observedChange {
                receivingFileChange = change
            }
            pendingLocalChange = nil
            observedChange = change
            imagePreparation = nil
            sendingChange = nil
            cancelImageApplication()
            localOnDemandCopy = nil
            sourceGate.clear()
            if pasteboard.inspectCurrentKind() == .files {
                onDiagnostic?(.staleFilesSuppressed)
                onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
            }
            return
        }
        let replacedRemoteRevision: ClipboardRevision?
        if let tracked = trackedRemoteManifest, tracked.change != change {
            trackedRemoteManifest = nil
            replacedRemoteRevision = tracked.revision
        } else {
            replacedRemoteRevision = nil
        }
        pendingLocalChange = nil
        observedChange = change
        imagePreparation = nil
        cancelImageApplication()
        guard !pasteboard.isSensitive else {
            sendingChange = nil
            localOnDemandCopy = nil
            sourceGate.clear()
            if let replacedRemoteRevision { transfer.invalidateRemoteManifest(replacedRemoteRevision) }
            onStatus?("剪贴板内容已标记为敏感，未同步到对端")
            return
        }
        if hasSharedState, let marker = pasteboard.contentMarker, marker.hasPrefix(session.uuidString + ":") {
            sharedChange = change
            lastSharedMarker = marker
            return
        }
        guard let kind = pasteboard.inspectCurrentKind() else {
            localOnDemandCopy = nil
            sourceGate.clear()
            if let replacedRemoteRevision { transfer.invalidateRemoteManifest(replacedRemoteRevision) }
            onStatus?("此剪贴板类型暂不能同步")
            return
        }
        if kind == .files {
            if pasteboard.isRelayedFromOtherDevice {
                localOnDemandCopy = nil
                sourceGate.clear()
                if let replacedRemoteRevision { transfer.invalidateRemoteManifest(replacedRemoteRevision) }
                onDiagnostic?(.staleFilesSuppressed)
                onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
                return
            }
            if staleFileChange == change {
                localOnDemandCopy = nil
                sourceGate.clear()
                if let replacedRemoteRevision { transfer.invalidateRemoteManifest(replacedRemoteRevision) }
                onDiagnostic?(.staleFilesSuppressed)
                return
            }
            if !deferFileOfferUntilPaste {
                localOnDemandCopy = nil
                sourceGate.clear()
                sendCurrentEager()
                return
            }
        }
        staleFileChange = nil
        let token = UUID()
        localOnDemandCopy = LocalOnDemandCopy(
            token: token,
            change: change,
            kind: kind,
            revision: nil,
            materializedOnPeer: false,
            cachedPNG: nil
        )
        sharedChange = nil
        lastSharedMarker = nil
        sourceGate.clear()
        let gate = sourceGate
        transfer.announceManifest(kind: kind) { [weak self] revision in
            if kind == .text || kind == .png {
                gate.setExpected(revision: revision, kind: kind)
            } else {
                gate.clear()
            }
            DispatchQueue.main.async {
                guard let self, self.running, self.localOnDemandCopy?.token == token else { return }
                if let revision {
                    if (kind == .text || kind == .png) && !gate.matches(revision: revision) {
                        self.localOnDemandCopy = nil
                    } else {
                        self.localOnDemandCopy?.revision = revision
                    }
                } else {
                    self.localOnDemandCopy = nil
                }
            }
        }
    }

    private func sendCurrentEager() {
        guard running, allowsAutomaticSending else { return }
        let change = pasteboard.changeCount
        if !allowsDecoupledFileTransfer, receivingFileChange != nil {
            if change != deferredLocalChange { pendingLocalChange = change }
            settleWaiters(false)
            return
        }
        let previousObserved = observedChange
        pendingLocalChange = nil
        observedChange = change
        imagePreparation = nil
        cancelImageApplication()
        if pasteboard.isRelayedFromOtherDevice {
            if trackedRemoteManifest != nil {
                trackedRemoteManifest?.change = change
            }
            if receivingFileChange != nil, receivingFileChange == previousObserved {
                receivingFileChange = change
            }
            sendingChange = nil
            localOnDemandCopy = nil
            sourceGate.clear()
            if pasteboard.inspectCurrentKind() == .files {
                onDiagnostic?(.staleFilesSuppressed)
                onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
            } else if !waiters.isEmpty {
                onStatus?("剪贴板内容来自系统通用剪贴板（接力），已跳过 QuietDesk 回传")
            }
            settleWaiters(false)
            return
        }
        guard !pasteboard.isSensitive else {
            sendingChange = nil
            localOnDemandCopy = nil
            sourceGate.clear()
            onStatus?("剪贴板内容已标记为敏感，未同步到对端")
            settleWaiters(false)
            return
        }
        let payload: ClipboardPayload
        if let files = pasteboard.fileURLs, !files.isEmpty {
            if receivingFileChange != nil {
                if change != deferredLocalChange { pendingLocalChange = change }
                observedChange = Int.min
                settleWaiters(false)
                return
            }
            payload = .files(files)
        } else if let copy = localOnDemandCopy, copy.change == change, let cachedPNG = copy.cachedPNG {
            payload = .png(cachedPNG)
        } else if let png = pasteboard.pngData {
            if localOnDemandCopy?.change == change { localOnDemandCopy?.cachedPNG = png }
            payload = .png(png)
        } else if let tiff = pasteboard.tiffData {
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
                        if self.localOnDemandCopy?.change == change {
                            self.localOnDemandCopy?.cachedPNG = png
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
        // 通用剪贴板（另一台设备复制后由系统接力同步过来）的内容不应再转发给对端，否则会形成回环。
        if pasteboard.isRelayedFromOtherDevice {
            if case .files = payload {
                onDiagnostic?(.staleFilesSuppressed)
                onStatus?("剪贴板文件来自系统通用剪贴板（接力），已跳过 QuietDesk 文件回传")
            } else if !waiters.isEmpty {
                onStatus?("剪贴板内容来自系统通用剪贴板（接力），已跳过 QuietDesk 回传")
            }
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
        let activeSend = (allowsDecoupledFileTransfer && isFile) ? fileSendingChange : sendingChange
        if (!isFile && lastSharedMarker == contentMarker) || ((hasSharedState || activeSend != nil) && pasteboard.contentMarker == contentMarker) {
            hasSharedState = true
            lastSharedMarker = contentMarker
            sharedChange = change
            if allowsDecoupledFileTransfer && isFile {
                fileSendingChange = nil
            } else {
                sendingChange = nil
            }
            settleWaiters(true)
            return
        }
        if isFile, !allowsFileSending {
            onStatus?("对端需更新到 0.5.0 才能确认接收文件，未发送文件内容")
            settleWaiters(false)
            return
        }
        if isFile, localOnDemandCopy?.change == change {
            localOnDemandCopy?.materializedOnPeer = true
            sourceGate.clear()
        }
        if allowsDecoupledFileTransfer && isFile {
            fileSendingChange = change
        } else {
            sendingChange = change
            if !allowsDecoupledFileTransfer {
                fileSendingChange = isFile ? change : nil
            }
        }
        let summary = diagnosticSummary(for: payload)
        onDiagnostic?(.sending(summary.kind, fileCount: summary.fileCount))
        transfer.send(payload, preparation: preparation, deferred: { [weak self] in
            DispatchQueue.main.async { self?.deferLocalCopy(change: change, isFile: isFile) }
        }) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(success ? .sent(summary.kind, fileCount: summary.fileCount) : .sendFailed(summary.kind, fileCount: summary.fileCount))
                if self.allowsDecoupledFileTransfer && isFile {
                    guard self.fileSendingChange == change else { return }
                    self.fileSendingChange = nil
                    if success, self.observedChange == change {
                        self.sharedChange = change
                        self.hasSharedState = true
                        self.lastSharedMarker = contentMarker
                    }
                    return
                }
                guard self.sendingChange == change else { return }
                self.sendingChange = nil
                if !self.allowsDecoupledFileTransfer, self.fileSendingChange == change {
                    self.fileSendingChange = nil
                }
                if success {
                    if self.localOnDemandCopy?.change == change {
                        self.localOnDemandCopy?.materializedOnPeer = true
                        self.sourceGate.clear()
                    }
                    self.sharedChange = change
                    self.hasSharedState = true
                    self.lastSharedMarker = contentMarker
                }
                self.settleWaiters(success)
            }
        }
    }

    private func handleRemoteManifest(_ manifest: ClipboardManifest) {
        guard running, allowsOnDemandClipboard else { return }
        if !allowsDecoupledFileTransfer, receivingFileChange != nil {
            return
        }
        if imagePreparation != nil {
            imagePreparation = nil
            sendingChange = nil
            settleWaiters(false)
        }
        cancelImageApplication()
        localOnDemandCopy = nil
        sourceGate.clear()

        if manifest.kind == .files {
            trackedRemoteManifest = TrackedRemoteManifest(
                revision: manifest.revision,
                kind: .files,
                change: pasteboard.changeCount,
                installedOnPasteboard: false
            )
            return
        }

        let marker = Self.lazyMarker(for: manifest.revision, kind: manifest.kind, session: session)
        let revision = manifest.revision
        let kind = manifest.kind
        let wrote = pasteboard.writeLazy(
            kind,
            marker: marker,
            fetch: { [weak self] in
                guard let self, self.running else { return nil }
                return self.pullRemotePayloadSynchronously(revision: revision, kind: kind)
            },
            asyncFetch: { [weak self] completion in
                guard let self, self.running else {
                    completion(nil)
                    return
                }
                self.pullRemotePayloadAsynchronously(revision: revision, kind: kind, completion: completion)
            }
        )
        guard wrote else {
            onDiagnostic?(.applyFailed(kind == .png ? .png : .text, fileCount: 0))
            onStatus?("系统剪贴板写入失败")
            transfer.invalidateRemoteManifest(revision)
            return
        }
        let newChange = pasteboard.changeCount
        trackedRemoteManifest = TrackedRemoteManifest(
            revision: revision,
            kind: kind,
            change: newChange,
            installedOnPasteboard: true
        )
        observedChange = newChange
        pendingLocalChange = nil
        deferredLocalChange = nil
        staleFileChange = nil
        sharedChange = newChange
        hasSharedState = true
        lastSharedMarker = marker
        sendingChange = nil
    }

    private func pullRemotePayloadSynchronously(revision: ClipboardRevision, kind: ClipboardManifestKind) -> ClipboardPayload? {
        sourceGate.setPullingRemotely(true)
        defer { sourceGate.setPullingRemotely(false) }
        let payload = transfer.pullPayloadSynchronously(revision: revision, kind: kind)
        if let payload {
            let summary = diagnosticSummary(for: payload)
            onDiagnostic?(.applied(summary.kind, fileCount: summary.fileCount))
        } else {
            onDiagnostic?(.applyFailed(kind == .png ? .png : .text, fileCount: 0))
        }
        return payload
    }

    private func pullRemotePayloadAsynchronously(revision: ClipboardRevision, kind: ClipboardManifestKind,
                                                 completion: @escaping (ClipboardPayload?) -> Void) {
        transfer.pullPayload(revision: revision, kind: kind) { [weak self] payload in
            DispatchQueue.main.async {
                if let self, self.running {
                    if let payload {
                        let summary = self.diagnosticSummary(for: payload)
                        self.onDiagnostic?(.applied(summary.kind, fileCount: summary.fileCount))
                    } else {
                        self.onDiagnostic?(.applyFailed(kind == .png ? .png : .text, fileCount: 0))
                    }
                }
                completion(payload)
            }
        }
    }

    private func fulfillPullRequest(_ request: ClipboardPullRequest) {
        guard running, allowsOnDemandClipboard,
              let copy = localOnDemandCopy,
              copy.kind == request.kind,
              (copy.revision == nil || copy.revision == request.revision),
              pasteboard.changeCount == copy.change,
              !pasteboard.isSensitive else {
            localOnDemandCopy = nil
            sourceGate.clear()
            transfer.rejectPull(request, reason: "对端剪贴板已变化，请重新复制")
            poll()
            return
        }

        switch request.kind {
        case .text:
            guard let text = pasteboard.text else {
                transfer.rejectPull(request, reason: "剪贴板文字已不可用")
                return
            }
            let bytes = Data(text.utf8)
            do {
                try ClipboardAutomaticLimits.validate(type: "text", bytes: UInt64(bytes.count))
            } catch {
                transfer.rejectPull(request, reason: error.localizedDescription)
                return
            }
            sendPulledPayload(.text(bytes), request: request, change: copy.change)
        case .png:
            if let cachedPNG = copy.cachedPNG {
                sendPulledPayload(.png(cachedPNG), request: request, change: copy.change)
                return
            }
            if let png = pasteboard.pngData {
                do {
                    try ClipboardAutomaticLimits.validate(type: "png", bytes: UInt64(png.count))
                } catch {
                    transfer.rejectPull(request, reason: error.localizedDescription)
                    return
                }
                if localOnDemandCopy?.change == copy.change {
                    localOnDemandCopy?.cachedPNG = png
                }
                sendPulledPayload(.png(png), request: request, change: copy.change)
                return
            }
            guard let tiff = pasteboard.tiffData else {
                transfer.rejectPull(request, reason: "剪贴板图片已不可用")
                return
            }
            guard UInt64(tiff.count) <= ClipboardAutomaticLimits.imageBytes else {
                transfer.rejectPull(request, reason: "图片超过 64 MiB，未自动同步，请保存为文件后复制")
                return
            }
            let convert = convertTIFF
            let change = copy.change
            imageQueue.async { [weak self] in
                let png = convert(tiff)
                DispatchQueue.main.async {
                    guard let self, self.running else { return }
                    guard self.pasteboard.changeCount == change, !self.pasteboard.isSensitive else {
                        self.transfer.rejectPull(request, reason: "对端剪贴板已变化，请重新复制")
                        return
                    }
                    guard let png else {
                        self.transfer.rejectPull(request, reason: "剪贴板图片无法转换为 PNG")
                        return
                    }
                    do {
                        try ClipboardAutomaticLimits.validate(type: "png", bytes: UInt64(png.count))
                    } catch {
                        self.transfer.rejectPull(request, reason: error.localizedDescription)
                        return
                    }
                    if self.localOnDemandCopy?.change == change {
                        self.localOnDemandCopy?.cachedPNG = png
                    }
                    self.sendPulledPayload(.png(png), request: request, change: change)
                }
            }
        case .files:
            transfer.rejectPull(request, reason: "按需拉取不支持文件")
        }
    }

    private func sendPulledPayload(_ payload: ClipboardPayload, request: ClipboardPullRequest, change: Int) {
        let summary = diagnosticSummary(for: payload)
        onDiagnostic?(.sending(summary.kind, fileCount: 0))
        transfer.sendPulled(payload, requestID: request.requestID) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.onDiagnostic?(success ? .sent(summary.kind, fileCount: 0) : .sendFailed(summary.kind, fileCount: 0))
                if success, self.localOnDemandCopy?.change == change {
                    self.localOnDemandCopy?.materializedOnPeer = true
                    self.sharedChange = change
                }
            }
        }
    }

    private func deferLocalCopy(change: Int, isFile: Bool = false) {
        if allowsDecoupledFileTransfer && isFile {
            guard running, fileSendingChange == change else { return }
            fileSendingChange = nil
            pendingLocalChange = change
            observedChange = Int.min
            settleWaiters(false)
            return
        }
        guard running, sendingChange == change else { return }
        imagePreparation = nil
        sendingChange = nil
        if !allowsDecoupledFileTransfer { fileSendingChange = nil }
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
        let isKeptBackgroundFile: Bool
        if allowsDecoupledFileTransfer, case .files = payload,
           let receivingFileChange, pasteboard.changeCount != receivingFileChange,
           !pasteboard.isRelayedFromOtherDevice {
            isKeptBackgroundFile = true
        } else {
            isKeptBackgroundFile = false
        }
        if allowsOnDemandClipboard, !isKeptBackgroundFile, !allowsAutomaticSending,
           let tracked = trackedRemoteManifest, pasteboard.changeCount != tracked.change,
           !pasteboard.isRelayedFromOtherDevice {
            trackedRemoteManifest = nil
            localOnDemandCopy = nil
            sourceGate.clear()
            completion(permit.performIfValid { true })
            return
        }
        if !isKeptBackgroundFile {
            if imagePreparation != nil {
                imagePreparation = nil
                sendingChange = nil
                settleWaiters(false)
            }
            cancelImageApplication()
        }
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
                guard self.running, self.pasteboard.changeCount == change || self.pasteboard.isRelayedFromOtherDevice else {
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
            if let receivingFileChange, pasteboard.changeCount != receivingFileChange,
               !pasteboard.isRelayedFromOtherDevice {
                // The transfer is complete on disk; a later local copy still owns the pasteboard.
                receivedFilesKeptLocally = true
                deferredLocalChange = nil
                staleFileChange = nil
                onDiagnostic?(.applied(summary.kind, fileCount: summary.fileCount))
                if !allowsDecoupledFileTransfer {
                    settleWaiters(false)
                }
                return true
            }
        }
        trackedRemoteManifest = nil
        localOnDemandCopy = nil
        sourceGate.clear()
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

    nonisolated private static func lazyMarker(for revision: ClipboardRevision, kind: ClipboardManifestKind, session: UUID) -> String {
        "\(session.uuidString):lazy:\(kind.rawValue):\(revision.origin.uuidString):\(revision.counter)"
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
