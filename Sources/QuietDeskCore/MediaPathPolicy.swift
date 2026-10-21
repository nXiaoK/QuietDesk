import Foundation

private let mediaPolicyTimeTolerance: TimeInterval = 0.000_001

public enum MediaPath: String, Codable, Sendable {
    case tcp, udp
}

public enum MediaBottleneck: String, Sendable {
    case network, encoder, decoder
}

public enum MediaPathReason: String, Sendable {
    case initialProbe, recoveryProbe, probeTimeout, probeFailed, noPong, mediaTimeout, networkDegraded, epochExhausted
}

public enum MediaPathAction: Equatable, Sendable {
    case beginProbe(id: UUID, timeout: TimeInterval)
    case cancelProbe(id: UUID)
    case selectPath(MediaPath, epoch: UInt32, reason: MediaPathReason)
    case reduceLoad(MediaBottleneck)
    case restartSession(reason: MediaPathReason)
}

// A local measurement window, not a report trusted directly from the other endpoint.
public struct MediaPathSample: Sendable {
    public let duration: TimeInterval
    public let mediaActive: Bool
    public let networkSamples: Int
    public let decodedFrames: Int
    public let lossFraction: Double?
    public let jitterMilliseconds: Double?
    public let queueMilliseconds: Double?
    public let encodeMilliseconds: Double?
    public let decodeMilliseconds: Double?
    public let frameBudgetMilliseconds: Double

    public init(duration: TimeInterval, mediaActive: Bool, networkSamples: Int, decodedFrames: Int,
                lossFraction: Double? = nil, jitterMilliseconds: Double? = nil, queueMilliseconds: Double? = nil,
                encodeMilliseconds: Double? = nil, decodeMilliseconds: Double? = nil,
                frameBudgetMilliseconds: Double = 1_000 / 60) {
        self.duration = duration; self.mediaActive = mediaActive
        self.networkSamples = networkSamples; self.decodedFrames = decodedFrames
        self.lossFraction = lossFraction; self.jitterMilliseconds = jitterMilliseconds
        self.queueMilliseconds = queueMilliseconds; self.encodeMilliseconds = encodeMilliseconds
        self.decodeMilliseconds = decodeMilliseconds; self.frameBudgetMilliseconds = frameBudgetMilliseconds
    }

    var isValid: Bool {
        guard duration.isFinite, duration > 0, duration <= 5, networkSamples >= 0, decodedFrames >= 0,
              frameBudgetMilliseconds.isFinite, frameBudgetMilliseconds > 0 else { return false }
        for value in [lossFraction, jitterMilliseconds, queueMilliseconds, encodeMilliseconds, decodeMilliseconds] {
            if let value, !value.isFinite || value < 0 { return false }
        }
        return lossFraction.map { $0 <= 1 } ?? true
    }

    var hasNetworkEvidence: Bool {
        networkSamples >= 8 && (lossFraction != nil || jitterMilliseconds != nil || queueMilliseconds != nil)
    }

    var bottleneck: MediaBottleneck? {
        // Direct loss/jitter evidence survives a simultaneous compute bottleneck. A queue alone does not.
        if hasNetworkEvidence, (lossFraction ?? 0) >= 0.03 || (jitterMilliseconds ?? 0) >= 30 { return .network }
        if let encodeMilliseconds, encodeMilliseconds >= frameBudgetMilliseconds { return .encoder }
        if let decodeMilliseconds, decodeMilliseconds >= frameBudgetMilliseconds { return .decoder }
        if hasNetworkEvidence, (queueMilliseconds ?? 0) >= 60 { return .network }
        return nil
    }
}

// One coordinator owns this value and executes its actions. A selection is only a request;
// the coordinator confirms a new epoch after its first complete keyframe has decoded.
public struct MediaPathPolicy: Sendable {
    public enum Phase: String, Sendable {
        case legacyTCP, initialTCP, probingUDP, trialUDP, udp, switchingTCP, tcpTrial, tcp, probingRecovery, stopped
    }

    public private(set) var phase: Phase
    public private(set) var targetPath: MediaPath = .tcp
    public private(set) var activePath: MediaPath? = .tcp
    public private(set) var epoch: UInt32
    public private(set) var probeID: UUID?
    public private(set) var recoveryAttempt = 0
    public private(set) var paused = false
    public private(set) var lastReason: MediaPathReason?
    public private(set) var nextRecoveryAt: TimeInterval?
    private var lastNow: TimeInterval
    private var lastObservationAt: TimeInterval
    private var probeDeadline: TimeInterval?
    private var selectionStartedAt: TimeInterval?
    private var lastPongAt: TimeInterval?
    private var networkBadDuration: TimeInterval = 0
    private var computeBadDuration: TimeInterval = 0
    private var computeBottleneck: MediaBottleneck?
    private var loadReduced = false
    private var healthyDuration: TimeInterval = 0
    private var trialDuration: TimeInterval = 0
    private var trialHasFrame = false
    private var pausedAt: TimeInterval?
    private var resumeProbeIsInitial: Bool?
    private var alternateProbeUsed = false
    private let initialProbeTimeout: TimeInterval

    public init(capable: Bool, now: TimeInterval, initialEpoch: UInt32 = 0, initialProbeTimeout: TimeInterval = 1.5) {
        phase = capable ? .initialTCP : .legacyTCP
        epoch = initialEpoch
        lastNow = now.isFinite ? now : 0
        lastObservationAt = lastNow
        self.initialProbeTimeout = initialProbeTimeout.isFinite ? min(5, max(1.5, initialProbeTimeout)) : 1.5
    }

    public mutating func tick(now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), phase != .legacyTCP, phase != .stopped, !paused else { return [] }
        if phase == .initialTCP { return beginProbe(initial: true, now: now) }
        if let probeDeadline, now >= probeDeadline, let probeID {
            return probeFailed(id: probeID, now: now, reason: .probeTimeout)
        }
        if targetPath == .udp, let lastPongAt, now - lastPongAt >= 1 {
            return fallBack(now: now, reason: .noPong)
        }
        if phase == .trialUDP, !trialHasFrame, let selectionStartedAt, now - selectionStartedAt >= 2 {
            return fallBack(now: now, reason: .mediaTimeout)
        }
        if phase == .tcp || phase == .tcpTrial, let nextRecoveryAt, now >= nextRecoveryAt {
            return beginProbe(initial: false, now: now)
        }
        return []
    }

    public mutating func probeSucceeded(id: UUID, now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), !paused, id == probeID, let deadline = probeDeadline, now < deadline else { return [] }
        let initial = phase == .probingUDP
        guard initial || phase == .probingRecovery else { return [] }
        guard advanceEpoch() else { return [.cancelProbe(id: id), .restartSession(reason: .epochExhausted)] }
        probeID = nil; probeDeadline = nil; nextRecoveryAt = nil
        targetPath = .udp; phase = .trialUDP
        selectionStartedAt = now; lastPongAt = now
        lastObservationAt = now
        resetEvidence(); trialHasFrame = false
        lastReason = initial ? .initialProbe : .recoveryProbe
        return [.cancelProbe(id: id), .selectPath(.udp, epoch: epoch, reason: lastReason!)]
    }

    public mutating func probeFailed(id: UUID, now: TimeInterval) -> [MediaPathAction] {
        probeFailed(id: id, now: now, reason: .probeFailed)
    }

    // Only the coordinator's first, delivery-failure-backed alternate route may bypass
    // the direct route's cooldown. Subsequent probes retain the normal backoff.
    public mutating func probeAlternateRoute(now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), !paused, !alternateProbeUsed, targetPath == .tcp, probeID == nil,
              [.initialTCP, .tcp, .tcpTrial, .switchingTCP].contains(phase) else { return [] }
        alternateProbeUsed = true
        return beginProbe(initial: false, now: now)
    }

    public mutating func receivedPong(epoch: UInt32, now: TimeInterval) {
        guard accept(now), phase != .stopped, self.epoch == epoch, targetPath == .udp else { return }
        lastPongAt = now
    }

    // The coordinator calls this only after an actual media attempt fails. A capture
    // preparation rejection is not evidence that the network path cannot carry media.
    public mutating func mediaFailed(epoch: UInt32, now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), !paused, self.epoch == epoch, targetPath == .udp,
              phase == .trialUDP || phase == .udp else { return [] }
        return fallBack(now: now, reason: .mediaTimeout)
    }

    @discardableResult
    public mutating func mediaBecameUsable(epoch: UInt32, now: TimeInterval) -> Bool {
        guard accept(now), !paused, phase != .stopped, self.epoch == epoch else { return false }
        if phase == .trialUDP {
            activePath = .udp; trialHasFrame = true
            return true
        }
        if phase == .switchingTCP {
            activePath = .tcp; phase = .tcpTrial
            selectionStartedAt = nil; lastObservationAt = now; trialDuration = 0
            return true
        }
        return false
    }

    public mutating func observe(_ sample: MediaPathSample, epoch: UInt32, now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), !paused, phase != .legacyTCP, phase != .stopped, self.epoch == epoch,
              sample.isValid else { return [] }
        let elapsed = min(sample.duration, max(0, now - lastObservationAt))
        if now - lastObservationAt > sample.duration + 0.5 { resetEvidence(preservingReduction: true) }
        lastObservationAt = now
        guard elapsed > 0 else { return [] }
        guard sample.mediaActive else { resetEvidence(preservingReduction: true); return [] }
        guard phase == .trialUDP || phase == .udp || phase == .tcpTrial || phase == .tcp else { return [] }
        let cause = sample.bottleneck
        if cause == .encoder || cause == .decoder {
            networkBadDuration = 0; loadReduced = false; healthyDuration = 0
            if computeBottleneck != cause { computeBadDuration = 0 }
            computeBottleneck = cause; computeBadDuration += elapsed
            if computeBadDuration + mediaPolicyTimeTolerance >= 3 {
                computeBadDuration = 0
                return [.reduceLoad(cause!)]
            }
            return []
        }
        computeBadDuration = 0; computeBottleneck = nil
        guard sample.hasNetworkEvidence else { networkBadDuration = 0; healthyDuration = 0; return [] }
        if cause == .network {
            healthyDuration = 0; trialDuration = 0
            networkBadDuration += elapsed
            if networkBadDuration + mediaPolicyTimeTolerance >= 3 {
                networkBadDuration = 0
                if loadReduced, targetPath == .udp { return fallBack(now: now, reason: .networkDegraded) }
                loadReduced = true
                return [.reduceLoad(.network)]
            }
            return []
        }
        networkBadDuration = 0; loadReduced = false
        healthyDuration += elapsed
        if phase == .trialUDP, trialHasFrame {
            trialDuration += elapsed
            if trialDuration + mediaPolicyTimeTolerance >= 5 { phase = .udp }
        } else if phase == .tcpTrial {
            trialDuration += elapsed
            if trialDuration + mediaPolicyTimeTolerance >= 5 { phase = .tcp }
        }
        if targetPath == .udp, healthyDuration + mediaPolicyTimeTolerance >= 30 { recoveryAttempt = 0 }
        return []
    }

    public mutating func setPaused(_ value: Bool, now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), phase != .legacyTCP, phase != .stopped, paused != value else { return [] }
        paused = value; resetEvidence(preservingReduction: true); lastObservationAt = now
        if value {
            pausedAt = now
            if let id = probeID {
                resumeProbeIsInitial = phase == .probingUDP
                probeID = nil; probeDeadline = nil
                phase = resumeProbeIsInitial == true ? .initialTCP : .tcp
                return [.cancelProbe(id: id)]
            }
        } else {
            let duration = max(0, now - (pausedAt ?? now))
            if let nextRecoveryAt { self.nextRecoveryAt = nextRecoveryAt + duration }
            if let selectionStartedAt { self.selectionStartedAt = selectionStartedAt + duration }
            if targetPath == .udp { lastPongAt = now }
            pausedAt = nil
            if let initial = resumeProbeIsInitial {
                resumeProbeIsInitial = nil
                return beginProbe(initial: initial, now: now)
            }
        }
        return []
    }

    public mutating func stop() -> [MediaPathAction] {
        guard phase != .stopped else { return [] }
        let action = probeID.map { MediaPathAction.cancelProbe(id: $0) }
        probeID = nil; probeDeadline = nil; nextRecoveryAt = nil; resumeProbeIsInitial = nil
        selectionStartedAt = nil; lastPongAt = nil; pausedAt = nil
        if epoch < .max { epoch += 1 }
        phase = .stopped; activePath = nil
        resetEvidence()
        return action.map { [$0] } ?? []
    }

    private mutating func accept(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastNow else { return false }
        lastNow = now
        return true
    }

    private mutating func beginProbe(initial: Bool, now: TimeInterval) -> [MediaPathAction] {
        let id = UUID(), timeout: TimeInterval = initial ? initialProbeTimeout : 5
        probeID = id; probeDeadline = now + timeout
        phase = initial ? .probingUDP : .probingRecovery
        lastObservationAt = now; resetEvidence()
        return [.beginProbe(id: id, timeout: timeout)]
    }

    private mutating func probeFailed(id: UUID, now: TimeInterval, reason: MediaPathReason) -> [MediaPathAction] {
        guard accept(now), !paused, id == probeID, phase == .probingUDP || phase == .probingRecovery else { return [] }
        probeID = nil; probeDeadline = nil; phase = .tcp
        lastReason = reason; scheduleRecovery(now: now); resetEvidence(); trialHasFrame = false
        return [.cancelProbe(id: id)]
    }

    private mutating func fallBack(now: TimeInterval, reason: MediaPathReason) -> [MediaPathAction] {
        guard targetPath == .udp else { return [] }
        guard advanceEpoch() else { return [.restartSession(reason: .epochExhausted)] }
        targetPath = .tcp; phase = .switchingTCP
        selectionStartedAt = now; lastPongAt = nil; lastObservationAt = now
        lastReason = reason; scheduleRecovery(now: now); resetEvidence()
        return [.selectPath(.tcp, epoch: epoch, reason: reason)]
    }

    private mutating func advanceEpoch() -> Bool {
        guard epoch < .max else {
            _ = stop(); lastReason = .epochExhausted
            return false
        }
        epoch += 1
        return true
    }

    private mutating func scheduleRecovery(now: TimeInterval) {
        recoveryAttempt = min(4, recoveryAttempt + 1)
        nextRecoveryAt = now + [30.0, 60, 120, 300][recoveryAttempt - 1]
    }

    private mutating func resetEvidence(preservingReduction: Bool = false) {
        networkBadDuration = 0; computeBadDuration = 0; computeBottleneck = nil
        if !preservingReduction { loadReduced = false }
        healthyDuration = 0; trialDuration = 0
    }
}

// Automatic recommendations change pending/effective settings, never the user's preferred ceiling.
// The coordinator serializes requests and confirms only settings actually applied by the host.
public struct MediaQualityPolicy: Sendable {
    // An upgrade reduced again within the probation window failed; each failure doubles the healthy
    // time needed before the next one, so an unsustainable level is not retried every few seconds.
    public static let initialUpgradeHold: TimeInterval = 10
    public static let maximumUpgradeHold: TimeInterval = 300
    public static let upgradeProbation: TimeInterval = 30

    public private(set) var preferred: StreamSettings?
    public private(set) var upperBound: StreamSettings
    public private(set) var effective: StreamSettings
    public private(set) var pending: StreamSettings?
    public private(set) var upgradeHold = MediaQualityPolicy.initialUpgradeHold
    private let sourceLongestEdge: Int?
    private var lastNow: TimeInterval
    private var lastObservationAt: TimeInterval
    private var lastChangeAt: TimeInterval
    private var badDuration: TimeInterval = 0
    private var healthyDuration: TimeInterval = 0
    private var lastBottleneck: MediaBottleneck?
    private var pendingUpgrade = false
    private var upgradedAt: TimeInterval?

    public init(hostDefault: StreamSettings, preferred: StreamSettings? = nil, applied: StreamSettings? = nil,
                sourceLongestEdge: Int? = nil, now: TimeInterval) throws {
        try hostDefault.validateControlValues()
        if let preferred { try preferred.validateControlValues() }
        if let applied { try applied.validateControlValues() }
        self.preferred = preferred
        upperBound = preferred ?? hostDefault
        effective = applied ?? upperBound
        self.sourceLongestEdge = sourceLongestEdge.flatMap { (2...8192).contains($0) ? $0 : nil }
        lastNow = now.isFinite ? now : 0
        lastObservationAt = lastNow; lastChangeAt = lastNow
    }

    public mutating func chooseManually(_ settings: StreamSettings, now: TimeInterval) throws -> StreamSettings? {
        try settings.validateControlValues()
        guard accept(now) else { return nil }
        preferred = settings; upperBound = settings
        resetEvidence(); lastObservationAt = now; lastChangeAt = now
        upgradeHold = Self.initialUpgradeHold; upgradedAt = nil
        pending = effective == settings ? nil : settings
        pendingUpgrade = false
        return pending
    }

    public mutating func reduceLoad(for cause: MediaBottleneck, now: TimeInterval) -> StreamSettings? {
        guard accept(now), pending == nil, now - lastChangeAt + mediaPolicyTimeTolerance >= 3 else { return nil }
        settleUpgrade(now: now)
        var next = StreamSettings(longestEdge: min(effective.longestEdge, upperBound.longestEdge),
                                  framesPerSecond: min(effective.framesPerSecond, upperBound.framesPerSecond),
                                  megabits: min(effective.megabits, upperBound.megabits))
        if next != effective { return recommendReduction(next, now: now) }
        let dimensions = cause == .network ? [0, 1, 2] : [1, 2, 0]
        for dimension in dimensions {
            switch dimension {
            case 0:
                if let lower = StreamSettings.bitRates.last(where: { $0 < next.megabits }) { next.megabits = lower }
            case 1:
                let current = min(next.longestEdge, sourceLongestEdge ?? next.longestEdge)
                if let lower = StreamSettings.longestEdges.last(where: { $0 < current }) { next.longestEdge = lower }
            default:
                if let lower = StreamSettings.frameRates.last(where: { $0 < next.framesPerSecond }) { next.framesPerSecond = lower }
            }
            if next != effective { return recommendReduction(next, now: now) }
        }
        return nil
    }

    // When a coordinator consumes MediaPathAction.reduceLoad, it calls reduceLoad directly;
    // it must not also submit the same bad window here as a second adaptation source.
    public mutating func observe(_ sample: MediaPathSample, now: TimeInterval) -> StreamSettings? {
        guard accept(now), sample.isValid else { return nil }
        settleUpgrade(now: now)
        let elapsed = min(sample.duration, max(0, now - lastObservationAt))
        if now - lastObservationAt > sample.duration + 0.5 { resetEvidence() }
        lastObservationAt = now
        guard elapsed > 0 else { return nil }
        guard sample.mediaActive, pending == nil else { resetEvidence(); return nil }
        if let cause = sample.bottleneck {
            healthyDuration = 0
            if cause != lastBottleneck { badDuration = 0 }
            lastBottleneck = cause; badDuration += elapsed
            guard badDuration + mediaPolicyTimeTolerance >= 3 else { return nil }
            return reduceLoad(for: cause, now: now)
        }
        badDuration = 0; lastBottleneck = nil
        guard sample.hasNetworkEvidence, sample.decodedFrames > 0 else { healthyDuration = 0; return nil }
        healthyDuration += elapsed
        guard healthyDuration + mediaPolicyTimeTolerance >= upgradeHold,
              now - lastChangeAt + mediaPolicyTimeTolerance >= 3 else { return nil }
        var next = effective
        if next.framesPerSecond < upperBound.framesPerSecond {
            next.framesPerSecond = StreamSettings.frameRates.first(where: { $0 > next.framesPerSecond && $0 <= upperBound.framesPerSecond }) ?? next.framesPerSecond
        } else if next.longestEdge < upperBound.longestEdge {
            next.longestEdge = StreamSettings.longestEdges.first(where: { $0 > next.longestEdge && $0 <= upperBound.longestEdge }) ?? next.longestEdge
        } else if next.megabits < upperBound.megabits {
            next.megabits = StreamSettings.bitRates.first(where: { $0 > next.megabits && $0 <= upperBound.megabits }) ?? next.megabits
        }
        guard next != effective else { return nil }
        let recommended = recommend(next, now: now)
        pendingUpgrade = true
        return recommended
    }

    @discardableResult
    public mutating func confirmApplied(_ settings: StreamSettings, now: TimeInterval) -> Bool {
        guard accept(now), pending == settings else { return false }
        effective = settings; pending = nil; lastChangeAt = now; lastObservationAt = now
        if pendingUpgrade { upgradedAt = now }
        pendingUpgrade = false
        resetEvidence()
        return true
    }

    public mutating func synchronizeApplied(_ settings: StreamSettings, now: TimeInterval) throws {
        try settings.validateControlValues()
        guard accept(now) else { return }
        effective = settings
        if pending == settings { pending = nil; pendingUpgrade = false }
        lastChangeAt = now; lastObservationAt = now
        resetEvidence()
    }

    public mutating func rejectPending(now: TimeInterval) {
        guard accept(now) else { return }
        pending = nil; pendingUpgrade = false; lastChangeAt = now; lastObservationAt = now
        resetEvidence()
    }

    public mutating func resetObservation(now: TimeInterval) {
        guard accept(now) else { return }
        lastObservationAt = now; resetEvidence()
    }

    private mutating func accept(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastNow else { return false }
        lastNow = now
        return true
    }

    private mutating func recommend(_ settings: StreamSettings, now: TimeInterval) -> StreamSettings {
        pending = settings; pendingUpgrade = false; lastChangeAt = now; resetEvidence()
        return settings
    }

    private mutating func recommendReduction(_ settings: StreamSettings, now: TimeInterval) -> StreamSettings {
        if upgradedAt != nil {
            upgradeHold = min(Self.maximumUpgradeHold, upgradeHold * 2)
            upgradedAt = nil
        }
        return recommend(settings, now: now)
    }

    // An applied upgrade that survives probation proves that level; later pressure starts from the short hold.
    private mutating func settleUpgrade(now: TimeInterval) {
        guard let upgradedAt, now - upgradedAt + mediaPolicyTimeTolerance >= Self.upgradeProbation else { return }
        self.upgradedAt = nil
        upgradeHold = Self.initialUpgradeHold
    }

    private mutating func resetEvidence() {
        badDuration = 0; healthyDuration = 0; lastBottleneck = nil
    }
}
