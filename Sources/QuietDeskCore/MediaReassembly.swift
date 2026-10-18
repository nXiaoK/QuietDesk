import Foundation

public struct MediaBufferLimits: Sendable {
    public let maximumFrameBytes: Int
    public let maximumBufferedBytes: Int
    public let maximumFrames: Int
    public let frameTimeToLive: TimeInterval
    public let keyFrameTimeToLive: TimeInterval
    public let reorderDelay: TimeInterval
    public let nackInterval: TimeInterval
    public let acknowledgementRepeatInterval: TimeInterval
    public let maximumRepairRounds: Int
    public let repairSafetyMargin: TimeInterval

    public init(maximumFrameBytes: Int = MediaFrame.maximumPacketBytes,
                maximumBufferedBytes: Int = 32 * 1_024 * 1_024, maximumFrames: Int = 3,
                frameTimeToLive: TimeInterval = 0.15, keyFrameTimeToLive: TimeInterval = 2.0,
                reorderDelay: TimeInterval = 0.003,
                nackInterval: TimeInterval = 0.01, acknowledgementRepeatInterval: TimeInterval = 0.02,
                maximumRepairRounds: Int = 2, repairSafetyMargin: TimeInterval = 0.005) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumFrames = maximumFrames
        self.frameTimeToLive = frameTimeToLive
        self.keyFrameTimeToLive = keyFrameTimeToLive
        self.reorderDelay = reorderDelay
        self.nackInterval = nackInterval
        self.acknowledgementRepeatInterval = acknowledgementRepeatInterval
        self.maximumRepairRounds = maximumRepairRounds
        self.repairSafetyMargin = repairSafetyMargin
    }

    fileprivate func validate() throws {
        guard (1...MediaFrame.maximumPacketBytes).contains(maximumFrameBytes), maximumBufferedBytes > 0,
              (1...64).contains(maximumFrames), frameTimeToLive.isFinite, frameTimeToLive > 0,
              keyFrameTimeToLive.isFinite, keyFrameTimeToLive > 0,
              reorderDelay.isFinite, reorderDelay >= 0, reorderDelay < min(frameTimeToLive, keyFrameTimeToLive),
              nackInterval.isFinite, nackInterval > 0,
              acknowledgementRepeatInterval.isFinite, acknowledgementRepeatInterval > 0,
              (0...16).contains(maximumRepairRounds), repairSafetyMargin.isFinite, repairSafetyMargin >= 0 else {
            throw DeskError.invalid("媒体缓存或时限配置无效")
        }
    }
}

public enum MediaReceiveEvent: Sendable {
    case frameReady(MediaFrame)
    case feedback(MediaFeedback)
    case recoveryRequired(MediaFrameHeader)
}

// Call on one media queue, and only after transport authentication. Epoch changes are local decisions.
public final class MediaFrameReassembler {
    public private(set) var stream: MediaStreamID
    public private(set) var requiresRecovery = false
    public private(set) var bufferedBytes = 0
    public var pendingFrameCount: Int { assemblies.count }
    private let limits: MediaBufferLimits
    private let clock: () -> TimeInterval
    private var lastNow: TimeInterval
    private var expectedFrameID: UInt64
    private var waitingForFirstIDR = true
    private var awaitingDecode: MediaFrameHeader?
    private var gapStartedAt: TimeInterval?
    private var assemblies: [UInt64: Assembly] = [:]
    private var lastDecoded: MediaFrameHeader?
    private var lastAcknowledgementAt: TimeInterval?

    private final class Assembly {
        let header: MediaFrameHeader
        let totalBytes: Int
        let fragmentCount: Int
        let firstReceivedAt: TimeInterval
        var lastNackAt: TimeInterval?
        var bytes: Data
        var received: [Bool]
        var receivedCount = 0
        var frame: MediaFrame?

        init(_ fragment: MediaFragment, now: TimeInterval) {
            header = fragment.header
            totalBytes = fragment.frameBytes
            fragmentCount = Int(fragment.fragmentCount)
            firstReceivedAt = now
            bytes = Data(count: totalBytes)
            received = Array(repeating: false, count: fragmentCount)
        }

        init(_ frame: MediaFrame, bytes: Data, now: TimeInterval) {
            header = frame.header
            totalBytes = bytes.count
            fragmentCount = (bytes.count + MediaFragment.maximumPayloadBytes - 1) / MediaFragment.maximumPayloadBytes
            firstReceivedAt = now
            self.bytes = bytes
            received = Array(repeating: true, count: fragmentCount)
            receivedCount = fragmentCount
            self.frame = frame
        }

        func missingRanges() -> [MediaFragmentRange] {
            var ranges: [MediaFragmentRange] = []
            var index = 0
            while index < received.count, ranges.count < MediaFeedback.maximumMissingRanges {
                if received[index] { index += 1; continue }
                let first = index
                while index < received.count, !received[index] { index += 1 }
                ranges.append(MediaFragmentRange(first: UInt16(first), count: UInt16(index - first)))
            }
            return ranges
        }
    }

    public init(stream: MediaStreamID, firstFrameID: UInt64 = 1, limits: MediaBufferLimits = .init(),
                clock: @escaping () -> TimeInterval = { SessionClock.now }) throws {
        try limits.validate()
        let now = clock()
        guard now.isFinite, firstFrameID < UInt64.max else { throw DeskError.invalid("媒体时钟或初始帧号无效") }
        self.stream = stream
        self.expectedFrameID = firstFrameID
        self.limits = limits
        self.clock = clock
        lastNow = now
    }

    public func replaceStream(_ stream: MediaStreamID, firstFrameID: UInt64 = 1) {
        // A fresh epoch starts at an IDR. Keep the previous valid image outside this reassembler.
        self.stream = stream
        expectedFrameID = firstFrameID
        assemblies.removeAll()
        bufferedBytes = 0
        awaitingDecode = nil
        gapStartedAt = nil
        waitingForFirstIDR = true
        requiresRecovery = firstFrameID == UInt64.max
        lastDecoded = nil
        lastAcknowledgementAt = nil
    }

    public func receive(_ fragment: MediaFragment) throws -> [MediaReceiveEvent] {
        guard fragment.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        if fragment.header.frameID < expectedFrameID {
            if let lastDecoded { events.append(.feedback(try MediaFeedback(kind: .decoded, header: lastDecoded))) }
            return events
        }
        let distance = fragment.header.frameID - expectedFrameID
        guard distance < UInt64(limits.maximumFrames), fragment.header.frameID < UInt64.max,
              fragment.frameBytes <= limits.maximumFrameBytes else {
            return events + invalidate(at: fragment.header)
        }
        let assembly: Assembly
        if let existing = assemblies[fragment.header.frameID] {
            guard existing.header == fragment.header, existing.totalBytes == fragment.frameBytes,
                  existing.fragmentCount == Int(fragment.fragmentCount) else {
                _ = invalidate(at: fragment.header)
                throw DeskError.invalid("同一媒体帧的分片元数据冲突")
            }
            assembly = existing
        } else {
            guard assemblies.count < limits.maximumFrames,
                  fragment.frameBytes <= limits.maximumBufferedBytes - bufferedBytes else {
                return events + invalidate(at: fragment.header)
            }
            assembly = Assembly(fragment, now: now)
            assemblies[fragment.header.frameID] = assembly
            bufferedBytes += fragment.frameBytes
        }
        let index = Int(fragment.fragmentIndex)
        let start = index * MediaFragment.maximumPayloadBytes
        let range = start..<(start + fragment.payload.count)
        if assembly.received[index] {
            guard assembly.bytes.subdata(in: range) == fragment.payload else {
                _ = invalidate(at: fragment.header)
                throw DeskError.invalid("重复媒体分片内容冲突")
            }
        } else {
            assembly.bytes.replaceSubrange(range, with: fragment.payload)
            assembly.received[index] = true
            assembly.receivedCount += 1
            if assembly.receivedCount == assembly.fragmentCount {
                do {
                    assembly.frame = try MediaFrame(header: assembly.header, packetBytes: assembly.bytes)
                } catch {
                    _ = invalidate(at: fragment.header)
                    throw error
                }
                events.append(.feedback(try MediaFeedback(kind: .reassembled, header: assembly.header)))
            }
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    // TCP already provides a complete envelope, but reference ordering and epoch fences remain identical.
    public func receive(_ frame: MediaFrame) throws -> [MediaReceiveEvent] {
        guard frame.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        if frame.header.frameID < expectedFrameID {
            if let lastDecoded { events.append(.feedback(try MediaFeedback(kind: .decoded, header: lastDecoded))) }
            return events
        }
        let bytes = frame.packetBytes
        guard frame.header.frameID - expectedFrameID < UInt64(limits.maximumFrames),
              frame.header.frameID < UInt64.max, bytes.count <= limits.maximumFrameBytes else {
            return events + invalidate(at: frame.header)
        }
        if let existing = assemblies[frame.header.frameID] {
            guard existing.header == frame.header, existing.totalBytes == bytes.count,
                  existing.frame != nil, existing.bytes == bytes else {
                _ = invalidate(at: frame.header)
                throw DeskError.invalid("重复完整媒体帧内容冲突")
            }
        } else {
            guard assemblies.count < limits.maximumFrames, bytes.count <= limits.maximumBufferedBytes - bufferedBytes else {
                return events + invalidate(at: frame.header)
            }
            assemblies[frame.header.frameID] = Assembly(frame, bytes: bytes, now: now)
            bufferedBytes += bytes.count
            events.append(.feedback(try MediaFeedback(kind: .reassembled, header: frame.header)))
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    public func poll() -> [MediaReceiveEvent] {
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        for id in assemblies.keys.sorted() {
            guard let assembly = assemblies[id], assembly.frame == nil,
                  now - assembly.firstReceivedAt >= limits.reorderDelay,
                  assembly.lastNackAt.map({ now - $0 >= limits.nackInterval }) ?? true else { continue }
            let missing = assembly.missingRanges()
            if !missing.isEmpty, let feedback = try? MediaFeedback(kind: .nack, header: assembly.header, missingRanges: missing) {
                assembly.lastNackAt = now
                events.append(.feedback(feedback))
            }
        }
        if let lastDecoded, lastAcknowledgementAt.map({ now - $0 >= limits.acknowledgementRepeatInterval }) ?? true,
           let feedback = try? MediaFeedback(kind: .decoded, header: lastDecoded) {
            lastAcknowledgementAt = now
            events.append(.feedback(feedback))
        }
        return events
    }

    // decoded is cumulative only because frames are offered one at a time in reference order.
    public func decoded(_ header: MediaFrameHeader, success: Bool) -> [MediaReceiveEvent] {
        guard header.stream == stream, !requiresRecovery, awaitingDecode == header else { return [] }
        let now = currentTime()
        guard success else { return invalidate(at: header) }
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        if let removed = assemblies.removeValue(forKey: header.frameID) { bufferedBytes -= removed.totalBytes }
        awaitingDecode = nil
        waitingForFirstIDR = false
        lastDecoded = header
        lastAcknowledgementAt = now
        events.append(.feedback(try! MediaFeedback(kind: .decoded, header: header)))
        expectedFrameID += 1
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    private func currentTime() -> TimeInterval {
        let now = clock()
        if now.isFinite { lastNow = max(lastNow, now) }
        return lastNow
    }

    private func updateGap(at now: TimeInterval) {
        if assemblies[expectedFrameID] == nil, !assemblies.isEmpty {
            if gapStartedAt == nil { gapStartedAt = now }
        } else { gapStartedAt = nil }
    }

    private func readyFrame() -> [MediaReceiveEvent] {
        guard awaitingDecode == nil, let frame = assemblies[expectedFrameID]?.frame else { return [] }
        if waitingForFirstIDR, !frame.header.isIDR { return invalidate(at: frame.header) }
        awaitingDecode = frame.header
        return [.frameReady(frame)]
    }

    private func expire(at now: TimeInterval) -> [MediaReceiveEvent] {
        guard !requiresRecovery else { return [] }
        let gapTimeToLive = waitingForFirstIDR ? limits.keyFrameTimeToLive : limits.frameTimeToLive
        if let gapStartedAt, now - gapStartedAt >= gapTimeToLive {
            return invalidate(at: MediaFrameHeader(stream: stream, frameID: expectedFrameID, isIDR: waitingForFirstIDR))
        }
        if let oldest = assemblies.values.filter({
            now - $0.firstReceivedAt >= ($0.header.isIDR ? limits.keyFrameTimeToLive : limits.frameTimeToLive)
        })
            .min(by: { $0.header.frameID < $1.header.frameID }) {
            return invalidate(at: oldest.header)
        }
        return []
    }

    private func invalidate(at header: MediaFrameHeader) -> [MediaReceiveEvent] {
        guard !requiresRecovery else { return [] }
        requiresRecovery = true
        assemblies.removeAll()
        bufferedBytes = 0
        awaitingDecode = nil
        gapStartedAt = nil
        return [.feedback(try! MediaFeedback(kind: .expired, header: header)), .recoveryRequired(header)]
    }
}

public enum MediaFrameTerminalReason: Sendable { case decoded, expired, superseded }

public enum MediaSendEvent: Sendable {
    case retransmit([MediaFragment])
    case terminal(header: MediaFrameHeader, sequence: UInt32, reason: MediaFrameTerminalReason)
    case recoveryRequired(MediaFrameHeader)
}

// Deadlines are in this sender's clock domain, normally capture time plus a bounded media budget.
public final class MediaRetransmissionCache {
    public private(set) var stream: MediaStreamID
    public private(set) var requiresRecovery = false
    public private(set) var bufferedBytes = 0
    public var pendingFrameCount: Int { frames.count }
    private let limits: MediaBufferLimits
    private let clock: () -> TimeInterval
    private var lastNow: TimeInterval
    private var nextFrameID: UInt64
    private var nextPacketSequence: UInt64 = 1
    private var awaitingIDR: MediaFrameHeader?
    private var needsFirstIDR = true
    private var frames: [UInt64: CachedFrame] = [:]
    private var highestInserted: UInt64?

    private struct CachedFrame {
        let header: MediaFrameHeader
        let sequence: UInt32
        let fragments: [MediaFragment]
        let bytes: Int
        let deadline: TimeInterval
        var reassembled = false
        var repairRounds = 0
        var lastRepairAt: TimeInterval?
    }

    public init(stream: MediaStreamID, firstFrameID: UInt64 = 1, limits: MediaBufferLimits = .init(),
                clock: @escaping () -> TimeInterval = { SessionClock.now }) throws {
        try limits.validate()
        let now = clock()
        guard now.isFinite, firstFrameID < UInt64.max else { throw DeskError.invalid("媒体时钟或初始帧号无效") }
        self.stream = stream
        self.nextFrameID = firstFrameID
        self.limits = limits
        self.clock = clock
        lastNow = now
    }

    // On an insertion error after encoding, the caller must abandon that reference chain and replace the epoch.
    public func insert(_ frame: MediaFrame, deadline: TimeInterval) throws -> [MediaFragment] {
        let now = currentTime()
        guard !requiresRecovery, frame.header.stream == stream, frame.header.frameID == nextFrameID,
              nextFrameID < UInt64.max, awaitingIDR == nil,
              !needsFirstIDR || frame.header.isIDR, deadline.isFinite, deadline > now else {
            throw DeskError.invalid("媒体帧顺序、恢复屏障或截止时间无效")
        }
        let payloadBytes = frame.packetBytes.count
        guard payloadBytes <= limits.maximumFrameBytes else { throw DeskError.invalid("媒体帧超过缓存上限") }
        let count = (payloadBytes + MediaFragment.maximumPayloadBytes - 1) / MediaFragment.maximumPayloadBytes
        let bytes = payloadBytes + count * MediaFragment.encodedHeaderBytes
        guard frames.count < limits.maximumFrames, bytes <= limits.maximumBufferedBytes - bufferedBytes,
              nextPacketSequence < UInt64.max - UInt64(count) else {
            throw DeskError.invalid("媒体发送窗口或缓存已满")
        }
        let fragments = try MediaFragment.fragment(frame: frame, startingPacketSequence: nextPacketSequence)
        nextPacketSequence += UInt64(count)
        frames[frame.header.frameID] = CachedFrame(header: frame.header, sequence: frame.packet.sequence,
                                                 fragments: fragments, bytes: bytes, deadline: deadline)
        bufferedBytes += bytes
        nextFrameID += 1
        highestInserted = frame.header.frameID
        if needsFirstIDR { awaitingIDR = frame.header }
        return fragments
    }

    public func handle(_ feedback: MediaFeedback, estimatedRoundTrip: TimeInterval) -> [MediaSendEvent] {
        guard feedback.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        guard let inserted = highestInserted, feedback.header.frameID <= inserted else { return events }
        // A receiver detecting a wholly missing frame cannot know whether it happened to be an IDR.
        if feedback.kind != .expired, let cached = frames[feedback.header.frameID], cached.header != feedback.header { return events }
        switch feedback.kind {
        case .decoded:
            // Repeated cumulative decode status recovers a lost earlier ACK without retransmitting video.
            let confirmed = frames.keys.filter { $0 <= feedback.header.frameID }.sorted()
            for id in confirmed {
                if let frame = remove(id) {
                    events.append(.terminal(header: frame.header, sequence: frame.sequence, reason: .decoded))
                }
            }
            if let awaitingIDR, feedback.header.frameID >= awaitingIDR.frameID {
                self.awaitingIDR = nil
                needsFirstIDR = false
            }
        case .expired:
            if frames[feedback.header.frameID] != nil { events += invalidate(at: feedback.header) }
        case .reassembled:
            if var cached = frames[feedback.header.frameID] {
                cached.reassembled = true
                frames[feedback.header.frameID] = cached
            }
        case .nack:
            guard var cached = frames[feedback.header.frameID], !cached.reassembled,
                  estimatedRoundTrip.isFinite, estimatedRoundTrip >= 0,
                  now + estimatedRoundTrip + limits.repairSafetyMargin < cached.deadline,
                  cached.repairRounds < limits.maximumRepairRounds,
                  cached.lastRepairAt.map({ now - $0 >= max(limits.nackInterval, estimatedRoundTrip) }) ?? true else { return events }
            var fragments: [MediaFragment] = []
            for range in feedback.missingRanges {
                let end = Int(range.first) + Int(range.count)
                guard end <= cached.fragments.count else { return events }
                fragments += cached.fragments[Int(range.first)..<end]
            }
            guard !fragments.isEmpty else { return events }
            cached.repairRounds += 1
            cached.lastRepairAt = now
            frames[feedback.header.frameID] = cached
            events.append(.retransmit(fragments))
        }
        return events
    }

    public func expire() -> [MediaSendEvent] { expire(at: currentTime()) }

    public func replaceStream(_ stream: MediaStreamID, firstFrameID: UInt64 = 1) -> [MediaSendEvent] {
        var events: [MediaSendEvent] = []
        for id in frames.keys.sorted() {
            if let frame = remove(id) { events.append(.terminal(header: frame.header, sequence: frame.sequence, reason: .superseded)) }
        }
        self.stream = stream
        nextFrameID = firstFrameID
        nextPacketSequence = 1
        awaitingIDR = nil
        needsFirstIDR = true
        requiresRecovery = firstFrameID == UInt64.max
        highestInserted = nil
        return events
    }

    private func currentTime() -> TimeInterval {
        let now = clock()
        if now.isFinite { lastNow = max(lastNow, now) }
        return lastNow
    }

    private func remove(_ id: UInt64) -> CachedFrame? {
        guard let frame = frames.removeValue(forKey: id) else { return nil }
        bufferedBytes -= frame.bytes
        return frame
    }

    private func expire(at now: TimeInterval) -> [MediaSendEvent] {
        guard !requiresRecovery, let frame = frames.values.filter({ now >= $0.deadline })
            .min(by: { $0.header.frameID < $1.header.frameID }) else { return [] }
        return invalidate(at: frame.header)
    }

    private func invalidate(at header: MediaFrameHeader) -> [MediaSendEvent] {
        guard !requiresRecovery else { return [] }
        requiresRecovery = true
        var events: [MediaSendEvent] = []
        for id in frames.keys.sorted() {
            if let frame = remove(id) { events.append(.terminal(header: frame.header, sequence: frame.sequence, reason: .expired)) }
        }
        awaitingIDR = nil
        events.append(.recoveryRequired(header))
        return events
    }
}
