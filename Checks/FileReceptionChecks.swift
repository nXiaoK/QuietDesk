import Foundation
import QuietDeskCore

func runFileReceptionChecks() {
    for action in ["send", "prepare", "prepared-send"] {
        run("An opted-in \(action) defers during accepted file reception and can retry after completion") {
            try withCheckFolder { folder in
                let file = folder.appendingPathComponent("incoming.bin"), bytes = Data(repeating: 71, count: 100_000)
                try bytes.write(to: file)
                let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
                let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
                let heldReady = DispatchSemaphore(value: 0), actionDone = DispatchSemaphore(value: 0)
                let fileDone = DispatchSemaphore(value: 0), idle = DispatchSemaphore(value: 0), retryDone = DispatchSemaphore(value: 0)
                let held = Box<Message?>(nil), preparation = Box<UUID?>(nil)
                let callbacks = Box<[String]>([]), messages = Box<[MessageKind]>([])
                let results = Box<[Bool]>([]), receivedFile = Box(false), retriedText = Box(false)
                sender.onSend = { message in
                    if message.kind == .clipboardChunk, held.read() == nil {
                        held.set(message); heldReady.signal(); return
                    }
                    receiver.receive(message)
                }
                receiver.onSend = { message in messages.update { $0.append(message.kind) }; sender.receive(message) }
                receiver.onFileOffer = { [weak receiver] in
                    if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
                }
                receiver.onFileReceptionChanged = { if $0 == nil { idle.signal() } }
                receiver.onReceive = { payload in
                    if case .files(let urls) = payload, let url = urls.first { receivedFile.set((try? Data(contentsOf: url)) == bytes) }
                }
                sender.onReceive = { payload in
                    if case .text(let data) = payload { retriedText.set(data == Data("latest local copy".utf8)) }
                }
                defer { stopTransfers(sender, receiver) }
                if action == "prepared-send" {
                    receiver.prepareSend { preparation.set($0); actionDone.signal() }
                    try wait(actionDone, "Initial image preparation did not start")
                    try check(preparation.read() != nil, "Initial preparation token missing")
                }
                sender.send(.files([file])) { result in results.update { $0.append(result) }; fileDone.signal() }
                try wait(heldReady, "Accepted file did not reach a held chunk")
                let deferred = { callbacks.update { $0.append("deferred") }; actionDone.signal() }
                if action == "prepare" {
                    receiver.prepareSend(deferred: deferred) { _ in callbacks.update { $0.append("completion") }; actionDone.signal() }
                } else {
                    // Missing paths must not be inspected while reception is protected.
                    let payload: ClipboardPayload = action == "send" ? .files([folder.appendingPathComponent("not-created")]) : .png(Data([1, 2, 3]))
                    receiver.send(payload, preparation: preparation.read(), deferred: deferred) { _ in
                        callbacks.update { $0.append("completion") }; actionDone.signal()
                    }
                }
                try wait(actionDone, "Deferred operation did not report its result")
                try check(callbacks.read() == ["deferred"] && !messages.read().contains(.clipboardCancel)
                          && !messages.read().contains(.clipboardBegin) && results.read().isEmpty,
                          "Opting in cancelled reception, read the new file, changed the wire revision or completed instead of deferring")
                guard let held = held.read() else { throw CheckFailure("Held chunk missing") }
                receiver.receive(held)
                try wait(fileDone, "Deferred local copy interrupted the accepted file")
                try wait(idle, "Completed file reception did not become idle")
                receiver.prepareSend(deferred: deferred) { preparation.set($0); actionDone.signal() }
                try wait(actionDone, "Retry could not prepare after file reception")
                try check(preparation.read() != nil && callbacks.read() == ["deferred"], "Idle preparation was deferred or refused")
                receiver.send(.text(Data("latest local copy".utf8)), preparation: preparation.read(), deferred: deferred) { result in
                    results.update { $0.append(result) }; retryDone.signal()
                }
                try wait(retryDone, "Latest local copy could not send after reception")
                stopTransfers(sender, receiver)
                try check(results.read() == [true, true] && receivedFile.read() && retriedText.read()
                          && callbacks.read() == ["deferred"], "File bytes, retry or exactly-once callback semantics changed")
            }
        }
    }

    for accepted in [true, false] {
        run("Local send and preparation preserve an applying file until its \(accepted ? "success" : "failure") callback") {
            try withCheckFolder { folder in
                let file = folder.appendingPathComponent("applying.bin"), bytes = Data([1, 3, 5, 7])
                try bytes.write(to: file)
                let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
                let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
                let applying = DispatchSemaphore(value: 0), deferredDone = DispatchSemaphore(value: 0)
                let done = DispatchSemaphore(value: 0), idle = DispatchSemaphore(value: 0)
                let application = Box<(ClipboardApplyPermit, (Bool) -> Void)?>(nil)
                let callbacks = Box<[String]>([]), result = Box<Bool?>(nil), copiedBytes = Box(false)
                sender.onSend = { receiver.receive($0) }; receiver.onSend = { sender.receive($0) }
                receiver.onFileOffer = { [weak receiver] in
                    if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
                }
                receiver.onFileReceptionChanged = { if $0 == nil { idle.signal() } }
                receiver.onApplyWithPermit = { payload, permit, completion in
                    if case .files(let urls) = payload, let url = urls.first { copiedBytes.set((try? Data(contentsOf: url)) == bytes) }
                    application.set((permit, completion)); applying.signal()
                }
                defer { stopTransfers(sender, receiver) }
                sender.send(.files([file])) { result.set($0); done.signal() }
                try wait(applying, "Received file did not reach publication")
                let deferred = { callbacks.update { $0.append("deferred") }; deferredDone.signal() }
                receiver.prepareSend(deferred: deferred) { _ in callbacks.update { $0.append("prepare completion") }; deferredDone.signal() }
                receiver.send(.text(Data("local".utf8)), deferred: deferred) { _ in
                    callbacks.update { $0.append("send completion") }; deferredDone.signal()
                }
                try wait(deferredDone, "Preparation did not defer during publication")
                try wait(deferredDone, "Send did not defer during publication")
                guard let (permit, complete) = application.read() else { throw CheckFailure("Application callback missing") }
                try check(permit.isValid && callbacks.read() == ["deferred", "deferred"] && result.read() == nil,
                          "Deferred copy invalidated file publication or invoked a completion")
                complete(accepted ? permit.performIfValid { true } : false)
                try wait(done, "File publication did not settle the sender")
                try wait(idle, "Publication outcome did not clear receiving state")
                stopTransfers(sender, receiver)
                try check(result.read() == accepted && copiedBytes.read() && !permit.isValid,
                          "Publication result, completed bytes or permit lifetime changed")
            }
        }
    }

    run("Opted-in local copies can still replace an unaccepted file offer") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("offered.bin")
            try Data([9, 8, 7]).write(to: file)
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let offered = DispatchSemaphore(value: 0), oldDone = DispatchSemaphore(value: 0), newDone = DispatchSemaphore(value: 0)
            let result = Box<[Bool]>([]), deferred = Box(false), receivedText = Box(false), beganReceiving = Box(false)
            sender.onSend = { receiver.receive($0) }; receiver.onSend = { sender.receive($0) }
            receiver.onFileOffer = { if $0 != nil { offered.signal() } }
            receiver.onFileReceptionChanged = { if $0 != nil { beganReceiving.set(true) } }
            sender.onReceive = { payload in
                if case .text(let data) = payload { receivedText.set(data == Data("newer".utf8)) }
            }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([file])) { value in result.update { $0.append(value) }; oldDone.signal() }
            try wait(offered, "File request was not offered")
            receiver.send(.text(Data("newer".utf8)), deferred: { deferred.set(true); newDone.signal() }) { value in
                result.update { $0.append(value) }; newDone.signal()
            }
            try wait(oldDone, "Unaccepted file offer was not superseded")
            try wait(newDone, "Explicit local copy did not replace the pending offer")
            stopTransfers(sender, receiver)
            try check(result.read() == [false, true] && receivedText.read() && !deferred.read() && !beganReceiving.read(),
                      "File approval started implicitly or pending offers became protected")
        }
    }

    run("Omitting the deferred callback preserves replacement of an accepted file reception") {
        try withCheckFolder { folder in
            let file = folder.appendingPathComponent("legacy.bin")
            try Data(repeating: 76, count: 100_000).write(to: file)
            let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"), requireFileApproval: true)
            let held = DispatchSemaphore(value: 0), oldDone = DispatchSemaphore(value: 0), newDone = DispatchSemaphore(value: 0)
            let oldResult = Box<Bool?>(nil), newResult = Box<Bool?>(nil), receivedFile = Box(false)
            sender.onSend = { message in
                if message.kind == .clipboardChunk { held.signal() } else { receiver.receive(message) }
            }
            receiver.onSend = { sender.receive($0) }
            receiver.onFileOffer = { [weak receiver] in
                if let offer = $0 { receiver?.respondToFileOffer(id: offer.id, accept: true) }
            }
            receiver.onReceive = { _ in receivedFile.set(true) }
            defer { stopTransfers(sender, receiver) }
            sender.send(.files([file])) { oldResult.set($0); oldDone.signal() }
            try wait(held, "File reception did not start")
            receiver.send(.text(Data("replacement".utf8))) { newResult.set($0); newDone.signal() }
            try wait(oldDone, "Default local send did not replace the active reception")
            try wait(newDone, "Default replacement did not complete")
            stopTransfers(sender, receiver)
            try check(oldResult.read() == false && newResult.read() == true && !receivedFile.read(),
                      "Optional protection changed callers that did not opt in")
        }
    }

    run("Stopped receivers complete opted-in attempts without deferring them") {
        try withCheckFolder { folder in
            let receiver = ClipboardTransfer(storage: folder)
            let stopped = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            let outcomes = Box<[String]>([])
            receiver.stop { stopped.signal() }
            try wait(stopped, "Receiver did not stop")
            receiver.prepareSend(deferred: { outcomes.update { $0.append("deferred") }; completed.signal() }) { token in
                outcomes.update { $0.append(token == nil ? "no token" : "unexpected token") }; completed.signal()
            }
            receiver.send(.text(Data()), deferred: { outcomes.update { $0.append("deferred") }; completed.signal() }) { value in
                outcomes.update { $0.append(value ? "unexpected success" : "failed") }; completed.signal()
            }
            try wait(completed, "Stopped preparation did not settle"); try wait(completed, "Stopped send did not settle")
            try check(outcomes.read() == ["no token", "failed"], "A stopped receiver deferred an attempt or invoked the wrong callback")
        }
    }
}
