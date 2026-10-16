import AppKit
import QuietDeskCore
import CryptoKit

@MainActor
final class ClipboardSync {
    static let storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuietDesk/Clipboard", isDirectory: true)
    var onStatus: ((String) -> Void)?
    var onFileOffer: ((ClipboardFileOffer?) -> Void)?
    var allowsFileSending: Bool
    private let transfer: ClipboardTransfer
    private var timer: Timer?
    private var observedChange = NSPasteboard.general.changeCount
    private var sharedChange: Int?
    private var sendingChange: Int?
    private var waiters: [(Bool) -> Void] = []
    private var running = true
    private var hasSharedState = false
    private var lastSharedMarker: String?
    private let session: UUID
    private static let marker = NSPasteboard.PasteboardType("local.quietdesk.clipboard-session")

    init(session: UUID, allowsFileSending: Bool, send: @escaping (Message) -> Void) {
        self.session = session
        self.allowsFileSending = allowsFileSending
        transfer = ClipboardTransfer(storage: Self.storageURL, requireFileApproval: true)
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
                guard let self, self.running else { return }
                self.onFileOffer?(offer)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func receive(_ message: Message) { transfer.receive(message) }

    func respondToFileOffer(id: UUID, accept: Bool) {
        guard running else { return }
        if accept, NSPasteboard.general.changeCount != observedChange {
            transfer.respondToFileOffer(id: id, accept: false)
            sendCurrent()
            return
        }
        transfer.respondToFileOffer(id: id, accept: accept)
    }

    func prepareForPaste(_ completion: @escaping (Bool) -> Void) {
        guard running else { completion(false); return }
        let change = NSPasteboard.general.changeCount
        if change == sharedChange { completion(true); return }
        if let files = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
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
        guard running, NSPasteboard.general.changeCount != observedChange else { return }
        sendCurrent()
    }

    private func sendCurrent() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        observedChange = change
        let payload: ClipboardPayload
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            payload = .files(files)
        } else if let png = pasteboard.data(forType: .png) { payload = .png(png) }
        else if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:]) { payload = .png(png) }
        else if let text = pasteboard.string(forType: .string) { payload = .text(Data(text.utf8)) }
        else {
            onStatus?("此剪贴板类型暂不能同步")
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
            return
        }
        let contentMarker = marker(for: payload)
        let isFile: Bool
        if case .files = payload { isFile = true } else { isFile = false }
        if isFile {
            let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(false) }
        }
        if (!isFile && lastSharedMarker == contentMarker) || ((hasSharedState || sendingChange != nil) && pasteboard.string(forType: Self.marker) == contentMarker) {
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
        transfer.send(payload) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.running, self.sendingChange == change else { return }
                self.sendingChange = nil
                if success { self.sharedChange = change; self.hasSharedState = true; self.lastSharedMarker = contentMarker }
                let callbacks = self.waiters; self.waiters.removeAll()
                callbacks.forEach { $0(success) }
            }
        }
    }

    private func apply(_ payload: ClipboardPayload) -> Bool {
        guard running else { return false }
        let pasteboard = NSPasteboard.general
        let accepted: Bool
        switch payload {
        case .text(let bytes):
            guard let text = String(data: bytes, encoding: .utf8) else { return false }
            pasteboard.clearContents(); accepted = pasteboard.setString(text, forType: .string)
        case .png(let bytes):
            guard NSBitmapImageRep(data: bytes) != nil else { onStatus?("接收的图片无效"); return false }
            pasteboard.clearContents(); accepted = pasteboard.setData(bytes, forType: .png)
        case .files(let urls):
            pasteboard.clearContents(); accepted = pasteboard.writeObjects(urls as [NSURL])
        }
        guard accepted else { onStatus?("系统剪贴板写入失败"); return false }
        let contentMarker = marker(for: payload)
        pasteboard.setString(contentMarker, forType: Self.marker)
        observedChange = pasteboard.changeCount
        sharedChange = observedChange
        hasSharedState = true
        lastSharedMarker = contentMarker
        sendingChange = nil
        let callbacks = waiters; waiters.removeAll(); callbacks.forEach { $0(true) }
        return true
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
