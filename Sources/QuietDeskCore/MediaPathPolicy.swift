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

// Why the viewer moved video to another path. Diagnostic logs keep only the stable numeric code.
public enum MediaSwitchCause: Equatable, Sendable {
    case initial, recovery, retry, auxiliaryClosed
    case policy(MediaPathReason)

    public var diagnosticCode: Int {
        switch self {
        case .initial: return 1
        case .recovery: return 2
        case .retry: return 3
        case .auxiliaryClosed: return 4
        case .policy(let reason):
            switch reason {
            case .initialProbe: return 10
            case .recoveryProbe: return 11
            case .probeTimeout: return 12
            case .probeFailed: return 13
            case .noPong: return 14
            case .mediaTimeout: return 15
            case .networkDegraded: return 16
            case .epochExhausted: return 17
            }
        }
    }
}

public enum MediaPathAction: Equatable, Sendable {
    case beginProbe(id: UUID, timeout: TimeInterval)
    case cancelProbe(id: UUID)
    case selectPath(MediaPath, epoch: UInt32, reason: MediaPathReason)
    case reduceLoad(MediaBottleneck)
    case restartSession(reason: MediaPathReason)
    // Abandon the current UDP attempt and start a fresh keyframe on UDP after udpRetryDelay.
    case retryUDP
}

public enum MediaNetworkCondition: Equatable, Sendable {
    case severe, congested, healthy
}

// Compute load is the mean over one sample window. One slow keyframe, or a frame queued behind a burst
// of earlier ones, is latency rather than evidence that the codec cannot keep up with the frame rate.
public struct MediaComputeTiming: Sendable {
    private var total: Double = 0
    private var count = 0
    public init() {}
    public var mean: Double? { count > 0 ? total / Double(count) : nil }
    public mutating func add(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        total += milliseconds; count += 1
    }
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
    // Host-measured growth of frame delivery time over its recent minimum (TCP and UDP alike).
    public let deliveryMilliseconds: Double?
    // Video payload actually received in this window, used to tell a filled link from a quiet screen.
    public let receivedMegabits: Double?
    // Classified from the active transport route; a low RTT alone does not identify a local network.
    public let isLocalNetwork: Bool
    public let roundTripMilliseconds: Double?

    public init(duration: TimeInterval, mediaActive: Bool, networkSamples: Int, decodedFrames: Int,
                lossFraction: Double? = nil, jitterMilliseconds: Double? = nil, queueMilliseconds: Double? = nil,
                encodeMilliseconds: Double? = nil, decodeMilliseconds: Double? = nil,
                frameBudgetMilliseconds: Double = 1_000 / 60, deliveryMilliseconds: Double? = nil,
                receivedMegabits: Double? = nil, isLocalNetwork: Bool = false, roundTripMilliseconds: Double? = nil) {
        self.duration = duration; self.mediaActive = mediaActive
        self.networkSamples = networkSamples; self.decodedFrames = decodedFrames
        self.lossFraction = lossFraction; self.jitterMilliseconds = jitterMilliseconds
        self.queueMilliseconds = queueMilliseconds; self.encodeMilliseconds = encodeMilliseconds
        self.decodeMilliseconds = decodeMilliseconds; self.frameBudgetMilliseconds = frameBudgetMilliseconds
        self.deliveryMilliseconds = deliveryMilliseconds; self.receivedMegabits = receivedMegabits
        self.isLocalNetwork = isLocalNetwork; self.roundTripMilliseconds = roundTripMilliseconds
    }

    var isValid: Bool {
        guard duration.isFinite, duration > 0, duration <= 5, networkSamples >= 0, decodedFrames >= 0,
              frameBudgetMilliseconds.isFinite, frameBudgetMilliseconds > 0 else { return false }
        for value in [lossFraction, jitterMilliseconds, queueMilliseconds, encodeMilliseconds, decodeMilliseconds,
                      deliveryMilliseconds, receivedMegabits, roundTripMilliseconds] {
            if let value, !value.isFinite || value < 0 { return false }
        }
        return lossFraction.map { $0 <= 1 } ?? true
    }

    private var hasDatagramEvidence: Bool {
        networkSamples >= 8 && (lossFraction != nil || jitterMilliseconds != nil || queueMilliseconds != nil)
    }

    var hasNetworkEvidence: Bool { hasDatagramEvidence || deliveryMilliseconds != nil }

    /// A codec this much slower than the frame interval is overloaded. One just over it only delivers a few
    /// frames fewer than the cap, and the margin keeps measurement noise from reading as overload.
    public static let computeMargin = 1.1

    /// Time per frame of the slower codec: the host encodes one frame at a time, and decode time leaves out
    /// queueing behind earlier frames, so 1000 / this is the frame rate both sustain.
    public var computeMilliseconds: Double? {
        switch (encodeMilliseconds, decodeMilliseconds) {
        case let (encode?, decode?): return max(encode, decode)
        case let (encode, decode): return encode ?? decode
        }
    }

    var bottleneck: MediaBottleneck? {
        // Direct loss/jitter/delivery evidence survives a simultaneous compute bottleneck. A queue alone does not.
        if hasDatagramEvidence, (lossFraction ?? 0) >= 0.03 || (jitterMilliseconds ?? 0) >= 30 { return .network }
        if (deliveryMilliseconds ?? 0) >= 150 { return .network }
        // The slower codec is the one named, so the time per frame reported with it is its own.
        if let computeMilliseconds, computeMilliseconds >= frameBudgetMilliseconds * Self.computeMargin {
            return (decodeMilliseconds ?? 0) > (encodeMilliseconds ?? 0) ? .decoder : .encoder
        }
        if hasDatagramEvidence, (queueMilliseconds ?? 0) >= 60 { return .network }
        return nil
    }

    // Loss is the primary UDP signal; delivery growth covers TCP, where the system hides loss as delay.
    // The coordinator leaves keyframes out of the queue figure, so pacing one large frame is not congestion.
    public var networkCondition: MediaNetworkCondition? {
        guard hasNetworkEvidence else { return nil }
        let datagram = hasDatagramEvidence
        let loss = datagram ? lossFraction ?? 0 : 0
        let queue = datagram ? queueMilliseconds ?? 0 : 0
        let delivery = deliveryMilliseconds ?? 0
        if loss >= 0.10 || delivery >= 500 { return .severe }
        if loss >= 0.03 || delivery >= 150 || queue >= 120 || (datagram && (jitterMilliseconds ?? 0) >= 30) { return .congested }
        if loss < 0.01, delivery < 80, queue < 60 { return .healthy }
        return nil
    }
}

// Host side: time from handing a non-keyframe to the transport until the viewer reports it reassembled.
// Growth over the recent minimum is queueing somewhere on the path.
public struct MediaDeliveryEstimator: Sendable {
    public static let baselineSpan: TimeInterval = 30
    private var recent: [(at: TimeInterval, seconds: TimeInterval)] = []
    private var window: [TimeInterval] = []

    public init() {}

    public mutating func add(_ seconds: TimeInterval, at now: TimeInterval) {
        guard seconds.isFinite, seconds >= 0, seconds < 60, now.isFinite else { return }
        window.append(seconds)
        recent.append((now, seconds))
        if recent.count > 4_096 { recent.removeFirst(recent.count - 4_096) }
    }

    /// Mean delivery in this window above the 30-second minimum, in milliseconds; nil with fewer than three frames.
    public mutating func takeWindow(at now: TimeInterval) -> Double? {
        defer { window.removeAll() }
        recent.removeAll { now - $0.at > Self.baselineSpan }
        guard window.count >= 3, let floor = recent.map(\.seconds).min() else { return nil }
        return max(0, window.reduce(0, +) / Double(window.count) - floor) * 1_000
    }

    public mutating func reset() { recent.removeAll(); window.removeAll() }
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
    private var udpSelectedAt: TimeInterval?
    private var trialDuration: TimeInterval = 0
    private var trialHasFrame = false
    private var pausedAt: TimeInterval?
    private var resumeProbeIsInitial: Bool?
    private var alternateProbeUsed = false
    // UDP is kept while it can carry video at all; only this many failed UDP keyframes in a row,
    // each followed by a lower quality and a fresh UDP attempt, fall back to TCP.
    public static let udpMediaFailureLimit = 3
    public static let udpRetryDelay: TimeInterval = 1
    public private(set) var udpMediaFailures = 0
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
            return udpMediaFailed(now: now, abandonAttempt: true)
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
        probeID = nil; probeDeadline = nil; nextRecoveryAt = nil; udpMediaFailures = 0
        targetPath = .udp; phase = .trialUDP
        selectionStartedAt = now; lastPongAt = now; udpSelectedAt = now
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
        return udpMediaFailed(now: now, abandonAttempt: false)
    }

    // The coordinator already lowered quality for a failure it reported; a silent trial needs both.
    private mutating func udpMediaFailed(now: TimeInterval, abandonAttempt: Bool) -> [MediaPathAction] {
        udpMediaFailures += 1
        guard udpMediaFailures < Self.udpMediaFailureLimit else {
            udpMediaFailures = 0
            return fallBack(now: now, reason: .mediaTimeout)
        }
        if phase == .trialUDP { selectionStartedAt = now + Self.udpRetryDelay }
        resetEvidence()
        return abandonAttempt ? [.reduceLoad(.network), .retryUDP] : [.retryUDP]
    }

    /// `path` carried the committed keyframe. A recovery committed on TCP while a UDP trial waits for its
    /// retry keeps the picture current, but it neither proves UDP nor clears UDP failures.
    @discardableResult
    public mutating func mediaBecameUsable(epoch: UInt32, path: MediaPath, now: TimeInterval) -> Bool {
        guard accept(now), !paused, phase != .stopped, self.epoch == epoch else { return false }
        guard path == targetPath else {
            // That recovery held the UDP retry back, so the retry's trial window starts no earlier than now.
            if phase == .trialUDP, !trialHasFrame, let started = selectionStartedAt { selectionStartedAt = max(started, now) }
            return false
        }
        if path == .udp { udpMediaFailures = 0 }
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
        if now - lastObservationAt > sample.duration + 0.5 { resetEvidence() }
        lastObservationAt = now
        guard elapsed > 0 else { return [] }
        guard sample.mediaActive else { resetEvidence(); return [] }
        guard phase == .trialUDP || phase == .udp || phase == .tcpTrial || phase == .tcp else { return [] }
        let cause = sample.bottleneck
        // Compute pressure says nothing about the path. The quality policy lowers the load from the measured
        // codec time in the same sample; such a window only does not count toward a trial.
        if cause == .encoder || cause == .decoder { return [] }
        guard sample.hasNetworkEvidence else { return [] }
        // A congested path keeps its transport: the quality policy lowers the load instead, and only
        // failures to deliver video at all change the path.
        if cause == .network { trialDuration = 0; return [] }
        if phase == .trialUDP, trialHasFrame {
            trialDuration += elapsed
            if trialDuration + mediaPolicyTimeTolerance >= 5 { phase = .udp }
        } else if phase == .tcpTrial {
            trialDuration += elapsed
            if trialDuration + mediaPolicyTimeTolerance >= 5 { phase = .tcp }
        }
        return []
    }

    public mutating func setPaused(_ value: Bool, now: TimeInterval) -> [MediaPathAction] {
        guard accept(now), phase != .legacyTCP, phase != .stopped, paused != value else { return [] }
        paused = value; resetEvidence(); lastObservationAt = now
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
            if let udpSelectedAt { self.udpSelectedAt = udpSelectedAt + duration }
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
        selectionStartedAt = nil; lastPongAt = nil; pausedAt = nil; udpSelectedAt = nil
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
        // Only UDP that lasted about five minutes earns a fresh backoff. A route that fails every
        // minute or so keeps escalating, instead of switching paths every 30 seconds forever.
        if let udpSelectedAt, now - udpSelectedAt + mediaPolicyTimeTolerance >= 300 { recoveryAttempt = 0 }
        udpSelectedAt = nil
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

    private mutating func resetEvidence() {
        trialDuration = 0
    }
}

// Automatic recommendations change pending/effective settings, never the user's preferred ceiling.
// The coordinator serializes requests and confirms only settings actually applied by the host.
//
// Network adaptation is rate based: bitrate moves first in small steps, and the frame rate and then the
// longest edge drop only once the bitrate is too low to keep them sharp. Raising the bitrate needs healthy
// windows in which video actually filled a meaningful part of it, so a quiet screen never proves a level
// the path cannot carry. Compute pressure lowers the frame rate to what the codec sustains before the size.
public struct MediaQualityPolicy: Sendable {
    // An upgrade reduced again within the probation window failed; each failure doubles the healthy
    // time needed before the next one, so an unsustainable level is not retried every few seconds.
    public static let initialUpgradeHold: TimeInterval = 10
    public static let maximumUpgradeHold: TimeInterval = 300
    // A bitrate step reaches the running encoder without a new keyframe, so it may be tried sooner.
    public static let initialBitrateHold: TimeInterval = 4
    public static let maximumBitrateHold: TimeInterval = 120
    public static let upgradeProbation: TimeInterval = 30
    // Below this many bits per pixel and frame, screen text smears; lower the frame rate or size instead.
    public static let minimumBitsPerPixel = 0.02
    // Raising the frame rate or size needs room for twice that floor at the new level.
    public static let comfortableBitsPerPixel = 0.04
    // A bitrate upgrade needs windows that used at least this share of the current target.
    public static let filledShare = 0.5
    // Compute pressure lowers the frame rate first, straight to the rate the slower codec sustains
    // (1000 / its time per frame) but not below this floor. At the floor the size drops only when the
    // codec sustains less than `computeRateTolerance` of it, about 50 of 60 fps.
    public static let computeRateFloor = 60
    public static let computeRateTolerance = 0.85
    // A higher frame rate needs the measured time per frame to fit this share of its frame interval.
    public static let computeHeadroom = 0.85
    // Local links reduce only for delay. The host keeps at most three frames in flight, so about 100 ms of
    // queueing already caps the frame rate near 30 fps; scrolling was seen to hold steady near 120 ms.
    public static let localDelayedMilliseconds = 80.0
    public static let localReductionDelay: TimeInterval = 2
    public static let localHealthyMilliseconds = 50.0

    /// Why the last automatic recommendation was made, for diagnostics and the quality tooltip.
    public enum Adjustment: Equatable, Sendable {
        case network, localLatency, raise
        case compute(MediaBottleneck, milliseconds: Double?)
    }

    private enum UpgradeKind { case bitrate, pixels }

    public private(set) var preferred: StreamSettings?
    public private(set) var upperBound: StreamSettings
    public private(set) var effective: StreamSettings
    public private(set) var pending: StreamSettings?
    public private(set) var isLocalNetwork = false
    public private(set) var upgradeHold = MediaQualityPolicy.initialUpgradeHold
    public private(set) var bitrateHold = MediaQualityPolicy.initialBitrateHold
    private let bitRates: [Int]
    private var sourceLongestEdge: Int?
    private var aspect = 0.625
    private var lastNow: TimeInterval
    private var lastObservationAt: TimeInterval
    private var lastChangeAt: TimeInterval
    private var computeDuration: TimeInterval = 0
    private var congestedDuration: TimeInterval = 0
    private var healthyDuration: TimeInterval = 0
    private var filledDuration: TimeInterval = 0
    private var lastBottleneck: MediaBottleneck?
    private var pendingUpgrade: UpgradeKind?
    private var upgraded: (kind: UpgradeKind, at: TimeInterval)?
    public private(set) var lastAdjustment: Adjustment?
    // The slowest codec time per frame in the current run of healthy windows.
    private var peakComputeMilliseconds: Double?
    // Produced edges a compute reduction left, and when; not retried before the longest upgrade hold.
    private var slowEdges: [Int: TimeInterval] = [:]
    // Local delay reduced the load on this route, so its recovery climbs one step at a time.
    private var localLatencyLimited = false

    /// `bitRates` are the steps the host accepts; the ceiling itself always comes from the user or host.
    public init(hostDefault: StreamSettings, preferred: StreamSettings? = nil, applied: StreamSettings? = nil,
                sourceLongestEdge: Int? = nil, bitRates: [Int] = StreamSettings.bitRates,
                appliedSize: (width: Int, height: Int)? = nil, now: TimeInterval) throws {
        try hostDefault.validateControlValues()
        if let preferred { try preferred.validateControlValues() }
        if let applied { try applied.validateControlValues() }
        let ladder = Array(Set(bitRates.filter { StreamSettings.adaptiveBitRates.contains($0) })).sorted()
        guard !ladder.isEmpty else { throw DeskError.invalid("画质码率档位无效") }
        self.preferred = preferred
        upperBound = preferred ?? hostDefault
        effective = applied ?? upperBound
        self.bitRates = ladder
        self.sourceLongestEdge = sourceLongestEdge.flatMap { (2...8192).contains($0) ? $0 : nil }
        lastNow = now.isFinite ? now : 0
        lastObservationAt = lastNow; lastChangeAt = lastNow
        if let appliedSize { learn(appliedSize, for: effective) }
    }

    /// The first request for a path known to be narrow: the ceiling with its bitrate capped.
    public func startingSettings(maximumMegabits: Int) -> StreamSettings {
        var start = upperBound
        if let capped = bitRates.last(where: { $0 <= maximumMegabits }), capped < start.megabits { start.megabits = capped }
        return start
    }

    public mutating func chooseManually(_ settings: StreamSettings, now: TimeInterval) throws -> StreamSettings? {
        try settings.validateControlValues()
        guard accept(now) else { return nil }
        preferred = settings; upperBound = settings
        resetEvidence(); lastObservationAt = now; lastChangeAt = now
        upgradeHold = Self.initialUpgradeHold; bitrateHold = Self.initialBitrateHold; upgraded = nil
        slowEdges.removeAll(); lastAdjustment = nil; localLatencyLimited = false
        pending = effective == settings ? nil : settings
        pendingUpgrade = nil
        return pending
    }

    /// Route changes discard mixed-path timing evidence, but retain an in-flight settings request.
    public mutating func setLocalNetwork(_ enabled: Bool, now: TimeInterval) {
        guard accept(now), isLocalNetwork != enabled else { return }
        isLocalNetwork = enabled
        localLatencyLimited = false
        lastObservationAt = now
        resetEvidence()
    }

    /// `severe` halves the bitrate at once, for loss that is already breaking frames. For compute pressure,
    /// `computeMilliseconds` (the slower codec's measured time per frame) picks the frame rate it sustains;
    /// without it, as after a failed decode, the pixel load drops first. Local links require observed delay instead.
    public mutating func reduceLoad(for cause: MediaBottleneck, severe: Bool = false, computeMilliseconds: Double? = nil,
                                    now: TimeInterval) -> StreamSettings? {
        let spacing: TimeInterval = cause != .network ? 3 : severe ? 1 : 2
        guard accept(now), !isLocalNetwork, pending == nil, now - lastChangeAt + mediaPolicyTimeTolerance >= spacing else { return nil }
        settleUpgrade(now: now)
        var next = StreamSettings(longestEdge: min(effective.longestEdge, upperBound.longestEdge),
                                  framesPerSecond: min(effective.framesPerSecond, upperBound.framesPerSecond),
                                  megabits: min(effective.megabits, upperBound.megabits))
        let adjustment: Adjustment = cause == .network ? .network : .compute(cause, milliseconds: computeMilliseconds)
        if next != effective { return recommendReduction(next, adjustment: adjustment, now: now) }
        if cause == .network {
            next = networkReduction(from: next, factor: severe ? 0.5 : 0.75)
            return next != effective ? recommendReduction(next, adjustment: adjustment, now: now) : nil
        }
        if let computeMilliseconds, computeMilliseconds.isFinite, computeMilliseconds > 0 {
            next = computeReduction(from: next, milliseconds: computeMilliseconds)
            guard next != effective else { return nil }
            if shownEdge(next) < shownEdge(effective) { slowEdges[shownEdge(effective)] = now }
            return recommendReduction(next, adjustment: adjustment, now: now)
        }
        for dimension in [1, 2, 0] {
            switch dimension {
            case 0:
                if let lower = bitRates.last(where: { $0 < next.megabits }) { next.megabits = lower }
            case 1:
                if let lower = StreamSettings.longestEdges.last(where: { $0 < shownEdge(next) }) { next.longestEdge = lower }
            default:
                if let lower = StreamSettings.frameRates.last(where: { $0 < next.framesPerSecond }) { next.framesPerSecond = lower }
            }
            if next != effective { return recommendReduction(next, adjustment: adjustment, now: now) }
        }
        return nil
    }

    // Direct path failures already adapt nonlocal links, so their bad windows must not adapt twice.
    // Local links still need sampled delay after a path action asks to reduce the load.
    public mutating func observe(_ sample: MediaPathSample, now: TimeInterval) -> StreamSettings? {
        guard accept(now) else { return nil }
        guard sample.isValid else {
            if isLocalNetwork { lastObservationAt = now; resetEvidence() }
            return nil
        }
        setLocalNetwork(sample.isLocalNetwork, now: now)
        settleUpgrade(now: now)
        let elapsed = min(sample.duration, max(0, now - lastObservationAt))
        if now - lastObservationAt > sample.duration + 0.5 { resetEvidence() }
        lastObservationAt = now
        guard elapsed > 0 else { return nil }
        guard sample.mediaActive, pending == nil else { resetEvidence(); return nil }
        if isLocalNetwork {
            // Local links keep the chosen quality despite codec load or loss. Only sustained delay
            // reduces the load, including when congestion prevents frames from finishing decoding.
            guard let delay = [sample.deliveryMilliseconds, sample.roundTripMilliseconds].compactMap({ $0 }).max() else {
                resetEvidence()
                return nil
            }
            if delay >= Self.localDelayedMilliseconds {
                healthyDuration = 0; filledDuration = 0
                congestedDuration += elapsed
                guard congestedDuration + mediaPolicyTimeTolerance >= Self.localReductionDelay else { return nil }
                congestedDuration = 0
                let current = StreamSettings(longestEdge: min(effective.longestEdge, upperBound.longestEdge),
                                             framesPerSecond: min(effective.framesPerSecond, upperBound.framesPerSecond),
                                             megabits: min(effective.megabits, upperBound.megabits))
                let next = networkReduction(from: current, factor: 0.75)
                guard next != effective else { return nil }
                localLatencyLimited = true
                return recommendReduction(next, adjustment: .localLatency, now: now)
            }
            congestedDuration = 0
            guard delay < Self.localHealthyMilliseconds, sample.decodedFrames > 0 else {
                healthyDuration = 0; filledDuration = 0
                return nil
            }
            healthyDuration += elapsed
            if !localLatencyLimited {
                // Below the ceiling for another reason, such as a cautious start: restore it at once.
                guard healthyDuration + mediaPolicyTimeTolerance >= 3, effective != upperBound else { return nil }
                lastAdjustment = .raise
                return recommend(upperBound, now: now)
            }
            // Delay already showed what this route carries. A quiet screen has low delay at any bitrate,
            // so climb one step at a time, and only on windows in which video used a real share of it.
            if let received = sample.receivedMegabits, received >= Double(effective.megabits) * Self.filledShare {
                filledDuration += elapsed
            }
            return upgrade(now: now)
        }
        if let cause = sample.bottleneck, cause != .network {
            congestedDuration = 0; healthyDuration = 0; filledDuration = 0; peakComputeMilliseconds = nil
            if cause != lastBottleneck { computeDuration = 0 }
            lastBottleneck = cause; computeDuration += elapsed
            guard computeDuration + mediaPolicyTimeTolerance >= 3 else { return nil }
            return reduceLoad(for: cause, computeMilliseconds: sample.computeMilliseconds, now: now)
        }
        computeDuration = 0; lastBottleneck = nil
        switch sample.networkCondition {
        case .severe?:
            congestedDuration = 0; healthyDuration = 0; filledDuration = 0
            return reduceLoad(for: .network, severe: true, now: now)
        case .congested?:
            healthyDuration = 0; filledDuration = 0; peakComputeMilliseconds = nil
            congestedDuration += elapsed
            guard congestedDuration + mediaPolicyTimeTolerance >= 2 else { return nil }
            return reduceLoad(for: .network, now: now)
        case .healthy?:
            congestedDuration = 0
            guard sample.decodedFrames > 0 else { return nil }
            healthyDuration += elapsed
            if let compute = sample.computeMilliseconds { peakComputeMilliseconds = max(peakComputeMilliseconds ?? 0, compute) }
            if let received = sample.receivedMegabits, received >= Double(effective.megabits) * Self.filledShare {
                filledDuration += elapsed
            }
            return upgrade(now: now)
        case nil:
            // Between thresholds, or a quiet screen: neither a reason to reduce nor proof for more.
            congestedDuration = 0
            return nil
        }
    }

    @discardableResult
    public mutating func confirmApplied(_ settings: StreamSettings, now: TimeInterval) -> Bool {
        guard accept(now), pending == settings else { return false }
        effective = settings; pending = nil; lastChangeAt = now; lastObservationAt = now
        if let pendingUpgrade { upgraded = (pendingUpgrade, now) }
        pendingUpgrade = nil
        resetEvidence()
        return true
    }

    /// The host's actual settings and, when known, the output size they produced.
    public mutating func synchronizeApplied(_ settings: StreamSettings, size: (width: Int, height: Int)? = nil,
                                            now: TimeInterval) throws {
        try settings.validateControlValues()
        guard accept(now) else { return }
        effective = settings
        if let size { learn(size, for: settings) }
        if pending == settings { pending = nil; pendingUpgrade = nil }
        lastChangeAt = now; lastObservationAt = now
        resetEvidence()
    }

    public mutating func rejectPending(now: TimeInterval) {
        guard accept(now) else { return }
        pending = nil; pendingUpgrade = nil; lastChangeAt = now; lastObservationAt = now
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

    // An output clearly smaller than its requested edge is the whole source, which caps every larger setting.
    // Scaling floors to even pixels, so an output within two pixels of the edge only shows the source is at
    // least that large, and lifts a smaller size learned before (the shared display may have changed).
    private mutating func learn(_ size: (width: Int, height: Int), for settings: StreamSettings) {
        let longest = max(size.width, size.height), shortest = min(size.width, size.height)
        guard (2...8192).contains(longest), shortest >= 2 else { return }
        aspect = Double(shortest) / Double(longest)
        if longest < settings.longestEdge - 2 { sourceLongestEdge = longest }
        else if let known = sourceLongestEdge, known < longest { sourceLongestEdge = nil }
    }

    private func shownEdge(_ settings: StreamSettings) -> Int {
        min(settings.longestEdge, sourceLongestEdge ?? settings.longestEdge)
    }

    private func megabits(_ bitsPerPixel: Double, for settings: StreamSettings) -> Double {
        let edge = Double(shownEdge(settings))
        return bitsPerPixel * min(36_000_000, edge * edge * aspect) * Double(settings.framesPerSecond) / 1_000_000
    }

    // The highest supported rate the codec keeps up with, not below the floor; at the floor, one size step
    // only when the codec falls clearly short of it, then the remaining rate and bitrate steps.
    private func computeReduction(from current: StreamSettings, milliseconds: Double) -> StreamSettings {
        var next = current
        let sustained = 1_000 / milliseconds
        let floor = min(Self.computeRateFloor, upperBound.framesPerSecond)
        if current.framesPerSecond > floor {
            let rate = StreamSettings.frameRates.last(where: { Double($0) <= sustained && $0 < current.framesPerSecond }) ?? floor
            next.framesPerSecond = max(floor, rate)
            return next
        }
        guard sustained < Double(floor) * Self.computeRateTolerance else { return current }
        if let lower = StreamSettings.longestEdges.last(where: { $0 < shownEdge(current) }) {
            next.longestEdge = lower
        } else if let lower = StreamSettings.frameRates.last(where: { $0 < current.framesPerSecond }) {
            next.framesPerSecond = lower
        } else if let lower = bitRates.last(where: { $0 < current.megabits }) {
            next.megabits = lower
        }
        return next
    }

    private func computeFits(_ framesPerSecond: Int) -> Bool {
        peakComputeMilliseconds.map { $0 <= Self.computeHeadroom * 1_000 / Double(framesPerSecond) } ?? true
    }

    private func recentlySlow(_ settings: StreamSettings, now: TimeInterval) -> Bool {
        slowEdges[shownEdge(settings)].map { now - $0 < Self.maximumUpgradeHold } ?? false
    }

    private func networkReduction(from current: StreamSettings, factor: Double) -> StreamSettings {
        var next = current
        let target = Double(current.megabits) * factor
        if let lower = bitRates.last(where: { Double($0) <= target && $0 < current.megabits }) ?? bitRates.last(where: { $0 < current.megabits }) {
            next.megabits = lower
        }
        // Keep text readable at a low bitrate: 30 fps first, then a smaller image, then fewer frames.
        while Double(next.megabits) < megabits(Self.minimumBitsPerPixel, for: next) {
            if next.framesPerSecond > 30 {
                next.framesPerSecond = StreamSettings.frameRates.last(where: { $0 < next.framesPerSecond && $0 >= 30 }) ?? 30
            } else if let lower = StreamSettings.longestEdges.last(where: { $0 < shownEdge(next) }), lower >= 1280 {
                next.longestEdge = lower
            } else if let lower = StreamSettings.frameRates.last(where: { $0 < next.framesPerSecond }) {
                next.framesPerSecond = lower
            } else { break }
        }
        return next
    }

    // Smoothness, then sharpness, once the bitrate leaves room for them; otherwise a larger bitrate.
    private mutating func upgrade(now: TimeInterval) -> StreamSettings? {
        guard now - lastChangeAt + mediaPolicyTimeTolerance >= 3 else { return nil }
        var next = effective
        if let higher = StreamSettings.frameRates.first(where: { $0 > next.framesPerSecond && $0 <= upperBound.framesPerSecond }) {
            var candidate = next; candidate.framesPerSecond = higher
            if Double(next.megabits) >= megabits(Self.comfortableBitsPerPixel, for: candidate), computeFits(higher) {
                guard healthyDuration + mediaPolicyTimeTolerance >= upgradeHold else { return nil }
                return recommendUpgrade(candidate, kind: .pixels, now: now)
            }
        }
        if shownEdge(next) < shownEdge(upperBound),
           let higher = StreamSettings.longestEdges.first(where: { $0 > next.longestEdge && $0 <= upperBound.longestEdge }) {
            var candidate = next; candidate.longestEdge = higher
            if Double(next.megabits) >= megabits(Self.comfortableBitsPerPixel, for: candidate), !recentlySlow(candidate, now: now) {
                guard healthyDuration + mediaPolicyTimeTolerance >= upgradeHold else { return nil }
                return recommendUpgrade(candidate, kind: .pixels, now: now)
            }
        }
        guard next.megabits < upperBound.megabits, filledDuration + mediaPolicyTimeTolerance >= bitrateHold else { return nil }
        let target = Double(next.megabits) * 1.25
        guard let higher = bitRates.first(where: { Double($0) >= target && $0 <= upperBound.megabits })
                ?? bitRates.last(where: { $0 > next.megabits && $0 <= upperBound.megabits }) else { return nil }
        next.megabits = higher
        return recommendUpgrade(next, kind: .bitrate, now: now)
    }

    private mutating func recommendUpgrade(_ settings: StreamSettings, kind: UpgradeKind, now: TimeInterval) -> StreamSettings {
        let recommended = recommend(settings, now: now)
        pendingUpgrade = kind
        lastAdjustment = .raise
        return recommended
    }

    private mutating func recommend(_ settings: StreamSettings, now: TimeInterval) -> StreamSettings {
        pending = settings; pendingUpgrade = nil; lastChangeAt = now; resetEvidence()
        return settings
    }

    private mutating func recommendReduction(_ settings: StreamSettings, adjustment: Adjustment,
                                             now: TimeInterval) -> StreamSettings {
        lastAdjustment = adjustment
        if let upgraded {
            switch upgraded.kind {
            case .bitrate: bitrateHold = min(Self.maximumBitrateHold, bitrateHold * 2)
            case .pixels: upgradeHold = min(Self.maximumUpgradeHold, upgradeHold * 2)
            }
            self.upgraded = nil
        }
        return recommend(settings, now: now)
    }

    // An applied upgrade that survives probation proves that level; later pressure starts from the short hold.
    private mutating func settleUpgrade(now: TimeInterval) {
        guard let upgraded, now - upgraded.at + mediaPolicyTimeTolerance >= Self.upgradeProbation else { return }
        self.upgraded = nil
        switch upgraded.kind {
        case .bitrate: bitrateHold = Self.initialBitrateHold
        case .pixels: upgradeHold = Self.initialUpgradeHold
        }
    }

    private mutating func resetEvidence() {
        computeDuration = 0; congestedDuration = 0; healthyDuration = 0; filledDuration = 0; lastBottleneck = nil
        peakComputeMilliseconds = nil
    }
}
