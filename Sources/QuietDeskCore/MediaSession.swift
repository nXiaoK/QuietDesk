import CryptoKit
import Foundation
import Network
import Security

// A child meter can outlive its Peer while Network.framework finishes submitted data.
private final class MediaTrafficRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: TrafficMeter
    private let onBytes: (Int) -> Void
    private var previous = TrafficTotals()

    init(parent: TrafficMeter, onBytes: @escaping (Int) -> Void) { self.parent = parent; self.onBytes = onBytes }

    func receive(_ snapshot: TrafficSnapshot) {
        let delta = lock.withLock { () -> TrafficTotals in
            let sent = max(previous.sentBytes, snapshot.totals.sentBytes)
            let received = max(previous.receivedBytes, snapshot.totals.receivedBytes)
            let delta = TrafficTotals(sentBytes: sent - previous.sentBytes, receivedBytes: received - previous.receivedBytes)
            previous = TrafficTotals(sentBytes: sent, receivedBytes: received)
            return delta
        }
        guard delta.sentBytes > 0 || delta.receivedBytes > 0 else { return }
        parent.record(sentBytes: delta.sentBytes, receivedBytes: delta.receivedBytes)
        let total = delta.sentBytes.addingReportingOverflow(delta.receivedBytes)
        if !total.overflow, let count = Int(exactly: total.partialValue) { onBytes(count) }
    }
}

package struct MediaDatagramChallenges {
    private static let lifetime: TimeInterval = 1
    private static let maximumOutstanding = 20
    private var outstanding: [(nonce: Data, sentAt: TimeInterval)] = []

    package init() {}

    package mutating func sent(_ nonce: Data, at now: TimeInterval) {
        outstanding.removeAll { now - $0.sentAt >= Self.lifetime }
        if outstanding.count == Self.maximumOutstanding { outstanding.removeFirst() }
        outstanding.append((nonce, now))
    }

    package mutating func answer(_ nonce: Data, at now: TimeInterval) -> (sentAt: TimeInterval, roundTrip: TimeInterval)? {
        guard let index = outstanding.firstIndex(where: { $0.nonce == nonce }) else { return nil }
        let sentAt = outstanding.remove(at: index).sentAt
        let roundTrip = now - sentAt
        guard roundTrip >= 0, roundTrip < Self.lifetime else { return nil }
        return (sentAt, roundTrip)
    }

    package mutating func clear() { outstanding.removeAll(keepingCapacity: true) }
}

// One queue owns negotiation, transport selection, frame credit and cutover transactions.
public final class MediaSession: @unchecked Sendable {
    public struct DatagramEndpoint: Sendable {
        public let host: String
        public let port: UInt16
        // Called on the media queue when this route's current datagram lease is retired.
        public let retire: (@Sendable () -> Void)?
        public init(host: String, port: UInt16, retire: (@Sendable () -> Void)? = nil) {
            self.host = host; self.port = port; self.retire = retire
        }
    }
    public static let maximumTCPAudioFallbackPendingBytes = 512 * 1024
    public var diagnostics: PerformanceDiagnostics?
    public var onVideo: ((MediaFrame, @escaping (Bool) -> Void) -> Void)?
    public var onCommitStream: ((MediaStreamID, VideoPacket) -> Void)?
    public var onReceiveFrameWindow: ((Int?) -> Void)?
    public var onPrepareRecovery: ((@escaping (Bool) -> Void) -> Void)?
    public var onPrepareStream: ((MediaStreamID, @escaping (Bool) -> Void) -> Void)?
    public var onProduceRecoveryFrame: (() -> Void)?
    public var onResumeFrames: (() -> Void)?
    public var onAcknowledged: ((UInt32) -> Void)?
    public var onState: ((String) -> Void)?
    // Viewer only, on the media queue: a new transaction moves video to another path (labels match onState).
    public var onPathSwitch: ((String, MediaSwitchCause) -> Void)?
    public var onBytes: ((Int) -> Void)?
    public var onFrameSent: (() -> Void)?
    public var onReliableData: ((Message) -> Void)?
    public var onCursorPosition: ((CursorPosition) -> Void)?
    public var onInteractiveInput: ((RemoteInput) -> Void)?
    public var onAudioPacket: ((RemoteAudioPacket) -> Void)?
    public var onReduceLoad: ((MediaBottleneck) -> Void)?
    public var onSample: ((MediaPathSample) -> Void)?
    /// Host-side frame delivery delay above the recent minimum, excluding keyframes and planned pacing.
    public var onVideoDeliveryDelay: ((Double) -> Void)?
    public var hasRecentMappedPayload: (() -> Bool)?
    // Actual video route classification, delivered before its sample or direct reduction callback.
    public var onLocalNetwork: ((Bool) -> Void)?
    public var prepareAlternateDatagramPath: ((@escaping (DatagramEndpoint?) -> Void) -> Void)?
    public var onDatagramPathRetired: (() -> Void)?
    // Resolve the host lease at admission, before DTLS authentication can outlive that lease.
    public var hostDatagramBinding: ((NWEndpoint) -> ((Data) -> Void)?)?
    public var onReliablePathFailure: (() -> Void)?
    // Viewer only, once per relayed DTLS flow after it passed the session-key handshake and a
    // challenge in both directions. The secret lets the relay bridges authenticate a direct path.
    public var onRelayedDatagramAuthenticated: ((NWEndpoint, Data) -> Void)?
    // Viewer only, on the media queue, once per sample window: the share of UDP video fragments that
    // missed the reorder window over about five seconds. Nil while video is not being received over
    // UDP (committed or on trial) or too few fragments arrived. Display and diagnostics only; path and quality policy do not use it.
    public var onDatagramLoss: ((Double?) -> Void)?
    // Viewer report observations are ordered on the media queue. An outgoing receiver settles its
    // fragments before the new receiver's trial or preparation event is published.
    public var onDiagnosticVideoPath: ((DiagnosticVideoPath) -> Void)?
    public var onDiagnosticUDPRoundTrip: ((Double) -> Void)?
    public var onDiagnosticUDPLoss: ((_ settled: Int, _ lost: Int) -> Void)?

    public static func peerAssistSecret(datagramKey: Data, sessionID: UUID) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: datagramKey), salt: Data(sessionID.uuidString.utf8),
                               info: Data("QuietDesk relay peer path v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    private enum Side { case host, viewer }
    public enum Path: String, Sendable { case udp, tcp, shared }
    public enum DiagnosticVideoPath: Equatable, Sendable {
        case preparing
        case trialUDP(relayed: Bool)
        case committed(Path, relayedUDP: Bool)
    }
    private enum Stage { case preparing, ready, producing, decoded, committed }
    private struct Transaction {
        let id: UUID
        let stream: MediaStreamID
        let path: Path
        let started: TimeInterval
        var stage: Stage = .preparing
        var packet: VideoPacket?
        var diagnostic: PerformanceDiagnostics.Token?
        var frameSubmitted = false
        var localNetwork = false
        var awaitingUDPVerification = false
        // A recovery on the path already in use: the host produces the keyframe without waiting for the
        // viewer's ready, and each side commits once the viewer decoded it.
        var fast = false
        // Viewer, fast only: the host's ready arrived, so every control message sent before it has too.
        var hostReady = false
        // Host, fast on UDP only: the keyframe waits for the pong of a ping sent after this transaction
        // began. That ping crossed the path behind everything the old stream had sent, so its answer shows
        // the path is up and its queue no longer holds the old stream's datagrams.
        var awaitingLiveness = false
        var livenessFrom: TimeInterval = 0
        // Viewer, fast only: when the datagram copy of the prepare last left, and how often.
        var requestSentAt: TimeInterval = 0
        var requestSends = 0
        // Viewer, fast only: the keyframe arrived before the host's ready. Control messages the host sent
        // while preparing this stream (its cursor binding) precede that ready, so decoding waits for it.
        var heldFrame: MediaFrame?
    }
    private static let fastRequestInterval: TimeInterval = 0.05
    private static let maximumFastRequests = 20
    private struct Datagram {
        let header: MediaFrameHeader
        let fragmentIndex: UInt16?
        let data: Data
        let repair: Bool
        // The last original fragment of its frame: once it left, the viewer's word about the frame is due.
        var completesOriginals = false
    }
    private struct PathFingerprint: Equatable {
        let status: NWPath.Status
        let wifi: Bool
        let ethernet: Bool
        let cellular: Bool
        let loopback: Bool
        let other: Bool
        let ipv4: Bool
        let ipv6: Bool

        init(_ path: NWPath) {
            status = path.status; wifi = path.usesInterfaceType(.wifi)
            ethernet = path.usesInterfaceType(.wiredEthernet); cellular = path.usesInterfaceType(.cellular)
            loopback = path.usesInterfaceType(.loopback); other = path.usesInterfaceType(.other)
            ipv4 = path.supportsIPv4; ipv6 = path.supportsIPv6
        }
    }
    private let queue = DispatchQueue(label: "quietdesk.media-session", qos: .userInteractive)
    private let control: Peer
    private let key: PairingKey
    private let side: Side
    private let host: String?
    private let port: UInt16
    private let udpEnabled: Bool
    private let relayRoutingEnabled: Bool
    private let initialDatagramRelayed: Bool
    private var relayRoutingNegotiated = false
    private var viewerAcceptsMarkedRepairs = false
    private var datagramInteractiveNegotiated = false
    private var dynamicFrameWindowNegotiated = false
    private var parityFECNegotiated = false
    private var blockFECNegotiated = false
    // Host only: the largest frame, in fragments, the viewer accepts block FEC shards for.
    private var fecFragmentLimit = BlockFECPlanner.legacyProtectedFrameFragments
    private var datagramAudioNegotiated = false
    private var fastRecoveryNegotiated = false
    private var advertisedReceiveFrameWindow: Int?
    private var lastReportedReceiveWindow: Int?
    private var hasMeasuredRoundTrip = false
    private var lastHostNackAt: TimeInterval?
    private var recentNackEvents: [(at: TimeInterval, count: Int)] = []
    private let interactiveDatagramLock = NSLock()
    private var interactiveDatagramAvailable = false
    private static let repairedFragmentKind: UInt8 = 5
    private static let cursorPositionDatagramKind: UInt8 = 6
    private static let interactiveInputDatagramKind: UInt8 = 7
    private static let parityDatagramKind: UInt8 = 8
    private static let audioPacketDatagramKind: UInt8 = 9
    private static let blockFECDatagramKind: UInt8 = 10
    private static let recoveryRequestDatagramKind: UInt8 = 11
    private var alternateRequested = false
    private var alternateProbePending = false
    private var alternateRetryDeferred = false
    private var alternateEndpoint: DatagramEndpoint?
    private var reliableDeliveryFailures = 0
    private var reliableFailureNotified = false
    private var hostAssist: ((Data) -> Void)?
    private var udpRelayed = false
    private var settings: StreamSettings
    private var stopped = false
    private var started = false
    private var paused = false
    private var configurationSuspended = false
    private var recoveryHold = false
    private let ingressLock = NSLock()
    private var ingressBytes = 0
    private var ingressMessages = 0
    private var negotiated = false
    private var sessionID: UUID?
    private var datagramKey: Data?
    private var grant: MediaBindingGrant?
    private var bindingToken: Data?
    private var offerSent = false
    private var udpAvailable = false
    private var udpListener: NWListener?
    private var udpPeer: BoundedDatagramPeer?
    private weak var assistAnnouncedPeer: BoundedDatagramPeer?
    private var pendingDatagramPeers: [ObjectIdentifier: BoundedDatagramPeer] = [:]
    private var udpVerified = false
    private var receivedChallenge = false
    private var challenges = MediaDatagramChallenges()
    private var lastPingAt: TimeInterval = 0
    private var lastPongAt: TimeInterval = 0
    private var livenessResumedAt: TimeInterval = 0
    private var livenessGrace = LocalSchedulingGrace()
    private var roundTrip: TimeInterval = 0.01
    // Send time of the newest answered challenge.
    private var lastAnsweredChallengeAt: TimeInterval = 0
    private var controlRoundTrip: (milliseconds: Double, at: TimeInterval)?
    private var reportedLocalNetwork: Bool?
    private var videoPeer: Peer?
    private var bulkPeer: Peer?
    private var videoBound = false
    private var bulkBound = false
    private var pendingAuxiliary: [ObjectIdentifier: Peer] = [:]
    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var pathFingerprint: PathFingerprint?
    private var policy: MediaPathPolicy
    private var active: (stream: MediaStreamID, path: Path, localNetwork: Bool)?
    private var transaction: Transaction?
    private var receiver: MediaFrameReassembler?
    private var lossWindow = MediaLossWindow()
    private var cache: MediaRetransmissionCache?
    private var nextFrameID: UInt64 = 1
    private var transportEpoch: UInt32 = 0
    private var codecEpoch: UInt32 = 0
    private var fallbackAt: TimeInterval = 0
    private var retryAt: TimeInterval = 0
    private var retryPath: Path?
    private var requestedRecoveryAt: TimeInterval = 0
    private var interruptedStream: MediaStreamID?
    private var pendingDatagrams: [Datagram] = []
    private var datagramOffset = 0
    private var pendingDatagramBytes = 0
    private var pacingCredit: Double = 0
    private var pacingUpdatedAt: TimeInterval = 0
    private var pacingScheduled = false
    private var pacingTimer: DispatchSourceTimer?
    private var pacingGeneration: UInt64 = 0
    private var pollScheduled = false
    private var pollTimer: DispatchSourceTimer?
    private var decoding: Set<MediaFrameHeader> = []
    private var reassembledLocally: Set<MediaFrameHeader> = []
    private var reassembledAtPeer: Set<MediaFrameHeader> = []
    private var sentHeaders: Set<MediaFrameHeader> = []
    private var originalSubmittedCounts: [MediaFrameHeader: Int] = [:]
    private var sampleStartedAt = SessionClock.now
    private var samplePackets = 0
    private var sampleFrames = 0
    private var sampleWaitMilliseconds: Double = 0
    private var sampleBytes = 0
    private var sampleSettledFragments = 0
    private var sampleLostFragments = 0
    private var sampleDeliveryMilliseconds: Double?
    private var sampleMappedTransfer: MappedTransferState?
    private var waitingCreditStream: MediaStreamID?
    private var udpJitter = MediaJitterEstimator()
    private var deliveryEstimator = MediaDeliveryEstimator()
    private var deliveryPath: Path?
    // Hand-off time and the frame's own pacing time, which is not queueing.
    private var deliverySentAt: [MediaFrameHeader: (at: TimeInterval, paced: TimeInterval)] = [:]
    private var sampleEncode = MediaComputeTiming()
    private var sampleDecode = MediaComputeTiming()
    private var sampleDirectReduction = false
    private var lastVideoAt: TimeInterval = 0
    private var lastDecodedAt: TimeInterval?

    public static func host(control: Peer, key: PairingKey, port: UInt16, settings: StreamSettings,
                            relayRouting: Bool = false) throws -> MediaSession {
        try MediaSession(control: control, key: key, side: .host, host: nil, port: port, settings: settings,
                         udpEnabled: true, relayRouting: relayRouting, relayedDatagram: false)
    }

    public static func viewer(control: Peer, key: PairingKey, host: String, port: UInt16,
                              settings: StreamSettings, udpEnabled: Bool = true, relayRouting: Bool = false,
                              relayedDatagram: Bool = false) throws -> MediaSession {
        guard !host.isEmpty else { throw DeskError.invalid("媒体目标地址为空") }
        return try MediaSession(control: control, key: key, side: .viewer, host: host, port: port,
                                settings: settings, udpEnabled: udpEnabled, relayRouting: relayRouting, relayedDatagram: relayedDatagram)
    }

    private init(control: Peer, key: PairingKey, side: Side, host: String?, port: UInt16,
                 settings: StreamSettings, udpEnabled: Bool, relayRouting: Bool, relayedDatagram: Bool) throws {
        try settings.validateControlValues()
        guard port > 0 else { throw DeskError.invalid("媒体端口无效") }
        self.control = control; self.key = key; self.side = side; self.host = host
        self.port = port; self.settings = settings; self.udpEnabled = udpEnabled
        relayRoutingEnabled = relayRouting
        initialDatagramRelayed = relayedDatagram
        policy = MediaPathPolicy(capable: udpEnabled, now: SessionClock.now, initialProbeTimeout: relayedDatagram ? 5 : 1.5)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.livenessGrace = LocalSchedulingGrace()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, !self.stopped else { return }
                let fingerprint = PathFingerprint(path)
                if let previous = self.pathFingerprint, previous != fingerprint { self.networkPathChanged() }
                self.pathFingerprint = fingerprint
            }
            self.pathMonitor = monitor; monitor.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
            if self.side == .viewer {
                self.onDiagnosticVideoPath?(.preparing)
                self.sendControl(MediaControl(.request, relayRouting: self.relayRoutingEnabled ? true : nil,
                                              receiveFrameWindow: MediaBufferLimits.receiveFrameWindow, markedRepairs: true,
                                              datagramInteractive: true, dynamicFrameWindow: true, parityFEC: true,
                                              blockFEC: true, datagramAudio: true,
                                              fecFragmentLimit: BlockFECPlanner.maximumProtectedFrameFragments,
                                              fastRecovery: true))
                self.onState?("正在优化传输")
            }
        }
    }

    // This method only classifies synchronously; all state changes stay on the media queue.
    public func receive(_ message: Message) -> Bool {
        guard [.mediaControl, .mediaFrame, .mediaFeedback].contains(message.kind) else { return false }
        guard message.payload.count <= Wire.maximumMessageBytes else { control.close("媒体消息过大"); return true }
        let cost = message.payload.count + 5
        let accepted = ingressLock.withLock { () -> Bool in
            guard ingressMessages < 256, cost <= 32 * 1024 * 1024 - ingressBytes else { return false }
            ingressBytes += cost; ingressMessages += 1
            return true
        }
        guard accepted else { control.close("媒体接收队列已满"); return true }
        queue.async { [weak self] in
            guard let self else { return }
            self.ingressLock.withLock { self.ingressBytes -= cost; self.ingressMessages -= 1 }
            self.receiveMessage(message, auxiliary: nil)
        }
        return true
    }

    public func sendVideo(_ packet: VideoPacket) {
        queue.async { [weak self] in self?.sendFrame(packet) }
    }

    public func sendReliableData(_ message: Message) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if Self.isBulk(message.kind), self.bulkBound, let peer = self.bulkPeer { peer.send(message) }
            else { self.control.send(message) }
        }
    }

    @discardableResult
    public func sendCursorPosition(_ position: CursorPosition) -> Bool {
        guard side == .host, interactiveDatagramLock.withLock({ interactiveDatagramAvailable }) else { return false }
        let encoded = position.encode()
        var packet = Data(capacity: 1 + encoded.count)
        packet.append(Self.cursorPositionDatagramKind)
        packet.append(encoded)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.paused, !self.configurationSuspended, self.datagramInteractiveNegotiated,
               self.udpVerified, let peer = self.udpPeer, self.sendDatagram(packet, using: peer) {
                return
            }
            self.control.send(Message(.cursorPosition, encoded))
        }
        return true
    }

    @discardableResult
    public func sendInteractiveInput(_ input: RemoteInput) -> Bool {
        guard side == .viewer,
              input.kind == .move || input.kind == .drag,
              input.pointerSequence != nil,
              interactiveDatagramLock.withLock({ interactiveDatagramAvailable }),
              let encoded = try? JSONEncoder().encode(input),
              encoded.count + 1 <= MediaFragment.maximumDatagramBytes + 1 else {
            return false
        }
        var packet = Data(capacity: 1 + encoded.count)
        packet.append(Self.interactiveInputDatagramKind)
        packet.append(encoded)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.paused, !self.configurationSuspended, self.datagramInteractiveNegotiated,
               self.udpVerified, let peer = self.udpPeer {
                _ = self.sendDatagram(packet, using: peer)
                return
            }
            self.control.send(Message(.input, encoded))
        }
        return true
    }

    @discardableResult
    public func sendAudioPacket(_ packet: RemoteAudioPacket) -> Bool {
        guard side == .host else { return false }
        let encoded = packet.encode()
        guard encoded.count + 1 <= MediaFragment.maximumDatagramBytes + 1 else { return false }
        var datagram = Data(capacity: 1 + encoded.count)
        datagram.append(Self.audioPacketDatagramKind)
        datagram.append(encoded)
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.paused, !self.configurationSuspended else { return }
            if self.datagramAudioNegotiated, self.udpVerified, let peer = self.udpPeer {
                _ = self.sendDatagram(datagram, using: peer)
                return
            }
            // Over TCP fallback, drop live audio packets if the control socket is congested (> 512 KiB).
            if self.control.queuedSendBytes <= Self.maximumTCPAudioFallbackPendingBytes {
                self.control.send(Message(.audioFrame, encoded))
            }
        }
        return true
    }

    private func refreshInteractiveDatagramAvailability() {
        let ready = !stopped && negotiated && datagramInteractiveNegotiated
            && !paused && !configurationSuspended && udpVerified && udpPeer != nil
            && (transaction == nil ? active?.path == .udp : transaction?.path == .udp)
        interactiveDatagramLock.withLock { interactiveDatagramAvailable = ready }
    }

    public func acceptAuxiliary(_ peer: Peer, role: MediaChannelRole) {
        guard role.isMediaAuxiliary else { peer.close("辅助媒体通道角色无效"); return }
        installAuxiliaryHandlers(peer, role: role, accepting: true)
    }

    /// `restartsStream` is false when the host changed only the running encoder's bitrate, so the
    /// current reference chain stays valid and no new keyframe transaction is needed. A restarting
    /// configuration establishes a new playback observation window even when only the codec changed.
    public func updateSettings(_ value: StreamSettings, restartsStream: Bool = true) {
        guard (try? value.validateControlValues()) != nil else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let changed = self.settings != value
            self.settings = value
            if restartsStream { self.policy.mediaConfigurationChanged(now: SessionClock.now) }
            self.videoPeer?.setVideoPacing(VideoSendPacing(megabits: value.megabits))
            if self.side == .viewer { self.receiver?.updateLimits(self.bufferLimits) }
            else { self.refreshHostFrameWindow() }
            if changed, restartsStream, self.active != nil, !self.configurationSuspended { self.requestRecovery() }
        }
    }

    public func recordComputeTiming(encodeMilliseconds: Double? = nil, decodeMilliseconds: Double? = nil) {
        guard [encodeMilliseconds, decodeMilliseconds].allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }) else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if let encodeMilliseconds { self.sampleEncode.add(encodeMilliseconds) }
            if let decodeMilliseconds { self.sampleDecode.add(decodeMilliseconds) }
        }
    }

    /// The capture pump had an eligible new image and a free encoder, but no frame credit.
    public func recordFrameCreditWait() {
        queue.async { [weak self] in
            guard let self, self.side == .host, !self.stopped, !self.paused, !self.configurationSuspended,
                  self.transaction == nil, !self.recoveryHold, let stream = self.active?.stream,
                  self.waitingCreditStream != stream else { return }
            let cutoff = SessionClock.now - 1 / Double(self.settings.framesPerSecond)
            // Entries are non-IDR frames removed at the first reassembly/decoded feedback.
            if self.deliverySentAt.contains(where: { $0.key.stream == stream && $0.value.at <= cutoff }),
               self.hasRecentMappedPayload?() == true {
                self.waitingCreditStream = stream
            }
        }
    }

    public func recordControlRoundTrip(milliseconds: Double) {
        guard milliseconds.isFinite, (0...60_000).contains(milliseconds) else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.controlRoundTrip = (milliseconds, SessionClock.now)
            if self.side == .viewer { self.receiver?.updateLimits(self.bufferLimits) }
            else { self.refreshHostFrameWindow() }
        }
    }

    public func setPaused(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.paused != value else { return }
            self.paused = value
            self.challenges.clear()
            self.refreshInteractiveDatagramAvailability()
            self.reliableDeliveryFailures = 0; self.reliableFailureNotified = false
            if !value { self.livenessResumedAt = SessionClock.uptime }
            else { self.udpJitter.reset() }
            self.handleActions(self.policy.setPaused(value, now: SessionClock.now))
            self.clearDatagrams()
            if value { self.abortTransaction(retry: false) }
            else if self.active != nil {
                if self.active?.path == .udp, !self.udpVerified, self.udpAvailable { self.startUDP() }
                self.requestRecovery()
            }
        }
    }

    public func networkPathChanged() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.udpVerified = false
            self.hasMeasuredRoundTrip = false
            self.refreshInteractiveDatagramAvailability()
            self.controlRoundTrip = nil
            self.udpJitter.reset()
            self.receivedChallenge = false
            self.challenges.clear()
            self.udpPeer?.close("媒体网络路径变化，需要重新验证")
            self.clearDatagrams()
        }
    }

    // The prepared alternate route closed: later probes return to the direct endpoint, and a
    // further delivery failure may prepare a new route under the normal probe backoff.
    public func alternateDatagramPathClosed() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.alternateEndpoint != nil else { return }
            let usingAlternate = self.udpPeer != nil && self.udpRelayed && !self.initialDatagramRelayed
            self.alternateEndpoint = nil; self.alternateProbePending = false; self.alternateRequested = false
            guard usingAlternate else { return }
            self.udpVerified = false; self.receivedChallenge = false; self.challenges.clear()
            self.refreshInteractiveDatagramAvailability()
            self.udpJitter.reset()
            self.udpPeer?.close("中继媒体路径已关闭")
            self.clearDatagrams()
        }
    }

    public func suspendForConfiguration(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { completion(); return }
            guard self.negotiated else { completion(); return }
            self.configurationSuspended = true
            self.refreshInteractiveDatagramAvailability()
            self.recoveryHold = true
            self.udpJitter.reset()
            self.abortTransaction(retry: false)
            self.clearDatagrams()
            if let cache = self.cache {
                self.handleSendEvents(cache.replaceStream(cache.stream))
            }
            self.cache = nil
            self.handleActions(self.policy.setPaused(true, now: SessionClock.now))
            if self.side == .host, !self.paused, let prepare = self.onPrepareRecovery {
                let lock = NSLock()
                var completed = false
                prepare { [weak self] _ in
                    let finish = lock.withLock { () -> Bool in
                        guard !completed else { return false }
                        completed = true
                        return true
                    }
                    guard finish else { return }
                    if let self { self.queue.async { completion() } } else { completion() }
                }
            } else { completion() }
        }
    }

    public func resumeAfterConfiguration() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            guard self.negotiated else { return }
            self.configurationSuspended = false
            self.refreshInteractiveDatagramAvailability()
            self.livenessResumedAt = SessionClock.uptime
            self.handleActions(self.policy.setPaused(self.paused, now: SessionClock.now))
            if !self.paused {
                self.requestedRecoveryAt = 0
                self.requestRecovery()
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.refreshInteractiveDatagramAvailability()
            _ = self.policy.stop()
            self.timer?.cancel(); self.timer = nil
            self.pollTimer?.cancel(); self.pollTimer = nil; self.pollScheduled = false
            self.pathMonitor?.cancel(); self.pathMonitor = nil
            self.udpListener?.cancel(); self.udpListener = nil
            self.udpPeer?.close(); self.udpPeer = nil
            self.challenges.clear()
            for peer in self.pendingDatagramPeers.values { peer.close() }
            self.pendingDatagramPeers.removeAll()
            self.videoPeer?.close(); self.videoPeer = nil
            self.bulkPeer?.close(); self.bulkPeer = nil
            for peer in self.pendingAuxiliary.values { peer.close() }
            self.pendingAuxiliary.removeAll()
            self.transaction = nil; self.active = nil; self.receiver = nil; self.cache = nil
            self.bindingToken = nil; self.datagramKey = nil; self.grant = nil
            self.clearDatagrams()
            self.onDatagramPathRetired?(); self.alternateEndpoint?.retire?()
        }
    }

    private func receiveMessage(_ message: Message, auxiliary: Peer?, role: MediaChannelRole? = nil) {
        guard !stopped else { return }
        observeLocalScheduling()
        do {
            switch message.kind {
            case .mediaControl:
                let value = try MediaControl.read(message.payload)
                if let auxiliary {
                    guard value.role == role else { throw DeskError.invalid("媒体绑定与 ALPN 角色不匹配") }
                    try receiveBinding(value, peer: auxiliary)
                }
                else { try receiveControl(value) }
            case .mediaFrame:
                guard side == .viewer, negotiated else { throw DeskError.invalid("媒体帧会话尚未协商") }
                if let auxiliary, auxiliary !== videoPeer || !videoBound { throw DeskError.invalid("媒体连接尚未绑定") }
                let frame = try MediaFrame.decode(message.payload)
                guard expectedStream == frame.header.stream else { return }
                lastVideoAt = SessionClock.now; sampleBytes += message.payload.count
                handleReceiveEvents(try receiver?.receive(frame) ?? [])
            case .mediaFeedback:
                guard auxiliary == nil else { throw DeskError.invalid("辅助通道不接受媒体反馈") }
                guard side == .host, negotiated else { return }
                receiveFeedback(try MediaFeedback.decode(message.payload))
            default:
                guard let auxiliary, auxiliary === bulkPeer, bulkBound, Self.isBulk(message.kind) else {
                    throw DeskError.invalid("辅助媒体通道消息无效")
                }
                onReliableData?(message)
            }
        } catch {
            if let auxiliary { auxiliary.close("媒体消息无效：\(error.localizedDescription)") }
            else { control.close("媒体协商失败：\(error.localizedDescription)") }
        }
    }

    private func receiveControl(_ value: MediaControl) throws {
        if value.operation == .request {
            guard side == .host else { throw DeskError.invalid("媒体能力请求方向无效") }
            if sessionID != nil { if offerSent { sendOffer() }; return }
            viewerAcceptsMarkedRepairs = value.markedRepairs == true
            relayRoutingNegotiated = relayRoutingEnabled && value.relayRouting == true
            datagramInteractiveNegotiated = value.datagramInteractive == true
            dynamicFrameWindowNegotiated = value.dynamicFrameWindow == true
            parityFECNegotiated = value.parityFEC == true
            blockFECNegotiated = value.blockFEC == true
            fecFragmentLimit = value.fecFragmentLimit.map { min(BlockFECPlanner.maximumProtectedFrameFragments, max(2, $0)) }
                ?? BlockFECPlanner.legacyProtectedFrameFragments
            datagramAudioNegotiated = value.datagramAudio == true
            fastRecoveryNegotiated = value.fastRecovery == true
            advertisedReceiveFrameWindow = value.receiveFrameWindow
            let identifier = UUID(), token = try randomBytes(32), sessionKey = try randomBytes(32)
            sessionID = identifier; bindingToken = token; datagramKey = sessionKey
            grant = try MediaBindingGrant(sessionID: identifier, token: token, now: SessionClock.now)
            negotiated = true
            refreshInteractiveDatagramAvailability()
            refreshHostFrameWindow(forceNotify: true)
            prepareListener(sessionKey: sessionKey, identifier: identifier)
            return
        }
        if value.operation == .offer {
            guard side == .viewer, sessionID == nil, let identifier = value.sessionID,
                  let token = value.token, let sessionKey = value.datagramKey else { return }
            sessionID = identifier; bindingToken = token; datagramKey = sessionKey
            negotiated = true; udpAvailable = udpEnabled && value.path != "tcp"
            relayRoutingNegotiated = relayRoutingEnabled && value.relayRouting == true
            datagramInteractiveNegotiated = value.datagramInteractive == true
            dynamicFrameWindowNegotiated = value.dynamicFrameWindow == true
            parityFECNegotiated = value.parityFEC == true
            blockFECNegotiated = value.blockFEC == true
            datagramAudioNegotiated = value.datagramAudio == true
            fastRecoveryNegotiated = value.fastRecovery == true
            refreshInteractiveDatagramAvailability()
            fallbackAt = SessionClock.now + 1.5
            openAuxiliary(.video); openAuxiliary(.bulk)
            if udpAvailable { handleActions(policy.tick(now: SessionClock.now)) }
            return
        }
        guard negotiated, value.sessionID == sessionID else { return }
        if value.operation == .stats {
            guard side == .viewer, let milliseconds = value.encodeMilliseconds else { return }
            // Newer hosts report their window mean; an older host's per-second maximum is treated the same way.
            if value.encodeIdle != true { sampleEncode.add(milliseconds) }
            sampleMappedTransfer = value.mappedTransfer
            if let delivery = value.deliveryMilliseconds { sampleDeliveryMilliseconds = max(sampleDeliveryMilliseconds ?? 0, delivery) }
            return
        }
        if value.operation == .recover {
            guard value.transportEpoch == active?.stream.transportEpoch,
                  value.codecEpoch == active?.stream.codecEpoch else { return }
            if side == .viewer {
                let deliveryFailed = hasDeliveryFailureEvidence && relayRoutingNegotiated && value.mediaFailure == true
                if deliveryFailed, active?.path != .udp { reliableDeliveryFailed() }
                requestRecovery(mediaFailure: deliveryFailed)
            }
            return
        }
        guard let id = value.transactionID, let transport = value.transportEpoch, let codec = value.codecEpoch,
              let rawPath = value.path, let path = Path(rawValue: rawPath), let identifier = sessionID else {
            throw DeskError.invalid("媒体切换身份缺失")
        }
        let stream = MediaStreamID(sessionID: identifier, transportEpoch: transport, codecEpoch: codec)
        switch value.operation {
        case .prepare:
            guard side == .host else { throw DeskError.invalid("媒体切换请求方向无效") }
            if let current = transaction {
                guard current.id == id else {
                    sendTransaction(.abort, Transaction(id: id, stream: stream, path: path, started: SessionClock.now))
                    return
                }
                guard current.stream == stream, current.path == path else { throw DeskError.invalid("媒体事务标识冲突") }
                if current.stage != .preparing { sendTransaction(.ready, current) }
                return
            }
            let canAwaitUDP = path == .udp && !udpVerified && (udpPeer != nil || !pendingDatagramPeers.isEmpty)
            guard transport > transportEpoch, codec > codecEpoch, !paused, !configurationSuspended,
                  path != .udp || udpVerified || canAwaitUDP, path != .tcp || videoBound else {
                sendTransaction(.abort, Transaction(id: id, stream: stream, path: path, started: SessionClock.now))
                return
            }
            transportEpoch = transport; codecEpoch = codec
            recoveryHold = true
            var pending = Transaction(id: id, stream: stream, path: path, started: SessionClock.now)
            pending.diagnostic = diagnostics?.start()
            // The viewer coordinates switches and already holds this stream's receiver when it asks for the
            // short exchange. This side's own view of the active path can lag an aborted commit, so it is not consulted.
            pending.fast = fastRecoveryNegotiated && value.fast == true
            pending.awaitingUDPVerification = canAwaitUDP
            if pending.fast, path == .udp, !canAwaitUDP {
                pending.awaitingLiveness = true; pending.livenessFrom = SessionClock.uptime
                challenges.clear(); lastAnsweredChallengeAt = 0
                sendPing()
            }
            transaction = pending
            refreshInteractiveDatagramAvailability()
            if canAwaitUDP {
                sendPing()
                queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, !self.stopped, self.transaction?.id == id,
                          self.transaction?.awaitingUDPVerification == true else { return }
                    self.abortTransaction(retry: true)
                }
                return
            }
            startHostPreparation(id: id, stream: stream)
        case .ready:
            guard var pending = transaction, pending.id == id, pending.stream == stream, pending.path == path else { return }
            if side == .viewer {
                if pending.fast {
                    let held = pending.heldFrame
                    pending.hostReady = true; pending.heldFrame = nil; transaction = pending
                    if let held { handleReceiveEvents([.frameReady(held)]) }
                    commitViewerTransaction()
                    return
                }
                guard pending.stage == .preparing else { return }
                try prepareViewerReceiver(stream: stream, path: path)
                pending.stage = .ready; transaction = pending
                sendTransaction(.ready, pending)
            } else {
                guard pending.stage == .ready else { return }
                pending.stage = .producing; transaction = pending
                onProduceRecoveryFrame?()
            }
        case .decodedReady:
            guard side == .host, var pending = transaction, pending.id == id,
                  pending.stream == stream, pending.path == path,
                  pending.frameSubmitted, pending.stage == .producing || pending.stage == .decoded else { return }
            if pending.stage == .producing {
                let header = MediaFrameHeader(stream: stream, frameID: 1, isIDR: true)
                // This reliable, transaction-bound confirmation may precede the UDP ACK.
                reassembledAtPeer.insert(header)
                handleSendEvents(cache?.handle(try MediaFeedback(kind: .decoded, header: header), estimatedRoundTrip: roundTrip) ?? [])
                guard transaction?.id == id else { return }
            }
            if pending.stage != .decoded { diagnostics?.record(.mediaSwitch, since: pending.diagnostic, kind: .mediaFrame, identifier: 1) }
            pending.stage = .decoded; transaction = pending
            sendTransaction(.commit, pending)
        case .commit:
            guard side == .viewer, let pending = transaction, pending.id == id, pending.stream == stream,
                  pending.path == path, !pending.fast else { return }
            commitViewerTransaction()
        case .committed:
            if side == .host, let pending = transaction, pending.id == id, pending.stream == stream, pending.fast {
                commitFastHostTransaction()
                return
            }
            guard side == .host, let pending = transaction, pending.id == id,
                  pending.stream == stream, pending.path == path, pending.stage == .decoded else { return }
            active = (stream, path, pending.localNetwork); transaction = nil; recoveryHold = false
            refreshInteractiveDatagramAvailability()
            recordTransport(path)
            onState?(stateLabel(path)); onResumeFrames?()
        case .abort:
            guard transaction?.id == id, transaction?.stream == stream else { return }
            abortTransaction(retry: true, notify: false, mediaFailure: hasDeliveryFailureEvidence && value.mediaFailure == true)
        default: throw DeskError.invalid("控制通道不接受媒体绑定消息")
        }
    }

    // Viewer: the reassembler of a transaction's stream, in place before its keyframe can arrive.
    private func prepareViewerReceiver(stream: MediaStreamID, path: Path) throws {
        collectLoss(abandoning: true)
        receiver = try MediaFrameReassembler(stream: stream, limits: bufferLimits)
        if path == .udp { receiver?.onSettledFragments = onDiagnosticUDPLoss }
        onDiagnosticVideoPath?(path == .udp ? .trialUDP(relayed: udpRelayed) : .preparing)
        decoding.removeAll(); reassembledLocally.removeAll()
    }

    // Viewer: the transaction's keyframe decoded and, for the fast exchange, the host's ready arrived.
    private func commitViewerTransaction() {
        guard side == .viewer, var pending = transaction, pending.stage == .decoded, let packet = pending.packet,
              !pending.fast || pending.hostReady else { return }
        let stream = pending.stream, path = pending.path
        pending.stage = .committed; transaction = pending
        active = (stream, path, pending.localNetwork)
        refreshInteractiveDatagramAvailability()
        diagnostics?.record(.mediaSwitch, since: pending.diagnostic, kind: .mediaFrame, identifier: 1)
        recordTransport(path)
        onCommitStream?(stream, packet)
        _ = policy.mediaBecameUsable(epoch: policy.epoch, path: path == .udp ? .udp : .tcp, now: SessionClock.now)
        sendTransaction(.committed, pending)
        transaction = nil
        reliableDeliveryFailures = 0
        reliableFailureNotified = false
        onDiagnosticVideoPath?(.committed(path, relayedUDP: path == .udp && udpRelayed))
        onState?(stateLabel(path))
    }

    // Host: a recovery follows an outage or a queue that overflowed, and a keyframe paced into either is
    // lost. It leaves once the stream is prepared and the transaction's own ping was answered; pings go
    // out faster meanwhile.
    private func produceFastKeyFrame() {
        guard side == .host, var pending = transaction, pending.fast, pending.stage == .ready else { return }
        if pending.awaitingLiveness, lastAnsweredChallengeAt < pending.livenessFrom { return }
        pending.awaitingLiveness = false; pending.stage = .producing; transaction = pending
        onProduceRecoveryFrame?()
    }

    // Viewer: the datagram copy of a fast prepare, repeated until the host answers on either path.
    private func sendFastRequest() {
        guard side == .viewer, var pending = transaction, pending.fast, pending.path == .udp,
              let request = try? transactionControl(.prepare, pending).message() else { return }
        pending.requestSentAt = SessionClock.uptime; pending.requestSends += 1
        transaction = pending
        var datagram = Data([Self.recoveryRequestDatagramKind]); datagram.append(request.payload)
        sendDatagram(datagram)
    }

    // Host: the viewer decoded the keyframe of a fast transaction, reported by its decode feedback or
    // by its committed message, whichever arrives first.
    private func commitFastHostTransaction() {
        guard side == .host, let pending = transaction, pending.fast, pending.frameSubmitted, pending.stage == .producing,
              let decoded = try? MediaFeedback(kind: .decoded, header: MediaFrameHeader(stream: pending.stream, frameID: 1, isIDR: true))
        else { return }
        reassembledAtPeer.insert(decoded.header)
        handleSendEvents(cache?.handle(decoded, estimatedRoundTrip: roundTrip) ?? [])
        guard transaction?.id == pending.id else { return }
        diagnostics?.record(.mediaSwitch, since: pending.diagnostic, kind: .mediaFrame, identifier: 1)
        active = (pending.stream, pending.path, pending.localNetwork); transaction = nil; recoveryHold = false
        refreshInteractiveDatagramAvailability()
        recordTransport(pending.path)
        onState?(stateLabel(pending.path)); onResumeFrames?()
    }

    private func prepareListener(sessionKey: Data, identifier: UUID) {
        do {
            let listener = try NWListener(using: MediaSecureTransport.dtlsParameters(sessionKey: sessionKey,
                identity: Data(identifier.uuidString.utf8)), on: NWEndpoint.Port(rawValue: port)!)
            let admission = PendingHandshakeGate()
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let address: String?
                if case .hostPort(let host, _) = connection.endpoint { address = host.debugDescription } else { address = nil }
                guard let reservation = admission.reserve(address: address, now: SessionClock.now) else { connection.cancel(); return }
                let binding = self.hostDatagramBinding?(connection.endpoint)
                self.queue.async { [weak self] in
                    guard let self, !self.stopped,
                          self.udpPeer == nil || self.relayRoutingNegotiated && self.pendingDatagramPeers.count < 2 else {
                        admission.release(reservation); connection.cancel(); return
                    }
                    do {
                        let peer = try BoundedDatagramPeer(connection: connection,
                            maximumDatagramBytes: MediaFragment.maximumDatagramBytes + 1, queue: self.queue)
                        if self.udpPeer == nil { self.installDatagram(peer, hostBinding: binding, release: { admission.release(reservation) }) }
                        else {
                            let id = ObjectIdentifier(peer)
                            self.pendingDatagramPeers[id] = peer
                            peer.onReady = { [weak self, weak peer] in
                                admission.release(reservation)
                                guard let self, let peer, !self.stopped,
                                      self.pendingDatagramPeers.removeValue(forKey: id) === peer else { return }
                                let previous = self.udpPeer
                                self.installDatagram(peer, hostBinding: binding, start: false)
                                previous?.close("已认证的新媒体路径替代旧路径")
                            }
                            peer.onClose = { [weak self] _ in
                                admission.release(reservation)
                                self?.pendingDatagramPeers.removeValue(forKey: id)
                            }
                            peer.start()
                        }
                    } catch { admission.release(reservation); connection.cancel() }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped, self.sessionID == identifier else { return }
                switch state {
                case .ready: self.udpAvailable = true; self.sendOffer()
                case .failed: self.udpAvailable = false; self.sendOffer()
                default: break
                }
            }
            udpListener = listener; listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.stopped, !self.offerSent else { return }
                self.sendOffer()
            }
        } catch { udpAvailable = false; sendOffer() }
    }

    private func sendOffer() {
        guard let sessionID, let token = bindingToken, let datagramKey, !stopped else { return }
        offerSent = true
        sendControl(MediaControl(.offer, sessionID: sessionID, token: token, datagramKey: datagramKey,
                                 path: udpAvailable ? "udp" : "tcp", relayRouting: relayRoutingNegotiated ? true : nil,
                                 datagramInteractive: datagramInteractiveNegotiated ? true : nil,
                                 dynamicFrameWindow: dynamicFrameWindowNegotiated ? true : nil,
                                 parityFEC: parityFECNegotiated ? true : nil,
                                 blockFEC: blockFECNegotiated ? true : nil,
                                 datagramAudio: datagramAudioNegotiated ? true : nil,
                                 fastRecovery: fastRecoveryNegotiated ? true : nil))
    }

    private func openAuxiliary(_ role: MediaChannelRole) {
        guard let host, role.isMediaAuxiliary else { return }
        do {
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                using: try MediaSecureTransport.tlsParameters(key: key, roles: [role]))
            let peer = Peer(connection: connection, handshakeTimeout: 5)
            if role == .video { videoPeer = peer; peer.setVideoPacing(VideoSendPacing(megabits: settings.megabits)) }
            else { bulkPeer = peer }
            installAuxiliaryHandlers(peer, role: role, accepting: false)
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer else { return }
                self.queue.async { [weak self, weak peer] in
                    guard let self, let peer, !self.stopped, let sessionID = self.sessionID,
                          let token = self.bindingToken else { return }
                    guard MediaSecureTransport.negotiatedRole(on: connection) == role else { peer.close("媒体 ALPN 未协商"); return }
                    do { peer.send(try MediaControl(.bind, sessionID: sessionID, token: token, role: role).message()) }
                    catch { peer.close("媒体绑定参数无效") }
                }
            }
            peer.start()
        } catch { onState?("辅助通道不可用，保留 TCP 兼容路径") }
    }

    // Called before returning from the accepted Peer's ready callback.
    private func installAuxiliaryHandlers(_ peer: Peer, role: MediaChannelRole, accepting: Bool) {
        peer.onMessageHandled = { [weak self, weak peer] message, resume in
            guard let self, let peer else { resume(); return }
            self.queue.async { [weak self, weak peer] in
                defer { resume() }
                guard let self, let peer else { return }
                self.receiveMessage(message, auxiliary: peer, role: role)
            }
        }
        let previousClose = peer.onClose
        peer.onClose = { [weak self, weak peer] reason in
            previousClose?(reason)
            guard let self, let peer else { return }
            self.queue.async { [weak self, weak peer] in
                guard let self, let peer, !self.stopped else { return }
                self.pendingAuxiliary.removeValue(forKey: ObjectIdentifier(peer))
                if self.videoPeer === peer {
                    self.videoPeer = nil; self.videoBound = false
                    if self.side == .viewer, self.active?.path == .tcp || self.transaction?.path == .tcp {
                        self.abortTransaction(retry: false); self.beginSwitch(.shared, cause: .auxiliaryClosed)
                    } else if self.side == .host { self.requestRecovery() }
                }
                if self.bulkPeer === peer { self.bulkPeer = nil; self.bulkBound = false }
            }
        }
        let relay = MediaTrafficRelay(parent: control.trafficMeter) { [weak self] count in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onBytes?(count)
            }
        }
        peer.onTraffic = nil
        peer.trafficMeter.onUpdate = { [relay] snapshot in relay.receive(snapshot) }
        relay.receive(peer.trafficMeter.snapshot())
        if accepting {
            queue.async { [weak self, peer] in
                guard let self, !self.stopped, self.side == .host,
                      self.pendingAuxiliary.count < 4 else { peer.close(); return }
                let identifier = ObjectIdentifier(peer)
                self.pendingAuxiliary[identifier] = peer
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
                    guard let self, let peer, self.pendingAuxiliary[identifier] === peer else { return }
                    peer.close("媒体通道绑定超时")
                }
            }
        }
    }

    private func receiveBinding(_ value: MediaControl, peer: Peer) throws {
        guard value.sessionID == sessionID, let role = value.role, role.isMediaAuxiliary else { throw DeskError.invalid("媒体会话绑定不匹配") }
        if side == .host {
            guard value.operation == .bind, var grant, grant.consume(value, now: SessionClock.now),
                  role == .video ? videoPeer == nil : bulkPeer == nil else { throw DeskError.invalid("媒体绑定令牌失效或重复") }
            self.grant = grant
            if role == .video {
                videoPeer = peer; videoBound = true
                peer.setVideoPacing(VideoSendPacing(megabits: settings.megabits))
            } else { bulkPeer = peer; bulkBound = true }
            pendingAuxiliary.removeValue(forKey: ObjectIdentifier(peer))
            peer.send(try MediaControl(.bound, sessionID: sessionID, token: value.token, role: role).message())
        } else {
            guard value.operation == .bound, value.token == bindingToken,
                  role == .video ? videoPeer === peer : bulkPeer === peer else { throw DeskError.invalid("媒体绑定确认无效") }
            if role == .video { videoBound = true } else { bulkBound = true }
        }
    }

    private func installDatagram(_ peer: BoundedDatagramPeer, hostBinding: ((Data) -> Void)? = nil, start: Bool = true, release: @escaping () -> Void = {}) {
        if side == .host { hostAssist = hostBinding; udpRelayed = hostBinding != nil }
        udpPeer = peer; udpVerified = false; receivedChallenge = false; challenges.clear(); lastPongAt = 0
        lastAnsweredChallengeAt = 0
        refreshInteractiveDatagramAvailability()
        udpJitter.reset()
        peer.onReady = { [weak self, weak peer] in
            release()
            guard let self, let peer, !self.stopped, self.udpPeer === peer else { return }
            self.sendPing()
        }
        peer.onDatagram = { [weak self, weak peer] data in
            guard let self, let peer, !self.stopped, self.udpPeer === peer else { return }
            self.control.trafficMeter.record(receivedBytes: UInt64(data.count)); self.onBytes?(data.count)
            self.diagnostics?.recordValue(.mediaDatagramReceivedBytes, data.count, kind: .mediaFrame)
            self.receiveDatagram(data)
        }
        peer.onClose = { [weak self, weak peer] _ in
            release()
            guard let self, let peer, self.udpPeer === peer else { return }
            self.udpPeer = nil; self.udpVerified = false
            self.challenges.clear()
            self.refreshInteractiveDatagramAvailability()
            self.clearDatagrams()
            if self.side == .host, self.pendingDatagramPeers.isEmpty,
               self.transaction?.awaitingUDPVerification == true || self.transaction?.awaitingLiveness == true {
                self.abortTransaction(retry: true)
            }
            if self.side == .viewer, let probe = self.policy.probeID {
                self.handleActions(self.policy.probeFailed(id: probe, now: SessionClock.now))
            }
        }
        if start { peer.start() }
        else { sendPing() }
    }

    private func startUDP() {
        guard !stopped, udpAvailable, udpPeer == nil, let host, let identifier = sessionID, let datagramKey else { return }
        do {
            let destination = alternateEndpoint ?? DatagramEndpoint(host: host, port: port)
            let connection = NWConnection(host: NWEndpoint.Host(destination.host), port: NWEndpoint.Port(rawValue: destination.port)!,
                using: try MediaSecureTransport.dtlsParameters(sessionKey: datagramKey, identity: Data(identifier.uuidString.utf8)))
            let peer = try BoundedDatagramPeer(connection: connection,
                maximumDatagramBytes: MediaFragment.maximumDatagramBytes + 1,
                handshakeTimeout: alternateEndpoint != nil || initialDatagramRelayed ? 5 : 1.5, queue: queue)
            udpRelayed = alternateEndpoint != nil || initialDatagramRelayed
            installDatagram(peer)
        } catch {
            if let probe = policy.probeID { handleActions(policy.probeFailed(id: probe, now: SessionClock.now)) }
        }
    }

    private func sendPing() {
        guard !paused, udpPeer != nil, let nonce = try? randomBytes(16) else { return }
        let now = SessionClock.uptime
        lastPingAt = now
        var payload = Data([1]); payload.append(nonce); payload.append(Data(count: 1024 - payload.count))
        if sendDatagram(payload) { challenges.sent(nonce, at: now) }
    }

    private func receiveDatagram(_ data: Data) {
        guard let kind = data.first else { return }
        observeLocalScheduling()
        do {
            switch kind {
            case 1:
                guard data.count == 1024 else { return }
                receivedChallenge = true
                var response = data; response[response.startIndex] = 2
                sendDatagram(response)
                if !paused, !udpVerified, lastPongAt > 0, SessionClock.uptime - lastPongAt < 1 {
                    verifiedUDP(receivedPong: false)
                }
            case 2:
                guard !paused, data.count == 1024 else { return }
                let now = SessionClock.uptime
                guard let sample = challenges.answer(data.dropFirst().prefix(16), at: now) else { return }
                let measured = sample.roundTrip
                lastAnsweredChallengeAt = max(lastAnsweredChallengeAt, sample.sentAt)
                lastPongAt = now
                roundTrip = max(0.001, measured)
                hasMeasuredRoundTrip = true
                udpJitter.observeRoundTrip(measured)
                if side == .viewer { receiver?.updateLimits(bufferLimits) }
                else { refreshHostFrameWindow() }
                recordDuration(.mediaRoundTrip, seconds: measured)
                if let onDiagnosticUDPRoundTrip, let active, active.path == .udp, receiver?.stream == active.stream,
                   transaction == nil, udpVerified, !paused, !configurationSuspended {
                    onDiagnosticUDPRoundTrip(measured * 1_000)
                }
                if receivedChallenge { verifiedUDP() }
                if transaction?.awaitingLiveness == true { produceFastKeyFrame() }
            case 3, Self.repairedFragmentKind:
                guard side == .viewer, udpVerified else { return }
                let fragment = try MediaFragment.decode(Data(data.dropFirst()))
                guard fragment.header.stream == expectedStream else { return }
                samplePackets += 1; sampleBytes += data.count; lastVideoAt = SessionClock.now
                handleReceiveEvents(try receiver?.receive(fragment, isRepair: kind == Self.repairedFragmentKind) ?? [])
                scheduleReceiverPoll()
            case Self.parityDatagramKind:
                guard side == .viewer, parityFECNegotiated, udpVerified else { return }
                let parity = try MediaFrameParity.decode(Data(data.dropFirst()))
                guard parity.header.stream == expectedStream else { return }
                samplePackets += 1; sampleBytes += data.count; lastVideoAt = SessionClock.now
                handleReceiveEvents(try receiver?.receive(parity) ?? [])
                scheduleReceiverPoll()
            case Self.blockFECDatagramKind:
                guard side == .viewer, blockFECNegotiated, udpVerified else { return }
                let shard = try MediaFrameFECShard.decode(Data(data.dropFirst()))
                guard shard.header.stream == expectedStream else { return }
                samplePackets += 1; sampleBytes += data.count; lastVideoAt = SessionClock.now
                handleReceiveEvents(try receiver?.receive(shard) ?? [])
                scheduleReceiverPoll()
            case 4:
                guard side == .host, udpVerified else { return }
                receiveFeedback(try MediaFeedback.decode(Data(data.dropFirst())))
            case Self.recoveryRequestDatagramKind:
                // The same prepare also travels on the control connection; whichever arrives first starts it.
                guard side == .host, fastRecoveryNegotiated, udpVerified else { return }
                let value = try MediaControl.read(Data(data.dropFirst()))
                guard value.operation == .prepare, value.fast == true else { return }
                try receiveControl(value)
            case Self.cursorPositionDatagramKind:
                guard side == .viewer, datagramInteractiveNegotiated, udpVerified else { return }
                do {
                    onCursorPosition?(try CursorPosition.decode(Data(data.dropFirst())))
                } catch {
                    control.close("交互光标数据报无效：\(error.localizedDescription)")
                }
            case Self.interactiveInputDatagramKind:
                guard side == .host, datagramInteractiveNegotiated, udpVerified else { return }
                do {
                    let input = try Wire.readJSON(RemoteInput.self, Data(data.dropFirst()))
                    try input.validate()
                    guard input.kind == .move || input.kind == .drag, input.pointerSequence != nil else {
                        throw DeskError.invalid("交互数据报输入类型无效")
                    }
                    onInteractiveInput?(input)
                } catch {
                    control.close("交互输入数据报无效：\(error.localizedDescription)")
                }
            case Self.audioPacketDatagramKind:
                guard side == .viewer, datagramAudioNegotiated, udpVerified else { return }
                do {
                    onAudioPacket?(try RemoteAudioPacket.decode(Data(data.dropFirst())))
                } catch {
                    control.close("远端音频数据报无效：\(error.localizedDescription)")
                }
            default: return
            }
        } catch {
            // Authenticated but malformed media is not allowed to grow a reassembly or select a path.
            requestRecovery()
        }
    }

    private func verifiedUDP(receivedPong: Bool = true) {
        udpVerified = true
        refreshInteractiveDatagramAvailability()
        if udpRelayed, let peer = udpPeer, assistAnnouncedPeer !== peer, let datagramKey, let sessionID {
            assistAnnouncedPeer = peer
            let secret = Self.peerAssistSecret(datagramKey: datagramKey, sessionID: sessionID)
            if side == .host { hostAssist?(secret) }
            else { onRelayedDatagramAuthenticated?(peer.endpoint, secret) }
        }
        if side == .host, var pending = transaction, pending.awaitingUDPVerification, pending.stage == .preparing {
            pending.awaitingUDPVerification = false
            transaction = pending
            startHostPreparation(id: pending.id, stream: pending.stream)
        }
        if side == .viewer {
            if receivedPong { policy.receivedPong(epoch: policy.epoch, now: SessionClock.now) }
            if let probe = policy.probeID { handleActions(policy.probeSucceeded(id: probe, now: SessionClock.now)) }
        }
    }

    private func startHostPreparation(id: UUID, stream: MediaStreamID) {
        let prepare: ((@escaping (Bool) -> Void) -> Void)?
        if let onPrepareStream { prepare = { complete in onPrepareStream(stream, complete) } }
        else { prepare = onPrepareRecovery }
        guard let prepare else { abortTransaction(retry: true); return }
        prepare { [weak self] success in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped, self.transaction?.id == id,
                      self.transaction?.stage == .preparing,
                      self.transaction?.awaitingUDPVerification == false else { return }
                guard success, self.transaction?.path != .udp || self.udpVerified else {
                    self.abortTransaction(retry: true)
                    return
                }
                do {
                    self.clearDatagrams()
                    self.cache = try MediaRetransmissionCache(stream: stream, limits: self.bufferLimits)
                    self.reassembledAtPeer.removeAll()
                    self.sentHeaders.removeAll()
                    self.nextFrameID = 1
                    self.transaction?.stage = .ready
                    if let pending = self.transaction { self.sendTransaction(.ready, pending) }
                    if self.transaction?.fast == true { self.produceFastKeyFrame() }
                } catch { self.abortTransaction(retry: true) }
            }
        }
    }

    private func beginSwitch(_ path: Path, cause: MediaSwitchCause) {
        guard side == .viewer, !stopped, !paused, !configurationSuspended, negotiated,
              transaction == nil, let sessionID else { return }
        guard transportEpoch < UInt32.max, codecEpoch < UInt32.max else {
            control.close("媒体会话代次已耗尽，需要重新连接", retryable: true)
            return
        }
        guard path != .udp || udpVerified, path != .tcp || videoBound else { return }
        transportEpoch += 1; codecEpoch += 1
        var pending = Transaction(id: UUID(), stream: MediaStreamID(sessionID: sessionID,
            transportEpoch: transportEpoch, codecEpoch: codecEpoch), path: path, started: SessionClock.now)
        pending.localNetwork = localNetworkClassification(path) ?? false
        pending.diagnostic = diagnostics?.start()
        transaction = pending
        refreshInteractiveDatagramAvailability()
        reportLocalNetwork()
        // Same-path recoveries are counted by diagnostics; only route changes are reported with a cause.
        if active?.path != path {
            sampleStartedAt = SessionClock.now; samplePackets = 0; sampleFrames = 0; sampleWaitMilliseconds = 0
            sampleBytes = 0; sampleSettledFragments = 0; sampleLostFragments = 0; sampleDeliveryMilliseconds = nil
            sampleMappedTransfer = nil
            sampleEncode = MediaComputeTiming(); sampleDecode = MediaComputeTiming(); sampleDirectReduction = false
            _ = udpJitter.takeWindowMilliseconds()
            onPathSwitch?(stateLabel(path), cause)
        }
        onState?(active == nil ? "正在准备视频" : "正在恢复画面")
        // Recovering on the path already in use needs no proof of the path: receive the keyframe as soon as
        // the host can produce it, and ask on the datagram path as well, where a lost segment delays nothing.
        if fastRecoveryNegotiated, active?.path == path, (try? prepareViewerReceiver(stream: pending.stream, path: path)) != nil {
            pending.fast = true; pending.stage = .ready
            transaction = pending
        }
        sendTransaction(.prepare, pending)
        sendFastRequest()
    }

    private func abortTransaction(retry: Bool, notify: Bool = true, mediaFailure: Bool = false) {
        guard let pending = transaction else { return }
        if notify { sendTransaction(.abort, pending, mediaFailure: mediaFailure ? true : nil) }
        transaction = nil; clearDatagrams()
        refreshInteractiveDatagramAvailability()
        if side == .viewer {
            retryAt = SessionClock.now + (retry ? 0.5 : 0)
            retryPath = retry ? pending.path : nil
            collectLoss(abandoning: true)
            // A failed UDP attempt settles its lost fragments only now; report them before any switch.
            if pending.path == .udp { onDatagramLoss?(lossWindow.fraction(at: SessionClock.now)) }
            receiver = nil; decoding.removeAll(); reassembledLocally.removeAll()
            onDiagnosticVideoPath?(.preparing)
            onState?("正在恢复画面")
            if mediaFailure { reportReduction(.network, localNetwork: pending.localNetwork) }
            if mediaFailure, pending.path != .udp { reliableDeliveryFailed() }
            if mediaFailure, pending.path == .udp {
                retryAt = 0; retryPath = nil
                handleActions(policy.mediaFailed(epoch: policy.epoch, now: SessionClock.now), localNetwork: pending.localNetwork)
            }
        }
    }

    private var expectedStream: MediaStreamID? { transaction?.stream ?? active?.stream }

    private var effectiveRoundTripSeconds: TimeInterval? {
        let udpRTT: TimeInterval? = ((transaction?.path ?? active?.path) == .udp && hasMeasuredRoundTrip) ? roundTrip : nil
        let ctrlRTT: TimeInterval? = controlRoundTrip.flatMap {
            SessionClock.now - $0.at <= 15 ? $0.milliseconds / 1_000 : nil
        }
        switch (udpRTT, ctrlRTT) {
        case let (u?, c?): return max(u, c)
        case let (u?, nil): return u
        case let (nil, c?): return c
        case (nil, nil): return hasMeasuredRoundTrip ? roundTrip : nil
        }
    }

    private var effectiveHostReceiveWindow: Int? {
        guard dynamicFrameWindowNegotiated else { return advertisedReceiveFrameWindow }
        return MediaBufferLimits.recommendedFrameWindow(framesPerSecond: settings.framesPerSecond,
                                                        roundTripSeconds: effectiveRoundTripSeconds)
    }

    private func refreshHostFrameWindow(forceNotify: Bool = false) {
        guard side == .host, negotiated else { return }
        cache?.updateLimits(bufferLimits)
        let target = effectiveHostReceiveWindow
        if forceNotify || target != lastReportedReceiveWindow {
            lastReportedReceiveWindow = target
            onReceiveFrameWindow?(target)
        }
    }

    private var bufferLimits: MediaBufferLimits {
        let maximumFrames: Int
        if side == .viewer {
            maximumFrames = dynamicFrameWindowNegotiated
                ? MediaBufferLimits.maximumDynamicFrameWindow : MediaBufferLimits.receiveFrameWindow
        } else {
            maximumFrames = max(MediaBufferLimits.receiveFrameWindow,
                                effectiveHostReceiveWindow ?? MediaBufferLimits.receiveFrameWindow)
        }
        return MediaBufferLimits(maximumFrames: maximumFrames,
                                 frameTimeToLive: (transaction?.path ?? active?.path) == .udp ? max(0.25, roundTrip * 3 + 0.08) : 5,
                                 keyFrameTimeToLive: 5, completedFrameTimeToLive: 5)
    }

    private func recentNackedFragmentCount(at now: TimeInterval) -> Int {
        recentNackEvents.removeAll { now - $0.at > 5.0 }
        return recentNackEvents.reduce(0) { $0 + $1.count }
    }

    private var hasRecentLoss: Bool { lastHostNackAt.map { SessionClock.now - $0 <= 8.0 } ?? false }

    private func desiredBlockFECParityCount(isIDR: Bool, fragmentCount: Int, payloadBytes: Int) -> Int {
        guard blockFECNegotiated, (2...fecFragmentLimit).contains(fragmentCount) else { return 0 }
        let recentMissing = recentNackedFragmentCount(at: SessionClock.now)
        let recentLoss = hasRecentLoss
        // Frames queued behind the pacer are the large ones of a scroll or a video. On a path that is
        // losing they need parity most, so a short backlog keeps one step less of it instead of none.
        let backlogged = pendingDatagramBytes > 0
        if backlogged, !recentLoss || Double(pendingDatagramBytes) > bytesPerSecond * 0.1 { return 0 }
        let rawParity: Int
        if recentMissing >= 6 {
            rawParity = backlogged ? 2 : 3
        } else if recentLoss {
            rawParity = backlogged ? 1 : 2
        } else if isIDR || settings.framesPerSecond >= 60 || roundTrip >= 0.015 {
            rawParity = 1
        } else {
            return 0
        }
        if isIDR {
            return min(rawParity, 2)
        }
        let fps = Double(max(1, settings.framesPerSecond))
        let perFrameBudget = (Double(max(1, settings.megabits)) * 125_000.0) / fps
        let budgetScale = (recentLoss || roundTrip >= 0.015) ? 1.35 : 1.15
        for candidate in stride(from: rawParity, through: 1, by: -1) {
            let blocks = BlockFECPlanner.partition(fragmentCount: fragmentCount, parityPerBlock: candidate)
            let totalShards = blocks.reduce(0) { $0 + $1.parityCount }
            let totalBytes = payloadBytes + totalShards * MediaFragment.maximumPayloadBytes
            if Double(totalBytes) <= perFrameBudget * budgetScale || (recentLoss && candidate == 1) {
                return candidate
            }
        }
        return 0
    }

    // A frame that fits one fragment has no block to protect: a lost copy is the whole frame, and when
    // nothing follows it the viewer cannot even ask for it. On a path that is losing, a second copy a few
    // milliseconds later (apart from the first in a loss burst) costs one datagram.
    private static let singleFragmentRepeatDelay: TimeInterval = 0.004

    private func repeatSingleFragment(_ fragment: MediaFragment) {
        guard hasRecentLoss else { return }
        let header = fragment.header
        queue.asyncAfter(deadline: .now() + Self.singleFragmentRepeatDelay) { [weak self] in
            guard let self, !self.stopped, !self.paused, !self.configurationSuspended,
                  self.cache?.frameHeader(for: header.frameID) == header, !self.reassembledAtPeer.contains(header),
                  (self.transaction?.stream ?? self.active?.stream) == header.stream else { return }
            self.enqueue([fragment])
        }
    }

    private func shouldEmitParity(isIDR: Bool, fragmentCount: Int, payloadBytes: Int) -> Bool {
        guard !blockFECNegotiated, parityFECNegotiated, !isIDR, (2...MediaFrameParity.maximumProtectedFragments).contains(fragmentCount),
              pendingDatagramBytes == 0 else { return false }
        let fps = Double(max(1, settings.framesPerSecond))
        let perFrameBudget = (Double(max(1, settings.megabits)) * 125_000.0) / fps
        let recentLoss = lastHostNackAt.map { SessionClock.now - $0 <= 8.0 } ?? false
        let budgetScale = (recentLoss || roundTrip >= 0.015) ? 1.0 : 0.85
        let maxCount = (recentLoss || roundTrip >= 0.015) ? MediaFrameParity.maximumProtectedFragments : 6
        return fragmentCount <= maxCount
            && Double(payloadBytes + MediaFragment.maximumPayloadBytes) <= perFrameBudget * budgetScale
    }

    private func sendFrame(_ packet: VideoPacket) {
        guard side == .host, !stopped else { return }
        guard !paused, !configurationSuspended else { onAcknowledged?(packet.sequence); return }
        if recoveryHold, transaction == nil { onAcknowledged?(packet.sequence); requestRecovery(); return }
        guard negotiated, let target = transaction.map({ ($0.stream, $0.path) }) ?? active.map({ ($0.stream, $0.path) }) else {
            do { control.send(Message(.video, try packet.encode())); onFrameSent?() }
            catch { control.close(error.localizedDescription) }
            return
        }
        if let pending = transaction, pending.stage != .producing { onAcknowledged?(packet.sequence); return }
        do {
            let isIDR = try MediaFrame.containsIDR(packet.avcc, codec: packet.codec)
            if transaction != nil, !isIDR { abortTransaction(retry: true); onAcknowledged?(packet.sequence); return }
            if cache?.stream != target.0 { cache = try MediaRetransmissionCache(stream: target.0, limits: bufferLimits); nextFrameID = 1 }
            let header = MediaFrameHeader(stream: target.0, frameID: nextFrameID, isIDR: isIDR)
            let frame = try MediaFrame(header: header, packet: packet)
            let bytes = frame.packetBytes.count
            let fragmentCount = (bytes + MediaFragment.maximumPayloadBytes - 1) / MediaFragment.maximumPayloadBytes
            let blockParityCount = target.1 == .udp
                ? desiredBlockFECParityCount(isIDR: isIDR, fragmentCount: fragmentCount, payloadBytes: bytes) : 0
            let parityShards = blockParityCount > 0
                ? BlockFECPlanner.partition(fragmentCount: fragmentCount, parityPerBlock: blockParityCount).reduce(0) { $0 + $1.parityCount } : 0
            // The frame leaves together with its parity, after what the pacer already holds. Waiting there
            // must not use up the delivery deadline; it still shows in the delivery estimate, where
            // sustained queueing behind earlier frames is load the quality policy lowers.
            let paced = Self.udpPacingSpan(payloadBytes: bytes, megabits: settings.megabits, parityShards: parityShards)
            let queued = target.1 == .udp ? Double(pendingDatagramBytes) / bytesPerSecond : 0
            let budget = target.1 != .udp ? 5
                : isIDR ? max(1, queued + paced + roundTrip * 2 + 0.2) : max(0.25, queued + paced + roundTrip * 3 + 0.08)
            let fragments = try cache!.insert(frame, deadline: SessionClock.now + min(5, budget))
            sentHeaders.insert(header)
            if deliveryPath != target.1 { deliveryPath = target.1; deliveryEstimator.reset(); deliverySentAt.removeAll() }
            if !isIDR, deliverySentAt.count < 16 {
                let pacedSpan = target.1 == .udp ? paced : Double(bytes) / VideoSendPacing(megabits: settings.megabits).bytesPerSecond
                deliverySentAt[header] = (SessionClock.now, pacedSpan)
            }
            if transaction != nil { transaction?.frameSubmitted = true }
            nextFrameID += 1
            if target.1 == .udp {
                if blockParityCount > 0,
                   let fecBlocks = try? MediaFrameFECShard.makeBlocks(
                       header: header,
                       frameBytes: bytes,
                       fragments: fragments,
                       parityPerBlock: blockParityCount
                   ) {
                    enqueue(fragments, fecBlocks: fecBlocks)
                } else {
                    let parity = shouldEmitParity(isIDR: isIDR, fragmentCount: fragments.count, payloadBytes: bytes)
                        ? (try? MediaFrameParity.make(header: header, frameBytes: bytes, fragments: fragments)) : nil
                    enqueue(fragments, parity: parity)
                    if fragments.count == 1 { repeatSingleFragment(fragments[0]) }
                }
            }
            else {
                let peer = target.1 == .tcp ? videoPeer : control
                guard let peer else { requestRecovery(); return }
                peer.send(Message(.mediaFrame, try frame.encode()))
            }
            onFrameSent?()
        } catch { onAcknowledged?(packet.sequence); requestRecovery() }
    }

    private func handleReceiveEvents(_ events: [MediaReceiveEvent], decoderFailure: Bool = false) {
        for event in events {
            switch event {
            case .frameReady(let frame):
                guard frame.header.stream == expectedStream, let onVideo else { continue }
                if transaction?.fast == true, transaction?.hostReady == false, transaction?.stream == frame.header.stream {
                    transaction?.heldFrame = frame
                    continue
                }
                guard decoding.insert(frame.header).inserted else { continue }
                onVideo(frame) { [weak self] success in
                    self?.queue.async { [weak self] in
                        guard let self, !self.stopped, self.expectedStream == frame.header.stream,
                              self.decoding.remove(frame.header) != nil else { return }
                        self.observeLocalScheduling()
                        if success {
                            let now = SessionClock.now
                            if let last = self.lastDecodedAt { self.recordDuration(.mediaDecodeInterval, seconds: now - last, identifier: frame.header.frameID) }
                            self.lastDecodedAt = now
                            self.sampleFrames += 1
                        }
                        if !success { self.reportReduction(.decoder) }
                        self.handleReceiveEvents(self.receiver?.decoded(frame.header, success: success) ?? [], decoderFailure: !success)
                        if !success, self.transaction?.stream == frame.header.stream {
                            self.abortTransaction(retry: true)
                            return
                        }
                        if success, var pending = self.transaction, pending.stream == frame.header.stream,
                           pending.stage == .ready, frame.header.isIDR {
                            pending.stage = .decoded; pending.packet = frame.packet; self.transaction = pending
                            if pending.fast { self.commitViewerTransaction() }
                            else { self.sendTransaction(.decodedReady, pending) }
                        }
                    }
                }
            case .feedback(let feedback):
                if feedback.kind == .reassembled { reassembledLocally.insert(feedback.header) }
                if feedback.kind == .decoded { reassembledLocally.remove(feedback.header) }
                // The reassembler owns this wait, so late, repeated or expired fragments cannot leave stale timing.
                if feedback.kind == .reassembled, let waited = receiver?.collectionDuration(of: feedback.header) {
                    // The sender paces each frame at about the target rate; only time beyond that is queueing.
                    // A frame that waited for a retransmission or FEC measures the repair, not the path's queue.
                    if !feedback.header.isIDR, receiver?.wasRepaired(feedback.header) != true {
                        let paced = Self.udpPacingSpan(payloadBytes: receiver?.fragmentedBytes(of: feedback.header) ?? 0,
                                                       megabits: settings.megabits,
                                                       parityShards: receiver?.parityShardCount(of: feedback.header) ?? 0)
                        sampleWaitMilliseconds = max(sampleWaitMilliseconds, max(0, waited - paced) * 1000)
                    }
                    recordDuration(.mediaReassembly, seconds: waited, identifier: feedback.header.frameID)
                }
                if feedback.kind == .expired { diagnostics?.recordValue(.mediaExpired, 1, kind: .mediaFrame, identifier: feedback.header.frameID) }
                if !decoderFailure || feedback.kind != .expired { sendFeedback(feedback) }
            case .recoveryRequired(let header):
                let deliveryFailed = hasDeliveryFailureEvidence && !decoderFailure && !reassembledLocally.contains(header)
                reassembledLocally.remove(header)
                if transaction?.stream == header.stream { abortTransaction(retry: true, mediaFailure: deliveryFailed) }
                else { requestRecovery(mediaFailure: deliveryFailed) }
            }
        }
    }

    private func handleSendEvents(_ events: [MediaSendEvent]) {
        for event in events {
            switch event {
            case .terminal(let header, let sequence, let reason):
                if reason == .expired { recoveryHold = true }
                discardQueued(header)
                originalSubmittedCounts.removeValue(forKey: header)
                sentHeaders.remove(header)
                deliverySentAt.removeValue(forKey: header)
                if reason == .decoded { reassembledAtPeer.remove(header) }
                onAcknowledged?(sequence)
            case .retransmit(let fragments):
                enqueue(fragments, repair: true)
            case .recoveryRequired(let header):
                if transaction?.stream == header.stream {
                    abortTransaction(retry: true, mediaFailure: hasDeliveryFailureEvidence && transaction?.frameSubmitted == true && !reassembledAtPeer.contains(header))
                }
                else { requestRecovery(mediaFailure: hasDeliveryFailureEvidence && !reassembledAtPeer.contains(header)) }
                reassembledAtPeer.removeAll()
            }
        }
    }

    private func receiveFeedback(_ feedback: MediaFeedback) {
        guard feedback.header.stream == cache?.stream else { return }
        if feedback.kind == .decoded, transaction?.fast == true, transaction?.stream == feedback.header.stream {
            commitFastHostTransaction()
        }
        let targetHeader = (feedback.kind == .nack || feedback.kind == .expired)
            ? (cache?.frameHeader(for: feedback.header.frameID) ?? feedback.header)
            : feedback.header
        var accepted = feedback
        if feedback.kind == .nack {
            let now = SessionClock.now
            lastHostNackAt = now
            let submitted = originalSubmittedCounts[targetHeader] ?? 0
            let ranges = feedback.missingRanges.compactMap { range -> MediaFragmentRange? in
                let first = Int(range.first), end = min(submitted, Int(range.first) + Int(range.count))
                guard end > first else { return nil }
                return MediaFragmentRange(first: range.first, count: UInt16(end - first))
            }
            guard !ranges.isEmpty, let filtered = try? MediaFeedback(kind: .nack, header: targetHeader, missingRanges: ranges) else { return }
            let missingCount = ranges.reduce(0) { $0 + Int($1.count) }
            recentNackEvents.removeAll { now - $0.at > 5.0 }
            if recentNackEvents.count < 128 {
                recentNackEvents.append((now, missingCount))
            }
            // Its delivery time now includes a repair round trip, which is loss rather than queueing.
            deliverySentAt.removeValue(forKey: targetHeader)
            accepted = filtered
        }
        if feedback.kind == .reassembled || feedback.kind == .decoded, let sent = deliverySentAt.removeValue(forKey: feedback.header) {
            deliveryEstimator.add(max(0, SessionClock.now - sent.at - sent.paced), at: SessionClock.now)
        }
        if (feedback.kind == .reassembled || feedback.kind == .decoded),
           sentHeaders.contains(feedback.header), reassembledAtPeer.count < bufferLimits.maximumFrames {
            reassembledAtPeer.insert(feedback.header)
            discardQueued(feedback.header)
        }
        handleSendEvents(cache?.handle(accepted, estimatedRoundTrip: roundTrip) ?? [])
    }

    private func sendTailProbes() {
        guard let probes = cache?.tailProbes(estimatedRoundTrip: roundTrip), !probes.isEmpty else { return }
        // A paced frame the viewer never reported is loss, and its delivery time now includes the probe.
        lastHostNackAt = SessionClock.now
        for case .retransmit(let fragments) in probes {
            if let header = fragments.first?.header { deliverySentAt.removeValue(forKey: header) }
        }
        handleSendEvents(probes)
    }

    private func sendFeedback(_ feedback: MediaFeedback) {
        guard side == .viewer else { return }
        let path = transaction?.path ?? active?.path
        if path == .udp { var data = Data([4]); data.append(feedback.encode()); sendDatagram(data) }
        else { control.send(Message(.mediaFeedback, feedback.encode())) }
    }

    private func requestRecovery(mediaFailure: Bool = false) {
        guard negotiated, !stopped, !paused, !configurationSuspended, transaction == nil,
              SessionClock.now - requestedRecoveryAt >= 0.25 else { return }
        requestedRecoveryAt = SessionClock.now
        diagnostics?.recordValue(.mediaRecovery, 1, kind: .mediaFrame)
        if side == .viewer {
            if mediaFailure, let active, active.path == .udp, interruptedStream != active.stream {
                interruptedStream = active.stream
                let actions = policy.mediaInterrupted(epoch: policy.epoch, now: SessionClock.now)
                if !actions.isEmpty { handleActions(actions); return }
            }
            if active?.path == .udp, udpAvailable, !udpVerified, udpPeer != nil {
                retryAt = SessionClock.now + 0.3; retryPath = .udp
                return
            }
            let path: Path = active?.path == .udp && udpVerified ? .udp : videoBound ? .tcp : .shared
            beginSwitch(path, cause: .recovery)
        } else if let active {
            sendControl(MediaControl(.recover, sessionID: active.stream.sessionID,
                transportEpoch: active.stream.transportEpoch, codecEpoch: active.stream.codecEpoch,
                mediaFailure: relayRoutingNegotiated && mediaFailure ? true : nil))
        }
    }

    private func reliableDeliveryFailed() {
        guard side == .viewer, relayRoutingNegotiated, !stopped, !paused, !configurationSuspended else { return }
        reliableDeliveryFailures += 1
        if udpEnabled, udpAvailable, !alternateRequested, let prepareAlternateDatagramPath {
            alternateRequested = true
            prepareAlternateDatagramPath { [weak self] endpoint in
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped, self.alternateEndpoint == nil,
                          let endpoint, !endpoint.host.isEmpty, endpoint.port > 0 else { return }
                    self.alternateEndpoint = endpoint
                    self.alternateProbePending = true
                }
            }
        }
        if reliableDeliveryFailures >= 3, !reliableFailureNotified {
            reliableFailureNotified = true
            onReliablePathFailure?()
        }
    }

    private func enqueue(
        _ fragments: [MediaFragment],
        repair: Bool = false,
        parity: MediaFrameParity? = nil,
        fecBlocks: [(descriptor: BlockFECPlanner.BlockDescriptor, shards: [MediaFrameFECShard])] = []
    ) {
        guard !fragments.isEmpty else { return }
        let kindByte: UInt8 = repair && viewerAcceptsMarkedRepairs ? Self.repairedFragmentKind : 3
        let encodedParity: Data? = parity.map { value in
            let payload = value.encode()
            var data = Data(capacity: 1 + payload.count)
            data.append(Self.parityDatagramKind)
            data.append(payload)
            return data
        }
        var shardsByEndIndex: [Int: [(MediaFrameHeader, Data)]] = [:]
        var totalFECBytes = 0
        for entry in fecBlocks {
            let triggerAfterIndex = entry.descriptor.start + entry.descriptor.dataCount - 1
            for shard in entry.shards {
                let payload = shard.encode()
                var data = Data(capacity: 1 + payload.count)
                data.append(Self.blockFECDatagramKind)
                data.append(payload)
                totalFECBytes += data.count
                shardsByEndIndex[triggerAfterIndex, default: []].append((shard.header, data))
            }
        }
        let bytes = fragments.reduce(0) { $0 + 1 + MediaFragment.encodedHeaderBytes + $1.payload.count }
            + (encodedParity?.count ?? 0)
            + totalFECBytes
        guard bytes <= 32 * 1024 * 1024 - pendingDatagramBytes else { requestRecovery(); return }
        var encoded: [Datagram] = []
        encoded.reserveCapacity(fragments.count + (encodedParity == nil ? 0 : 1) + fecBlocks.reduce(0) { $0 + $1.shards.count })
        for (idx, fragment) in fragments.enumerated() {
            var data = Data(capacity: 1 + MediaFragment.encodedHeaderBytes + fragment.payload.count)
            data.append(kindByte)
            data.append(fragment.encode())
            encoded.append(Datagram(header: fragment.header, fragmentIndex: fragment.fragmentIndex, data: data, repair: repair,
                                    completesOriginals: !repair && Int(fragment.fragmentIndex) + 1 == Int(fragment.fragmentCount)))
            if !repair, let blockShards = shardsByEndIndex[idx] {
                for (shardHeader, shardData) in blockShards {
                    encoded.append(Datagram(header: shardHeader, fragmentIndex: nil, data: shardData, repair: false))
                }
            }
        }
        if let parity, let encodedParity {
            encoded.append(Datagram(header: parity.header, fragmentIndex: nil, data: encodedParity, repair: false))
        }
        pendingDatagramBytes += bytes
        if repair, datagramOffset < pendingDatagrams.count {
            if datagramOffset > 0 {
                pendingDatagrams.removeFirst(datagramOffset)
                datagramOffset = 0
            }
            let insertAt = pendingDatagrams.firstIndex(where: { !$0.repair }) ?? pendingDatagrams.count
            pendingDatagrams.insert(contentsOf: encoded, at: insertAt)
        } else {
            pendingDatagrams.append(contentsOf: encoded)
        }
        pumpDatagrams()
    }

    // 1.6x target bitrate with a 2 Mbps floor prevents weak WAN tiers (1-6 Mbps) from pacing bursts at 12 Mbps,
    // while keeping candidate keyframes inside the UDP trial window.
    public static func udpPacingBytesPerSecond(megabits: Int) -> Double {
        max(250_000, Double(max(1, megabits)) * 1_000_000 / 8 * 1.6)
    }

    public static func udpPacingBurstBytes(megabits: Int) -> Double {
        let rate = udpPacingBytesPerSecond(megabits: megabits)
        return min(32_768.0, max(Double(MediaFragment.maximumDatagramBytes + 1) * 4, rate * 0.008))
    }

    /// Time the pacer needs for a frame and the parity shards sent with it.
    public static func udpPacingSpan(payloadBytes: Int, megabits: Int, parityShards: Int = 0) -> TimeInterval {
        guard payloadBytes > 0 else { return 0 }
        let fragments = max(1, (payloadBytes + MediaFragment.maximumPayloadBytes - 1) / MediaFragment.maximumPayloadBytes)
        let wireBytes = payloadBytes + fragments * (1 + MediaFragment.encodedHeaderBytes)
            + max(0, parityShards) * (1 + MediaFrameFECShard.encodedHeaderBytes + MediaFragment.maximumPayloadBytes)
        return Double(wireBytes) / udpPacingBytesPerSecond(megabits: megabits)
    }

    private var bytesPerSecond: Double { Self.udpPacingBytesPerSecond(megabits: settings.megabits) }

    private func pumpDatagrams() {
        guard !stopped, !paused, let peer = udpPeer, udpVerified else { return }
        let now = SessionClock.now, burst = Self.udpPacingBurstBytes(megabits: settings.megabits)
        pacingCredit = min(burst, pacingCredit + max(0, now - pacingUpdatedAt) * bytesPerSecond)
        pacingUpdatedAt = now
        while datagramOffset < pendingDatagrams.count {
            let item = pendingDatagrams[datagramOffset]
            if item.header.stream != transaction?.stream && item.header.stream != active?.stream {
                pendingDatagramBytes -= item.data.count; datagramOffset += 1; continue
            }
            guard pacingCredit >= Double(item.data.count) else {
                schedulePacing(after: max(0.0002, (Double(item.data.count) - pacingCredit) / bytesPerSecond))
                return
            }
            guard sendDatagram(item.data, using: peer, repair: item.repair) else { schedulePacing(after: 0.001); return }
            if !item.repair, let fragmentIndex = item.fragmentIndex {
                originalSubmittedCounts[item.header] = max(originalSubmittedCounts[item.header] ?? 0, Int(fragmentIndex) + 1)
            }
            if item.completesOriginals { cache?.originalsSubmitted(item.header) }
            pacingCredit -= Double(item.data.count); pendingDatagramBytes -= item.data.count; datagramOffset += 1
        }
        pendingDatagrams.removeAll(keepingCapacity: true); datagramOffset = 0
    }

    private func schedulePacing(after delay: TimeInterval) {
        if datagramOffset >= 256 {
            pendingDatagrams.removeFirst(datagramOffset)
            datagramOffset = 0
        }
        guard !pacingScheduled else { return }
        pacingScheduled = true
        if let pacingTimer {
            pacingTimer.schedule(deadline: .now() + delay, leeway: .microseconds(200))
            return
        }
        let generation = pacingGeneration
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, generation == self.pacingGeneration else { return }
            self.pacingScheduled = false; self.pumpDatagrams()
        }
        timer.schedule(deadline: .now() + delay, leeway: .microseconds(200))
        pacingTimer = timer; timer.resume()
    }

    private func scheduleReceiverPoll() {
        guard side == .viewer, !stopped, !paused, !configurationSuspended,
              let delay = receiver?.nextPollDelay, delay < 0.009 else { return }
        let wait = max(0.0005, delay)
        guard !pollScheduled else { return }
        pollScheduled = true
        if let pollTimer {
            pollTimer.schedule(deadline: .now() + wait, leeway: .microseconds(300))
            return
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.pollScheduled = false
            guard self.side == .viewer, !self.paused, !self.configurationSuspended else { return }
            self.handleReceiveEvents(self.receiver?.poll() ?? [])
            self.scheduleReceiverPoll()
        }
        timer.schedule(deadline: .now() + wait, leeway: .microseconds(300))
        pollTimer = timer; timer.resume()
    }

    private func clearDatagrams() {
        pacingGeneration &+= 1
        pacingTimer?.cancel(); pacingTimer = nil; pacingScheduled = false
        pollTimer?.cancel(); pollTimer = nil; pollScheduled = false
        pendingDatagrams.removeAll(); datagramOffset = 0; pendingDatagramBytes = 0
        pacingCredit = 0; pacingUpdatedAt = SessionClock.now
        originalSubmittedCounts.removeAll()
    }

    private func discardQueued(_ header: MediaFrameHeader) {
        pendingDatagrams = pendingDatagrams.dropFirst(datagramOffset).filter { $0.header != header }
        datagramOffset = 0
        pendingDatagramBytes = pendingDatagrams.reduce(0) { $0 + $1.data.count }
    }

    @discardableResult
    private func sendDatagram(_ data: Data, using peer: BoundedDatagramPeer? = nil, repair: Bool = false) -> Bool {
        guard let target = peer ?? udpPeer else { return false }
        let meter = control.trafficMeter
        return target.send(data) { [weak self] success in
            guard success else { return }
            meter.record(sentBytes: UInt64(data.count))
            self?.diagnostics?.recordValue(.mediaDatagramSentBytes, data.count, kind: .mediaFrame)
            if repair { self?.diagnostics?.recordValue(.mediaRepairBytes, data.count, kind: .mediaFrame) }
            self?.onBytes?(data.count)
        }
    }

    private func observeLocalScheduling() {
        if livenessGrace.observe(now: SessionClock.uptime, interval: 0.01, allowance: 1), negotiated, !paused, !configurationSuspended {
            // A queued packet may run before the timer after a stall. Neither can prove delivery failure
            // from an old deadline, or accept a pre-stall nonce as a fresh RTT sample.
            challenges.clear()
            udpJitter.reset()
            sendPing()
            policy.allowLivenessRecovery(now: SessionClock.now)
        }
    }

    private var hasDeliveryFailureEvidence: Bool { !livenessGrace.isActive(at: SessionClock.uptime) }

    private func tick() {
        guard !stopped else { return }
        observeLocalScheduling()
        let uptime = SessionClock.uptime
        let now = SessionClock.now
        if let pending = transaction, now - pending.started > 8 {
            let header = MediaFrameHeader(stream: pending.stream, frameID: 1, isIDR: true)
            abortTransaction(retry: true, mediaFailure: hasDeliveryFailureEvidence && pending.frameSubmitted && pending.stage == .producing && !reassembledAtPeer.contains(header))
        }
        guard negotiated, !paused, !configurationSuspended else { return }
        if udpPeer != nil, SessionClock.uptime - lastPingAt >= (transaction?.awaitingLiveness == true ? Self.fastRequestInterval : 0.2) { sendPing() }
        if side == .viewer, let pending = transaction, pending.fast, pending.path == .udp, !pending.hostReady,
           pending.stage == .ready, receiver?.pendingFrameCount == 0, pending.requestSends < Self.maximumFastRequests,
           uptime - pending.requestSentAt >= Self.fastRequestInterval { sendFastRequest() }
        if side == .host, udpVerified, !livenessGrace.isActive(at: uptime),
           uptime - max(lastPongAt, livenessResumedAt) >= 1 {
            udpVerified = false
            refreshInteractiveDatagramAvailability()
            udpPeer?.close("媒体路径保活超时")
        }
        if side == .viewer {
            if alternateProbePending, transaction == nil, policy.probeID == nil {
                let actions = policy.probeAlternateRoute(now: now)
                if !actions.isEmpty {
                    alternateProbePending = false; alternateRetryDeferred = retryAt > 0
                    retryAt = 0; retryPath = nil
                    retireDatagramPath()
                    handleActions(actions)
                }
            }
            if udpAvailable, transaction == nil || SessionClock.uptime - lastPongAt >= 1 { handleActions(policy.tick(now: now)) }
            if transaction == nil, now >= retryAt {
                if retryAt > 0 {
                    if retryPath == .udp, !udpVerified, udpPeer != nil {
                        retryAt = now + 0.1
                        return
                    }
                    retryAt = 0
                    let retry = retryPath; retryPath = nil
                    beginSwitch(retry == .udp && udpVerified ? .udp : videoBound ? .tcp : .shared, cause: .retry)
                } else if active == nil, (videoBound && !udpAvailable || now >= fallbackAt), policy.probeID == nil {
                    beginSwitch(videoBound ? .tcp : .shared, cause: .initial)
                }
            }
            handleReceiveEvents(receiver?.poll() ?? [])
            if now - sampleStartedAt >= 1 {
                collectLoss()
                let duration = min(5, now - sampleStartedAt)
                let localNetwork = reportLocalNetwork()
                // Control heartbeats arrive every five seconds; each counts only in the window it arrived in, so
                // one delayed heartbeat cannot stand for several windows of local delay. Never reuse an old route's
                // UDP RTT, or the initial 10 ms estimate, as evidence that the current video path is healthy.
                var measuredRoundTrip = controlRoundTrip.flatMap { $0.at >= sampleStartedAt ? $0.milliseconds : nil }
                let isActiveUDP = (transaction?.path ?? active?.path) == .udp && udpVerified
                if isActiveUDP, lastPongAt > 0, SessionClock.uptime - lastPongAt < 1 {
                    measuredRoundTrip = max(measuredRoundTrip ?? 0, roundTrip * 1_000)
                }
                let windowJitter = udpJitter.takeWindowMilliseconds()
                let sample = MediaPathSample(duration: duration,
                    mediaActive: now - lastVideoAt < 1, networkSamples: samplePackets, decodedFrames: sampleFrames,
                    lossFraction: sampleSettledFragments >= MediaLossWindow.minimumFragments
                        ? Double(sampleLostFragments) / Double(sampleSettledFragments) : nil,
                    jitterMilliseconds: isActiveUDP && samplePackets > 0 ? windowJitter : nil,
                    queueMilliseconds: samplePackets > 0 ? sampleWaitMilliseconds : nil,
                    encodeMilliseconds: sampleEncode.mean, decodeMilliseconds: sampleDecode.mean,
                    frameBudgetMilliseconds: 1000 / Double(settings.framesPerSecond),
                    deliveryMilliseconds: sampleDeliveryMilliseconds,
                    receivedMegabits: Double(sampleBytes) * 8 / duration / 1_000_000,
                    isLocalNetwork: localNetwork, roundTripMilliseconds: measuredRoundTrip, mappedTransfer: sampleMappedTransfer)
                let actions = policy.observe(sample, epoch: policy.epoch, now: now)
                if localNetwork || (!sampleDirectReduction && !actions.contains(where: { if case .reduceLoad = $0 { return true }; return false })) { onSample?(sample) }
                // A UDP trial that has not committed yet is when loss explains a fallback, so follow
                // the path currently receiving video rather than only the committed one.
                onDatagramLoss?((transaction?.path ?? active?.path) == .udp ? lossWindow.fraction(at: now) : nil)
                handleActions(actions)
                sampleStartedAt = now; samplePackets = 0; sampleFrames = 0; sampleWaitMilliseconds = 0
                sampleBytes = 0; sampleSettledFragments = 0; sampleLostFragments = 0; sampleDeliveryMilliseconds = nil
                sampleMappedTransfer = nil
                sampleEncode = MediaComputeTiming(); sampleDecode = MediaComputeTiming()
                sampleDirectReduction = false
            }
        } else {
            handleSendEvents(cache?.expire() ?? [])
            sendTailProbes()
            if now - sampleStartedAt >= 1 {
                let delivery = deliveryEstimator.takeWindow(at: now).map { min(60_000, $0) }
                if let delivery { onVideoDeliveryDelay?(delivery) }
                if let identifier = sessionID {
                    var mapped: MappedTransferState?
                    if hasRecentMappedPayload?() == true {
                        let waited = waitingCreditStream != nil && waitingCreditStream == active?.stream && transaction == nil
                        mapped = waited ? .waitingForVideoCredit : .transferring
                    }
                    let encode = sampleEncode.mean.flatMap { $0 <= 10_000 ? $0 : nil }
                    if encode != nil || delivery != nil || mapped != nil {
                        sendControl(MediaControl(.stats, sessionID: identifier, encodeMilliseconds: encode ?? 0,
                                                 deliveryMilliseconds: delivery, encodeIdle: encode == nil ? true : nil,
                                                 mappedTransfer: mapped))
                    }
                }
                waitingCreditStream = nil
                sampleStartedAt = now; sampleEncode = MediaComputeTiming(); sampleDecode = MediaComputeTiming()
            }
        }
        pumpDatagrams()
    }

    private func handleActions(_ actions: [MediaPathAction], localNetwork: Bool? = nil) {
        guard side == .viewer, !stopped else { return }
        for action in actions {
            switch action {
            case .beginProbe: startUDP(); if udpPeer != nil { sendPing() }
            case .cancelProbe:
                if policy.lastReason == .probeFailed || policy.lastReason == .probeTimeout { retireDatagramPath() }
                // A failed alternate resumes the reliable retry it deferred, so delivery failures stay bounded.
                if alternateRetryDeferred, !paused {
                    alternateRetryDeferred = false
                    if policy.targetPath == .tcp, transaction == nil { retryAt = SessionClock.now; retryPath = nil }
                }
            case .selectPath(let path, _, let reason):
                if path == .tcp, reason == .noPong { retireDatagramPath() }
                if transaction != nil { abortTransaction(retry: false) }
                beginSwitch(path == .udp ? .udp : videoBound ? .tcp : .shared, cause: .policy(reason))
            case .reduceLoad(let bottleneck): reportReduction(bottleneck, localNetwork: localNetwork)
            case .retryUDP:
                // The lower quality requested with this failure reaches the host before the fresh keyframe.
                if transaction != nil { abortTransaction(retry: false) }
                retryAt = SessionClock.now + MediaPathPolicy.udpRetryDelay; retryPath = .udp
            case .restartSession: control.close("媒体传输代次已耗尽，请重新连接", retryable: true)
            }
        }
    }

    @discardableResult
    private func reportLocalNetwork(_ failedRoute: Bool? = nil) -> Bool {
        let local = failedRoute ?? localNetworkClassification(transaction?.path ?? active?.path ?? .shared)
            ?? transaction?.localNetwork ?? active?.localNetwork ?? false
        if failedRoute == nil {
            if transaction != nil { transaction?.localNetwork = local }
            else if active != nil { active?.localNetwork = local }
        }
        if reportedLocalNetwork != local {
            reportedLocalNetwork = local
            onLocalNetwork?(local)
        }
        return local
    }

    private func localNetworkClassification(_ path: Path) -> Bool? {
        switch path {
        case .udp: return udpRelayed ? false : udpPeer?.localNetworkClassification
        case .tcp: return initialDatagramRelayed ? false : videoPeer?.localNetworkClassification
        case .shared: return initialDatagramRelayed ? false : control.localNetworkClassification
        }
    }

    private func reportReduction(_ cause: MediaBottleneck, localNetwork: Bool? = nil) {
        // A closed connection may no longer have a NWPath. Keep the failed epoch's known classification;
        // every new transaction starts from its own connection, including switches to a relay.
        let local = reportLocalNetwork(localNetwork ?? transaction?.localNetwork ?? active?.localNetwork)
        // LAN reductions require sustained latency samples; a decoder or delivery failure alone must
        // neither lower the chosen ceiling nor hide the latency window from that policy.
        if !local { sampleDirectReduction = true }
        onReduceLoad?(cause)
    }

    private func retireDatagramPath() {
        let previous = udpPeer
        udpPeer = nil; udpVerified = false; receivedChallenge = false; challenges.clear(); lastPongAt = 0
        refreshInteractiveDatagramAvailability()
        udpJitter.reset()
        previous?.close("媒体路径失活，需要重新握手")
        clearDatagrams()
        onDatagramPathRetired?(); alternateEndpoint?.retire?()
    }

    private func sendControl(_ value: MediaControl) {
        do { control.send(try value.message()) }
        catch { control.close("媒体控制参数无效") }
    }

    private func transactionControl(_ operation: MediaControl.Operation, _ value: Transaction, mediaFailure: Bool? = nil) -> MediaControl {
        MediaControl(operation, sessionID: value.stream.sessionID, transactionID: value.id,
            transportEpoch: value.stream.transportEpoch, codecEpoch: value.stream.codecEpoch, path: value.path.rawValue,
            mediaFailure: mediaFailure, fast: operation == .prepare && value.fast ? true : nil)
    }

    private func sendTransaction(_ operation: MediaControl.Operation, _ value: Transaction, mediaFailure: Bool? = nil) {
        sendControl(transactionControl(operation, value, mediaFailure: mediaFailure))
    }

    // Counts of a reassembler that is about to be replaced still belong to the current window.
    private func collectLoss(abandoning: Bool = false) {
        if abandoning { receiver?.abandon() }
        guard let counts = receiver?.takeFragmentCounts() else { return }
        lossWindow.add(settled: counts.settled, lost: counts.lost, at: SessionClock.now)
        sampleSettledFragments += counts.settled; sampleLostFragments += min(counts.lost, counts.settled)
    }

    private func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw DeskError.invalid("无法生成媒体会话凭据") }
        return bytes
    }

    private func stateLabel(_ path: Path) -> String {
        if path == .udp, udpRelayed { return "中继 UDP 视频" }
        switch path { case .udp: return "UDP 视频"; case .tcp: return "TCP 视频"; case .shared: return "TCP 兼容模式" }
    }

    private func recordDuration(_ metric: PerformanceMetric, seconds: TimeInterval, identifier: UInt64? = nil) {
        guard seconds.isFinite, seconds >= 0, let value = Int(exactly: (seconds * 1_000_000).rounded()) else { return }
        diagnostics?.recordValue(metric, value, kind: .mediaFrame, identifier: identifier)
    }

    private func recordTransport(_ path: Path) {
        diagnostics?.recordValue(.mediaTransport, path == .udp ? 1 : path == .tcp ? 2 : 3, kind: .mediaFrame)
    }

    private static func isBulk(_ kind: MessageKind) -> Bool {
        [.clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd,
         .clipboardReceipt, .clipboardCancel, .clipboardManifest, .clipboardPull].contains(kind)
    }

    deinit {
        timer?.cancel(); pacingTimer?.cancel(); pathMonitor?.cancel(); udpListener?.cancel(); udpPeer?.close(); videoPeer?.close(); bulkPeer?.close()
        for peer in pendingAuxiliary.values { peer.close() }
        for peer in pendingDatagramPeers.values { peer.close() }
    }
}
