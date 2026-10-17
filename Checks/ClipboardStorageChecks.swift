import Foundation
import Darwin
import QuietDeskCore

func runClipboardStorageChecks() {
    run("Insufficient clipboard disk capacity rejects approval before downloading contents") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("source.bin")
            try Data(repeating: 87, count: 100).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let storage = folder.appendingPathComponent("b")
            let b = ClipboardTransfer(storage: storage, requireFileApproval: true, availableCapacity: { _ in 99 })
            defer { stopTransfers(a, b) }
            let offer = Box<ClipboardFileOffer?>(nil), downloaded = Box(false), success = Box(true)
            let offered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            a.onSend = { message in
                if [.clipboardEntry, .clipboardChunk].contains(message.kind) { downloaded.set(true) }
                b.receive(message)
            }
            b.onSend = { a.receive($0) }
            b.onFileOffer = { value in if let value { offer.set(value); offered.signal() } }
            a.send(.files([file])) { success.set($0); done.signal() }
            try wait(offered, "File offer was not shown")
            b.respondToFileOffer(id: offer.read()!.id, accept: true)
            try wait(done, "Insufficient space did not cancel sender")
            try check(!success.read() && !downloaded.read(), "Insufficient space downloaded contents")
            try check(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("partial").path),
                      "Insufficient capacity created a partial transfer")
        }
    }

    run("Automatic clipboard capacity failure returns cancellation while exact byte capacity can complete") {
        try withCheckFolder { folder in
            for capacity in [UInt64(3), 4] {
                let a = ClipboardTransfer(storage: folder.appendingPathComponent("a\(capacity)"))
                let b = ClipboardTransfer(storage: folder.appendingPathComponent("b\(capacity)"), availableCapacity: { _ in capacity })
                defer { stopTransfers(a, b) }
                let done = DispatchSemaphore(value: 0), success = Box(false), received = Box(false)
                a.onSend = { b.receive($0) }; b.onSend = { a.receive($0) }
                b.onReceive = { payload in if case .text(let bytes) = payload { received.set(bytes == Data("test".utf8)) } }
                a.send(.text(Data("test".utf8))) { success.set($0); done.signal() }
                try wait(done, "Automatic capacity response was not delivered")
                try check(success.read() == (capacity == 4) && received.read() == (capacity == 4), "Capacity boundary was not respected")
            }
        }
    }

    run("Startup cleans abandoned leased partials while preserving live, legacy and received directories") {
        try withCheckFolder { storage in
            let partial = storage.appendingPathComponent("partial")
            let stale = partial.appendingPathComponent("instance-" + UUID().uuidString)
            let live = partial.appendingPathComponent("instance-" + UUID().uuidString)
            let legacy = partial.appendingPathComponent("legacy"), received = storage.appendingPathComponent("received/old")
            for directory in [stale, live, legacy, received] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: directory.appendingPathComponent("content"))
            }
            try Data().write(to: stale.appendingPathComponent(".lease"))
            try Data().write(to: legacy.appendingPathComponent(".lease"))
            let descriptor = Darwin.open(live.appendingPathComponent(".lease").path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw CheckFailure("Cannot create synthetic live lease") }
            defer { Darwin.close(descriptor) }
            try check(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Cannot lock synthetic live lease")
            let transfer = ClipboardTransfer(storage: storage)
            let stopped = DispatchSemaphore(value: 0)
            transfer.stop { stopped.signal() }
            try wait(stopped, "Startup cleanup did not finish")
            try check(!FileManager.default.fileExists(atPath: stale.path), "Abandoned leased partial remained")
            for directory in [live, legacy, received] {
                try check(Data(contentsOf: directory.appendingPathComponent("content")) == Data([1, 2, 3]),
                          "Startup cleanup removed live, legacy or received data")
            }
        }
    }

    run("Another receiver sharing storage cannot remove an active transfer lease") {
        try withCheckFolder { folder in
            let storage = folder.appendingPathComponent("shared")
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let b = ClipboardTransfer(storage: storage)
            defer { stopTransfers(a, b) }
            let receipt = Box<Message?>(nil), ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let success = Box(false), correct = Box(false)
            let expected = Data(repeating: 81, count: 100_000)
            a.onSend = { b.receive($0) }
            b.onSend = { message in
                if message.kind == .clipboardReceipt,
                   let object = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
                   (object["sequence"] as? NSNumber)?.uint64Value == 2, receipt.read() == nil {
                    receipt.set(message); ready.signal()
                } else { a.receive(message) }
            }
            b.onReceive = { payload in if case .text(let data) = payload { correct.set(data == expected) } }
            a.send(.text(expected)) { success.set($0); done.signal() }
            try wait(ready, "No active transfer to protect")
            let other = ClipboardTransfer(storage: storage), stopped = DispatchSemaphore(value: 0)
            other.stop { stopped.signal() }
            try wait(stopped, "Other receiver did not stop")
            a.receive(receipt.read()!)
            try wait(done, "Active transfer was removed by another receiver")
            try check(success.read() && correct.read(), "Another instance damaged an active transfer")
        }
    }
}
