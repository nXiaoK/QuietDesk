import Foundation
import QuietDeskCore

func runFileResultChecks() {
    run("File success is reported once only after final acknowledgement, with receiver-owned completed URLs") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("example.bin"), bytes = Data(repeating: 83, count: 100_000)
            try bytes.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let storage = folder.appendingPathComponent("receiver")
            let b = ClipboardTransfer(storage: storage, requireFileApproval: true)
            let endReady = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let sent = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
            let heldEnd = Box<Message?>(nil), finalReceipt = Box<Message?>(nil)
            let aResults = Box<[ClipboardFileResult]>([]), bResults = Box<[ClipboardFileResult]>([]), starts = Box(0)
            a.onSend = { message in
                if message.kind == .clipboardEnd { heldEnd.set(message); endReady.signal() }
                else { b.receive(message) }
            }
            b.onSend = { message in
                if message.kind == .clipboardReceipt, heldEnd.read() != nil { finalReceipt.set(message) }
                else { a.receive(message) }
            }
            b.onFileOffer = { [weak b] offer in if let offer { b?.respondToFileOffer(id: offer.id, accept: true) } }
            b.onFileTransferStarted = { starts.update { $0 += 1 } }
            a.onFileResult = { result in aResults.update { $0.append(result) }; sent.signal() }
            b.onFileResult = { result in bResults.update { $0.append(result) }; received.signal() }
            defer { stopTransfers(a, b) }
            a.send(.files([file]), completion: { _ in done.signal() })
            try wait(endReady, "No final file message")
            try check(aResults.read().isEmpty && bResults.read().isEmpty, "Sending bytes prematurely published success")
            b.receive(heldEnd.read()!)
            try wait(received, "Receiver did not publish completed files")
            try check(aResults.read().isEmpty, "Sender reported success without final acknowledgement")
            let result = bResults.read()[0]
            try check(result.direction == .receiving && result.outcome == .completed && result.files.count == 1,
                      "Receiver result lost direction, outcome or actual files")
            try check(result.files[0].path.hasPrefix(storage.appendingPathComponent("received").path + "/")
                      && Data(contentsOf: result.files[0]) == bytes, "Result exposed source paths or incomplete bytes")
            guard let receipt = finalReceipt.read() else { throw CheckFailure("No final receipt") }
            a.receive(receipt); a.receive(receipt)
            try wait(done, "Final acknowledgement did not settle send"); try wait(sent, "Sender result missing")
            b.receive(heldEnd.read()!)
            stopTransfers(a, b)
            try check(aResults.read().count == 1 && aResults.read()[0].outcome == .completed
                      && aResults.read()[0].direction == .sending && aResults.read()[0].files.isEmpty
                      && bResults.read().count == 1 && starts.read() == 1, "Duplicate end/ack published another file result")
        }
    }

    for accept in [true, false] {
        run("File publication \(accept ? "success" : "failure") retains actual saved files without inventing clipboard success") {
            try withCheckFolder { folder in
                let file = folder.appendingPathComponent("saved.bin"), bytes = Data([1, 2, 3])
                try bytes.write(to: file)
                let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
                let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
                let ready = DispatchSemaphore(value: 0), resultReady = DispatchSemaphore(value: 0)
                let publish = Box<((Bool) -> Void)?>(nil), result = Box<ClipboardFileResult?>(nil)
                a.onSend = { b.receive($0) }; b.onSend = { a.receive($0) }
                b.onFileOffer = { [weak b] in if let offer = $0 { b?.respondToFileOffer(id: offer.id, accept: true) } }
                b.onApplyWithPermit = { _, _, completion in publish.set(completion); ready.signal() }
                b.onFileResult = { result.set($0); resultReady.signal() }
                defer { stopTransfers(a, b) }
                a.send(.files([file]))
                try wait(ready, "File did not reach publication")
                try check(result.read() == nil, "A pending application was reported complete")
                publish.read()!(accept)
                try wait(resultReady, "Publication result missing")
                let value = result.read()!
                try check(value.outcome == (accept ? .completed : .failed) && value.files.count == 1
                          && Data(contentsOf: value.files[0]) == bytes, "Saved files disappeared from the publication outcome")
            }
        }
    }

    run("Decline and interrupted reception emit exactly one cancellation without a completed-file action") {
        try withCheckFolder { folder in
            for decline in [true, false] {
                let file = folder.appendingPathComponent("cancel-\(decline).bin")
                try Data(repeating: 7, count: 100_000).write(to: file)
                let a = ClipboardTransfer(storage: folder.appendingPathComponent("a-\(decline)"))
                let b = ClipboardTransfer(storage: folder.appendingPathComponent("b-\(decline)"), requireFileApproval: true)
                let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
                let offer = Box<ClipboardFileOffer?>(nil), reception = Box<UUID?>(nil), held = Box<Message?>(nil)
                let results = Box<[ClipboardFileResult]>([])
                a.onSend = { message in
                    if message.kind == .clipboardChunk { held.set(message); ready.signal() } else { b.receive(message) }
                }
                b.onSend = { a.receive($0) }
                b.onFileOffer = { [weak b] value in
                    guard let value else { return }
                    offer.set(value)
                    if decline { ready.signal() } else { b?.respondToFileOffer(id: value.id, accept: true) }
                }
                b.onFileReceptionChanged = { if let value = $0 { reception.set(value) } }
                b.onFileResult = { result in results.update { $0.append(result) }; finished.signal() }
                defer { stopTransfers(a, b) }
                a.send(.files([file]))
                try wait(ready, "No file offer or active chunk")
                if decline {
                    b.respondToFileOffer(id: offer.read()!.id, accept: false)
                    b.respondToFileOffer(id: offer.read()!.id, accept: false)
                } else {
                    b.cancelFileReception(id: reception.read()!)
                    b.cancelFileReception(id: reception.read()!)
                }
                try wait(finished, "Cancellation result missing")
                if let late = held.read() { b.receive(late) }
                stopTransfers(a, b)
                try check(results.read().count == 1 && results.read()[0].outcome == .cancelled
                          && results.read()[0].files.isEmpty, "Cancellation duplicated or invented saved files")
            }
        }
    }

    run("File preparation failure is typed, while text success produces no file result") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            let done = DispatchSemaphore(value: 0), reported = DispatchSemaphore(value: 0)
            let results = Box<[ClipboardFileResult]>([]), otherResults = Box<[ClipboardFileResult]>([])
            a.onSend = { b.receive($0) }; b.onSend = { a.receive($0) }
            a.onFileResult = { value in results.update { $0.append(value) }; reported.signal() }
            b.onFileResult = { value in otherResults.update { $0.append(value) } }
            defer { stopTransfers(a, b) }
            a.send(.files([folder.appendingPathComponent("missing.bin")]), completion: { _ in done.signal() })
            try wait(done, "Missing source did not fail"); try wait(reported, "Missing file result absent")
            a.send(.text(Data("接收完成 is just text".utf8)), completion: { _ in done.signal() })
            try wait(done, "Text did not complete")
            stopTransfers(a, b)
            try check(results.read().count == 1 && results.read()[0].outcome == .failed
                      && results.read()[0].files.isEmpty && otherResults.read().isEmpty,
                      "Text success created file actions or file failure was not typed")
        }
    }

    run("A remote replacement during publication retains completed files but ignores the late application callback") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("late.bin"), bytes = Data([9, 7, 5])
            try bytes.write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true)
            let ready = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0), textDone = DispatchSemaphore(value: 0)
            let pending = Box<(ClipboardApplyPermit, (Bool) -> Void)?>(nil), results = Box<[ClipboardFileResult]>([])
            a.onSend = { b.receive($0) }; b.onSend = { a.receive($0) }
            b.onFileOffer = { [weak b] in if let offer = $0 { b?.respondToFileOffer(id: offer.id, accept: true) } }
            b.onApplyWithPermit = { payload, permit, completion in
                if case .files = payload { pending.set((permit, completion)); ready.signal() }
                else { completion(permit.performIfValid { true }) }
            }
            b.onFileResult = { value in results.update { $0.append(value) }; cancelled.signal() }
            defer { stopTransfers(a, b) }
            a.send(.files([file]))
            try wait(ready, "File did not reach publication")
            a.send(.text(Data("new copy".utf8)), completion: { _ in textDone.signal() })
            try wait(cancelled, "Superseded publication did not produce a file result")
            try wait(textDone, "Replacement text was blocked")
            let (permit, complete) = pending.read()!
            try check(!permit.isValid, "Superseded application retained a valid permit")
            complete(true)
            stopTransfers(a, b)
            let values = results.read()
            try check(values.count == 1 && values[0].outcome == .cancelled && values[0].files.count == 1
                      && Data(contentsOf: values[0].files[0]) == bytes,
                      "Late publication invented success or lost completed local files")
        }
    }

    run("Disk admission failures report files as failed without inventing completed paths") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("no-space.bin")
            try Data([1, 2, 3]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"), requireFileApproval: true, availableCapacity: { _ in 0 })
            let ready = DispatchSemaphore(value: 0), result = Box<ClipboardFileResult?>(nil), chunks = Box(0)
            a.onSend = { message in
                if message.kind == .clipboardChunk { chunks.update { $0 += 1 } }
                b.receive(message)
            }
            b.onSend = { a.receive($0) }
            b.onFileOffer = { [weak b] in if let offer = $0 { b?.respondToFileOffer(id: offer.id, accept: true) } }
            b.onFileResult = { result.set($0); ready.signal() }
            defer { stopTransfers(a, b) }
            a.send(.files([file]))
            try wait(ready, "Disk admission failure result missing")
            stopTransfers(a, b)
            try check(result.read()?.outcome == .failed && result.read()?.files.isEmpty == true && chunks.read() == 0,
                      "Disk failure downloaded data or offered completed-file actions")
        }
    }

    run("Stopping a pending file invalidates it without a stale completion result") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("stop.bin")
            try Data([1]).write(to: file)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let ready = DispatchSemaphore(value: 0)
            let results = Box<[ClipboardFileResult]>([])
            a.onSend = { if $0.kind == .clipboardBegin { ready.signal() } }
            a.onFileResult = { value in results.update { $0.append(value) } }
            a.send(.files([file]))
            try wait(ready, "File did not start")
            let stopped = DispatchSemaphore(value: 0)
            a.stop { stopped.signal() }
            try wait(stopped, "Sender did not stop")
            try check(results.read().isEmpty, "Session stop emitted a stale file result")
        }
    }
}
