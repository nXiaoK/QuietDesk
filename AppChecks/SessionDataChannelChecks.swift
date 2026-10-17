import Foundation
import QuietDeskCore

private struct ChannelCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ChannelCheckFailure(message) }
}

private final class ChannelBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private func onBackground(_ body: @escaping () throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    let failure = ChannelBox<Error?>(nil)
    DispatchQueue.global().async {
        do { try body() } catch { failure.update { $0 = error } }
        done.signal()
    }
    try require(done.wait(timeout: .now() + 5) == .success, "Data path waited for the blocked main thread")
    if let error = failure.read() { throw error }
}

private func videoMessage(_ sequence: UInt32, keyFrame: Bool) throws -> Message {
    let packet = VideoPacket(sequence: sequence, sps: keyFrame ? Data([0x67, 1]) : Data(),
                             pps: keyFrame ? Data([0x68]) : Data(), avcc: Data([0, 0, 0, 2, 0x65, 0x88]))
    return Message(.video, try packet.encode())
}

@main
private struct SessionDataChannelChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Video parsing and decode acknowledgement finish while the main thread is blocked") {
            let sent = ChannelBox<[Message]>([]), decoded = ChannelBox<[UInt32]>([])
            let touchedMain = ChannelBox(false)
            let channel = SessionDataChannel(send: { message in
                sent.update { $0.append(message) }
                if Thread.isMainThread { touchedMain.update { $0 = true } }
            }, onFreshFrame: { _ in })
            channel.configureVideo { packet, complete in
                decoded.update { $0.append(packet.sequence) }
                if Thread.isMainThread { touchedMain.update { $0 = true } }
                complete()
            }
            try onBackground {
                try require(channel.receive(try videoMessage(0xFEED_BEEF, keyFrame: true)), "Video missed the data endpoint")
            }
            let messages = sent.read()
            try require(decoded.read() == [0xFEED_BEEF] && messages.count == 1 && !touchedMain.read(), "Video parsing or ack required main")
            try require(messages[0].kind == .acknowledgement && messages[0].payload.count == 4, "Invalid acknowledgement envelope")
            var reader = ByteReader(messages[0].payload)
            try require(try reader.take() as UInt32 == 0xFEED_BEEF, "Acknowledged the wrong frame")
            let metrics = channel.takeMetrics()
            try require(metrics.frames == 1 && metrics.bytes == 0, "Decoded frame metrics were not recorded")
        }

        run("A fresh-frame token completes only after a keyframe decode") {
            let fresh = ChannelBox<[UUID]>([]), completions = ChannelBox<[() -> Void]>([])
            let channel = SessionDataChannel(send: { _ in }, onFreshFrame: { token in fresh.update { $0.append(token) } })
            channel.configureVideo { _, complete in completions.update { $0.append(complete) } }
            let token = UUID()
            channel.expectFreshFrame(token)
            try onBackground {
                try require(channel.receive(try videoMessage(1, keyFrame: false)), "Predictive frame was not routed")
                try require(channel.receive(try videoMessage(2, keyFrame: true)), "Keyframe was not routed")
            }
            try require(fresh.read().isEmpty, "Receiving a packet completed the fresh-frame barrier before decode")
            try onBackground { completions.read()[0]() }
            try require(fresh.read().isEmpty, "Predictive frame completed the fresh-frame barrier")
            try onBackground { completions.read()[1]() }
            try require(fresh.read() == [token], "Decoded keyframe failed to complete its token")
            channel.expectFreshFrame(nil)
            try onBackground {
                _ = try channel.receive(try videoMessage(3, keyFrame: true))
                completions.read()[2]()
            }
            try require(fresh.read() == [token], "A cleared token reappeared on another keyframe")
        }

        run("Acknowledgements use the background endpoint and reject every non-four-byte payload") {
            let sequences = ChannelBox<[UInt32]>([]), touchedMain = ChannelBox(false)
            let channel = SessionDataChannel(send: { _ in }, onFreshFrame: { _ in })
            channel.configureAcknowledgement { sequence in
                sequences.update { $0.append(sequence) }
                if Thread.isMainThread { touchedMain.update { $0 = true } }
            }
            try onBackground {
                for count in [0, 1, 2, 3, 5, 8, 256] {
                    do {
                        _ = try channel.receive(Message(.acknowledgement, Data(count: count)))
                    } catch { continue }
                    throw ChannelCheckFailure("Accepted an acknowledgement containing \(count) bytes")
                }
                let storage = Data(repeating: 0, count: 17) + Data([255, 255, 255, 255])
                try require(channel.receive(Message(.acknowledgement, storage.dropFirst(17))), "Valid sliced acknowledgement missed its endpoint")
            }
            try require(sequences.read() == [UInt32.max] && !touchedMain.read(), "Invalid ack reached the endpoint or valid ack required main")
        }

        run("Clipboard streaming messages enter the configured endpoint directly and control messages retain fallback") {
            let received = ChannelBox<[MessageKind]>([]), touchedMain = ChannelBox(false)
            let channel = SessionDataChannel(send: { _ in }, onFreshFrame: { _ in })
            channel.configureClipboard { message in
                received.update { $0.append(message.kind) }
                if Thread.isMainThread { touchedMain.update { $0 = true } }
            }
            let kinds: [MessageKind] = [.clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel]
            try onBackground {
                for kind in kinds { try require(channel.receive(Message(kind, Data([1, 2, 3]))), "Clipboard message missed its endpoint") }
                for kind: MessageKind in [.hello, .clipboardSettings, .requestClipboard, .input] {
                    try require(!channel.receive(Message(kind)), "Control message was swallowed by the data endpoint")
                }
                channel.configureClipboard(nil)
                try require(!channel.receive(Message(.clipboardBegin)), "A missing clipboard endpoint swallowed a message")
            }
            try require(received.read() == kinds && !touchedMain.read(), "Clipboard traffic visited main or changed order")
            let empty = SessionDataChannel(send: { _ in }, onFreshFrame: { _ in })
            try require(!empty.receive(try videoMessage(1, keyFrame: true)) && !empty.receive(Message(.acknowledgement)),
                        "Unconfigured data endpoints changed fallback behavior")
        }

        run("Invalidation fences late decode completions, endpoints and drained session metrics") {
            let sent = ChannelBox<[Message]>([]), fresh = ChannelBox<[UUID]>([])
            let completions = ChannelBox<[() -> Void]>([]), endpointCalls = ChannelBox(0)
            let channel = SessionDataChannel(send: { message in sent.update { $0.append(message) } },
                                             onFreshFrame: { token in fresh.update { $0.append(token) } })
            channel.configureVideo { _, complete in completions.update { $0.append(complete) } }
            channel.configureAcknowledgement { _ in endpointCalls.update { $0 += 1 } }
            channel.configureClipboard { _ in endpointCalls.update { $0 += 1 } }
            channel.expectFreshFrame(UUID())
            try onBackground { _ = try channel.receive(try videoMessage(4, keyFrame: true)) }
            channel.recordBytes(512)
            channel.recordFrame()
            channel.invalidate()
            try onBackground {
                completions.read()[0]()
                for kind: MessageKind in [.video, .acknowledgement, .clipboardChunk, .hello] {
                    try require(channel.receive(Message(kind)), "Invalidated channel did not discard old-session traffic")
                }
                channel.recordBytes(256)
                channel.recordFrame()
            }
            let metrics = channel.takeMetrics()
            try require(sent.read().isEmpty && fresh.read().isEmpty && endpointCalls.read() == 0,
                        "Old session completion sent an ack, released input or reached an endpoint")
            try require(metrics.bytes == 0 && metrics.frames == 0, "Invalidation retained or accepted metrics")
        }

        run("Concurrent byte and frame producers drain each metric exactly once") {
            let channel = SessionDataChannel(send: { _ in }, onFreshFrame: { _ in })
            let drained = ChannelBox((bytes: 0, frames: 0))
            try onBackground {
                DispatchQueue.concurrentPerform(iterations: 8) { _ in
                    for index in 0..<1_000 {
                        channel.recordBytes(17); channel.recordFrame()
                        if index % 113 == 0 {
                            let metrics = channel.takeMetrics()
                            drained.update { $0.bytes += metrics.bytes; $0.frames += metrics.frames }
                        }
                    }
                }
            }
            let first = channel.takeMetrics(), second = channel.takeMetrics()
            try require(drained.read().bytes + first.bytes == 136_000 && drained.read().frames + first.frames == 8_000,
                        "Concurrent metric updates or drains were lost")
            try require(second.bytes == 0 && second.frames == 0, "Metrics were drained more than once")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
