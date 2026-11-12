import Foundation
import QuietDeskCore

private func receiptSequence(_ message: Message) throws -> UInt64 {
    let value = try JSONSerialization.jsonObject(with: message.payload) as? [String: Any]
    guard let sequence = value?["sequence"] as? NSNumber else { throw CheckFailure("Missing receipt sequence") }
    return sequence.uint64Value
}

func runClipboardWindowChecks() {
    run("Clipboard window sends at most sixteen messages and accepts cumulative duplicate acknowledgements") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), allowsChunkWindow: true)
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), allowsChunkWindow: true)
            defer { stopTransfers(a, b) }
            let expected = Data(repeating: 81, count: 6 * 1_024 * 1_024 + 7)
            let sent = Box(0), chunkSizes = Box<[Int]>([]), receipts = Box<[Message]>([])
            let holding = Box(true), correct = Box(false), success = Box(false)
            let full = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
            a.onSend = { message in
                if [.clipboardEntry, .clipboardChunk, .clipboardEnd].contains(message.kind) {
                    sent.update { $0 += 1; if $0 == 16 { full.signal() } }
                }
                if message.kind == .clipboardChunk { chunkSizes.update { $0.append(message.payload.count - 32) } }
                b.receive(message)
            }
            b.onSend = { message in
                if message.kind == .clipboardReceipt, (try? receiptSequence(message)) != 0, holding.read() {
                    receipts.update { $0.append(message) }
                } else { a.receive(message) }
            }
            b.onReceive = { payload in
                if case .text(let data) = payload { correct.set(data == expected) }
                received.signal()
            }
            a.send(.text(expected)) { success.set($0); done.signal() }
            try wait(full, "Clipboard window never filled")
            Thread.sleep(forTimeInterval: 0.1)
            try check(sent.read() == 16 && chunkSizes.read().max() == 262_144, "Clipboard window was unbounded or retained legacy chunks")
            let until = Date().addingTimeInterval(3)
            while receipts.read().count < 16, Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            guard let latest = receipts.read().last else { throw CheckFailure("No cumulative receipt") }
            try check(receiptSequence(latest) == 16, "Receipt did not acknowledge the highest contiguous message")
            holding.set(false)
            a.receive(latest)
            a.receive(latest)
            try wait(done, "Cumulative acknowledgement did not resume transfer")
            try wait(received, "Windowed clipboard was not applied")
            try check(success.read() && correct.read(), "Windowed clipboard changed bytes or failed")
        }
    }

    run("Legacy clipboard remains 32 KiB stop-and-wait without the optional capability") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            defer { stopTransfers(a, b) }
            let firstChunk = DispatchSemaphore(value: 0), receiptReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let held = Box<Message?>(nil), chunks = Box<[Int]>([]), success = Box(false), advertised = Box(false)
            a.onSend = { message in
                if message.kind == .clipboardBegin {
                    if let value = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] {
                        advertised.set(value["chunkWindow"] != nil)
                    }
                }
                if message.kind == .clipboardChunk {
                    chunks.update { $0.append(message.payload.count - 32) }
                    firstChunk.signal()
                }
                b.receive(message)
            }
            b.onSend = { message in
                if message.kind == .clipboardReceipt, (try? receiptSequence(message)) == 2, held.read() == nil {
                    held.set(message); receiptReady.signal()
                } else { a.receive(message) }
            }
            a.send(.text(Data(repeating: 65, count: 100_000))) { success.set($0); done.signal() }
            try wait(firstChunk, "No legacy chunk")
            try wait(receiptReady, "No legacy receipt")
            Thread.sleep(forTimeInterval: 0.1)
            try check(chunks.read() == [32_768], "Legacy peer received a larger chunk or a send window")
            a.receive(held.read()!)
            try wait(done, "Legacy transfer did not finish")
            try check(success.read() && !advertised.read(), "Legacy transfer failed or advertised an unnegotiated capability")
            let legacy = try Wire.readJSON(ClipboardPreference.self, Data("{\"enabled\":true}".utf8))
            try check(legacy.chunkWindow == nil, "Missing capability enabled the new window")
        }
    }

    for mutation in ["duplicate", "out-of-order", "truncated"] {
        run("Clipboard rejects \(mutation) chunks without publishing partial data") {
            try withCheckFolder { folder in
                let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), allowsChunkWindow: true)
                let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), allowsChunkWindow: true)
                defer { stopTransfers(a, b) }
                let changed = Box(false), published = Box(false), success = Box(true)
                let done = DispatchSemaphore(value: 0)
                a.onSend = { message in
                    if message.kind == .clipboardChunk, !changed.read() {
                        changed.set(true)
                        if mutation == "duplicate" {
                            b.receive(message); b.receive(message)
                        } else if mutation == "truncated" {
                            b.receive(Message(.clipboardChunk, Data(message.payload.prefix(20))))
                        } else {
                            var payload = Data(message.payload.prefix(24)); payload.put(UInt64(999)); payload.append(message.payload.dropFirst(32))
                            b.receive(Message(.clipboardChunk, payload))
                        }
                    } else if !changed.read() { b.receive(message) }
                }
                b.onSend = { a.receive($0) }
                b.onReceive = { _ in published.set(true) }
                a.send(.text(Data(repeating: 65, count: 1_000_000))) { success.set($0); done.signal() }
                try wait(done, "Invalid chunk did not cancel transfer")
                try check(changed.read() && !success.read() && !published.read(), "Invalid chunk was not exercised, was applied or reported successful")
            }
        }
    }

    run("Clipboard rejects acknowledgements beyond the transmitted sequence") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder, allowsChunkWindow: true)
            defer { a.stop() }
            let done = DispatchSemaphore(value: 0), success = Box(true)
            a.onSend = { message in
                guard message.kind == .clipboardBegin,
                      var value = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else { return }
                value["sequence"] = 1
                value.removeValue(forKey: "type"); value.removeValue(forKey: "count"); value.removeValue(forKey: "bytes")
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
                a.receive(Message(.clipboardReceipt, data))
            }
            a.send(.text(Data("test".utf8))) { success.set($0); done.signal() }
            try wait(done, "Future acknowledgement was not rejected")
            try check(!success.read(), "Future acknowledgement completed an unsent transfer")
        }
    }

    run("Decoupled file lane uses a 64-chunk window and runs concurrently with bidirectional text clipboard transfers") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("bundle.bin")
            let expectedFile = Data(repeating: 0x5A, count: 18 * 1_024 * 1_024 + 19)
            try expectedFile.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"), requireFileApproval: true,
                                      allowsChunkWindow: true, allowsDecoupledFileTransfer: true)
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true,
                                      allowsChunkWindow: true, allowsDecoupledFileTransfer: true)
            defer { stopTransfers(a, b) }

            let fileOrigin = Box<String?>(nil), fileCounter = Box<UInt64?>(nil)
            let fileWindowCount = Box(0), heldFileReceipts = Box<[Message]>([])
            let holdFileReceipts = Box(true)
            let windowFull = DispatchSemaphore(value: 0)
            let textAToBDone = DispatchSemaphore(value: 0), textBToADone = DispatchSemaphore(value: 0)
            let fileSendDone = DispatchSemaphore(value: 0), fileReceiveDone = DispatchSemaphore(value: 0)
            let textOnB = Box<Data?>(nil), textOnA = Box<Data?>(nil)
            let explicitFiles = Box<[URL]>([]), pasteboardCallbackCalled = Box(false), fileSucceeded = Box(false)

            func revisionTuple(_ payload: Data) -> (UInt64, String)? {
                guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let rev = obj["revision"] as? [String: Any],
                      let counter = (rev["counter"] as? NSNumber)?.uint64Value,
                      let origin = rev["origin"] as? String else { return nil }
                return (counter, origin)
            }

            a.onSend = { message in
                if message.kind == .clipboardBegin,
                   let obj = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
                   obj["type"] as? String == "files",
                   let (counter, origin) = revisionTuple(message.payload) {
                    fileCounter.set(counter)
                    fileOrigin.set(origin)
                }
                if [.clipboardEntry, .clipboardChunk, .clipboardEnd].contains(message.kind) {
                    let isFileMessage: Bool
                    if message.kind == .clipboardChunk {
                        var reader = ByteReader(message.payload)
                        let counter: UInt64? = try? reader.take()
                        let uuidBytes = try? reader.bytes(16)
                        let origin = uuidBytes.map { bytes -> String in
                            let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
                            return UUID(uuid: raw).uuidString
                        }
                        isFileMessage = (counter == fileCounter.read() && origin == fileOrigin.read())
                    } else if let (counter, origin) = revisionTuple(message.payload) {
                        isFileMessage = (counter == fileCounter.read() && origin == fileOrigin.read())
                    } else {
                        isFileMessage = false
                    }
                    if isFileMessage {
                        fileWindowCount.update {
                            $0 += 1
                            if $0 == 64 { windowFull.signal() }
                        }
                    }
                }
                b.receive(message)
            }
            b.onSend = { message in
                if message.kind == .clipboardReceipt,
                   let (counter, origin) = revisionTuple(message.payload),
                   counter == fileCounter.read(), origin == fileOrigin.read(),
                   (try? receiptSequence(message)) != 0,
                   holdFileReceipts.read() {
                    heldFileReceipts.update { $0.append(message) }
                    return
                }
                a.receive(message)
            }
            b.onFileOffer = { [weak b] offer in
                if let offer, offer.isExplicitDrop {
                    b?.respondToFileOffer(id: offer.id, accept: true)
                }
            }
            b.onReceive = { payload in
                switch payload {
                case .text(let data):
                    textOnB.set(data)
                    textAToBDone.signal()
                case .files:
                    pasteboardCallbackCalled.set(true)
                case .png:
                    break
                }
            }
            b.onExplicitFilesReceived = { urls in
                explicitFiles.set(urls)
                fileReceiveDone.signal()
            }
            a.onReceive = { payload in
                if case .text(let data) = payload {
                    textOnA.set(data)
                    textBToADone.signal()
                }
            }

            a.sendExplicitFiles([file]) { ok in
                fileSucceeded.set(ok)
                fileSendDone.signal()
            }
            try wait(windowFull, "Decoupled file lane never filled 64-message window")
            Thread.sleep(forTimeInterval: 0.08)
            try check(fileWindowCount.read() == 64,
                      "Decoupled file lane exceeded or fell short of 64-message window: \(fileWindowCount.read())")

            let msgAToB = Data("concurrent-local-to-remote".utf8)
            let msgBToA = Data("concurrent-remote-to-local".utf8)
            a.send(.text(msgAToB))
            try wait(textAToBDone, "Text A->B blocked behind paused file transfer")
            b.send(.text(msgBToA))
            try wait(textBToADone, "Text B->A blocked behind paused file transfer")
            try check(textOnB.read() == msgAToB && textOnA.read() == msgBToA,
                      "Concurrent text transfers corrupted payload")

            let until = Date().addingTimeInterval(3)
            while heldFileReceipts.read().count < 64, Date() < until { Thread.sleep(forTimeInterval: 0.01) }
            guard let latestFileReceipt = heldFileReceipts.read().last else {
                throw CheckFailure("Missing cumulative file receipt")
            }
            holdFileReceipts.set(false)
            a.receive(latestFileReceipt)
            try wait(fileSendDone, "Resumed file transfer did not finish sending")
            try wait(fileReceiveDone, "Resumed file transfer did not deliver explicit files")
            let urls = explicitFiles.read()
            try check(fileSucceeded.read() && !pasteboardCallbackCalled.read() && urls.count == 1
                      && (try? Data(contentsOf: urls[0])) == expectedFile,
                      "Explicit dropped file modified pasteboard callback or lost bytes")

            let legacyPeer = ClipboardTransfer(storage: folder.appendingPathComponent("legacy"), requireFileApproval: true)
            defer { legacyPeer.stop() }
            let legacyRejected = DispatchSemaphore(value: 0)
            let legacyOffered = Box(false), legacyReceipts = Box(0), legacyError = Box("")
            legacyPeer.onFileOffer = { if $0 != nil { legacyOffered.set(true) } }
            legacyPeer.onSend = { msg in if msg.kind == .clipboardReceipt { legacyReceipts.update { $0 += 1 } } }
            legacyPeer.onStatus = { status in
                if status.contains("对端未协商独立文件传输通道") {
                    legacyError.set(status)
                    legacyRejected.signal()
                }
            }
            let unnegotiatedBegin = """
            {"revision":{"counter":1,"origin":"\(UUID().uuidString)"},"sequence":0,"type":"files","count":1,"bytes":4,"independentFileLane":true}
            """
            legacyPeer.receive(Message(.clipboardBegin, Data(unnegotiatedBegin.utf8)))
            try wait(legacyRejected, "Legacy peer accepted unnegotiated independentFileLane")
            try check(!legacyOffered.read() && legacyReceipts.read() == 0 && !legacyError.read().isEmpty,
                      "Legacy peer offered or acknowledged unnegotiated independentFileLane")
        }
    }

    run("On-demand clipboard negotiates backward-compatibly and pulls multi-chunk text and validated PNG off main thread") {
        try withCheckFolder { folder in
            let legacyPref = try JSONDecoder().decode(ClipboardPreference.self, from: Data(#"{"enabled":true}"#.utf8))
            try check(legacyPref.onDemandClipboard == nil, "Legacy preference unexpectedly set onDemandClipboard")
            let modernData = try JSONEncoder().encode(ClipboardPreference(enabled: true))
            let modernPref = try JSONDecoder().decode(ClipboardPreference.self, from: modernData)
            try check(modernPref.onDemandClipboard == true, "Modern preference did not advertise onDemandClipboard")

            let wireQueue = DispatchQueue(label: "checks.clipboard.ondemand.wire")
            let source = ClipboardTransfer(
                storage: folder.appendingPathComponent("source"),
                requireFileApproval: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true
            )
            let sink = ClipboardTransfer(
                storage: folder.appendingPathComponent("sink"),
                requireFileApproval: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true
            )
            defer { stopTransfers(source, sink) }

            let sourceSentKinds = Box<[MessageKind]>([])
            let sinkApplyCalled = Box(false)
            let latestManifest = Box<ClipboardManifest?>(nil)
            let manifestArrived = DispatchSemaphore(value: 0)
            let invalidatedRev = Box<ClipboardRevision?>(nil)
            let invalidatedDone = DispatchSemaphore(value: 0)
            let sourcePayload = Box<ClipboardPayload>(.text(Data()))
            let validPNGMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

            source.onSend = { msg in
                sourceSentKinds.update { $0.append(msg.kind) }
                wireQueue.async { sink.receive(msg) }
            }
            sink.onSend = { msg in
                wireQueue.async { source.receive(msg) }
            }
            sink.onApply = { _, completion in
                sinkApplyCalled.set(true)
                completion(true)
            }
            sink.onReceive = { _ in
                sinkApplyCalled.set(true)
            }
            sink.validatePulledPNG = { data in
                data.starts(with: validPNGMagic)
            }
            sink.onManifest = { manifest in
                latestManifest.set(manifest)
                manifestArrived.signal()
            }
            source.onManifestInvalidated = { rev in
                invalidatedRev.set(rev)
                invalidatedDone.signal()
            }
            source.onPullRequested = { [weak source] req in
                source?.sendPulled(sourcePayload.read(), requestID: req.requestID)
            }

            let expectedText = Data(repeating: 0x41, count: 600_000)
            sourcePayload.set(.text(expectedText))
            source.announceManifest(kind: .text)
            try wait(manifestArrived, "Text manifest did not arrive")
            try check(sourceSentKinds.read() == [.clipboardManifest], "Copy announcement sent payload chunks eagerly")
            guard let textManifest = latestManifest.read(), textManifest.kind == .text else {
                throw CheckFailure("Expected text manifest")
            }

            let pulledText = sink.pullPayloadSynchronously(revision: textManifest.revision, kind: .text)
            guard case .text(let pulledTextBytes)? = pulledText else {
                throw CheckFailure("Synchronous text pull returned nil or wrong kind")
            }
            try check(pulledTextBytes == expectedText && !sinkApplyCalled.read(),
                      "Pulled text mismatched or routed through eager apply callback")

            let expectedPNG = validPNGMagic + Data(repeating: 0x2B, count: 300_000)
            sourcePayload.set(.png(expectedPNG))
            source.announceManifest(kind: .png)
            try wait(manifestArrived, "PNG manifest did not arrive")
            guard let pngManifest = latestManifest.read(), pngManifest.kind == .png else {
                throw CheckFailure("Expected PNG manifest")
            }
            let pulledPNG = sink.pullPayloadSynchronously(revision: pngManifest.revision, kind: .png)
            guard case .png(let pulledPNGBytes)? = pulledPNG else {
                throw CheckFailure("Validated synchronous PNG pull returned nil")
            }
            try check(pulledPNGBytes == expectedPNG, "Pulled PNG bytes mismatched")

            sourcePayload.set(.png(Data([0x00, 0x01, 0x02, 0x03])))
            source.announceManifest(kind: .png)
            try wait(manifestArrived, "Invalid PNG manifest did not arrive")
            guard let badManifest = latestManifest.read() else { throw CheckFailure("Missing manifest") }
            let rejectedPNG = sink.pullPayloadSynchronously(revision: badManifest.revision, kind: .png)
            try check(rejectedPNG == nil, "Corrupt pulled PNG passed validation")

            sink.invalidateRemoteManifest(badManifest.revision)
            try wait(invalidatedDone, "Source was not notified when remote manifest was invalidated")
            try check(invalidatedRev.read() == badManifest.revision, "Invalidated revision mismatched")
        }
    }

    run("On-demand clipboard rejects unnegotiated messages and blocks pullRequestID on files") {
        try withCheckFolder { folder in
            let legacy = ClipboardTransfer(storage: folder.appendingPathComponent("legacy"), requireFileApproval: true)
            defer { legacy.stop() }
            let legacyStatus = Box<[String]>([])
            let legacyFailed = DispatchSemaphore(value: 0)
            legacy.onStatus = { status in
                legacyStatus.update { $0.append(status) }
                if status.contains("对端未协商按需剪贴板") {
                    legacyFailed.signal()
                }
            }
            let manifestMsg = try Wire.json(.clipboardManifest, ClipboardManifest(
                revision: ClipboardRevision(counter: 1, origin: UUID()),
                kind: .text
            ))
            legacy.receive(manifestMsg)
            try wait(legacyFailed, "Legacy peer accepted unnegotiated clipboardManifest")

            let negotiated = ClipboardTransfer(
                storage: folder.appendingPathComponent("negotiated"),
                requireFileApproval: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true
            )
            defer { negotiated.stop() }
            let fileOfferSeen = Box(false)
            let receiptsSent = Box(0)
            let rejectedDone = DispatchSemaphore(value: 0)
            negotiated.onFileOffer = { if $0 != nil { fileOfferSeen.set(true) } }
            negotiated.onSend = { msg in
                if msg.kind == .clipboardReceipt { receiptsSent.update { $0 += 1 } }
            }
            negotiated.onStatus = { status in
                if status.contains("按需拉取仅支持文字或图片") {
                    rejectedDone.signal()
                }
            }
            let spoofedFilesPull = """
            {"revision":{"counter":5,"origin":"\(UUID().uuidString)"},"sequence":0,"type":"files","count":1,"bytes":16,"pullRequestID":"\(UUID().uuidString)"}
            """
            negotiated.receive(Message(.clipboardBegin, Data(spoofedFilesPull.utf8)))
            try wait(rejectedDone, "Negotiated peer accepted pullRequestID on files")
            try check(!fileOfferSeen.read() && receiptsSent.read() == 0,
                      "Spoofed file pull triggered offer or receipt")
        }
    }
}
