import Foundation
import QuietDeskCore

func runFileApprovalChecks() {
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
            let requestedAt = ProcessInfo.processInfo.systemUptime
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(offerReady, "No file offer")
            guard let value = offer.read() else { throw CheckFailure("Missing file offer") }
            try check(value.createdUptime >= requestedAt && value.createdUptime <= ProcessInfo.processInfo.systemUptime, "Offer countdown does not use the request clock")
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
