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
private func eventually(_ message: String, _ condition: () -> Bool) throws {
    let end = Date().addingTimeInterval(5)
    while !condition(), Date() < end { pump(for: 0.01) }
    try require(condition(), message)
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

    func copy(_ payload: ClipboardPayload) {
        self.payload = payload; rawTIFF = nil; marker = nil; changeCount += 1
    }

    func republish() { marker = nil; changeCount += 1 }

    func write(_ payload: ClipboardPayload, marker: String) -> Bool {
        guard !rejectsWrites else { return false }
        self.payload = payload; self.marker = marker
        changeCount += 1; writes += 1
        return true
    }

    var copiedText: String? {
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
         convertLocalTIFF: @escaping (Data) -> Data? = { data in NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) },
         validateRemotePNG: ((Data) -> Bool)? = nil) {
        let session = UUID()
        localSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: localAllowed,
            controllingRemote: controllingLocal, pasteboard: local, storage: storage.appendingPathComponent("local"),
            convertTIFF: convertLocalTIFF) { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.localMessages.append(message.kind)
                    if self.routeLocal?(message) != false { self.remoteSync.receive(message) }
                }
            }
        remoteSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: remoteAllowed,
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

@main
private struct ClipboardFocusChecks {
    @MainActor
    static func main() {
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
            var failed = false
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

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
