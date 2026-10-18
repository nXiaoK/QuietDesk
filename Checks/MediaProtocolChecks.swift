import Foundation
import QuietDeskCore

private struct MediaCheckFailure: Error { let message: String }
private final class MediaCheckClock { var now: TimeInterval = 0 }

func runMediaProtocolChecks(check run: (String, () throws -> Void) -> Void) {
    func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw MediaCheckFailure(message: message) }
    }
    func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw MediaCheckFailure(message: "Invalid media input was accepted")
    }
    let session = UUID()
    let stream = MediaStreamID(sessionID: session, transportEpoch: 1, codecEpoch: 1)
    let nextStream = MediaStreamID(sessionID: session, transportEpoch: 2, codecEpoch: 2)
    func frame(_ id: UInt64, idr: Bool = false, sequence: UInt32 = 77, bytes: Int = 3,
               stream: MediaStreamID? = nil) throws -> MediaFrame {
        var avcc = Data()
        avcc.put(UInt32(max(1, bytes)))
        avcc.append(idr ? 0x65 : 0x41)
        avcc.append(Data(repeating: 0x88, count: max(1, bytes) - 1))
        return try MediaFrame(header: MediaFrameHeader(stream: stream ?? MediaStreamID(sessionID: session, transportEpoch: 1, codecEpoch: 1),
                                                       frameID: id, isIDR: idr),
                              packet: VideoPacket(sequence: sequence, sps: idr ? Data([0x67, 0x64]) : Data(),
                                                  pps: idr ? Data([0x68]) : Data(), avcc: avcc))
    }
    func ready(_ events: [MediaReceiveEvent]) -> [MediaFrame] {
        events.compactMap { if case .frameReady(let frame) = $0 { return frame }; return nil }
    }
    func feedback(_ events: [MediaReceiveEvent], _ kind: MediaFeedback.Kind) -> [MediaFeedback] {
        events.compactMap { if case .feedback(let value) = $0, value.kind == kind { return value }; return nil }
    }
    func terminal(_ events: [MediaSendEvent]) -> [UInt32] {
        events.compactMap { if case .terminal(_, let sequence, _) = $0 { return sequence }; return nil }
    }

    run("Media TCP envelope preserves independent frame and capture sequence, and rejects forged IDR") {
        let original = try frame(4, idr: true, sequence: UInt32.max)
        let bytes = try original.encode()
        let decoded = try MediaFrame.decode(bytes)
        try require(decoded.header == original.header && decoded.packet.sequence == UInt32.max
                    && decoded.packet.avcc == original.packet.avcc, "TCP envelope changed video or identity")
        for length in 0..<bytes.count { try rejects { _ = try MediaFrame.decode(Data(bytes.prefix(length))) } }
        try rejects { _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 4, isIDR: false), packet: original.packet) }
        let predicted = try frame(5)
        try rejects { _ = try MediaFrame(header: original.header, packet: predicted.packet) }
        try rejects { _ = try MediaFrame(header: original.header, packet: VideoPacket(sequence: 0, sps: Data(), pps: Data(), avcc: original.packet.avcc)) }
        try rejects { _ = try MediaFrame.containsIDR(Data([0, 0, 0, 1, 0xE5])) }
    }

    run("Media UDP fragments stay within DTLS application budget and reject corrupt shape") {
        let fragments = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 5_000))
        try require(fragments.count > 3, "Fixture was not fragmented")
        for fragment in fragments {
            try require(fragment.encode().count <= 1_100 && MediaFragment.decode(fragment.encode()) == fragment, "Datagram did not round trip")
        }
        let first = fragments[0]
        try rejects { _ = try MediaFragment(header: first.header, packetSequence: 0, frameBytes: first.frameBytes,
                                           fragmentIndex: first.fragmentIndex, fragmentCount: first.fragmentCount,
                                           payload: Data(first.payload.dropLast())) }
        try rejects { _ = try MediaFragment.decode(first.encode() + Data([0])) }
        try rejects { _ = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 5_000), startingPacketSequence: UInt64.max) }
    }

    run("Media feedback validates sorted bounded NACK ranges and exact framing") {
        let header = try frame(2).header
        let message = try MediaFeedback(kind: .nack, header: header,
                                        missingRanges: [.init(first: 1, count: 2), .init(first: 4, count: 1)])
        try require(MediaFeedback.decode(message.encode()) == message, "NACK ranges changed")
        try rejects { _ = try MediaFeedback(kind: .nack, header: header) }
        try rejects { _ = try MediaFeedback(kind: .decoded, header: header, missingRanges: [.init(first: 0, count: 1)]) }
        try rejects { _ = try MediaFeedback(kind: .nack, header: header, missingRanges: [.init(first: 1, count: 2), .init(first: 2, count: 1)]) }
        try rejects { _ = try MediaFeedback(kind: .nack, header: header, missingRanges: [.init(first: UInt16.max, count: 2)]) }
        try rejects { _ = try MediaFeedback.decode(message.encode() + Data([0])) }
    }

    run("Media reassembly accepts reordered fragments but decodes in reference order behind IDR") {
        let receiver = try MediaFrameReassembler(stream: stream)
        let first = try frame(1, idr: true, bytes: 3_000)
        let second = try frame(2, sequence: 93)
        var events: [MediaReceiveEvent] = []
        for fragment in try MediaFragment.fragment(frame: second) { events += try receiver.receive(fragment) }
        try require(ready(events).isEmpty, "P frame crossed the missing IDR")
        let fragments = try MediaFragment.fragment(frame: first)
        for fragment in fragments.reversed() { events += try receiver.receive(fragment) }
        try require(ready(events).map(\.header.frameID) == [1], "Reassembly ignored IDR barrier")
        try require(ready(try receiver.receive(fragments[0])).isEmpty, "Duplicate fragment decoded twice")
        let decoded = receiver.decoded(first.header, success: true)
        try require(ready(decoded).map(\.header.frameID) == [2], "Next reference frame was not released")
        try require(receiver.decoded(first.header, success: true).isEmpty, "Old decode completion advanced twice")
        _ = receiver.decoded(second.header, success: true)
        try require(receiver.bufferedBytes == 0 && receiver.pendingFrameCount == 0, "Decode did not release bounded memory")
    }

    run("Media missing whole P frame expires its chain instead of feeding later P frames") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true)
        for fragment in try MediaFragment.fragment(frame: first) { _ = try receiver.receive(fragment) }
        _ = receiver.decoded(first.header, success: true)
        var later: [MediaReceiveEvent] = []
        for fragment in try MediaFragment.fragment(frame: frame(3)) { later += try receiver.receive(fragment) }
        try require(ready(later).isEmpty, "P frame crossed a reference hole")
        time.now = 0.16
        let expired = receiver.poll()
        try require(receiver.requiresRecovery && feedback(expired, .expired).count == 1 && receiver.bufferedBytes == 0,
                    "Lost whole frame did not invalidate and release its chain")
        try require(receiver.poll().isEmpty, "Expired chain emitted duplicate recovery")
        receiver.replaceStream(nextStream)
        try require(try receiver.receive(MediaFragment.fragment(frame: frame(1, idr: true))[0]).isEmpty, "Old epoch was accepted")
        let replacement = try frame(1, idr: true, stream: nextStream)
        try require(ready(try receiver.receive(MediaFragment.fragment(frame: replacement)[0])).count == 1, "Fresh IDR did not recover")
    }

    run("Media P-only start, conflicting duplicates and exhausted bytes cannot poison a chain") {
        let receiver = try MediaFrameReassembler(stream: stream)
        let predicted = try MediaFragment.fragment(frame: frame(1))[0]
        try require(ready(try receiver.receive(predicted)).isEmpty && receiver.requiresRecovery, "P frame started a new codec epoch")
        receiver.replaceStream(stream)
        let parts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 3_000))
        _ = try receiver.receive(parts[0])
        var changed = parts[0].payload
        changed[changed.startIndex] ^= 1
        let conflict = try MediaFragment(header: parts[0].header, packetSequence: 45, frameBytes: parts[0].frameBytes,
                                         fragmentIndex: parts[0].fragmentIndex, fragmentCount: parts[0].fragmentCount, payload: changed)
        try rejects { _ = try receiver.receive(conflict) }
        try require(receiver.requiresRecovery && receiver.bufferedBytes == 0, "Conflict left a reusable poisoned chain")
        let bounded = try MediaFrameReassembler(stream: stream, limits: MediaBufferLimits(maximumBufferedBytes: 100))
        _ = try bounded.receive(parts[0])
        try require(bounded.requiresRecovery && bounded.bufferedBytes == 0, "Oversized reservation allocated outside the budget")
    }

    run("Media NACK waits for reordering, identifies holes and duplicates never extend TTL") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let parts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 3_000))
        _ = try receiver.receive(parts[0])
        _ = try receiver.receive(parts[2])
        time.now = 0.002
        try require(feedback(receiver.poll(), .nack).isEmpty, "NACK ignored reordering grace")
        time.now = 0.004
        let missing = feedback(receiver.poll(), .nack)
        try require(missing.count == 1 && missing[0].missingRanges == [.init(first: 1, count: 1)], "NACK did not isolate the missing fragment")
        try require(feedback(receiver.poll(), .nack).isEmpty, "NACK rate limit was ignored")
        time.now = 0.14
        _ = try receiver.receive(parts[0])
        time.now = 0.151
        try require(!feedback(receiver.poll(), .expired).isEmpty, "Repeated fragment extended frame lifetime")
    }

    run("Media decode failure and late callbacks require a fresh epoch") {
        let receiver = try MediaFrameReassembler(stream: stream)
        let initial = try frame(1, idr: true)
        _ = try receiver.receive(MediaFragment.fragment(frame: initial)[0])
        try require(!feedback(receiver.decoded(initial.header, success: false), .expired).isEmpty && receiver.requiresRecovery,
                    "Decode error did not request recovery")
        receiver.replaceStream(nextStream)
        let current = try frame(1, idr: true, stream: nextStream)
        _ = try receiver.receive(MediaFragment.fragment(frame: current)[0])
        try require(receiver.decoded(initial.header, success: true).isEmpty, "Old epoch decode completion released new state")
        try require(!feedback(receiver.decoded(current.header, success: true), .decoded).isEmpty, "Current epoch decode failed")
    }

    run("Media sender waits for IDR decode and cumulative ACK settles original sequences once") {
        let time = MediaCheckClock()
        let cache = try MediaRetransmissionCache(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true, sequence: 500)
        _ = try cache.insert(first, deadline: 1)
        try rejects { _ = try cache.insert(frame(2, sequence: 501), deadline: 1) }
        let initialACK = try MediaFeedback(kind: .decoded, header: first.header)
        try require(terminal(cache.handle(initialACK, estimatedRoundTrip: 0.005)) == [500], "IDR ACK lost capture sequence")
        try require(cache.handle(initialACK, estimatedRoundTrip: 0.005).isEmpty, "Duplicate ACK settled twice")
        _ = try cache.insert(frame(2, sequence: UInt32.max), deadline: 1)
        let third = try frame(3, sequence: 0)
        _ = try cache.insert(third, deadline: 1)
        let finalACK = try MediaFeedback(kind: .decoded, header: third.header)
        try require(terminal(cache.handle(finalACK, estimatedRoundTrip: 0.005)) == [UInt32.max, 0]
                    && cache.pendingFrameCount == 0 && cache.bufferedBytes == 0, "Cumulative decode did not repair a lost ACK")
    }

    run("Media repairs only requested fragments within deadline and bounded rounds") {
        let time = MediaCheckClock()
        let cache = try MediaRetransmissionCache(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true, bytes: 3_000)
        let parts = try cache.insert(first, deadline: 0.1)
        let nack = try MediaFeedback(kind: .nack, header: first.header, missingRanges: [.init(first: 1, count: 1)])
        let repair = cache.handle(nack, estimatedRoundTrip: 0.005)
        guard case .retransmit(let fragments)? = repair.first else { throw MediaCheckFailure(message: "Missing repair") }
        try require(fragments == [parts[1]], "Repair included unrequested fragments")
        try require(cache.handle(nack, estimatedRoundTrip: 0.005).isEmpty, "NACK duplicate bypassed repair pacing")
        time.now = 0.02
        try require(!cache.handle(nack, estimatedRoundTrip: 0.005).isEmpty, "Second bounded repair was suppressed")
        time.now = 0.04
        try require(cache.handle(nack, estimatedRoundTrip: 0.005).isEmpty, "Repair rounds were unbounded")
        time.now = 0.1
        try require(terminal(cache.expire()) == [77] && cache.requiresRecovery && cache.bufferedBytes == 0, "Expiry did not terminate sender credit")
        try require(cache.expire().isEmpty, "Expiry settled twice")
        try rejects { _ = try cache.insert(frame(2), deadline: 1) }
        _ = cache.replaceStream(nextStream)
        let fresh = try frame(1, idr: true, stream: nextStream)
        _ = try cache.insert(fresh, deadline: 0.15)
        let tooLate = try MediaFeedback(kind: .nack, header: fresh.header, missingRanges: [.init(first: 0, count: 1)])
        try require(cache.handle(tooLate, estimatedRoundTrip: 0.1).isEmpty, "Unfinishable repair consumed bandwidth")
    }

    run("Media epoch replacement settles all stale credits and ignores delayed feedback") {
        let cache = try MediaRetransmissionCache(stream: stream, clock: { 0 })
        let first = try frame(1, idr: true, sequence: 100)
        _ = try cache.insert(first, deadline: 1)
        try require(terminal(cache.replaceStream(nextStream)) == [100], "Replacement abandoned capture credit")
        try require(cache.replaceStream(nextStream).isEmpty, "Replacement settled an old credit twice")
        let current = try frame(1, idr: true, sequence: 200, stream: nextStream)
        _ = try cache.insert(current, deadline: 1)
        try require(cache.handle(MediaFeedback(kind: .decoded, header: first.header), estimatedRoundTrip: 0).isEmpty
                    && cache.pendingFrameCount == 1, "Old ACK released new epoch credit")
        let invalidRange = try MediaFeedback(kind: .nack, header: current.header, missingRanges: [.init(first: 100, count: 1)])
        try require(cache.handle(invalidRange, estimatedRoundTrip: 0).isEmpty, "Out-of-range NACK was serviced")
    }

    run("Media repeated cumulative decode feedback recovers feedback loss without replaying video") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let initial = try frame(1, idr: true)
        _ = try receiver.receive(MediaFragment.fragment(frame: initial)[0])
        _ = receiver.decoded(initial.header, success: true)
        time.now = 0.021
        try require(feedback(receiver.poll(), .decoded).map(\.header) == [initial.header], "Lost decode ACK had no repeated status")
        try require(feedback(receiver.poll(), .decoded).isEmpty, "Repeated ACK was not bounded")
    }

    run("Media complete TCP frames use the same IDR, ordered decode and bounded lifetime contract") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true)
        let second = try frame(2)
        try require(ready(try receiver.receive(second)).isEmpty, "Complete TCP P frame bypassed IDR")
        try require(ready(try receiver.receive(first)).map(\.header.frameID) == [1], "TCP IDR did not enter decode")
        try require(ready(try receiver.receive(first)).isEmpty, "Repeated complete frame decoded twice")
        try require(ready(receiver.decoded(first.header, success: true)).map(\.header.frameID) == [2], "TCP did not resume reference order")
        time.now = 0.16
        try require(feedback(receiver.poll(), .expired).map(\.header.frameID) == [2], "Slow TCP decode escaped its finite epoch lifetime")
        try require(receiver.decoded(second.header, success: true).isEmpty, "Late decode revived an expired epoch")
    }
}
