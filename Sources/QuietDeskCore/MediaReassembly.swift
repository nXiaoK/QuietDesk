import Foundation

public struct MediaBufferLimits: Sendable {
    public static let legacyFrameWindow = 3
    public static let receiveFrameWindow = 6
    public static let maximumDynamicFrameWindow = 24

    public static func recommendedFrameWindow(framesPerSecond: Int, roundTripSeconds: TimeInterval? = nil) -> Int {
        let fps = max(1, min(240, framesPerSecond))
        let baseline = fps > 60 ? 8 : fps >= 60 ? Self.receiveFrameWindow : 4
        guard let rtt = roundTripSeconds, rtt.isFinite, rtt > 0 else { return baseline }
        let bdp = Int(ceil(Double(fps) * min(1.0, rtt) * 1.5)) + 3
        return min(Self.maximumDynamicFrameWindow, max(baseline, bdp))
    }

    public let maximumFrameBytes: Int
    public let maximumBufferedBytes: Int
    public let maximumFrames: Int
    public let frameTimeToLive: TimeInterval
    public let keyFrameTimeToLive: TimeInterval
    // Optional decode/confirmation budget after full receipt; nil preserves the delivery deadline.
    public let completedFrameTimeToLive: TimeInterval?
    public let reorderDelay: TimeInterval
    public let nackInterval: TimeInterval
    public let acknowledgementRepeatInterval: TimeInterval
    public let maximumRepairRounds: Int
    // A keyframe is the recovery itself. One that a full queue or a loss burst left incomplete after two
    // rounds would otherwise wait out its deadline and be sent again whole; while the deadline allows,
    // asking again for what is still missing is the cheaper way.
    public let maximumKeyFrameRepairRounds: Int
    public let repairSafetyMargin: TimeInterval

    public init(maximumFrameBytes: Int = MediaFrame.maximumPacketBytes,
                maximumBufferedBytes: Int = 32 * 1_024 * 1_024, maximumFrames: Int = Self.legacyFrameWindow,
                frameTimeToLive: TimeInterval = 0.15, keyFrameTimeToLive: TimeInterval = 2.0,
                reorderDelay: TimeInterval = 0.003,
                nackInterval: TimeInterval = 0.01, acknowledgementRepeatInterval: TimeInterval = 0.02,
                maximumRepairRounds: Int = 2, repairSafetyMargin: TimeInterval = 0.005,
                completedFrameTimeToLive: TimeInterval? = nil, maximumKeyFrameRepairRounds: Int = 6) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumFrames = maximumFrames
        self.frameTimeToLive = frameTimeToLive
        self.keyFrameTimeToLive = keyFrameTimeToLive
        self.completedFrameTimeToLive = completedFrameTimeToLive
        self.reorderDelay = reorderDelay
        self.nackInterval = nackInterval
        self.acknowledgementRepeatInterval = acknowledgementRepeatInterval
        self.maximumRepairRounds = maximumRepairRounds
        self.maximumKeyFrameRepairRounds = maximumKeyFrameRepairRounds
        self.repairSafetyMargin = repairSafetyMargin
    }

    fileprivate func validate() throws {
        guard (1...MediaFrame.maximumPacketBytes).contains(maximumFrameBytes), maximumBufferedBytes > 0,
              (1...64).contains(maximumFrames), frameTimeToLive.isFinite, frameTimeToLive > 0,
              keyFrameTimeToLive.isFinite, keyFrameTimeToLive > 0,
              completedFrameTimeToLive.map({ $0.isFinite && $0 > 0 }) ?? true,
              reorderDelay.isFinite, reorderDelay >= 0, reorderDelay < min(frameTimeToLive, keyFrameTimeToLive),
              nackInterval.isFinite, nackInterval > 0,
              acknowledgementRepeatInterval.isFinite, acknowledgementRepeatInterval > 0,
              (0...16).contains(maximumRepairRounds), (0...16).contains(maximumKeyFrameRepairRounds),
              repairSafetyMargin.isFinite, repairSafetyMargin >= 0 else {
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
// Share of UDP video fragments that missed the reorder window over the last few seconds. It describes
// the video path only: TCP retransmits inside the system and whole frames never seen are not counted.
public struct MediaLossWindow: Sendable {
    public static let span: TimeInterval = 5
    public static let minimumFragments = 20
    private var entries: [(at: TimeInterval, settled: Int, lost: Int)] = []

    public init() {}

    public mutating func add(settled: Int, lost: Int, at now: TimeInterval) {
        guard now.isFinite, settled > 0 else { return }
        entries.append((now, settled, min(max(0, lost), settled)))
    }

    public mutating func fraction(at now: TimeInterval) -> Double? {
        entries.removeAll { now - $0.at > Self.span }
        let settled = entries.reduce(0) { $0 + $1.settled }
        guard settled >= Self.minimumFragments else { return nil }
        return Double(entries.reduce(0) { $0 + $1.lost }) / Double(settled)
    }

    public mutating func reset() { entries.removeAll() }
}

public final class MediaFrameReassembler {
    public private(set) var stream: MediaStreamID
    public private(set) var requiresRecovery = false
    public private(set) var bufferedBytes = 0
    public var pendingFrameCount: Int { assemblies.count }
    var hasIncompleteRepair: Bool {
        if let assembly = assemblies[expectedFrameID] {
            return assembly.frame == nil && assembly.lastNackAt != nil
                && (assembly.exposedCount == assembly.fragmentCount || assembly.requestedThroughTail)
        }
        return missingFrames[expectedFrameID]?.requested == true
    }
    private var limits: MediaBufferLimits
    private let clock: () -> TimeInterval
    private var lastNow: TimeInterval
    private var expectedFrameID: UInt64
    private var waitingForFirstIDR = true
    private var awaitingDecode: MediaFrameHeader?
    private var gapStartedAt: TimeInterval?
    private struct MissingFrame {
        let firstSeenAt: TimeInterval
        var lastNackAt: TimeInterval?
        var requested = false
    }
    private var missingFrames: [UInt64: MissingFrame] = [:]
    private var assemblies: [UInt64: Assembly] = [:]
    private var lastDecoded: MediaFrameHeader?
    private var lastAcknowledgementAt: TimeInterval?
    // Fragments of finished UDP frames, and how many of them missed the reorder window: requested
    // again or never arrived. Complete TCP envelopes are not fragments and are never counted.
    private var settledFragments = 0
    private var lateFragments = 0
    var onSettledFragments: ((_ settled: Int, _ lost: Int) -> Void)?

    private final class Assembly {
        let header: MediaFrameHeader
        let totalBytes: Int
        let fragmentCount: Int
        let fragmented: Bool
        let firstReceivedAt: TimeInterval
        var lastProgressAt: TimeInterval
        var lastNackAt: TimeInterval?
        var requestedThroughTail = false
        // Completed with a retransmission, a NACK in flight or FEC rather than by plain arrival.
        var repaired = false
        var bytes: Data
        var received: [Bool]
        var late: [Bool]
        var receivedCount = 0
        private(set) var exposedCount = 0
        struct FECBlock {
            let blockStart: Int
            let blockDataCount: Int
            let parityCount: Int
            var parityPayloads: [Int: Data] = [:]
        }
        private var firstMissingIndex = 0
        private var missingSince: [Int: TimeInterval] = [:]
        var parityPayload: Data?
        var fecBlocks: [Int: FECBlock] = [:]
        var frame: MediaFrame?
        var completedAt: TimeInterval?

        init(_ fragment: MediaFragment, now: TimeInterval) {
            header = fragment.header
            totalBytes = fragment.frameBytes
            fragmentCount = Int(fragment.fragmentCount)
            fragmented = true
            firstReceivedAt = now
            lastProgressAt = now
            bytes = Data(count: totalBytes)
            received = Array(repeating: false, count: fragmentCount)
            late = Array(repeating: false, count: fragmentCount)
        }

        init(_ parity: MediaFrameParity, now: TimeInterval) {
            header = parity.header
            totalBytes = parity.frameBytes
            fragmentCount = Int(parity.fragmentCount)
            fragmented = true
            firstReceivedAt = now
            lastProgressAt = now
            bytes = Data(count: totalBytes)
            received = Array(repeating: false, count: fragmentCount)
            late = Array(repeating: false, count: fragmentCount)
            parityPayload = parity.parityPayload
            exposeFragments(upTo: fragmentCount, at: now)
        }

        init(_ shard: MediaFrameFECShard, now: TimeInterval) {
            header = shard.header
            totalBytes = shard.frameBytes
            fragmentCount = Int(shard.fragmentCount)
            fragmented = true
            firstReceivedAt = now
            lastProgressAt = now
            bytes = Data(count: totalBytes)
            received = Array(repeating: false, count: fragmentCount)
            late = Array(repeating: false, count: fragmentCount)
            let start = Int(shard.blockStart)
            let dataCount = Int(shard.blockDataCount)
            var block = FECBlock(blockStart: start, blockDataCount: dataCount, parityCount: Int(shard.parityCount))
            block.parityPayloads[Int(shard.parityIndex)] = shard.parityPayload
            fecBlocks[start] = block
            exposeFragments(upTo: start + dataCount, at: now)
        }

        init(_ frame: MediaFrame, bytes: Data, now: TimeInterval) {
            header = frame.header
            totalBytes = bytes.count
            fragmentCount = (bytes.count + MediaFragment.maximumPayloadBytes - 1) / MediaFragment.maximumPayloadBytes
            fragmented = false
            firstReceivedAt = now
            lastProgressAt = now
            self.bytes = bytes
            received = Array(repeating: true, count: fragmentCount)
            late = Array(repeating: false, count: fragmentCount)
            receivedCount = fragmentCount
            exposedCount = fragmentCount
            firstMissingIndex = fragmentCount
            self.frame = frame
            completedAt = now
        }

        // Originals are sent in index order, followed by parity. Each newly exposed gap starts its own timer.
        func exposeFragments(upTo end: Int, at now: TimeInterval) {
            guard end > exposedCount else { return }
            for index in exposedCount..<end where !received[index] { missingSince[index] = now }
            exposedCount = end
        }

        func markReceived(_ index: Int, at now: TimeInterval, reorderDelay: TimeInterval) {
            if let since = missingSince.removeValue(forKey: index), now >= since + reorderDelay { late[index] = true }
            received[index] = true
            receivedCount += 1
            exposeFragments(upTo: index + 1, at: now)
            while firstMissingIndex < fragmentCount, received[firstMissingIndex] { firstMissingIndex += 1 }
            lastProgressAt = now
        }

        func nextRepairAt(_ limits: MediaBufferLimits) -> TimeInterval {
            let firstDeadline = missingSince[firstMissingIndex].map { $0 + limits.reorderDelay }
                ?? (lastProgressAt + max(limits.reorderDelay, limits.nackInterval))
            return max(firstDeadline, lastNackAt.map { $0 + limits.nackInterval } ?? firstDeadline)
        }

        func missingRanges(at now: TimeInterval, limits: MediaBufferLimits) -> [MediaFragmentRange] {
            let includeTail = now >= lastProgressAt + max(limits.reorderDelay, limits.nackInterval)
            func due(_ index: Int) -> Bool {
                !received[index] && (includeTail || missingSince[index].map { now >= $0 + limits.reorderDelay } == true)
            }
            var ranges: [MediaFragmentRange] = []
            var index = firstMissingIndex
            let end = includeTail ? fragmentCount : exposedCount
            while index < end, ranges.count < MediaFeedback.maximumMissingRanges {
                if !due(index) { index += 1; continue }
                let first = index
                repeat { index += 1 } while index < end && due(index)
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

    /// Returns and clears the fragment counts since the previous call.
    public func takeFragmentCounts() -> (settled: Int, lost: Int) {
        defer { settledFragments = 0; lateFragments = 0 }
        return (settledFragments, lateFragments)
    }

    private func settleFragments(_ count: Int, lost: Int) {
        settledFragments += count
        lateFragments += lost
        onSettledFragments?(count, lost)
    }

    /// Settles unfinished frames before this reassembler is dropped. Holes below received progress,
    /// requested fragments and a stalled tail count as lost; a tail that may still be arriving does not.
    public func abandon() {
        let now = currentTime()
        for assembly in assemblies.values where assembly.fragmented && assembly.frame == nil {
            let end = now - assembly.lastProgressAt >= limits.reorderDelay ? assembly.fragmentCount : assembly.exposedCount
            settleFragments(end, lost: (0..<end).lazy.filter { !assembly.received[$0] || assembly.late[$0] }.count)
        }
        assemblies.removeAll()
        missingFrames.removeAll()
        bufferedBytes = 0
        awaitingDecode = nil
        gapStartedAt = nil
    }

    public func updateLimits(_ limits: MediaBufferLimits) {
        guard (try? limits.validate()) != nil else { return }
        self.limits = limits
    }

    public func replaceStream(_ stream: MediaStreamID, firstFrameID: UInt64 = 1) {
        // A fresh epoch starts at an IDR. Keep the previous valid image outside this reassembler.
        self.stream = stream
        expectedFrameID = firstFrameID
        assemblies.removeAll()
        missingFrames.removeAll()
        bufferedBytes = 0
        awaitingDecode = nil
        gapStartedAt = nil
        waitingForFirstIDR = true
        requiresRecovery = firstFrameID == UInt64.max
        lastDecoded = nil
        lastAcknowledgementAt = nil
    }

    public func receive(_ fragment: MediaFragment, isRepair: Bool = false) throws -> [MediaReceiveEvent] {
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
        var missingGap: MissingFrame?
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
            missingGap = missingFrames.removeValue(forKey: fragment.header.frameID)
            assembly = Assembly(fragment, now: now)
            if missingGap?.requested == true {
                assembly.repaired = true
                if assembly.fragmentCount == 1 { assembly.requestedThroughTail = true }
            }
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
            assembly.markReceived(index, at: now, reorderDelay: limits.reorderDelay)
            if isRepair { assembly.repaired = true }
            let missingHoleLate = missingGap.map { $0.requested || now - $0.firstSeenAt >= limits.reorderDelay } ?? false
            if missingHoleLate || (isRepair && assembly.requestedThroughTail) { assembly.late[index] = true }
            if assembly.receivedCount == assembly.fragmentCount {
                do {
                    assembly.frame = try MediaFrame(header: assembly.header, packetBytes: assembly.bytes)
                    assembly.completedAt = now
                    settleFragments(assembly.fragmentCount, lost: assembly.late.lazy.filter { $0 }.count)
                } catch {
                    _ = invalidate(at: fragment.header)
                    throw error
                }
                events.append(.feedback(try MediaFeedback(kind: .reassembled, header: assembly.header)))
            } else {
                try tryCompleteWithParity(assembly, now: now, events: &events)
                // A data fragment can only complete the block it belongs to.
                if assembly.frame == nil, let block = assembly.fecBlocks.values.first(where: {
                    $0.blockStart <= index && index < $0.blockStart + $0.blockDataCount
                }) {
                    try tryRecoverFECBlock(assembly, start: block.blockStart, now: now, events: &events)
                }
            }
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    public func receive(_ parity: MediaFrameParity) throws -> [MediaReceiveEvent] {
        guard parity.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        if parity.header.frameID < expectedFrameID {
            if let lastDecoded { events.append(.feedback(try MediaFeedback(kind: .decoded, header: lastDecoded))) }
            return events
        }
        let distance = parity.header.frameID - expectedFrameID
        guard distance < UInt64(limits.maximumFrames), parity.header.frameID < UInt64.max,
              parity.frameBytes <= limits.maximumFrameBytes else {
            return events + invalidate(at: parity.header)
        }
        let assembly: Assembly
        if let existing = assemblies[parity.header.frameID] {
            guard existing.header == parity.header, existing.totalBytes == parity.frameBytes,
                  existing.fragmentCount == Int(parity.fragmentCount) else {
                _ = invalidate(at: parity.header)
                throw DeskError.invalid("同一媒体帧的校验元数据冲突")
            }
            if let existingParity = existing.parityPayload {
                guard existingParity == parity.parityPayload else {
                    _ = invalidate(at: parity.header)
                    throw DeskError.invalid("重复媒体异或校验内容冲突")
                }
            } else {
                existing.parityPayload = parity.parityPayload
                existing.exposeFragments(upTo: existing.fragmentCount, at: now)
                existing.lastProgressAt = now
            }
            assembly = existing
        } else {
            guard assemblies.count < limits.maximumFrames,
                  parity.frameBytes <= limits.maximumBufferedBytes - bufferedBytes else {
                return events + invalidate(at: parity.header)
            }
            _ = missingFrames.removeValue(forKey: parity.header.frameID)
            assembly = Assembly(parity, now: now)
            assemblies[parity.header.frameID] = assembly
            bufferedBytes += parity.frameBytes
        }
        if assembly.frame == nil {
            try tryCompleteWithParity(assembly, now: now, events: &events)
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    private func tryCompleteWithParity(_ assembly: Assembly, now: TimeInterval, events: inout [MediaReceiveEvent]) throws {
        guard assembly.frame == nil,
              assembly.receivedCount == assembly.fragmentCount - 1,
              let parity = assembly.parityPayload,
              let missingIndex = assembly.received.firstIndex(of: false) else { return }
        var recovered = [UInt8](parity)
        assembly.bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<assembly.fragmentCount where index != missingIndex {
                let start = index * MediaFragment.maximumPayloadBytes
                let length = min(MediaFragment.maximumPayloadBytes, assembly.totalBytes - start)
                for offset in 0..<length {
                    recovered[offset] ^= base[start + offset]
                }
            }
        }
        let missingStart = missingIndex * MediaFragment.maximumPayloadBytes
        let expectedLength = min(MediaFragment.maximumPayloadBytes, assembly.totalBytes - missingStart)
        if expectedLength < MediaFragment.maximumPayloadBytes,
           recovered[expectedLength..<MediaFragment.maximumPayloadBytes].contains(where: { $0 != 0 }) {
            _ = invalidate(at: assembly.header)
            throw DeskError.invalid("媒体异或校验恢复尾部非零")
        }
        assembly.bytes.replaceSubrange(missingStart..<(missingStart + expectedLength),
                                       with: recovered.prefix(expectedLength))
        assembly.markReceived(missingIndex, at: now, reorderDelay: limits.reorderDelay)
        assembly.repaired = true
        do {
            assembly.frame = try MediaFrame(header: assembly.header, packetBytes: assembly.bytes)
            assembly.completedAt = now
            settleFragments(assembly.fragmentCount, lost: assembly.late.lazy.filter { $0 }.count)
        } catch {
            _ = invalidate(at: assembly.header)
            throw error
        }
        events.append(.feedback(try MediaFeedback(kind: .reassembled, header: assembly.header)))
    }

    public func receive(_ shard: MediaFrameFECShard) throws -> [MediaReceiveEvent] {
        guard shard.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        if shard.header.frameID < expectedFrameID {
            if let lastDecoded { events.append(.feedback(try MediaFeedback(kind: .decoded, header: lastDecoded))) }
            return events
        }
        let distance = shard.header.frameID - expectedFrameID
        guard distance < UInt64(limits.maximumFrames), shard.header.frameID < UInt64.max,
              shard.frameBytes <= limits.maximumFrameBytes else {
            return events + invalidate(at: shard.header)
        }
        let blockStart = Int(shard.blockStart)
        let blockDataCount = Int(shard.blockDataCount)
        let parityCount = Int(shard.parityCount)
        let parityIndex = Int(shard.parityIndex)

        let assembly: Assembly
        if let existing = assemblies[shard.header.frameID] {
            guard existing.header == shard.header, existing.totalBytes == shard.frameBytes,
                  existing.fragmentCount == Int(shard.fragmentCount) else {
                _ = invalidate(at: shard.header)
                throw DeskError.invalid("同一媒体帧的分块纠错帧元数据冲突")
            }
            if var block = existing.fecBlocks[blockStart] {
                guard block.blockDataCount == blockDataCount, block.parityCount == parityCount else {
                    _ = invalidate(at: shard.header)
                    throw DeskError.invalid("同一媒体帧的分块纠错块参数冲突")
                }
                if let existingPayload = block.parityPayloads[parityIndex] {
                    guard existingPayload == shard.parityPayload else {
                        _ = invalidate(at: shard.header)
                        throw DeskError.invalid("重复媒体分块纠错内容冲突")
                    }
                } else {
                    block.parityPayloads[parityIndex] = shard.parityPayload
                    existing.fecBlocks[blockStart] = block
                    existing.exposeFragments(upTo: blockStart + blockDataCount, at: now)
                    existing.lastProgressAt = now
                }
            } else {
                let newRange = blockStart..<(blockStart + blockDataCount)
                for other in existing.fecBlocks.values {
                    let otherRange = other.blockStart..<(other.blockStart + other.blockDataCount)
                    if newRange.overlaps(otherRange) {
                        _ = invalidate(at: shard.header)
                        throw DeskError.invalid("同一媒体帧的分块纠错范围重叠")
                    }
                }
                guard existing.fecBlocks.count < MediaFrameFECShard.maximumProtectedFragments else {
                    _ = invalidate(at: shard.header)
                    throw DeskError.invalid("媒体分块纠错块数量超限")
                }
                var block = Assembly.FECBlock(blockStart: blockStart, blockDataCount: blockDataCount, parityCount: parityCount)
                block.parityPayloads[parityIndex] = shard.parityPayload
                existing.fecBlocks[blockStart] = block
                existing.exposeFragments(upTo: blockStart + blockDataCount, at: now)
                existing.lastProgressAt = now
            }
            assembly = existing
        } else {
            guard assemblies.count < limits.maximumFrames,
                  shard.frameBytes <= limits.maximumBufferedBytes - bufferedBytes else {
                return events + invalidate(at: shard.header)
            }
            _ = missingFrames.removeValue(forKey: shard.header.frameID)
            assembly = Assembly(shard, now: now)
            assemblies[shard.header.frameID] = assembly
            bufferedBytes += shard.frameBytes
        }

        if assembly.frame == nil {
            try tryRecoverFECBlock(assembly, start: blockStart, now: now, events: &events)
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    private func tryRecoverFECBlock(
        _ assembly: Assembly,
        start: Int,
        now: TimeInterval,
        events: inout [MediaReceiveEvent]
    ) throws {
        guard assembly.frame == nil, let block = assembly.fecBlocks[start], !block.parityPayloads.isEmpty else { return }
        let end = start + block.blockDataCount
        let missingCount = (start..<end).lazy.filter { !assembly.received[$0] }.count
        guard missingCount > 0, block.parityPayloads.count >= missingCount else { return }

        var dataSlices: [Data?] = []
        dataSlices.reserveCapacity(block.blockDataCount)
        for index in start..<end {
            if assembly.received[index] {
                let byteStart = index * MediaFragment.maximumPayloadBytes
                let byteLen = min(MediaFragment.maximumPayloadBytes, assembly.totalBytes - byteStart)
                dataSlices.append(assembly.bytes.subdata(in: byteStart..<(byteStart + byteLen)))
            } else {
                dataSlices.append(nil)
            }
        }

        let recoveredMap: [Int: [UInt8]]?
        do {
            recoveredMap = try ReedSolomonGF256.reconstructMissingDataShards(
                dataShards: dataSlices,
                parityShards: block.parityPayloads,
                shardLength: MediaFragment.maximumPayloadBytes,
                parityCount: block.parityCount
            )
        } catch {
            _ = invalidate(at: assembly.header)
            throw error
        }
        guard let recoveredMap, !recoveredMap.isEmpty else { return }

        for (relativeCol, fullBytes) in recoveredMap.sorted(by: { $0.key < $1.key }) {
            let fragmentIndex = start + relativeCol
            let byteStart = fragmentIndex * MediaFragment.maximumPayloadBytes
            let expectedLength = min(MediaFragment.maximumPayloadBytes, assembly.totalBytes - byteStart)
            if expectedLength < MediaFragment.maximumPayloadBytes,
               fullBytes[expectedLength..<MediaFragment.maximumPayloadBytes].contains(where: { $0 != 0 }) {
                _ = invalidate(at: assembly.header)
                throw DeskError.invalid("媒体分块纠错恢复尾部非零")
            }
            assembly.bytes.replaceSubrange(byteStart..<(byteStart + expectedLength), with: fullBytes.prefix(expectedLength))
            assembly.markReceived(fragmentIndex, at: now, reorderDelay: limits.reorderDelay)
            assembly.repaired = true
        }

        if assembly.receivedCount == assembly.fragmentCount {
            do {
                assembly.frame = try MediaFrame(header: assembly.header, packetBytes: assembly.bytes)
                assembly.completedAt = now
                settleFragments(assembly.fragmentCount, lost: assembly.late.lazy.filter { $0 }.count)
            } catch {
                _ = invalidate(at: assembly.header)
                throw error
            }
            events.append(.feedback(try MediaFeedback(kind: .reassembled, header: assembly.header)))
        }
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
            missingFrames.removeValue(forKey: frame.header.frameID)
            assemblies[frame.header.frameID] = Assembly(frame, bytes: bytes, now: now)
            bufferedBytes += bytes.count
            events.append(.feedback(try MediaFeedback(kind: .reassembled, header: frame.header)))
        }
        updateGap(at: now)
        events += readyFrame()
        return events
    }

    /// Payload bytes of a fragmented frame that is still held.
    public func fragmentedBytes(of header: MediaFrameHeader) -> Int? {
        guard let assembly = assemblies[header.frameID], assembly.header == header, assembly.fragmented else { return nil }
        return assembly.totalBytes
    }

    // First fragment to completion, while the frame is still held. Whole frames had no fragment wait.
    public func collectionDuration(of header: MediaFrameHeader) -> TimeInterval? {
        guard let assembly = assemblies[header.frameID], assembly.header == header, assembly.fragmented,
              let completedAt = assembly.completedAt else { return nil }
        return completedAt - assembly.firstReceivedAt
    }

    /// Parity shards the sender paced with a held fragmented frame, as far as their blocks arrived.
    public func parityShardCount(of header: MediaFrameHeader) -> Int? {
        guard let assembly = assemblies[header.frameID], assembly.header == header, assembly.fragmented else { return nil }
        return assembly.fecBlocks.values.reduce(assembly.parityPayload == nil ? 0 : 1) { $0 + $1.parityCount }
    }

    /// Whether a held fragmented frame completed only through repair: a fragment that missed the reorder
    /// window, a retransmission or FEC. Its collection time then measures the repair, not path queueing.
    public func wasRepaired(_ header: MediaFrameHeader) -> Bool? {
        guard let assembly = assemblies[header.frameID], assembly.header == header, assembly.fragmented,
              assembly.completedAt != nil else { return nil }
        return assembly.repaired || assembly.late.contains(true)
    }

    /// Delay until the earliest pending NACK check for a missing frame or fragment hole, if any.
    public var nextPollDelay: TimeInterval? {
        guard !requiresRecovery else { return nil }
        let now = currentTime()
        var earliest: TimeInterval?
        func consider(_ due: TimeInterval) {
            let delay = max(0, due - now)
            earliest = earliest.map { min($0, delay) } ?? delay
        }
        for missing in missingFrames.values {
            let due = max(missing.firstSeenAt + limits.reorderDelay,
                          missing.lastNackAt.map { $0 + limits.nackInterval } ?? 0)
            consider(due)
        }
        for assembly in assemblies.values where assembly.frame == nil {
            consider(assembly.nextRepairAt(limits))
        }
        return earliest
    }

    public func poll() -> [MediaReceiveEvent] {
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        let candidateIDs = Set(assemblies.keys).union(missingFrames.keys).sorted()
        for id in candidateIDs {
            if var missing = missingFrames[id], assemblies[id] == nil {
                guard now - missing.firstSeenAt >= limits.reorderDelay,
                      missing.lastNackAt.map({ now - $0 >= limits.nackInterval }) ?? true else { continue }
                let header = MediaFrameHeader(stream: stream, frameID: id, isIDR: waitingForFirstIDR && id == expectedFrameID)
                if let feedback = try? MediaFeedback(kind: .nack, header: header,
                                                     missingRanges: [.init(first: 0, count: 1)]) {
                    missing.lastNackAt = now
                    missing.requested = true
                    missingFrames[id] = missing
                    events.append(.feedback(feedback))
                }
                continue
            }
            guard let assembly = assemblies[id], assembly.frame == nil,
                  now >= assembly.nextRepairAt(limits) else { continue }
            // A later fragment reveals a hole; an unseen tail may still be in the sender's
            // pacer. Only ask for that tail after unique fragments stop making progress.
            let missing = assembly.missingRanges(at: now, limits: limits)
            if !missing.isEmpty, let feedback = try? MediaFeedback(kind: .nack, header: assembly.header, missingRanges: missing) {
                assembly.lastNackAt = now
                assembly.repaired = true
                // Once a NACK spans the final fragment it has requested every remaining hole in this frame.
                if let last = missing.last, Int(last.first) + Int(last.count) == assembly.fragmentCount {
                    assembly.requestedThroughTail = true
                }
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
        missingFrames = missingFrames.filter { $0.key >= expectedFrameID && assemblies[$0.key] == nil }
        if assemblies[expectedFrameID] == nil, !assemblies.isEmpty {
            if gapStartedAt == nil { gapStartedAt = now }
        } else { gapStartedAt = nil }
        if let highest = assemblies.keys.max(), highest > expectedFrameID {
            for id in expectedFrameID..<highest where assemblies[id] == nil && missingFrames[id] == nil {
                missingFrames[id] = MissingFrame(firstSeenAt: now)
            }
        }
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
            if let completedAt = $0.completedAt, let timeout = limits.completedFrameTimeToLive {
                return now - completedAt >= timeout
            }
            let baseTTL = $0.header.isIDR ? limits.keyFrameTimeToLive : limits.frameTimeToLive
            // While unique fragments of a large paced P-frame are actively arriving within the NACK/reorder
            // cadence, allow the sender's pacing span (bounded by one baseTTL) before declaring expiry.
            let activePacing = !$0.header.isIDR && $0.receivedCount > 4
                && now - $0.lastProgressAt < max(limits.reorderDelay, limits.nackInterval) * 2
                ? min(baseTTL, max(0, $0.lastProgressAt - $0.firstReceivedAt)) : 0
            return now - $0.firstReceivedAt >= baseTTL + activePacing
        })
            .min(by: { $0.header.frameID < $1.header.frameID }) {
            return invalidate(at: oldest.header)
        }
        return []
    }

    private func invalidate(at header: MediaFrameHeader) -> [MediaReceiveEvent] {
        guard !requiresRecovery else { return [] }
        requiresRecovery = true
        for assembly in assemblies.values where assembly.fragmented && assembly.frame == nil {
            settleFragments(assembly.fragmentCount, lost: zip(assembly.received, assembly.late).lazy.filter { !$0.0 || $0.1 }.count)
        }
        assemblies.removeAll()
        missingFrames.removeAll()
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
    private var limits: MediaBufferLimits
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
        var deadline: TimeInterval
        var reassembled = false
        var repairRounds = 0
        var lastRepairAt: TimeInterval?
        // When pacing of the original fragments finished, and whether the receiver reported on the
        // frame since: reassembled, or asked for some of it.
        var submittedAt: TimeInterval?
        var heard = false
        var probes = 0
        var lastProbeAt: TimeInterval?
    }
    public static let maximumTailProbes = 2

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

    public func updateLimits(_ limits: MediaBufferLimits) {
        guard (try? limits.validate()) != nil else { return }
        self.limits = limits
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

    public func frameHeader(for frameID: UInt64) -> MediaFrameHeader? {
        frames[frameID]?.header
    }

    /// The sender finished pacing a frame's original fragments.
    public func originalsSubmitted(_ header: MediaFrameHeader) {
        guard header.stream == stream, var cached = frames[header.frameID], cached.header == header,
              cached.submittedAt == nil else { return }
        cached.submittedAt = currentTime()
        frames[header.frameID] = cached
    }

    /// A receiver asks for fragments only below something it received, so the newest frame is the one it
    /// cannot ask for: lost whole with nothing after it, such as the last small frame before the screen
    /// goes still, it stays unknown until the sender's deadline replaces the whole reference chain.
    /// After a quiet round trip without any word about that frame, its last fragment goes out again:
    /// that completes a single-fragment frame and shows the receiver what else to ask for.
    /// Older frames need no probe; the receiver sees their gap below the newer ones. A stream that keeps
    /// sending is therefore never probed, however late a queueing path makes its feedback.
    public func tailProbes(estimatedRoundTrip: TimeInterval) -> [MediaSendEvent] {
        guard !requiresRecovery, estimatedRoundTrip.isFinite, estimatedRoundTrip >= 0,
              let newest = highestInserted, var cached = frames[newest],
              !cached.heard, !cached.reassembled, cached.probes < Self.maximumTailProbes,
              let submittedAt = cached.submittedAt, let last = cached.fragments.last else { return [] }
        let now = currentTime()
        let quiet = max(0.03, estimatedRoundTrip * 1.5 + 0.02)
        guard now - (cached.lastProbeAt ?? submittedAt) >= quiet * Double(cached.probes + 1),
              now + estimatedRoundTrip + limits.repairSafetyMargin < cached.deadline else { return [] }
        cached.probes += 1
        cached.lastProbeAt = now
        frames[newest] = cached
        return [.retransmit([last])]
    }

    private func heard(_ id: UInt64) {
        guard var cached = frames[id], !cached.heard else { return }
        cached.heard = true
        frames[id] = cached
    }

    public func handle(_ feedback: MediaFeedback, estimatedRoundTrip: TimeInterval) -> [MediaSendEvent] {
        guard feedback.header.stream == stream, !requiresRecovery else { return [] }
        let now = currentTime()
        var events = expire(at: now)
        guard !requiresRecovery else { return events }
        guard let inserted = highestInserted, feedback.header.frameID <= inserted else { return events }
        // A receiver detecting a wholly missing frame cannot know whether it happened to be an IDR.
        if feedback.kind != .expired && feedback.kind != .nack,
           let cached = frames[feedback.header.frameID], cached.header != feedback.header { return events }
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
            heard(feedback.header.frameID)
            if var cached = frames[feedback.header.frameID] {
                if !cached.reassembled, let timeout = limits.completedFrameTimeToLive {
                    cached.deadline = max(cached.deadline, now + timeout)
                }
                cached.reassembled = true
                frames[feedback.header.frameID] = cached
            }
        case .nack:
            heard(feedback.header.frameID)
            guard var cached = frames[feedback.header.frameID], !cached.reassembled,
                  estimatedRoundTrip.isFinite, estimatedRoundTrip >= 0,
                  now + estimatedRoundTrip + limits.repairSafetyMargin < cached.deadline,
                  cached.repairRounds < (cached.header.isIDR ? limits.maximumKeyFrameRepairRounds : limits.maximumRepairRounds),
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
