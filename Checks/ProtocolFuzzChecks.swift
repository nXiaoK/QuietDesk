import Foundation
import Network
import QuietDeskCore

private struct ProtocolRandom {
    private var state: UInt64 = 0x5A17_E8C3_B910_246D
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(upperBound))
    }
    mutating func data(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(next(256)) }) }
}

func runProtocolFuzzChecks() {
    run("Wire enforces direct decode limits and handles nonzero Data slice indices") {
        for raw in UInt8.min...UInt8.max {
            var storage = Data(repeating: 0xEE, count: 17)
            storage.append(raw)
            storage.append(contentsOf: 0..<64)
            let body = storage.dropFirst(17)
            if let kind = MessageKind(rawValue: raw) {
                let message = try Wire.decodeBody(body)
                try check(message.kind == kind && message.payload == Data(0..<64), "Sliced wire payload changed")
                try check(try message.framed() == Data([0, 0, 0, 65]) + Data(body), "Sliced message did not reframe")
            } else {
                try rejects("Unknown message kind was accepted") { _ = try Wire.decodeBody(body) }
            }
        }
        let maximum = Data([MessageKind.clipboard.rawValue]) + Data(count: Wire.maximumMessageBytes - 1)
        try check(Wire.decodeBody(maximum).payload.count == Wire.maximumMessageBytes - 1, "Maximum legal body was rejected")
        try rejects("Oversized direct decode was accepted") { _ = try Wire.decodeBody(maximum + Data([0])) }
        try rejects("Oversized direct video decode was accepted") { _ = try VideoPacket.decode(maximum) }
        try rejects("Empty direct decode was accepted") { _ = try Wire.decodeBody(Data()) }
    }

    run("ByteReader random slices, bounds and failed reads preserve the cursor") {
        var signed = ByteReader(Data([0x80, 0xFF, 0xFE]))
        try check(try signed.take() as Int8 == Int8.min, "Signed byte decoding overflowed")
        try check(try signed.take() as Int16 == -2, "Signed integer decoding changed byte order")
        var random = ProtocolRandom()
        for _ in 0..<1_000 {
            let count = random.next(256)
            let prefix = random.next(32) + 1
            let bytes = random.data(count)
            let storage = random.data(prefix) + bytes
            var reader = ByteReader(storage.dropFirst(prefix))
            var consumed = 0
            while consumed < count {
                let remaining = count - consumed
                try rejects("ByteReader accepted excessive length") { _ = try reader.bytes(remaining + 1) }
                try rejects("ByteReader accepted negative length") { try reader.skip(-1) }
                try rejects("ByteReader accepted integer maximum length") { _ = try reader.bytes(Int.max) }
                try check(reader.remaining == remaining, "Failed read advanced cursor")
                if remaining >= 4, random.next(2) == 0 {
                    let expected = bytes[consumed..<(consumed + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    try check(try reader.take() as UInt32 == expected, "Sliced integer was decoded incorrectly")
                    consumed += 4
                } else {
                    let length = random.next(remaining) + 1
                    let result = try reader.bytes(length)
                    try check(result == bytes[consumed..<(consumed + length)], "Sliced bytes changed")
                    consumed += length
                }
            }
            try check(reader.remaining == 0 && (try reader.bytes(0)).isEmpty, "Exhausted reader was not empty")
            try rejects("Exhausted integer read succeeded") { _ = try reader.take() as UInt64 }
        }
    }

    run("Seeded protocol bytes and mutated video lengths are bounded and reject invalid NALs") {
        var random = ProtocolRandom()
        for _ in 0..<2_500 {
            let raw = random.data(random.next(768))
            if let message = try? Wire.decodeBody(raw) {
                try check(try message.framed().dropFirst(4) == raw, "Random wire round trip changed bytes")
            }
            if let packet = try? VideoPacket.decode(raw) {
                try check(try packet.encode() == raw, "Random video round trip changed bytes")
            }
            let nal = random.data(random.next(512) + 1)
            var avcc = Data()
            avcc.put(UInt32(nal.count)); avcc.append(nal)
            let packet = VideoPacket(sequence: UInt32(random.next(100_000)), sps: Data([0x67, 1]),
                                     pps: Data([0x68]), avcc: avcc)
            let encoded = try packet.encode()
            let cut = random.next(encoded.count)
            try rejects("Truncated single-NAL packet was accepted") { _ = try VideoPacket.decode(encoded.prefix(cut)) }
            let nalOffset = 8 + packet.sps.count + packet.pps.count
            for invalidLength in [UInt32(0), UInt32(nal.count + 1), UInt32.max] {
                var changed = encoded
                var length = Data(); length.put(invalidLength)
                changed.replaceSubrange(nalOffset..<(nalOffset + 4), with: length)
                try rejects("Out-of-bounds NAL length was accepted") { _ = try VideoPacket.decode(changed) }
            }
        }
        for lengths: (UInt16, UInt16) in [(4097, 1), (1, 4097), (0, 1), (1, 0), (.max, .max)] {
            var bytes = Data(); bytes.put(UInt32(1)); bytes.put(lengths.0); bytes.put(lengths.1)
            bytes.append(Data(count: 16))
            try rejects("Invalid SPS/PPS lengths were accepted") { _ = try VideoPacket.decode(bytes) }
        }
    }

    if CommandLine.arguments.contains("--skip-network") { return }
    run("Peer reassembles split four-byte headers and coalesced binary messages in order") {
        let key = try PairingKey.generate()
        let queue = DispatchQueue(label: "checks.fuzz-framing")
        let listener = try makeListener(key, queue: queue)
        let messages = [Message(.input, Data([11, 22, 33])), Message(.clipboard, Data(repeating: 0xD7, count: 200_000)),
                        Message(.acknowledgement, Data([0, 0, 0, 9])), Message(.input, Data())]
        let stream = try messages.reduce(into: Data()) { $0.append(try $1.framed()) }
        let split = try messages[0].framed().count + (try messages[1].framed().count) + 2
        let fragments = [stream[0..<1], stream[1..<2], stream[2..<3], stream[3..<split],
                         stream[split..<(split + 1)], stream[(split + 1)..<stream.count]]
        let server = Box<Peer?>(nil), received = Box(0), failure = Box<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { message in
                let index = received.read()
                guard index < messages.count else { failure.set("Duplicate message delivered"); done.signal(); return }
                if message.kind != messages[index].kind || message.payload != messages[index].payload {
                    failure.set("Fragmented or coalesced message changed")
                }
                received.set(index + 1)
                if index + 1 == messages.count { done.signal() }
            }
            peer.onClose = { reason in failure.set(reason); done.signal() }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No framing test port") }
        let client = NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key))
        defer { client.cancel(); server.read()?.close(); listener.cancel() }
        func sendFragment(_ index: Int) {
            guard index < fragments.count else { return }
            client.send(content: fragments[index], completion: .contentProcessed { error in
                if let error { failure.set(error.localizedDescription); done.signal(); return }
                queue.asyncAfter(deadline: .now() + 0.01) { sendFragment(index + 1) }
            })
        }
        client.stateUpdateHandler = { state in
            if case .ready = state { sendFragment(0) }
            if case .failed(let error) = state { failure.set(error.localizedDescription); done.signal() }
        }
        client.start(queue: queue)
        try wait(done, "Split headers and coalesced messages were not reassembled")
        try check(failure.read() == nil && received.read() == messages.count, failure.read() ?? "Missing framed message")
    }

    run("Peer rejects zero, excessive and unknown frames before delivering any message") {
        for malformed in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 255])] {
            let key = try PairingKey.generate()
            let queue = DispatchQueue(label: "checks.invalid-framing")
            let listener = try makeListener(key, queue: queue)
            let server = Box<Peer?>(nil), delivered = Box(false)
            let closed = DispatchSemaphore(value: 0)
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection)
                server.set(peer)
                peer.onMessage = { _ in delivered.set(true) }
                peer.onClose = { _ in closed.signal() }
                peer.start()
            }
            guard let port = listener.port else { throw CheckFailure("No malformed frame test port") }
            let client = NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key))
            defer { client.cancel(); server.read()?.close(); listener.cancel() }
            client.stateUpdateHandler = { state in
                if case .ready = state { client.send(content: malformed, completion: .contentProcessed { _ in }) }
            }
            client.start(queue: queue)
            try wait(closed, "Malformed frame did not close the peer")
            try check(!delivered.read() && server.read()?.closeIsRetryable == false, "Malformed input was delivered or marked retryable")
        }
    }
}
