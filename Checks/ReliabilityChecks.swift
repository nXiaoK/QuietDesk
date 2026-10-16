import Foundation
import Network
import VideoToolbox
import QuietDeskCore
import ImageIO
import CoreGraphics

func checkPNG() throws -> Data {
    let side = 384
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    var random: UInt32 = 7
    for index in pixels.indices where index % 4 != 3 {
        random = random &* 1_664_525 &+ 1_013_904_223
        pixels[index] = UInt8(truncatingIfNeeded: random >> 24)
    }
    return try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw CheckFailure("Cannot generate synthetic image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CheckFailure("Cannot encode synthetic PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure("PNG encoding failed") }
        return data as Data
    }
}

func withCheckFolder(_ body: (URL) throws -> Void) throws {
    let base = ProcessInfo.processInfo.environment["QUIETDESK_CHECK_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    let folder = base.appendingPathComponent("quietdesk-check-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

func stopTransfers(_ a: ClipboardTransfer, _ b: ClipboardTransfer) {
    let done = DispatchSemaphore(value: 0)
    a.stop { done.signal() }; b.stop { done.signal() }
    _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3)
}

func runReliabilityChecks() {
    run("Retry intervals increase, remain bounded, and reset after recovery") {
        var retry = RetryBackoff()
        var values: [Double] = []
        for _ in 0..<8 { values.append(retry.next()) }
        try check(values == [1, 2, 4, 8, 16, 30, 30, 30], "Incorrect retry sequence")
        retry.reset()
        try check(retry.attempt == 0 && retry.next() == 1, "Retry state did not reset")
    }

    run("Connection records round trip without storing pairing credentials") {
        let record = ConnectionRecord(address: "Example.COM", port: 5908, name: "Home")
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([ConnectionRecord].self, from: data)
        try check(decoded.first?.id == record.id, "Connection identity changed")
        try check(record.matches(address: "example.com", port: 5908), "Host matching must ignore case")
        try check(!record.matches(address: "example.com", port: 5909), "Distinct ports merged")
        let object = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        try check(Set(object[0].keys) == Set(["id", "address", "port", "name", "lastConnected"]), "Unexpected history fields")
    }

    run("Clipboard paths reject traversal and preserve Unicode names") {
        let root = URL(fileURLWithPath: "/tmp/quietdesk-path-check")
        for path in ["../escape", "/etc/passwd", "a/../../escape", "a//b", ".", "a/./b", "bad\0name", ""] {
            try rejects("Accepted unsafe path: \(path)") { _ = try ClipboardPaths.destination(root: root, relative: path) }
        }
        try check(ClipboardPaths.destination(root: root, relative: "项目/文 件.txt").path == root.path + "/项目/文 件.txt", "Unicode path changed")
    }

    run("Large text and binary image clipboard data stream in bounded chunks") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            let failure = Box<String?>(nil)
            let done = DispatchSemaphore(value: 0)
            let received = DispatchSemaphore(value: 0)
            let expected = Box<Data>(Data())
            a.onSend = { [weak b] message in
                if message.kind == .clipboardChunk && message.payload.count > 32_800 { failure.set("Oversized clipboard chunk") }
                b?.receive(message)
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onReceive = { payload in
                switch payload {
                case .text(let bytes): if bytes != expected.read() { failure.set("Clipboard bytes changed") }
                case .png(let bytes):
                    if bytes != expected.read() { failure.set("Image bytes changed") }
                    if let image = CGImageSourceCreateWithData(bytes as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                        if image.width != 384 || image.height != 384 { failure.set("Image dimensions changed") }
                    } else { failure.set("Transferred PNG could not be decoded") }
                case .files: failure.set("Wrong clipboard type")
                }
                received.signal()
            }
            defer { stopTransfers(a, b) }
            for payload in [ClipboardPayload.text(Data(repeating: 65, count: 1_200_000)),
                            .png(try checkPNG()), .text(Data())] {
                switch payload { case .text(let bytes), .png(let bytes): expected.set(bytes); default: break }
                a.send(payload) { success in if !success { failure.set("Send failed") }; done.signal() }
                try wait(done, "Clipboard completion timed out")
                try wait(received, "Clipboard not published")
                try check(failure.read() == nil, failure.read() ?? "Clipboard error")
            }
        }
    }

    run("Clipboard file tree preserves bytes, empty items, names and executable mode") {
        try withCheckFolder { folder in
            let source = folder.appendingPathComponent("原始项目")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            let bytes = Data((0..<180_000).map { UInt8($0 % 241) })
            let file = source.appendingPathComponent("文 件.bin")
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            try Data().write(to: source.appendingPathComponent("empty.txt"))
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            let received = Box<[URL]>([])
            let done = DispatchSemaphore(value: 0)
            let success = Box(false)
            b.onReceive = { if case .files(let urls) = $0 { received.set(urls) } }
            defer { stopTransfers(a, b) }
            a.send(.files([source])) { value in success.set(value); done.signal() }
            try wait(done, "File transfer timed out")
            try check(success.read(), "File transfer failed")
            guard let copy = received.read().first else { throw CheckFailure("No file URLs published") }
            try check(copy.lastPathComponent == source.lastPathComponent, "Top-level file name changed")
            try check(Data(contentsOf: copy.appendingPathComponent("文 件.bin")) == bytes, "File bytes changed")
            try check(Data(contentsOf: copy.appendingPathComponent("empty.txt")).isEmpty, "Empty file changed")
            var directory: ObjCBool = false
            try check(FileManager.default.fileExists(atPath: copy.appendingPathComponent("空目录").path, isDirectory: &directory) && directory.boolValue, "Empty directory missing")
            let mode = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("文 件.bin").path)[.posixPermissions] as? NSNumber
            try check(mode?.intValue == 0o755, "Executable permissions changed")
        }
    }

    run("A rejected system clipboard write does not acknowledge paste readiness") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            b.onApply = { _, completion in completion(false) }
            let done = DispatchSemaphore(value: 0), success = Box(true)
            defer { stopTransfers(a, b) }
            a.send(.text(Data("synthetic".utf8))) { accepted in success.set(accepted); done.signal() }
            try wait(done, "Rejected clipboard write did not finish")
            try check(!success.read(), "Failed clipboard write was acknowledged as ready")
        }
    }

    run("Interrupted clipboard transfer removes partial data and never publishes files") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let bFolder = folder.appendingPathComponent("b")
            let b = ClipboardTransfer(storage: bFolder)
            let first = DispatchSemaphore(value: 0)
            let completions = DispatchSemaphore(value: 0)
            let chunks = Box(0)
            let published = Box(false)
            a.onSend = { [weak b] message in
                if message.kind == .clipboardChunk {
                    let count = chunks.read() + 1; chunks.set(count)
                    if count == 1 { b?.receive(message); first.signal() }
                } else { b?.receive(message) }
            }
            b.onSend = { [weak a] in a?.receive($0) }
            b.onReceive = { _ in published.set(true) }
            a.send(.text(Data(repeating: 66, count: 500_000))) { _ in completions.signal() }
            try wait(first, "No first clipboard chunk")
            stopTransfers(a, b)
            try wait(completions, "Cancelled send not completed")
            try check(!published.read(), "Incomplete clipboard was published")
            let partial = bFolder.appendingPathComponent("partial")
            if FileManager.default.fileExists(atPath: partial.path) {
                try check(FileManager.default.contentsOfDirectory(atPath: partial.path).isEmpty, "Partial data not removed")
            }
        }
    }

    run("Clipboard rejects symbolic links without publishing a partial copy") {
        try withCheckFolder { folder in
            let target = folder.appendingPathComponent("target.txt")
            try Data("sentinel".utf8).write(to: target)
            let link = folder.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            a.onSend = { [weak b] in b?.receive($0) }; b.onSend = { [weak a] in a?.receive($0) }
            let done = DispatchSemaphore(value: 0)
            let accepted = Box(true)
            let published = Box(false)
            b.onReceive = { _ in published.set(true) }
            defer { stopTransfers(a, b) }
            a.send(.files([link])) { success in accepted.set(success); done.signal() }
            try wait(done, "Link rejection timed out")
            try check(!accepted.read() && !published.read(), "Symbolic link was followed")
        }
    }

    run("Concurrent copies converge to one revision without repeated clipboard publication") {
        try withCheckFolder { folder in
            let a = ClipboardTransfer(storage: folder.appendingPathComponent("a"))
            let b = ClipboardTransfer(storage: folder.appendingPathComponent("b"))
            let aText = Data("copy A".utf8), bText = Data("copy B".utf8)
            let aValue = Box(aText), bValue = Box(bText)
            let begins = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            let hold = Box(true), aBegin = Box<Message?>(nil), bBegin = Box<Message?>(nil)
            let publications = Box(0), outcomes = Box<[Bool]>([])
            a.onSend = { [weak b] message in
                if message.kind == .clipboardBegin && hold.read() { aBegin.set(message); begins.signal() }
                else { b?.receive(message) }
            }
            b.onSend = { [weak a] message in
                if message.kind == .clipboardBegin && hold.read() { bBegin.set(message); begins.signal() }
                else { a?.receive(message) }
            }
            a.onReceive = { if case .text(let bytes) = $0 { aValue.set(bytes); publications.update { $0 += 1 } } }
            b.onReceive = { if case .text(let bytes) = $0 { bValue.set(bytes); publications.update { $0 += 1 } } }
            defer { stopTransfers(a, b) }
            a.send(.text(aText)) { result in outcomes.update { $0.append(result) }; finished.signal() }
            b.send(.text(bText)) { result in outcomes.update { $0.append(result) }; finished.signal() }
            try wait(begins, "First copy did not begin"); try wait(begins, "Second copy did not begin")
            hold.set(false)
            guard let aMessage = aBegin.read(), let bMessage = bBegin.read() else { throw CheckFailure("Missing concurrent offers") }
            a.receive(bMessage); b.receive(aMessage)
            try wait(finished, "First concurrent copy did not finish"); try wait(finished, "Second concurrent copy did not finish")
            try check(aValue.read() == bValue.read(), "Clipboard revisions did not converge")
            try check(publications.read() == 1 && outcomes.read().filter { $0 }.count == 1, "Concurrent copies were published repeatedly")
        }
    }

    run("Malformed received file path cannot overwrite an existing file") {
        try withCheckFolder { folder in
            let sentinel = folder.appendingPathComponent("sentinel")
            let original = Data("keep".utf8)
            try original.write(to: sentinel)
            let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"))
            let rejected = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            let published = Box(false)
            receiver.onSend = { if $0.kind == .clipboardCancel { rejected.signal() } }
            receiver.onReceive = { _ in published.set(true) }
            let revision: [String: Any] = ["counter": 1, "origin": UUID().uuidString]
            let begin: [String: Any] = ["revision": revision, "sequence": 0, "type": "files", "count": 1, "bytes": 4]
            let entry: [String: Any] = ["revision": revision, "sequence": 1, "path": "../../sentinel", "directory": false, "bytes": 4, "mode": 384, "modified": 0]
            receiver.receive(Message(.clipboardBegin, try JSONSerialization.data(withJSONObject: begin)))
            receiver.receive(Message(.clipboardEntry, try JSONSerialization.data(withJSONObject: entry)))
            try wait(rejected, "Unsafe file path was not rejected")
            receiver.stop { stopped.signal() }; try wait(stopped, "Receiver did not stop")
            try check(Data(contentsOf: sentinel) == original && !published.read(), "Unsafe transfer modified existing data")
        }
    }

    run("Background decoding acknowledges frames without a visible display queue") {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard result == noErr, let pixel else { throw CheckFailure("Unable to create synthetic pixels") }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            if let address = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                memset(address, plane == 0 ? 64 : 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let encoder = try VideoEncoder(width: 320, height: 180, settings: .init())
        let decoder = VideoDecoder()
        let inbox = LatestFrameMailbox()
        let ack = DispatchSemaphore(value: 0)
        let error = Box<String?>(nil)
        let schedules = Box(0)
        encoder.onOutput = { output in
            do {
                let packet = try output.get()
                decoder.decode(packet) { result in
                    switch result {
                    case .success(let frame): if inbox.offer(frame) { schedules.set(schedules.read() + 1) }
                    case .failure(let issue): error.set(issue.localizedDescription)
                    }
                    ack.signal()
                }
            } catch let issue { error.set(issue.localizedDescription); ack.signal() }
        }
        defer { encoder.stop(); decoder.stop() }
        for index in UInt32(1)...10 {
            try encoder.encode(pixel, time: CMTime(value: Int64(index), timescale: 15), sequence: index, forceKeyFrame: index == 1)
            try wait(ack, "Background decode did not acknowledge")
            try check(error.read() == nil, error.read() ?? "Decode failed")
        }
        try check(schedules.read() == 1, "Hidden window accumulated display callbacks")
        try check(inbox.take().map { CVPixelBufferGetWidth($0) } == 320, "Latest decoded frame missing")
    }

    if !CommandLine.arguments.contains("--skip-network") {
        run("TLS clipboard streaming preserves bytes and allows control messages between chunks") {
            try withCheckFolder { folder in
                let key = try PairingKey.generate()
                let queue = DispatchQueue(label: "checks.clipboard-tls")
                let listener = try makeListener(key, queue: queue)
                let sender = ClipboardTransfer(storage: folder.appendingPathComponent("sender"))
                let receiver = ClipboardTransfer(storage: folder.appendingPathComponent("receiver"))
                let server = Box<Peer?>(nil)
                let sent = DispatchSemaphore(value: 0), control = DispatchSemaphore(value: 0)
                let bytes = Data(repeating: 77, count: 2_000_000)
                let payloadCorrect = Box(false), completed = Box(false), controlDuringTransfer = Box(false)
                let chunks = Box(0), sendSucceeded = Box(false)
                receiver.onReceive = { payload in
                    if case .text(let data) = payload { payloadCorrect.set(data == bytes) }
                    completed.set(true)
                }
                listener.newConnectionHandler = { connection in
                    let peer = Peer(connection: connection)
                    server.set(peer)
                    receiver.onSend = { [weak peer] in peer?.send($0) }
                    peer.onMessage = { message in
                        if message.kind == .input {
                            controlDuringTransfer.set(!completed.read())
                            control.signal()
                        } else { receiver.receive(message) }
                    }
                    peer.start()
                }
                guard let port = listener.port else { throw CheckFailure("No local port") }
                let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
                defer { stopTransfers(sender, receiver); client.close(); server.read()?.close(); listener.cancel() }
                sender.onSend = { [weak client] message in
                    client?.send(message)
                    if message.kind == .clipboardChunk {
                        chunks.update { $0 += 1 }
                        if chunks.read() == 4 { client?.send(Message(.input, Data([99]))) }
                    }
                }
                client.onMessage = { sender.receive($0) }
                client.onReady = { sender.send(.text(bytes)) { result in sendSucceeded.set(result); sent.signal() } }
                client.start()
                try wait(sent, "TLS clipboard did not complete")
                try wait(control, "Control message was blocked")
                try check(sendSucceeded.read() && payloadCorrect.read(), "TLS clipboard data changed")
                try check(controlDuringTransfer.read() && chunks.read() > 4, "Control traffic was delayed until the end")
            }
        }
        run("A dropped TLS session can reconnect and explicit cancellation does not retry") {
            let key = try PairingKey.generate()
            let queue = DispatchQueue(label: "checks.reconnect")
            let listener = try makeListener(key, queue: queue)
            let peers = Box<[Peer]>([]), client = Box<Peer?>(nil)
            let accepted = Box(0), attempts = Box(0), running = Box(true)
            let restored = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
            listener.newConnectionHandler = { connection in
                accepted.update { $0 += 1 }
                let count = accepted.read()
                let peer = Peer(connection: connection)
                peers.update { $0.append(peer) }
                peer.onReady = {
                    if count == 1 { peer.close("simulated cable disconnect") }
                    else { peer.send(Message(.hello, Data("restored".utf8))) }
                }
                peer.start()
            }
            guard let port = listener.port else { throw CheckFailure("No local port") }
            func connect() {
                guard running.read() else { return }
                attempts.update { $0 += 1 }
                let candidate = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
                client.set(candidate)
                candidate.onMessage = { _ in restored.signal() }
                candidate.onClose = { [weak candidate] _ in
                    if candidate?.closeIsRetryable == true { queue.asyncAfter(deadline: .now() + 0.05) { connect() } }
                    else { cancelled.signal() }
                }
                candidate.start()
            }
            defer { running.set(false); client.read()?.close(); peers.read().forEach { $0.close() }; listener.cancel() }
            connect()
            try wait(restored, "TLS reconnection did not recover")
            client.read()?.close("user cancelled")
            try wait(cancelled, "Explicit close was not classified as cancellation")
            try check(accepted.read() == 2 && attempts.read() == 2, "Unexpected retry after cancellation")
        }
        run("Partial message activity prevents idle timeout during a slow frame") {
            let key = try PairingKey.generate()
            let queue = DispatchQueue(label: "checks.slow-frame")
            let listener = try makeListener(key, queue: queue)
            let server = Box<Peer?>(nil)
            let received = DispatchSemaphore(value: 0)
            let error = Box<String?>(nil)
            let payload = Data(repeating: 67, count: 65_536)
            let framed = try Message(.clipboard, payload).framed()
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection, idleTimeout: 0.4, handshakeTimeout: 5, heartbeatInterval: 0.1)
                server.set(peer)
                peer.onMessage = { message in
                    if message.payload != payload { error.set("Slow payload changed") }
                    received.signal()
                }
                peer.onClose = { reason in error.set(reason) }
                peer.start()
            }
            guard let port = listener.port else { throw CheckFailure("No local port") }
            let client = NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key))
            defer { client.cancel(); server.read()?.close(); listener.cancel() }
            client.stateUpdateHandler = { state in
                if case .ready = state {
                    for (index, start) in stride(from: 0, to: framed.count, by: 4096).enumerated() {
                        let chunk = framed.subdata(in: start..<min(start + 4096, framed.count))
                        queue.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                            client.send(content: chunk, completion: .contentProcessed { _ in })
                        }
                    }
                }
            }
            client.start(queue: queue)
            try wait(received, seconds: 5, "Slow frame was disconnected")
            try check(error.read() == nil, error.read() ?? "Idle timeout")
        }
    }
}
