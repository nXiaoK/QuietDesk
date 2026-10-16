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

@MainActor
private final class MemoryPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var payload: ClipboardPayload = .text(Data())
    private var marker: String?
    var rejectsWrites = false

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
        self.payload = payload; marker = nil; changeCount += 1
    }

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

    init(storage: URL, localAllowed: Bool = false, remoteAllowed: Bool = false) {
        let session = UUID()
        localSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: localAllowed,
            pasteboard: local, storage: storage.appendingPathComponent("local")) { [weak self] message in
                guard let self else { return }
                self.localMessages.append(message.kind)
                if self.routeLocal?(message) != false { self.remoteSync.receive(message) }
            }
        remoteSync = ClipboardSync(session: session, allowsFileSending: true, allowsAutomaticSending: remoteAllowed,
            pasteboard: remote, storage: storage.appendingPathComponent("remote")) { [weak self] message in
                guard let self else { return }
                self.remoteMessages.append(message.kind)
                self.localSync.receive(message)
            }
    }

    func stop() {
        routeLocal = nil
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
