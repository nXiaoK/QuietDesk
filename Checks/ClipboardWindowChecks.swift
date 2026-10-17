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
}
