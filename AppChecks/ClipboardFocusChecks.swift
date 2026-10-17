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
                if self.routeRemote?(message) != false { self.localSync.receive(message) }
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
