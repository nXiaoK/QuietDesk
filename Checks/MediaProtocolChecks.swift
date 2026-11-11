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

    run("HEVC media frames check two-byte NAL headers and require VPS, SPS and PPS on keyframes only") {
        func unit(_ type: UInt8, tid: UInt8 = 1) -> Data { Data([type << 1, tid, 0xAA, 0xBB]) }
        func avcc(_ units: [Data]) -> Data { units.reduce(into: Data()) { $0.put(UInt32($1.count)); $0.append($1) } }
        let keyframe = VideoPacket(sequence: 1, codec: .hevc, vps: unit(32), sps: unit(33), pps: unit(34), avcc: avcc([unit(39), unit(20)]))
        let predicted = VideoPacket(sequence: 2, codec: .hevc, vps: Data(), sps: Data(), pps: Data(), avcc: avcc([unit(1)]))
        try require(try MediaFrame.containsIDR(keyframe.avcc, codec: .hevc), "An HEVC IDR was not recognised")
        try require(try !MediaFrame.containsIDR(predicted.avcc, codec: .hevc), "An HEVC trailing picture was taken for an IDR")
        for type: UInt8 in [16, 19, 21] {
            try require(try MediaFrame.containsIDR(avcc([unit(type)]), codec: .hevc), "HEVC random access type \(type) was not recognised")
        }
        let frame = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 1, isIDR: true), packet: keyframe)
        let decoded = try MediaFrame.decode(frame.encode())
        try require(decoded.packet.codec == .hevc && decoded.packet.vps == keyframe.vps && decoded.packet.sps == keyframe.sps
                    && decoded.packet.pps == keyframe.pps && decoded.packet.avcc == keyframe.avcc, "The HEVC envelope changed the frame")
        _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 2, isIDR: false), packet: predicted)
        try rejects { _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 2, isIDR: true), packet: predicted) }
        try rejects { _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 1, isIDR: false), packet: keyframe) }
        for (vps, sps, pps) in [(Data(), unit(33), unit(34)), (unit(33), unit(32), unit(34)), (unit(32), unit(33), Data([0x44]))] {
            try rejects { _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 1, isIDR: true),
                                             packet: VideoPacket(sequence: 1, codec: .hevc, vps: vps, sps: sps, pps: pps, avcc: keyframe.avcc)) }
        }
        try rejects { _ = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 2, isIDR: false),
                                         packet: VideoPacket(sequence: 2, codec: .hevc, vps: unit(32), sps: Data(), pps: Data(), avcc: predicted.avcc)) }
        for invalid in [Data([0x80 | 0x28, 1]), Data([0x28, 0]), Data([0x28])] {
            try rejects { _ = try MediaFrame.containsIDR(avcc([invalid]), codec: .hevc) }
        }
        let fragments = try MediaFragment.fragment(frame: MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 3, isIDR: true),
            packet: VideoPacket(sequence: 3, codec: .hevc, vps: unit(32), sps: unit(33), pps: unit(34),
                                avcc: avcc([Data([20 << 1, 1]) + Data(repeating: 0x5A, count: 6_000)]))))
        try require(fragments.count > 3 && fragments.allSatisfy { $0.encode().count <= 1_100 }, "HEVC fragments exceeded the datagram budget")
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
        time.now = 2.001
        try require(!feedback(receiver.poll(), .expired).isEmpty, "Repeated fragment extended frame lifetime")
    }

    run("Fragment wait stays measurable after repeated, late and expired fragments") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        // A stable stream sees repairs and late copies on every frame; none may use up later measurements.
        for id in UInt64(1)...6 {
            let current = try frame(id, idr: id == 1, bytes: 3_000)
            let parts = try MediaFragment.fragment(frame: current)
            time.now = Double(id)
            _ = try receiver.receive(parts[0])
            try require(receiver.collectionDuration(of: current.header) == nil, "Incomplete frame \(id) reported a wait")
            time.now = Double(id) + 0.04
            var events: [MediaReceiveEvent] = []
            for fragment in parts.dropFirst() { events += try receiver.receive(fragment) }
            try require(feedback(events, .reassembled).count == 1, "Frame \(id) did not complete")
            try require(receiver.collectionDuration(of: current.header).map { abs($0 - 0.04) < 0.000_001 } == true,
                        "Frame \(id) wait was not measured from its first fragment")
            try require(feedback(try receiver.receive(parts[1]), .reassembled).isEmpty, "Repeated fragment completed frame \(id) again")
            _ = receiver.decoded(current.header, success: true)
            try require(receiver.collectionDuration(of: current.header) == nil, "Decoded frame \(id) kept its timing")
            try require(feedback(try receiver.receive(parts[0]), .reassembled).isEmpty
                        && receiver.collectionDuration(of: current.header) == nil, "Late fragment revived frame \(id) timing")
        }
        let whole = try frame(7, bytes: 3_000)
        try require(feedback(try receiver.receive(whole), .reassembled).count == 1
                    && receiver.collectionDuration(of: whole.header) == nil, "Whole TCP frame reported a fragment wait")
        _ = receiver.decoded(whole.header, success: true)
        let lost = try frame(8, bytes: 3_000)
        _ = try receiver.receive(MediaFragment.fragment(frame: lost)[0])
        time.now += 1
        try require(!feedback(receiver.poll(), .expired).isEmpty && receiver.collectionDuration(of: lost.header) == nil,
                    "Expired frame kept its timing")
    }

    run("A paced 512 KiB IDR does not NACK fragments still ahead of receiving progress") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let initial = try frame(1, idr: true, bytes: 512 * 1024)
        let parts = try MediaFragment.fragment(frame: initial)
        var completed: [MediaFrame] = []
        for (index, fragment) in parts.enumerated() {
            time.now = Double(index) * 0.001
            completed += ready(try receiver.receive(fragment))
            time.now += 0.0005
            try require(feedback(receiver.poll(), .nack).isEmpty,
                        "Continuous pacing requested an unsent tail at fragment \(index)")
        }
        try require(completed.count == 1 && completed[0].packet.avcc == initial.packet.avcc,
                    "Paced IDR did not reconstruct its complete bytes")
        try require(feedback(receiver.decoded(initial.header, success: true), .decoded).count == 1,
                    "A complete paced IDR did not settle decode acknowledgement")
    }

    run("A later received fragment exposes an early hole without requesting the unseen tail") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let parts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 8_192))
        _ = try receiver.receive(parts[0])
        time.now = 0.001; _ = try receiver.receive(parts[2])
        time.now = 0.002; _ = try receiver.receive(parts[3])
        time.now = 0.004
        let nacks = feedback(receiver.poll(), .nack)
        try require(nacks.count == 1 && nacks[0].missingRanges == [.init(first: 1, count: 1)],
                    "Reordering did not reveal only the hole below the highest received fragment")
        time.now = 0.009; _ = try receiver.receive(parts[1])
        time.now = 0.015
        try require(feedback(receiver.poll(), .nack).isEmpty,
                    "A new hole-filling fragment was not counted as real receiving progress")
    }

    run("Loss counts only fragments that missed the reorder window, including frames that expired") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true, bytes: 8_192)
        let parts = try MediaFragment.fragment(frame: first)
        // A brief reordering inside the window is not loss.
        _ = try receiver.receive(parts[1]); _ = try receiver.receive(parts[0])
        _ = try receiver.receive(parts[3])
        time.now = 0.004
        try require(feedback(receiver.poll(), .nack).count == 1, "The hole below received progress was not requested")
        time.now = 0.006
        for part in [parts[2]] + Array(parts[4...]) { _ = try receiver.receive(part) }
        let repaired = receiver.takeFragmentCounts()
        try require(repaired.settled == parts.count && repaired.lost == 1, "A repaired fragment was not counted once: \(repaired)")
        try require(receiver.takeFragmentCounts() == (0, 0), "Counts were not cleared after reading")
        _ = receiver.decoded(first.header, success: true)
        let clean = try MediaFragment.fragment(frame: frame(2, bytes: 4_096))
        for part in clean { _ = try receiver.receive(part) }
        try require(receiver.takeFragmentCounts() == (clean.count, 0), "An in-order frame reported loss")
        let stalled = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let lost = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 8_192))
        time.now = 1
        _ = try stalled.receive(lost[0]); _ = try stalled.receive(lost[2])
        time.now = 10
        _ = stalled.poll()
        try require(stalled.requiresRecovery && stalled.takeFragmentCounts() == (lost.count, lost.count - 2),
                    "Fragments of an expired frame were not counted as lost")
        let dropped = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let inFlight = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 8_192))
        time.now = 20
        _ = try dropped.receive(inFlight[0]); _ = try dropped.receive(inFlight[2])
        dropped.abandon()
        try require(dropped.takeFragmentCounts() == (3, 1), "Abandoning counted a tail that may still be arriving")
        let stopped = try MediaFrameReassembler(stream: stream, clock: { time.now })
        _ = try stopped.receive(inFlight[inFlight.count - 1])
        time.now = 21
        stopped.abandon(); stopped.abandon()
        try require(stopped.takeFragmentCounts() == (inFlight.count, inFlight.count - 1),
                    "A stalled frame abandoned before expiry was not counted once")
        let reliable = try MediaFrameReassembler(stream: stream)
        _ = try reliable.receive(frame(1, idr: true, bytes: 8_192))
        try require(reliable.takeFragmentCounts() == (0, 0), "A complete TCP envelope was counted as UDP fragments")
        // A paced frame whose tail arrives after a tail NACK without any reordering hole is not packet loss.
        let paced = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let pacedParts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 8_192))
        time.now = 30
        _ = try paced.receive(pacedParts[0]); _ = try paced.receive(pacedParts[1])
        time.now = 30.015
        try require(feedback(paced.poll(), .nack).count == 1, "Tail probe did not fire after progress paused")
        for part in pacedParts.dropFirst(2) {
            time.now += 0.001
            _ = try paced.receive(part)
            _ = try paced.receive(part, isRepair: true)
        }
        try require(paced.takeFragmentCounts() == (pacedParts.count, 0),
                    "In-order paced tail fragments after a tail NACK were miscounted as lost")
    }

    run("Loss window reports a five-second share only with enough fragments") {
        var window = MediaLossWindow()
        window.add(settled: 10, lost: 1, at: 0)
        try require(window.fraction(at: 0.5) == nil, "Too few fragments produced a loss figure")
        window.add(settled: 90, lost: 9, at: 1)
        try require(abs((window.fraction(at: 1) ?? -1) - 0.1) < 1e-9, "The window did not combine recent fragments")
        window.add(settled: 50, lost: 80, at: 2)
        try require(abs((window.fraction(at: 2) ?? -1) - 60.0 / 150) < 1e-9, "Lost fragments exceeded settled fragments")
        try require(abs((window.fraction(at: 5.5) ?? -1) - 59.0 / 140) < 1e-9, "Entries older than five seconds were kept")
        try require(window.fraction(at: 7.5) == nil, "An idle window kept reporting stale loss")
        window.add(settled: 0, lost: 3, at: 8)
        try require(window.fraction(at: 8) == nil, "Loss without fragments was recorded")
    }

    run("A lost final fragment becomes repairable after receiving progress actually stalls") {
        let time = MediaCheckClock()
        let limits = MediaBufferLimits(reorderDelay: 0.02, nackInterval: 0.005)
        let receiver = try MediaFrameReassembler(stream: stream, limits: limits, clock: { time.now })
        let sender = try MediaRetransmissionCache(stream: stream, limits: limits, clock: { time.now })
        let initial = try frame(1, idr: true, bytes: 8_192)
        let parts = try sender.insert(initial, deadline: 1)
        for (index, fragment) in parts.dropLast().enumerated() {
            time.now = Double(index) * 0.001
            _ = try receiver.receive(fragment, isRepair: index == 0) // Unsolicited repair label.
        }
        let lastProgress = time.now
        time.now = lastProgress + 0.019
        try require(feedback(receiver.poll(), .nack).isEmpty, "Tail repair ignored the longer reorder grace")
        time.now = lastProgress + 0.021
        let nacks = feedback(receiver.poll(), .nack)
        try require(nacks.count == 1 && nacks[0].missingRanges == [.init(first: UInt16(parts.count - 1), count: 1)],
                    "A stopped tail was never repaired or included already received fragments")
        guard case .retransmit(let repairs)? = sender.handle(nacks[0], estimatedRoundTrip: 0.01).first,
              repairs.count == 1 else { throw MediaCheckFailure(message: "Sender did not repair the tail") }
        let recovered = ready(try receiver.receive(repairs[0], isRepair: true))
        _ = try receiver.receive(repairs[0], isRepair: true)
        try require(recovered.count == 1 && recovered[0].packet.avcc == initial.packet.avcc
                    && receiver.takeFragmentCounts() == (parts.count, 1),
                    "A genuine tail repair must reconstruct the IDR and count exactly one lost fragment")
        try require(feedback(receiver.decoded(initial.header, success: true), .decoded).count == 1
                    && receiver.pendingFrameCount == 0 && receiver.bufferedBytes == 0,
                    "Tail recovery could not complete the decode contract and release its buffer")
    }

    run("Duplicate fragments cannot postpone tail repair or extend the original frame deadline") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let parts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 8_192))
        _ = try receiver.receive(parts[0])
        time.now = 0.001; _ = try receiver.receive(parts[1])
        time.now = 0.008; _ = try receiver.receive(parts[1])
        time.now = 0.012
        let nacks = feedback(receiver.poll(), .nack)
        try require(nacks.count == 1 && nacks[0].missingRanges == [.init(first: 2, count: UInt16(parts.count - 2))],
                    "A duplicate fragment postponed the stalled tail's repair")
        time.now = 1.999; _ = try receiver.receive(parts[1])
        time.now = 2.001
        try require(feedback(receiver.poll(), .expired).count == 1 && receiver.requiresRecovery
                    && receiver.bufferedBytes == 0 && receiver.pendingFrameCount == 0,
                    "Duplicate traffic extended the finite frame lifetime")
        try require(try receiver.receive(parts[parts.count - 1]).isEmpty, "A late tail revived an expired reference chain")
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

    run("Completed UDP frames keep a separate decode budget without extending incomplete frames") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream,
            limits: MediaBufferLimits(completedFrameTimeToLive: 5), clock: { time.now })
        let first = try frame(1, idr: true)
        _ = try receiver.receive(first)
        _ = receiver.decoded(first.header, success: true)
        let second = try frame(2)
        for fragment in try MediaFragment.fragment(frame: second) { _ = try receiver.receive(fragment) }
        time.now = 0.25
        try require(!receiver.requiresRecovery && feedback(receiver.poll(), .expired).isEmpty,
                    "A complete frame inherited the UDP delivery deadline")
        try require(feedback(receiver.decoded(second.header, success: true), .decoded).count == 1,
                    "A complete frame could not acknowledge its delayed decode")
        let parts = try MediaFragment.fragment(frame: frame(3, bytes: 3_000))
        _ = try receiver.receive(parts[0])
        time.now = 0.41
        try require(feedback(receiver.poll(), .expired).count == 1 && receiver.requiresRecovery,
                    "The decode budget prolonged an incomplete UDP frame")
    }

    run("Complete frames and reassembly acknowledgements cannot extend a stalled decoder indefinitely") {
        let time = MediaCheckClock()
        let limits = MediaBufferLimits(completedFrameTimeToLive: 5)
        let cache = try MediaRetransmissionCache(stream: stream, limits: limits, clock: { time.now })
        let receiver = try MediaFrameReassembler(stream: stream, limits: limits, clock: { time.now })
        let first = try frame(1, idr: true)
        _ = try cache.insert(first, deadline: 1)
        _ = cache.handle(try MediaFeedback(kind: .decoded, header: first.header), estimatedRoundTrip: 0.01)
        let second = try frame(2)
        _ = try cache.insert(second, deadline: 0.2)
        let assembled = try MediaFeedback(kind: .reassembled, header: second.header)
        _ = cache.handle(assembled, estimatedRoundTrip: 0.01)
        _ = try receiver.receive(first)
        _ = receiver.decoded(first.header, success: true)
        _ = try receiver.receive(second)
        time.now = 0.25
        try require(cache.expire().isEmpty && !cache.requiresRecovery, "Reassembled sender credit expired before decoding")
        time.now = 4.9
        _ = cache.handle(assembled, estimatedRoundTrip: 0.01)
        _ = try receiver.receive(second)
        time.now = 5.01
        try require(terminal(cache.expire()) == [77] && cache.requiresRecovery,
                    "Repeated reassembly ACK prolonged sender credit")
        try require(feedback(receiver.poll(), .expired).count == 1 && receiver.requiresRecovery,
                    "Repeated complete frame prolonged the decoder deadline")
    }

    run("Media IDR assembly and initial gap have a separate finite recovery budget") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let parts = try MediaFragment.fragment(frame: frame(1, idr: true, bytes: 3_000))
        _ = try receiver.receive(parts[0])
        time.now = 0.16
        try require(feedback(receiver.poll(), .expired).isEmpty, "A recovery IDR inherited the short P-frame budget")
        time.now = 2.001
        try require(feedback(receiver.poll(), .expired).count == 1, "IDR reassembly had no finite lifetime")
        receiver.replaceStream(nextStream)
        _ = try receiver.receive(frame(2, idr: true, stream: nextStream))
        time.now = 2.2
        try require(feedback(receiver.poll(), .expired).isEmpty, "Initial missing IDR used the short gap budget")
        time.now = 4.002
        try require(feedback(receiver.poll(), .expired).map(\.header.frameID) == [1], "Initial IDR gap did not expire")
    }

    run("Media whole-frame expiry can retire a missing native IDR without knowing its frame flag") {
        let cache = try MediaRetransmissionCache(stream: stream, clock: { 0 })
        let first = try frame(1, idr: true, sequence: 10)
        _ = try cache.insert(first, deadline: 2)
        _ = cache.handle(try MediaFeedback(kind: .decoded, header: first.header), estimatedRoundTrip: 0)
        let second = try frame(2, idr: true, sequence: 11)
        _ = try cache.insert(second, deadline: 2)
        let unknownFlag = MediaFrameHeader(stream: stream, frameID: 2, isIDR: false)
        let events = cache.handle(try MediaFeedback(kind: .expired, header: unknownFlag), estimatedRoundTrip: 0)
        try require(terminal(events) == [11] && cache.requiresRecovery, "Missing-frame status could not retire an unknown IDR")
        try rejects { _ = try MediaFrameReassembler(stream: stream, limits: MediaBufferLimits(keyFrameTimeToLive: .nan)) }
        try rejects { _ = try MediaFrameReassembler(stream: stream, limits: MediaBufferLimits(completedFrameTimeToLive: .infinity)) }
        try rejects { _ = try MediaFrameReassembler(stream: stream, limits: MediaBufferLimits(completedFrameTimeToLive: 0)) }
        try rejects { _ = try MediaFrameReassembler(stream: stream, firstFrameID: UInt64.max) }
        try rejects { _ = try MediaRetransmissionCache(stream: stream, firstFrameID: UInt64.max) }
    }

    run("Media reassembler extends P-frame TTL while unique paced fragments actively arrive and updates RTT limits") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream,
            limits: MediaBufferLimits(frameTimeToLive: 0.15, nackInterval: 0.02), clock: { time.now })
        let first = try frame(1, idr: true)
        _ = try receiver.receive(first)
        _ = receiver.decoded(first.header, success: true)
        let pacedPredicted = try frame(2, bytes: 12_000)
        let parts = try MediaFragment.fragment(frame: pacedPredicted)
        try require(parts.count >= 10, "Fixture did not produce enough fragments for paced arrival")
        var completed: [MediaFrame] = []
        for (index, part) in parts.enumerated() {
            time.now = Double(index) * 0.022
            completed += ready(try receiver.receive(part))
        }
        try require(completed.count == 1 && !receiver.requiresRecovery,
                    "A large P-frame actively making progress across 200 ms expired prematurely")
        _ = receiver.decoded(pacedPredicted.header, success: true)
        receiver.updateLimits(MediaBufferLimits(frameTimeToLive: 0.45, nackInterval: 0.02))
        receiver.updateLimits(MediaBufferLimits(frameTimeToLive: .nan))
        let thirdParts = try MediaFragment.fragment(frame: frame(3, bytes: 3_000))
        _ = try receiver.receive(thirdParts[0])
        time.now += 0.30
        try require(feedback(receiver.poll(), .expired).isEmpty && !receiver.requiresRecovery,
                    "Updated RTT-derived frameTimeToLive was not applied")
        time.now += 0.20
        try require(feedback(receiver.poll(), .expired).count == 1 && receiver.requiresRecovery,
                    "Stalled P-frame did not expire after updated frameTimeToLive")
    }

    run("Wholly missing single-fragment P-frame and unknown-flag IDR repair via NACK without epoch stall") {
        let time = MediaCheckClock()
        let receiver = try MediaFrameReassembler(stream: stream, clock: { time.now })
        let sender = try MediaRetransmissionCache(stream: stream, clock: { time.now })
        let first = try frame(1, idr: true)
        let firstParts = try sender.insert(first, deadline: 1)
        _ = try receiver.receive(firstParts[0])
        let firstDecoded = receiver.decoded(first.header, success: true)
        _ = sender.handle(feedback(firstDecoded, .decoded)[0], estimatedRoundTrip: 0.005)

        // Frame 2 (1 fragment) is dropped in transit; frame 3 arrives at t = 0.010.
        time.now = 0.010
        let second = try frame(2, sequence: 102)
        let third = try frame(3, sequence: 103)
        let secondParts = try sender.insert(second, deadline: 1)
        let thirdParts = try sender.insert(third, deadline: 1)
        try require(secondParts.count == 1 && thirdParts.count == 1, "Desktop P-frame fixture exceeded 1 fragment")
        try require(ready(try receiver.receive(thirdParts[0])).isEmpty, "Frame 3 crossed missing frame 2")
        try require(receiver.nextPollDelay.map { abs($0 - 0.003) < 1e-6 } == true, "Missing frame did not arm reorder poll delay")
        time.now = 0.012
        try require(feedback(receiver.poll(), .nack).isEmpty, "Missing frame NACK fired before reorderDelay")
        time.now = 0.0135
        let nacks = feedback(receiver.poll(), .nack)
        try require(nacks.count == 1 && nacks[0].header.frameID == 2
                    && nacks[0].missingRanges == [.init(first: 0, count: 1)],
                    "Wholly missing 1-fragment P-frame was not NACKed")
        guard case .retransmit(let repairs)? = sender.handle(nacks[0], estimatedRoundTrip: 0.005).first,
              repairs == secondParts else {
            throw MediaCheckFailure(message: "Sender did not retransmit wholly missing 1-fragment P-frame")
        }
        time.now = 0.019
        let recoveredSecond = ready(try receiver.receive(repairs[0], isRepair: true))
        try require(recoveredSecond.map(\.header.frameID) == [2] && !receiver.requiresRecovery,
                    "Repaired 1-fragment P-frame did not immediately unblock decoding")
        let afterSecond = receiver.decoded(second.header, success: true)
        try require(ready(afterSecond).map(\.header.frameID) == [3], "Buffered frame 3 did not release after frame 2 repair")
        _ = receiver.decoded(third.header, success: true)
        try require(receiver.takeFragmentCounts() == (3, 1), "Repaired 1-fragment gap did not count 1 lost of 3 settled fragments")
        _ = sender.handle(try MediaFeedback(kind: .decoded, header: third.header), estimatedRoundTrip: 0.005)

        // Frame 4 is a mid-stream native IDR whose single packet is lost before frame 5 arrives.
        time.now = 0.030
        let fourthIDR = try frame(4, idr: true, sequence: 104)
        let fifth = try frame(5, sequence: 105)
        let fourthParts = try sender.insert(fourthIDR, deadline: 1)
        let fifthParts = try sender.insert(fifth, deadline: 1)
        _ = try receiver.receive(fifthParts[0])
        time.now = 0.034
        let idrNacks = feedback(receiver.poll(), .nack)
        try require(idrNacks.count == 1 && idrNacks[0].header.frameID == 4 && !idrNacks[0].header.isIDR,
                    "Receiver did not probe unknown missing frame 4")
        guard case .retransmit(let idrRepairs)? = sender.handle(idrNacks[0], estimatedRoundTrip: 0.005).first,
              idrRepairs == fourthParts else {
            throw MediaCheckFailure(message: "Sender rejected NACK for missing native IDR with unknown flag")
        }
        try require(ready(try receiver.receive(idrRepairs[0], isRepair: true)).map(\.header.frameID) == [4],
                    "Repaired mid-stream IDR did not enter decode")
    }
}
