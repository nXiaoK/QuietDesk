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
}
