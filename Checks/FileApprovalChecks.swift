import Foundation
import QuietDeskCore

func runFileApprovalChecks() {
    for independentLane in [false, true] {
        run("A physical paste requests one multi-root offer and sends no file data before approval (independent lane: \(independentLane))") {
            try withCheckFolder { folder in
                func endpoint(_ name: String) -> ClipboardTransfer {
                    ClipboardTransfer(storage: folder.appendingPathComponent(name), requireFileApproval: true,
                                      allowsDecoupledFileTransfer: independentLane, allowsOnDemandClipboard: true,
                                      allowsPhysicalFilePaste: true)
                }
                let sender = endpoint("sender"), receiver = endpoint("receiver")
                let roots = ["first.txt", "second.txt"].map { folder.appendingPathComponent($0) }
                for url in roots { try Data(url.lastPathComponent.utf8).write(to: url) }
                let manifest = Box<ClipboardManifest?>(nil), offer = Box<ClipboardFileOffer?>(nil)
                let sent = Box<[MessageKind]>([]), requested = Box(0), receipts = Box(0), handedOff = Box<[Bool]>([])
                let published = Box<[String]>([]), success = Box(false)
                let resolved = Box<[(ClipboardRevision, [URL]?)]>([])
                let copied = DispatchSemaphore(value: 0), prompted = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
                sender.onSend = { [weak receiver] message in sent.update { $0.append(message.kind) }; receiver?.receive(message) }
                receiver.onSend = { [weak sender] message in
                    if message.kind == .clipboardPull { requested.update { $0 += 1 } }
                    if message.kind == .clipboardReceipt { receipts.update { $0 += 1 } }
                    sender?.receive(message)
                }
                sender.onPullRequested = { [weak sender] request in
                    sender?.sendPulled(.files(roots), requestID: request.requestID) { success.set($0); done.signal() }
                }
                receiver.onManifest = { manifest.set($0); copied.signal() }
                receiver.onFilePasteRequestEnded = { _, result in handedOff.update { $0.append(result) } }
                receiver.onFileOffer = { if let value = $0 { offer.set(value); prompted.signal() } }
                receiver.onFilePasteResolved = { revision, roots in resolved.update { $0.append((revision, roots)) } }
                receiver.onApplyWithPermit = { payload, _, complete in
                    guard case .files(let files) = payload, resolved.read().last?.1 == files else { complete(false); return }
                    published.set(files.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
                    complete(true)
                }
                defer { stopTransfers(sender, receiver) }
                let count = independentLane ? roots.count : nil
                sender.announceManifest(kind: .files, fileRootCount: count)
                try wait(copied, "File manifest did not arrive")
                guard let revision = manifest.read()?.revision else { throw CheckFailure("Missing file manifest") }
                try check(manifest.read()?.fileRootCount == count && sent.read() == [.clipboardManifest] && requested.read() == 0,
                          "The file manifest changed root cardinality or initiated file transfer")
                receiver.requestFilePaste(revision: revision)
                receiver.requestFilePaste(revision: revision)
                try wait(prompted, "Physical read did not reach approval")
                guard let offered = offer.read() else { throw CheckFailure("File offer missing") }
                try check(requested.read() == 1 && sent.read() == [.clipboardManifest, .clipboardBegin] && receipts.read() == 0
                          && handedOff.read() == [true] && offered.count == 2 && !offered.isExplicitDrop,
                          "A repeated read downloaded or acknowledged files before approval")
                receiver.respondToFileOffer(id: offered.id, accept: true)
                try wait(done, "Approved files did not finish")
                try check(success.read() && resolved.read().map { $0.0 } == [revision] && published.read() == roots.map(\.lastPathComponent),
                          "The complete roots did not resolve their source exactly once before clipboard application")
            }
        }
    }

    run("A physical file offer can be declined before sending entries, and explicit drops still work without an independent lane") {
        try withCheckFolder { folder in
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"), requireFileApproval: true,
                                           allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true,
                                             allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let file = folder.appendingPathComponent("example")
            try Data([1]).write(to: file)
            let sent = Box<[MessageKind]>([]), results = Box<[Bool]>([]), dropped = Box<[String]>([])
            let prompts = Box<[Bool]>([]), rendered = Box<[Bool]>([]), done = DispatchSemaphore(value: 0)
            receiver.onFilePasteResolved = { _, urls in rendered.update { $0.append(urls != nil) } }
            sender.onSend = { [weak receiver] message in sent.update { $0.append(message.kind) }; receiver?.receive(message) }
            receiver.onSend = { [weak sender] in sender?.receive($0) }
            receiver.onManifest = { [weak receiver] in receiver?.requestFilePaste(revision: $0.revision) }
            sender.onPullRequested = { [weak sender] request in
                sender?.sendPulled(.files([file]), requestID: request.requestID) { value in
                    results.update { $0.append(value) }; done.signal()
                }
            }
            receiver.onFileOffer = { [weak receiver] value in
                guard let offer = value else { return }
                prompts.update { $0.append(offer.isExplicitDrop) }
                receiver?.respondToFileOffer(id: offer.id, accept: offer.isExplicitDrop)
            }
            receiver.onExplicitFilesReceived = { dropped.set($0.map(\.lastPathComponent)) }
            defer { stopTransfers(sender, receiver) }
            sender.announceManifest(kind: .files)
            try wait(done, "Declining the physical paste did not release its sender")
            try check(sent.read() == [.clipboardManifest, .clipboardBegin] && results.read() == [false], "Decline sent contents")
            sender.sendExplicitFiles([file]) { value in results.update { $0.append(value) }; done.signal() }
            try wait(done, "The later explicit drop did not finish")
            try check(rendered.read() == [false] && prompts.read() == [false, true] && dropped.read() == ["example"] && results.read() == [false, true],
                      "Explicit drop required a paste, or was applied to the clipboard")
        }
    }

    run("A new receiver-side copy withdraws a physical file approval and ignores a late click to accept") {
        try withCheckFolder { folder in
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"), requireFileApproval: true,
                                           allowsDecoupledFileTransfer: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true,
                                             allowsDecoupledFileTransfer: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let file = folder.appendingPathComponent("source")
            try Data([1]).write(to: file)
            let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let offered = Box<UUID?>(nil), delivered = Box(true), payloadSeen = Box(false), superseded = Box(false)
            sender.onSend = { [weak receiver] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSeen.set(true) }
                receiver?.receive(message)
            }
            receiver.onSend = { [weak sender] message in sender?.receive(message) }
            sender.onPullRequested = { [weak sender] request in
                sender?.sendPulled(.files([file]), requestID: request.requestID) { delivered.set($0); done.signal() }
            }
            receiver.onManifest = { [weak receiver] in receiver?.requestFilePaste(revision: $0.revision) }
            receiver.onFileOffer = { if let offer = $0 { offered.set(offer.id); ready.signal() } }
            receiver.onFileOfferEnded = { _, reason in superseded.set(reason == .superseded) }
            defer { stopTransfers(sender, receiver) }
            sender.announceManifest(kind: .files)
            try wait(ready, "File approval did not open")
            guard let oldID = offered.read() else { throw CheckFailure("Missing approval ID") }
            receiver.announceManifest(kind: .text)
            receiver.respondToFileOffer(id: oldID, accept: true)
            try wait(done, "Replacing the pasteboard did not stop the sending file")
            try check(superseded.read() && !delivered.read() && !payloadSeen.read(),
                      "The replaced approval started a download")
        }
    }

    run("A file paste rejects invalid manifest counts and a changed count cannot reach approval") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            defer { receiver.stop() }
            let origin = UUID(), revision = ClipboardRevision(counter: 10, origin: origin)
            let seen = Box<[ClipboardRevision]>([]), prompted = Box(false), request = Box<ClipboardPullRequest?>(nil)
            let resolved = Box<[ClipboardRevision]>([]), answered = DispatchSemaphore(value: 0)
            receiver.onManifest = { manifest in seen.update { $0.append(manifest.revision) } }
            receiver.onSend = { msg in
                if msg.kind == .clipboardPull { request.set(try? Wire.readJSON(ClipboardPullRequest.self, msg.payload)) }
                if msg.kind == .clipboardPull || msg.kind == .clipboardCancel { answered.signal() }
            }
            receiver.onFileOffer = { if $0 != nil { prompted.set(true) } }
            receiver.onFilePasteResolved = { revision, urls in if urls == nil { resolved.update { $0.append(revision) } } }
            for (kind, count) in [(ClipboardManifestKind.files, 0), (.files, ClipboardTransfer.maximumPromisedFileRoots + 1), (.text, 1)] {
                receiver.receive(try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: kind, fileRootCount: count)))
                try wait(answered, "Invalid root count was accepted")
            }
            receiver.receive(try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: .files, fileRootCount: 2)))
            receiver.requestFilePaste(revision: revision)
            try wait(answered, "Missing valid pull")
            guard let pull = request.read() else { throw CheckFailure("Missing pull ID") }
            let begin: [String: Any] = ["revision": ["counter": 11, "origin": origin.uuidString], "type": "files",
                                        "sequence": 0, "count": 2, "rootCount": 1, "bytes": 0, "pullRequestID": pull.requestID.uuidString]
            receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            try wait(answered, "Changed root count was accepted")
            try check(seen.read() == [revision] && !prompted.read() && resolved.read() == [revision],
                      "Invalid root metadata installed a promise, started approval, or stranded the original read")
        }
    }

    run("Negotiated Finder root names are bounded, safe, and bound to the received tree") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true, allowsOnDemandClipboard: true,
                allowsPhysicalFilePaste: true, allowsFileRootNames: true)
            defer { receiver.stop() }
            let origin = UUID(), revision = ClipboardRevision(counter: 1, origin: origin)
            let seen = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
            let pulled = DispatchSemaphore(value: 0), approved = DispatchSemaphore(value: 0)
            let request = Box<ClipboardPullRequest?>(nil)
            receiver.onManifest = { _ in seen.signal() }
            receiver.onSend = { message in
                switch message.kind {
                case .clipboardPull:
                    request.set(try? Wire.readJSON(ClipboardPullRequest.self, message.payload)); pulled.signal()
                case .clipboardCancel: cancelled.signal()
                case .clipboardReceipt: approved.signal()
                default: break
                }
            }
            for names in [["../outside"], ["."], ["a/b"], ["Readme", "README"], [String(repeating: "a", count: 256)]] {
                receiver.receive(try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: .files,
                    fileRootCount: names.count, fileRootNames: names)))
                try wait(cancelled, "Unsafe Finder root was advertised")
            }
            let names = (0..<100).map { "root-\($0)-" + String(repeating: "x", count: 48) }
            let manifest = try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: .files,
                fileRootCount: names.count, fileRootNames: names))
            try check(manifest.payload.count > 4096, "Fixture must exercise a large negotiated manifest")
            receiver.receive(manifest); try wait(seen, "Large negotiated root list did not reach the clipboard")
            receiver.requestFilePaste(revision: revision); try wait(pulled, "Valid file paste was not requested")
            let transfer: [String: Any] = ["counter": 2, "origin": origin.uuidString]
            guard let id = request.read()?.requestID else { throw CheckFailure("Missing paste request") }
            receiver.onFileOffer = { offer in if let offer { receiver.respondToFileOffer(id: offer.id, accept: true) } }
            let begin: [String: Any] = ["revision": transfer, "sequence": 0, "type": "files", "count": names.count,
                "rootCount": names.count, "names": [], "bytes": 0, "pullRequestID": id.uuidString]
            receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            try wait(approved, "Valid Finder transfer could not be approved")
            let entry: [String: Any] = ["revision": transfer, "sequence": 1, "path": "substitute", "directory": false,
                "bytes": 0, "mode": 0o600, "modified": 0]
            receiver.receive(Message(.clipboardEntry, try JSONSerialization.data(withJSONObject: entry)))
            try wait(cancelled, "Received root name escaped the approved manifest")
        }
    }

    run("More roots than the native promise limit retain the legacy file manifest") {
        try withCheckFolder { folder in
            let sender = ClipboardTransfer(storage: folder, requireFileApproval: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            defer { sender.stop() }
            let manifest = Box<ClipboardManifest?>(nil), announced = DispatchSemaphore(value: 0)
            sender.onSend = { message in
                if message.kind == .clipboardManifest {
                    manifest.set(try? Wire.readJSON(ClipboardManifest.self, message.payload)); announced.signal()
                }
            }
            sender.announceManifest(kind: .files, fileRootCount: ClipboardTransfer.maximumPromisedFileRoots + 1)
            try wait(announced, "The legacy file manifest was suppressed")
            try check(manifest.read()?.kind == .files && manifest.read()?.fileRootCount == nil, "The oversized native item count reached the peer")
        }
    }

    run("A promised paste with fewer actual roots fails after approval and never materializes partial URLs") {
        try withCheckFolder { folder in
            let directory = folder.appendingPathComponent("photos"), store = folder.appendingPathComponent("receiver")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([4]).write(to: directory.appendingPathComponent("image.bin"))
            let source = ClipboardTransfer(storage: folder.appendingPathComponent("source"), requireFileApproval: true,
                                           allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let sink = ClipboardTransfer(storage: store, requireFileApproval: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let captured = Box<ClipboardRevision?>(nil), resolved = Box<[ClipboardRevision]>([])
            let approved = Box(false), published = Box(false), sent = Box(true), done = DispatchSemaphore(value: 0)
            source.onSend = { [weak sink] msg in
                if msg.kind == .clipboardBegin, var body = try? JSONSerialization.jsonObject(with: msg.payload) as? [String: Any] {
                    body["rootCount"] = 2
                    if let bytes = try? JSONSerialization.data(withJSONObject: body) { sink?.receive(Message(.clipboardBegin, bytes)) }
                } else { sink?.receive(msg) }
            }
            source.onPullRequested = { [weak source] request in
                source?.sendPulled(.files([directory]), requestID: request.requestID) { sent.set($0); done.signal() }
            }
            sink.onManifest = { [weak sink] manifest in captured.set(manifest.revision); sink?.requestFilePaste(revision: manifest.revision) }
            sink.onSend = { [weak source] msg in source?.receive(msg) }
            sink.onFileOffer = { [weak sink] offer in
                if let offer { approved.set(offer.count == 2); sink?.respondToFileOffer(id: offer.id, accept: true) }
            }
            sink.onFilePasteResolved = { revision, urls in if urls == nil { resolved.update { $0.append(revision) } } }
            sink.onReceive = { _ in published.set(true) }
            source.announceManifest(kind: .files, fileRootCount: 2)
            try wait(done, "The sender did not receive the final rejection")
            stopTransfers(source, sink)
            try check(approved.read() && !sent.read() && !published.read() && resolved.read() == captured.read().map { [$0] },
                      "The mismatched received roots escaped into a completed paste")
            try check(!FileManager.default.fileExists(atPath: store.appendingPathComponent("received").path),
                      "An incomplete set of roots moved into the received directory")
        }
    }

    run("A content read queued behind withdrawal resolves without issuing a stale pull") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true, allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            defer { receiver.stop() }
            let revision = ClipboardRevision(counter: 1, origin: UUID()), pulls = Box(0), resolved = DispatchSemaphore(value: 0)
            receiver.onSend = { if $0.kind == .clipboardPull { pulls.update { $0 += 1 } } }
            receiver.onFilePasteResolved = { source, urls in if source == revision && urls == nil { resolved.signal() } }
            receiver.receive(try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: .files, fileRootCount: 1)))
            receiver.invalidateRemoteManifest(revision)
            receiver.requestFilePaste(revision: revision)
            try wait(resolved, "A stale content reader did not wake")
            try check(pulls.read() == 0, "A read on a retired manifest started another file pull")
        }
    }

    run("A file paste accepts only the requested offer from the manifest's origin and a newer revision") {
        try withCheckFolder { folder in
            let origin = UUID(), revision = ClipboardRevision(counter: 3, origin: origin)
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true,
                                             allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let read = DispatchSemaphore(value: 0), replied = DispatchSemaphore(value: 0), prompted = DispatchSemaphore(value: 0)
            let request = Box<ClipboardPullRequest?>(nil), offers = Box(0), receipts = Box(0)
            receiver.onSend = { message in
                if message.kind == .clipboardPull {
                    request.set(try? Wire.readJSON(ClipboardPullRequest.self, message.payload)); read.signal()
                } else if message.kind == .clipboardCancel { replied.signal() }
                else if message.kind == .clipboardReceipt { receipts.update { $0 += 1 } }
            }
            receiver.onFileOffer = { if $0 != nil { offers.update { $0 += 1 }; prompted.signal() } }
            defer { receiver.stop() }
            receiver.receive(try Wire.json(.clipboardManifest, ClipboardManifest(revision: revision, kind: .files)))
            receiver.requestFilePaste(revision: revision)
            try wait(read, "No physical read")
            guard let id = request.read()?.requestID else { throw CheckFailure("Missing pull ID") }
            func offer(revision: Int, source: UUID, requestID: UUID?) throws -> Message {
                var body: [String: Any] = ["revision": ["counter": revision, "origin": source.uuidString],
                                            "type": "files", "sequence": 0, "count": 1, "bytes": 0]
                if let requestID { body["pullRequestID"] = requestID.uuidString }
                return Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: body))
            }
            for message in try [offer(revision: 4, source: origin, requestID: nil),
                                offer(revision: 4, source: origin, requestID: UUID()),
                                offer(revision: 4, source: UUID(), requestID: id),
                                offer(revision: 3, source: origin, requestID: id)] {
                receiver.receive(message)
                try wait(replied, "Unrelated file offer escaped validation")
            }
            receiver.receive(try offer(revision: 4, source: origin, requestID: id))
            try wait(prompted, "Unrelated messages invalidated the requested offer")
            try check(offers.read() == 1 && receipts.read() == 0, "An unrelated or unapproved offer was acknowledged")
        }
    }

    run("Replacing a physical file source cancels the pending read and its late offer cannot open approval") {
        try withCheckFolder { folder in
            let source = ClipboardTransfer(storage: folder.appendingPathComponent("source"), requireFileApproval: true,
                                           allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let sink = ClipboardTransfer(storage: folder.appendingPathComponent("sink"), requireFileApproval: true,
                                         allowsOnDemandClipboard: true, allowsPhysicalFilePaste: true)
            let file = folder.appendingPathComponent("copied.txt")
            try Data([1, 2]).write(to: file)
            let manifest = Box<ClipboardRevision?>(nil), held = Box<Message?>(nil), shown = Box(false), acked = Box(false)
            let callback = Box<[Bool]>([]), complete = Box<[Bool]>([]), resolved = Box<[ClipboardRevision]>([])
            let copied = DispatchSemaphore(value: 0), prepared = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
            let rejected = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            source.onSend = { [weak sink] message in
                if message.kind == .clipboardBegin { held.set(message); prepared.signal() }
                else { sink?.receive(message) }
            }
            sink.onSend = { [weak source] message in
                if message.kind == .clipboardCancel { rejected.signal() }
                if message.kind == .clipboardReceipt { acked.set(true) }
                source?.receive(message)
            }
            source.onPullRequested = { [weak source] request in
                source?.sendPulled(.files([file]), requestID: request.requestID) { result in
                    complete.update { $0.append(result) }; finished.signal()
                }
            }
            sink.onManifest = { manifest.set($0.revision); copied.signal() }
            sink.onFilePasteResolved = { revision, urls in if urls == nil { resolved.update { $0.append(revision) } } }
            sink.onFilePasteRequestEnded = { _, result in callback.update { $0.append(result) }; cancelled.signal() }
            sink.onFileOffer = { if $0 != nil { shown.set(true) } }
            defer { stopTransfers(source, sink) }
            source.announceManifest(kind: .files)
            try wait(copied, "Missing file manifest")
            guard let revision = manifest.read() else { throw CheckFailure("Missing file revision") }
            sink.requestFilePaste(revision: revision)
            try wait(prepared, "File offer was not prepared")
            source.invalidateLocalFileManifest(revision)
            try wait(cancelled, "Source invalidation did not resolve the pending read")
            try wait(finished, "Source file transfer did not cancel")
            guard let late = held.read() else { throw CheckFailure("Missing delayed offer") }
            sink.receive(late)
            try wait(rejected, "Late file offer was not rejected")
            try check(callback.read() == [false] && resolved.read() == [revision] && complete.read() == [false] && !shown.read() && !acked.read(),
                      "Stale file data prompted or began downloading")
        }
    }

    run("Cancelling an accepted file reception removes partial data and ignores duplicate cancellation and late chunks") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("cancel.bin")
            try Data(repeating: 83, count: 120_000).write(to: file)
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let storage = folder.appendingPathComponent("receiver")
            let receiver = ClipboardTransfer(storage: storage, requireFileApproval: true)
            let heldReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
            let held = Box<Message?>(nil), chunks = Box(0), reception = Box<UUID?>(nil)
            let outcomes = Box<[Bool]>([]), published = Box(false), cancellations = Box(0)
            sender.onSend = { message in
                if message.kind == .clipboardChunk {
                    chunks.update { $0 += 1 }
                    if chunks.read() == 2 { held.set(message); heldReady.signal(); return }
                }
                receiver.receive(message)
            }
            receiver.onSend = { message in
                if message.kind == .clipboardCancel { cancellations.update { $0 += 1 } }
                sender.receive(message)
            }
            receiver.onFileOffer = { [weak receiver] in
                if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
            }
            receiver.onFileReceptionChanged = { id in
                if let id { reception.set(id) } else { cleared.signal() }
            }
            receiver.onReceive = { _ in published.set(true) }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([file])) { value in outcomes.update { $0.append(value) }; done.signal() }
            try wait(heldReady, "File did not reach its second chunk")
            guard let id = reception.read(), let late = held.read() else { throw CheckFailure("No active reception or held chunk") }
            receiver.cancelFileReception(id: id)
            receiver.cancelFileReception(id: id)
            try wait(done, "Manual cancellation did not stop the sender")
            try wait(cleared, "Manual cancellation left the reception active")
            receiver.receive(late)
            stopTransfers(sender, receiver)
            let partial = storage.appendingPathComponent("partial")
            try check((try FileManager.default.contentsOfDirectory(atPath: partial.path)).isEmpty
                      && !FileManager.default.fileExists(atPath: storage.appendingPathComponent("received").path),
                      "Cancelled file contents remained in partial or completed storage")
            try check(outcomes.read() == [false] && cancellations.read() == 1 && !published.read(),
                      "Cancellation completed twice, sent duplicate cancellation or published a partial file")
        }
    }

    run("A stale reception cancellation cannot interrupt the next accepted file") {
        try withCheckFolder { folder in
            let files = [folder.appendingPathComponent("first.bin"), folder.appendingPathComponent("next.bin")]
            let bytes = Data(repeating: 67, count: 100_000)
            for file in files { try bytes.write(to: file) }
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let heldReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0)
            let held = Box<Message?>(nil), ids = Box<[UUID]>([]), outcomes = Box<[Bool]>([])
            let correct = Box(false), cancellations = Box(0), shouldHold = Box(true)
            sender.onSend = { message in
                if message.kind == .clipboardChunk, shouldHold.read() {
                    shouldHold.set(false); held.set(message); heldReady.signal(); return
                }
                receiver.receive(message)
            }
            receiver.onSend = { message in
                if message.kind == .clipboardCancel { cancellations.update { $0 += 1 } }
                sender.receive(message)
            }
            receiver.onFileOffer = { [weak receiver] in
                if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
            }
            receiver.onFileReceptionChanged = { id in
                if let id { ids.update { $0.append(id) } } else { cleared.signal() }
            }
            receiver.onReceive = { payload in
                if case .files(let urls) = payload, let file = urls.first {
                    correct.set(file.lastPathComponent == "next.bin" && (try? Data(contentsOf: file)) == bytes)
                }
            }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([files[0]])) { value in outcomes.update { $0.append(value) }; done.signal() }
            try wait(heldReady, "First file did not start")
            guard let oldID = ids.read().first else { throw CheckFailure("First reception ID missing") }
            receiver.cancelFileReception(id: oldID)
            try wait(done, "First file was not cancelled"); try wait(cleared, "First reception state did not clear")
            shouldHold.set(true)
            sender.send(.files([files[1]])) { value in outcomes.update { $0.append(value) }; done.signal() }
            try wait(heldReady, "Next file did not start")
            guard let next = held.read() else { throw CheckFailure("Next file chunk missing") }
            receiver.cancelFileReception(id: oldID)
            receiver.cancelFileReception(id: UUID())
            receiver.receive(next)
            try wait(done, "Stale cancellation interrupted the next file")
            try wait(cleared, "Completed reception state did not clear")
            stopTransfers(sender, receiver)
            try check(ids.read().count == 2 && ids.read()[0] != ids.read()[1]
                      && outcomes.read() == [false, true] && cancellations.read() == 1 && correct.read(),
                      "Reception identity was reused, stale cancellation matched, or the next file changed")
        }
    }

    for ending in ["failure", "stop"] {
        run("File reception state clears after \(ending)") {
            try withCheckFolder { folder in
                let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true)
                let started = DispatchSemaphore(value: 0), cleared = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
                let revision: [String: Any] = ["counter": 1, "origin": UUID().uuidString]
                let states = Box<[UUID?]>([])
                receiver.onFileOffer = { [weak receiver] in
                    if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
                }
                receiver.onFileReceptionChanged = { id in
                    states.update { $0.append(id) }
                    if id != nil { started.signal() } else { cleared.signal() }
                }
                let begin: [String: Any] = ["revision": revision, "sequence": 0, "type": "files", "count": 1, "bytes": 2]
                receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
                try wait(started, "Approved reception did not publish its state")
                if ending == "failure" {
                    let invalid: [String: Any] = ["revision": revision, "sequence": 1, "path": "file", "directory": false,
                                                 "bytes": 3, "mode": 384, "modified": 0]
                    receiver.receive(Message(.clipboardEntry, try JSONSerialization.data(withJSONObject: invalid)))
                    try wait(cleared, "Failed reception state stayed active")
                }
                receiver.stop { stopped.signal() }
                try wait(stopped, "Receiver cleanup did not finish")
                if ending == "stop" { try wait(cleared, "Stopped reception state stayed active") }
                try check(states.read().count == 2 && states.read()[0] != nil && states.read()[1] == nil,
                          "Reception lifecycle did not publish one start and one end")
            }
        }
    }

    run("Received mode-zero files and directories remain readable, writable and removable by their owner") {
        try withCheckFolder { folder in
            let root = folder.appendingPathComponent("folder"), bytes = Data([0, 1, 2, 255])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("file.bin"))
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0), success = Box(false), usable = Box(false)
            sender.onSend = { message in
                if message.kind == .clipboardEntry,
                   var value = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] {
                    value["mode"] = 0
                    receiver.receive(Message(.clipboardEntry, try! JSONSerialization.data(withJSONObject: value)))
                } else { receiver.receive(message) }
            }
            receiver.onSend = { sender.receive($0) }
            receiver.onFileOffer = { [weak receiver] in if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) } }
            receiver.onReceive = { payload in
                guard case .files(let urls) = payload, let root = urls.first else { return }
                do {
                    let file = root.appendingPathComponent("file.bin")
                    let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
                    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                    let readable = try Data(contentsOf: file) == bytes
                    try bytes.write(to: file)
                    try FileManager.default.removeItem(at: root)
                    usable.set(readable && (rootMode?.intValue ?? 0) & 0o700 == 0o700 && (fileMode?.intValue ?? 0) & 0o600 == 0o600
                               && !FileManager.default.fileExists(atPath: root.path))
                } catch { usable.set(false) }
            }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([root])) { success.set($0); done.signal() }
            try wait(done, "Mode-zero file transfer did not finish")
            try check(success.read() && usable.read(), "Peer permissions prevented owner access or cleanup")
        }
    }

    let invalidRoots: [(String, Int, Int, [String], [(String, Bool)], Bool)] = [
        ("File roots must match the names shown in the confirmation", 1, 1, ["report.pdf"], [("other.pdf", false)], false),
        ("File roots cannot exceed the confirmed root count", 2, 1, ["first"], [("first", false), ("second", false)], false),
        ("File completion requires every confirmed root", 2, 2, ["folder"], [("folder", true), ("folder/child", false)], true),
        ("File roots cannot interleave their entries", 3, 2, ["first", "second"], [("first", true), ("second", true), ("first/child", false)], false),
        ("The first entry of each file root must describe the root itself", 1, 1, ["folder"], [("folder/child", false)], false)
    ]
    for (name, count, rootCount, names, entries, finish) in invalidRoots {
        run(name) {
            try withCheckFolder { folder in
                let storage = folder.appendingPathComponent("receiver")
                let receiver = ClipboardTransfer(storage: storage, requireFileApproval: true)
                let revision: [String: Any] = ["counter": 1, "origin": UUID().uuidString]
                let cancelled = DispatchSemaphore(value: 0), retried = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
                let published = Box(false), offered = Box(false)
                receiver.onFileOffer = { [weak receiver] offer in
                    if let offer {
                        if offer.names == ["retry"] { retried.signal() }
                        else { offered.set(true); receiver?.respondToFileOffer(id: offer.id, accept: true) }
                    }
                }
                receiver.onReceive = { _ in published.set(true) }
                receiver.onSend = { if $0.kind == .clipboardCancel { cancelled.signal() } }
                defer { receiver.stop() }
                let begin: [String: Any] = ["revision": revision, "sequence": 0, "type": "files", "count": count,
                    "bytes": 0, "names": names, "rootCount": rootCount]
                let approved = DispatchSemaphore(value: 0)
                receiver.onStatus = { if $0.hasPrefix("正在接收剪贴板") { approved.signal() } }
                receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
                try wait(approved, "Confirmed transfer did not start")
                for (index, entry) in entries.enumerated() {
                    let value: [String: Any] = ["revision": revision, "sequence": index + 1, "path": entry.0,
                        "directory": entry.1, "bytes": 0, "mode": 0o700, "modified": 0]
                    receiver.receive(Message(.clipboardEntry, try JSONSerialization.data(withJSONObject: value)))
                }
                if finish {
                    let end: [String: Any] = ["revision": revision, "sequence": entries.count + 1]
                    receiver.receive(Message(.clipboardEnd, try JSONSerialization.data(withJSONObject: end)))
                }
                try wait(cancelled, "Inconsistent confirmed roots were not cancelled")
                let retry: [String: Any] = ["revision": ["counter": 2, "origin": UUID().uuidString], "sequence": 0,
                    "type": "files", "count": 1, "rootCount": 1, "names": ["retry"], "bytes": 0]
                receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: retry)))
                try wait(retried, "Rejected roots prevented the next file offer")
                try check(offered.read() && !published.read(), "Inconsistent file roots were published")
                let partial = storage.appendingPathComponent("partial")
                let instances = try FileManager.default.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)
                try check(instances.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) == [".lease"] }
                          && !FileManager.default.fileExists(atPath: storage.appendingPathComponent("received").path),
                          "Rejected transfer left file contents in storage")
                receiver.stop { stopped.signal() }; try wait(stopped, "Receiver did not finish cleanup")
            }
        }
    }

    run("File offers over the entry limit only cancel and never request approval") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true)
            let cancelled = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            let messages = Box<[MessageKind]>([]), offered = Box(false), status = Box("")
            receiver.onFileOffer = { if $0 != nil { offered.set(true) } }
            receiver.onStatus = { status.set($0) }
            receiver.onSend = { message in messages.update { $0.append(message.kind) }; if message.kind == .clipboardCancel { cancelled.signal() } }
            let begin: [String: Any] = ["revision": ["counter": 1, "origin": UUID().uuidString], "sequence": 0,
                "type": "files", "count": ClipboardTransfer.maximumFileEntries + 1, "bytes": 0]
            receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            try wait(cancelled, "Oversized file offer did not cancel")
            receiver.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
            try check(messages.read() == [.clipboardCancel] && !offered.read() && status.read().contains("200000"),
                      "Oversized file offer prompted, acknowledged or lost its reason")
        }
    }

    run("File preview names cannot outnumber the confirmed roots") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder, requireFileApproval: true)
            let rejected = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0), offered = Box(false)
            receiver.onStatus = { if $0.contains("剪贴板传输信息无效") { rejected.signal() } }
            receiver.onFileOffer = { if $0 != nil { offered.set(true) } }
            let begin: [String: Any] = ["revision": ["counter": 1, "origin": UUID().uuidString], "sequence": 0,
                "type": "files", "count": 2, "rootCount": 1, "names": ["first", "second"], "bytes": 0]
            receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            try wait(rejected, "Inconsistent preview count was not rejected")
            receiver.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
            try check(!offered.read(), "Inconsistent preview names reached confirmation")
        }
    }

    run("Multiple roots preserve exact bytes when a preview truncates a Chinese character") {
        try withCheckFolder { folder in
            let longName = String(repeating: "文", count: 39) + "ab界长名称"
            let root = folder.appendingPathComponent(longName), second = folder.appendingPathComponent("second.bin")
            let childBytes = Data([0, 1, 254, 255]), secondBytes = Data(repeating: 73, count: 40_000)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try childBytes.write(to: root.appendingPathComponent("child.bin")); try secondBytes.write(to: second)
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0), correct = Box(false), success = Box(false), offerValid = Box(false)
            sender.onSend = { receiver.receive($0) }; receiver.onSend = { sender.receive($0) }
            receiver.onFileOffer = { [weak receiver] offer in
                if let offer {
                    offerValid.set(offer.count == 2 && offer.entryCount == 3 && offer.names == [ClipboardTransfer.previewName(longName), "second.bin"]
                                   && offer.names[0].contains("�"))
                    receiver?.respondToFileOffer(id: offer.id, accept: true)
                }
            }
            receiver.onReceive = { payload in
                if case .files(let urls) = payload, urls.count == 2 {
                    correct.set(urls[0].lastPathComponent == longName && (try? Data(contentsOf: urls[0].appendingPathComponent("child.bin"))) == childBytes
                        && (try? Data(contentsOf: urls[1])) == secondBytes)
                }
            }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([root, second])) { success.set($0); done.signal() }
            try wait(done, "Truncated-preview roots did not finish")
            try check(success.read() && correct.read() && offerValid.read(), "Preview truncation changed names, root counts or bytes")
        }
    }

    run("Legacy file transfers without names or root counts still complete after approval") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("legacy.bin"), bytes = Data([7, 8, 9])
            try bytes.write(to: file)
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0), correct = Box(false), success = Box(false), legacyOffer = Box(false)
            sender.onSend = { message in
                if message.kind == .clipboardBegin,
                   var value = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] {
                    value.removeValue(forKey: "names"); value.removeValue(forKey: "rootCount")
                    receiver.receive(Message(.clipboardBegin, try! JSONSerialization.data(withJSONObject: value)))
                } else { receiver.receive(message) }
            }
            receiver.onSend = { sender.receive($0) }
            receiver.onFileOffer = { [weak receiver] offer in
                if let offer { legacyOffer.set(offer.names.isEmpty && offer.count == 1 && offer.entryCount == 1); receiver?.respondToFileOffer(id: offer.id, accept: true) }
            }
            receiver.onReceive = { if case .files(let urls) = $0 { correct.set((try? Data(contentsOf: urls[0])) == bytes) } }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([file])) { success.set($0); done.signal() }
            try wait(done, "Legacy file transfer did not finish")
            try check(success.read() && correct.read() && legacyOffer.read(), "Legacy transfer behavior changed")
        }
    }

    run("Preparing too many file roots fails before any transfer begins") {
        try withCheckFolder { folder in
            let sender = ClipboardTransfer(storage: folder)
            let done = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            let messages = Box<[MessageKind]>([]), success = Box(true), status = Box("")
            sender.onSend = { message in messages.update { $0.append(message.kind) } }
            sender.onStatus = { status.set($0) }
            sender.send(.files(Array(repeating: folder.appendingPathComponent("unused"), count: ClipboardTransfer.maximumFileEntries + 1))) {
                success.set($0); done.signal()
            }
            try wait(done, "Oversized local file selection did not finish")
            sender.stop { stopped.signal() }; try wait(stopped, "Sender did not stop")
            try check(!success.read() && messages.read().isEmpty && status.read().contains("200000"), "Oversized selection sent a begin or failed for a different reason")
        }
    }

    run("File offers send metadata only, then transfer exact bytes after explicit acceptance") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("项目.bin")
            let bytes = Data(repeating: 73, count: 190_000)
            try bytes.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let storage = folder.appendingPathComponent("b")
            let b = ClipboardTransfer(storage: storage, requireFileApproval: true)
            let offerReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let offer = Box<ClipboardFileOffer?>(nil), correct = Box(false), success = Box(false)
            let messages = Box<[MessageKind]>([]), replies = Box(0)
            a.onSend = { [weak b] message in messages.update { $0.append(message.kind) }; b?.receive(message) }
            b.onSend = { [weak a] message in replies.update { $0 += 1 }; a?.receive(message) }
            b.onFileOffer = { if let value = $0 { offer.set(value); offerReady.signal() } }
            b.onReceive = { if case .files(let urls) = $0 { correct.set((try? Data(contentsOf: urls[0])) == bytes) } }
            defer { stopTransfers(a, b) }
            let requestedAt = SessionClock.now
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(offerReady, "No file offer")
            guard let value = offer.read() else { throw CheckFailure("Missing file offer") }
            try check(value.createdUptime >= requestedAt && value.createdUptime <= SessionClock.now, "Offer countdown does not use the request clock")
            try check(value.names == ["项目.bin"] && value.count == 1 && value.bytes == UInt64(bytes.count), "Offer metadata changed")
            try check(messages.read() == [.clipboardBegin] && replies.read() == 0, "File data or receipt sent before approval")
            try check(!FileManager.default.fileExists(atPath: storage.path), "Files written before approval")
            b.respondToFileOffer(id: value.id, accept: true)
            try wait(done, "Approved transfer did not finish")
            try check(success.read() && correct.read() && messages.read().contains(.clipboardChunk), "Approved bytes changed")
        }
    }

    run("An equal-size edit of received files still prompts and transfers back after a fresh copy") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("edited.bin")
            let original = Data([1, 2, 3]), modified = Data([4, 5, 6])
            try original.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), requireFileApproval: true)
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0)
            let received = Box<[URL]>([]), correct = Box(false), success = Box(false), returnedOffer = Box(false)
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { [weak b] in if let offer = $0 { b?.respondToFileOffer(id: offer.id, accept: true) } }
            a.onFileOffer = { [weak a] in
                if let offer = $0 { returnedOffer.set(true); a?.respondToFileOffer(id: offer.id, accept: true) }
            }
            b.onReceive = { if case .files(let urls) = $0 { received.set(urls) } }
            a.onReceive = { if case .files(let urls) = $0 { correct.set((try? Data(contentsOf: urls[0])) == modified) } }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(done, "Original file did not arrive")
            guard success.read(), let receivedFile = received.read().first else { throw CheckFailure("Original copy failed") }
            try modified.write(to: receivedFile)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: receivedFile.path)
            b.send(.files([receivedFile])) { success.set($0); done.signal() }
            try wait(done, "Edited file did not return")
            try check(returnedOffer.read() && success.read() && correct.read(), "Equal-size edit was silently mistaken for an echo")
        }
    }

    run("A failed file publication cannot suppress a later explicit copy back to its sender") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("retry.bin"), bytes = Data([7, 8, 9])
            try bytes.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), requireFileApproval: true)
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0)
            let downloaded = Box<[URL]>([]), correct = Box(false), success = Box(true), returnedOffer = Box(false)
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { [weak b] in if let offer = $0 { b?.respondToFileOffer(id: offer.id, accept: true) } }
            a.onFileOffer = { [weak a] in
                if let offer = $0 { returnedOffer.set(true); a?.respondToFileOffer(id: offer.id, accept: true) }
            }
            b.onApply = { payload, completion in
                if case .files(let urls) = payload { downloaded.set(urls) }
                completion(false)
            }
            a.onReceive = { if case .files(let urls) = $0 { correct.set((try? Data(contentsOf: urls[0])) == bytes) } }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(done, "Failed publication was not reported")
            try check(!success.read() && !downloaded.read().isEmpty, "Failed publication did not retain downloaded files")
            b.send(.files(downloaded.read())) { success.set($0); done.signal() }
            try wait(done, "Explicit copy after publication failure did not complete")
            try check(returnedOffer.read() && success.read() && correct.read(), "Failed send incorrectly suppressed an explicit copy")
        }
    }

    run("Declining a file offer preserves storage and ignores a later acceptance of that offer") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("unused.bin")
            try Data(repeating: 5, count: 100_000).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let storage = folder.appendingPathComponent("b")
            let b = ClipboardTransfer(storage: storage, requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let offer = Box<ClipboardFileOffer?>(nil), success = Box(true), payloadSent = Box(false), published = Box(false)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSent.set(true) }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { if let value = $0 { offer.set(value); ready.signal() } }
            b.onReceive = { _ in published.set(true) }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(ready, "No offer to decline")
            guard let offer = offer.read() else { throw CheckFailure("Missing offer") }
            b.respondToFileOffer(id: offer.id, accept: false)
            try wait(done, "Decline did not cancel sender")
            b.respondToFileOffer(id: offer.id, accept: true)
            stopTransfers(a, b)
            try check(!success.read() && !payloadSent.read() && !published.read(), "Declined file was downloaded or published")
            try check(!FileManager.default.fileExists(atPath: storage.path), "Declined offer created files")
        }
    }

    run("A new file copy supersedes the previous prompt and stale acceptance cannot start either download") {
        try withCheckFolder { folder in
            let files = [folder.appendingPathComponent("first"), folder.appendingPathComponent("second")]
            for file in files { try Data([1, 2, 3]).write(to: file) }
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let offers = Box<[ClipboardFileOffer]>([]), outcomes = Box<[Bool]>([]), payloadSent = Box(false)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSent.set(true) }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { if let value = $0 { offers.update { $0.append(value) }; ready.signal() } }
            defer { stopTransfers(a, b) }
            a.send(.files([files[0]])) { value in outcomes.update { $0.append(value) }; done.signal() }
            try wait(ready, "First offer missing")
            a.send(.files([files[1]])) { value in outcomes.update { $0.append(value) }; done.signal() }
            try wait(ready, "New offer missing")
            let values = offers.read()
            try check(values.count == 2 && values[0].id != values[1].id, "Offer identity reused")
            b.respondToFileOffer(id: values[0].id, accept: true)
            b.respondToFileOffer(id: values[1].id, accept: false)
            try wait(done, "Old copy not cancelled"); try wait(done, "New copy not declined")
            try check(outcomes.read() == [false, false] && !payloadSent.read(), "Stale acceptance sent a file")
        }
    }

    run("A local text copy cancels an incoming file offer while text continues to synchronize") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("file")
            try Data([8, 9]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), requireFileApproval: true)
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), fileDone = DispatchSemaphore(value: 0), textDone = DispatchSemaphore(value: 0)
            let offer = Box<ClipboardFileOffer?>(nil), cleared = Box(false), payloadSent = Box(false), correct = Box(false)
            let text = Data("new local clipboard".utf8)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSent.set(true) }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { value in if let value { offer.set(value); ready.signal() } else { cleared.set(true) } }
            a.onReceive = { if case .text(let bytes) = $0 { correct.set(bytes == text) } }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { _ in fileDone.signal() }
            try wait(ready, "No file offer")
            b.send(.text(text)) { _ in textDone.signal() }
            try wait(textDone, "Text was blocked by file prompt"); try wait(fileDone, "Old file sender not cancelled")
            guard let offer = offer.read() else { throw CheckFailure("No old offer ID") }
            b.respondToFileOffer(id: offer.id, accept: true)
            stopTransfers(a, b)
            try check(cleared.read() && correct.read() && !payloadSent.read(), "New local clipboard failed to replace pending file")
        }
    }

    run("Legacy file metadata with or without an optional fingerprint still requires approval") {
        for fingerprint in [nil, String(repeating: "0", count: 64)] as [String?] {
            try withCheckFolder { folder in
                let revision: [String: Any] = ["counter": 1, "origin": UUID().uuidString]
                var begin: [String: Any] = ["revision": revision, "sequence": 0, "type": "files", "count": 2, "bytes": 42]
                if let fingerprint { begin["fingerprint"] = fingerprint }
                let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
                let ready = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
                let offer = Box<ClipboardFileOffer?>(nil), acknowledged = Box(false)
                b.onFileOffer = { if let value = $0 { offer.set(value); ready.signal() } }
                b.onSend = { if $0.kind == .clipboardReceipt { acknowledged.set(true) }; if $0.kind == .clipboardCancel { cancelled.signal() } }
                b.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
                try wait(ready, "Legacy file offer bypassed prompt")
                guard let offer = offer.read() else { throw CheckFailure("No legacy offer") }
                try check(offer.names.isEmpty && offer.count == 2 && !acknowledged.read(), "Legacy offer was auto accepted")
                b.respondToFileOffer(id: offer.id, accept: false)
                try wait(cancelled, "Legacy transfer not declined")
                b.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
                let legacy = try Wire.readJSON(ClipboardPreference.self, Data("{\"enabled\":true}".utf8))
                try check(legacy.fileApproval == nil, "Old peer incorrectly advertises file consent")
                let modern = ClipboardPreference(enabled: true, session: UUID())
                try check(Wire.readJSON(ClipboardPreference.self, JSONEncoder().encode(modern)).fileApproval == true, "File approval capability lost")
            }
        }
    }

    run("Duplicate file offers do not create another prompt or acknowledge the transfer") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("duplicate")
            try Data([7]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let begin = Box<Message?>(nil), offer = Box<ClipboardFileOffer?>(nil), prompts = Box(0), receipts = Box(0)
            a.onSend = { [weak b] message in if message.kind == .clipboardBegin { begin.set(message) }; b?.receive(message) }
            b.onSend = { [weak a] message in if message.kind == .clipboardReceipt { receipts.update { $0 += 1 } }; a?.receive(message) }
            b.onFileOffer = { if let value = $0 { prompts.update { $0 += 1 }; offer.set(value); ready.signal() } }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { _ in done.signal() }
            try wait(ready, "No duplicate-test offer")
            guard let message = begin.read(), let offer = offer.read() else { throw CheckFailure("Missing duplicate-test metadata") }
            b.receive(message); b.respondToFileOffer(id: offer.id, accept: false)
            try wait(done, "Duplicate transfer did not cancel")
            try check(prompts.read() == 1 && receipts.read() == 0, "Duplicate offer triggered prompt or receipt")
        }
    }

    run("Files changed while waiting for approval are rejected before sending file data") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("changing")
            try Data([1]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let offer = Box<ClipboardFileOffer?>(nil), success = Box(true), payloadSent = Box(false), published = Box(false)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSent.set(true) }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { if let value = $0 { offer.set(value); ready.signal() } }
            b.onReceive = { _ in published.set(true) }
            defer { stopTransfers(a, b) }
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(ready, "No offer before editing")
            try Data([1, 2, 3]).write(to: file)
            guard let offer = offer.read() else { throw CheckFailure("No changed-file offer") }
            b.respondToFileOffer(id: offer.id, accept: true)
            try wait(done, "Changed file did not fail")
            stopTransfers(a, b)
            try check(!success.read() && !payloadSent.read() && !published.read(), "Changed file sent or published")
        }
    }

    run("Unsolicited file data before approval is rejected without creating receiver files") {
        try withCheckFolder { folder in
            let revision: [String: Any] = ["counter": 1, "origin": UUID().uuidString]
            let begin: [String: Any] = ["revision": revision, "sequence": 0, "type": "files", "count": 1, "bytes": 4]
            let entry: [String: Any] = ["revision": revision, "sequence": 1, "path": "file", "directory": false, "bytes": 4, "mode": 384, "modified": 0]
            let storage = folder.appendingPathComponent("b")
            let b = ClipboardTransfer(storage: storage, requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            let cleared = Box(false)
            b.onFileOffer = { value in if value == nil { cleared.set(true) } else { ready.signal() } }
            b.onSend = { if $0.kind == .clipboardCancel { cancelled.signal() } }
            b.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            try wait(ready, "No offer before unsolicited data")
            b.receive(Message(.clipboardEntry, try JSONSerialization.data(withJSONObject: entry)))
            try wait(cancelled, "Unsolicited data was not rejected")
            b.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
            try check(cleared.read() && !FileManager.default.fileExists(atPath: storage.path), "Unapproved file data created files")
        }
    }

    run("Stopping synchronization clears file prompts and later confirmation cannot download") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("stop")
            try Data([1]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            let offer = Box<ClipboardFileOffer?>(nil), cleared = Box(false), payloadSent = Box(false)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardEntry || message.kind == .clipboardChunk { payloadSent.set(true) }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { value in if let value { offer.set(value); ready.signal() } else { cleared.set(true) } }
            defer { stopTransfers(a, b) }
            a.send(.files([file]))
            try wait(ready, "No offer to stop")
            b.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
            guard let offer = offer.read() else { throw CheckFailure("No stopped offer") }
            b.respondToFileOffer(id: offer.id, accept: true)
            stopTransfers(a, b)
            try check(cleared.read() && !payloadSent.read(), "Stopped offer resumed download")
        }
    }

    run("Text and PNG remain automatic while file approval is required") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let done = DispatchSemaphore(value: 0), offered = Box(false), correct = Box(false), expected = Box<Data>(Data())
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            b.onFileOffer = { if $0 != nil { offered.set(true) } }
            b.onReceive = { payload in
                switch payload {
                case .text(let data), .png(let data): correct.set(data == expected.read())
                default: correct.set(false)
                }
            }
            defer { stopTransfers(a, b) }
            for payload in [ClipboardPayload.text(Data("文字仍自动同步".utf8)), .png(try checkPNG())] {
                switch payload { case .text(let data), .png(let data): expected.set(data); default: break }
                let success = Box(false)
                a.send(payload) { success.set($0); done.signal() }
                try wait(done, "Non-file transfer was blocked")
                try check(success.read() && correct.read() && !offered.read(), "Text or image incorrectly required file approval")
            }
        }
    }
}
