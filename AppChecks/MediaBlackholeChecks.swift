import Darwin
import Foundation
import Network
import QuietDeskCore

private struct BlackholeCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private final class BlackholeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private func requireBlackhole(_ condition: Bool, _ message: String) throws {
    if !condition { throw BlackholeCheckFailure(description: message) }
}

private func waitBlackhole(_ semaphore: DispatchSemaphore, _ message: @autoclosure () -> String, seconds: Double = 8) throws {
    if semaphore.wait(timeout: .now() + seconds) != .success { throw BlackholeCheckFailure(description: message()) }
}

private final class BlackholePortReservation {
    let port: NWEndpoint.Port
    private var descriptor: Int32

    init() throws {
        for _ in 0..<20 {
            let udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP), tcp = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard udp >= 0, tcp >= 0 else {
                if udp >= 0 { close(udp) }; if tcp >= 0 { close(tcp) }
                throw BlackholeCheckFailure(description: "Could not create fixture port reservations")
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let reserved = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    bind(udp, raw, length) == 0 && getsockname(udp, raw, &length) == 0 && bind(tcp, raw, length) == 0
                }
            }
            close(tcp)
            if reserved {
                descriptor = udp
                port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port))!
                return
            }
            close(udp)
        }
        throw BlackholeCheckFailure(description: "No paired TCP/UDP fixture port was available")
    }

    func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    deinit { release() }
}

private func blackholeTCPParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.disableAckStretching = true
    return NWParameters(tls: nil, tcp: tcp)
}

// Both legs remain plain TCP. Only the real endpoints terminate TLS and negotiate their ALPN roles.
private final class CiphertextTCPRelay {
    private let incoming: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private var incomingReady = false
    private var upstreamReady = false
    private var startedReads = false
    private var closed = false
    var onClosed: (() -> Void)?

    init(incoming: NWConnection, hostPort: NWEndpoint.Port, queue: DispatchQueue) {
        self.incoming = incoming
        upstream = NWConnection(host: "127.0.0.1", port: hostPort, using: blackholeTCPParameters())
        self.queue = queue
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.incomingReady = true; self.startReads() }
            if case .failed = state { self.stop() }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.upstreamReady = true; self.startReads() }
            if case .failed = state { self.stop() }
        }
        incoming.start(queue: queue)
        upstream.start(queue: queue)
    }

    func stop() {
        guard !closed else { return }
        closed = true
        incoming.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        incoming.cancel()
        upstream.cancel()
        onClosed?()
    }

    private func startReads() {
        guard !closed, incomingReady, upstreamReady, !startedReads else { return }
        startedReads = true
        forward(from: incoming, to: upstream)
        forward(from: upstream, to: incoming)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) {
        // At most one 64 KiB chunk per direction is awaiting send completion.
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.stop(); return }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                guard sendError == nil, !complete else { self.stop(); return }
                self.forward(from: source, to: destination)
            })
        }
    }
}

// A separate upstream socket for each client preserves DTLS peer identity and UDP message boundaries.
private final class CiphertextUDPRelay {
    private let incoming: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private var incomingReady = false
    private var upstreamReady = false
    private var startedReads = false
    private var closed = false
    var shouldForwardHostDatagram: ((Data) -> Bool)?
    var shouldForwardClientDatagram: ((Data) -> Bool)?
    var hostProbeDelay: TimeInterval = 0
    private var delayedDatagrams = 0
    var onClosed: (() -> Void)?

    init(incoming: NWConnection, hostPort: NWEndpoint.Port, queue: DispatchQueue) {
        self.incoming = incoming
        upstream = NWConnection(host: "127.0.0.1", port: hostPort, using: .udp)
        self.queue = queue
    }

    func start() {
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.incomingReady = true; self.startReads() }
            if case .failed = state { self.stop() }
        }
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.upstreamReady = true; self.startReads() }
            if case .failed = state { self.stop() }
        }
        incoming.start(queue: queue)
        upstream.start(queue: queue)
    }

    func stop() {
        guard !closed else { return }
        closed = true
        incoming.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        incoming.cancel()
        upstream.cancel()
        onClosed?()
    }

    private func startReads() {
        guard !closed, incomingReady, upstreamReady, !startedReads else { return }
        startedReads = true
        forward(from: incoming, to: upstream, fromHost: false)
        forward(from: upstream, to: incoming, fromHost: true)
    }

    private func forward(from source: NWConnection, to destination: NWConnection, fromHost: Bool) {
        source.receiveMessage { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, complete, let data, !data.isEmpty, data.count <= 65_507 else { self.stop(); return }
            if fromHost {
                if self.shouldForwardHostDatagram?(data) == false {
                    self.forward(from: source, to: destination, fromHost: fromHost)
                    return
                }
            } else if self.shouldForwardClientDatagram?(data) == false {
                self.forward(from: source, to: destination, fromHost: fromHost)
                return
            }
            if fromHost, self.hostProbeDelay > 0, data.first == 23, (1_024...1_080).contains(data.count) {
                guard self.delayedDatagrams < 8 else { self.stop(); return }
                self.delayedDatagrams += 1
                self.queue.asyncAfter(deadline: .now() + self.hostProbeDelay) { [weak self] in
                    guard let self, !self.closed else { return }
                    self.delayedDatagrams -= 1
                    destination.send(content: data, completion: .contentProcessed { [weak self] error in
                        if error != nil { self?.stop() }
                    })
                }
                self.forward(from: source, to: destination, fromHost: fromHost)
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.closed else { return }
                guard sendError == nil else { self.stop(); return }
                self.forward(from: source, to: destination, fromHost: fromHost)
            })
        }
    }
}

private final class LoopbackMediaBlackhole {
    struct Statistics {
        var tcpConnections = 0
        var udpClients = 0
        var clientDatagrams = 0
        var blockedClientDatagrams = 0
        var droppedHostDatagrams = 0
        var droppedHostBytes = 0
        var forwardedProbeSizedAfterDrop = 0
        var droppedSizes: Set<Int> = []
        var allowedProbeSizes: Set<Int> = []
        var firstDropAt: TimeInterval?
    }

    let firstDrop = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "checks.media-blackhole.proxy")
    private let hostPort: NWEndpoint.Port
    private let blockAllUDP: Bool
    private let probeDelay: TimeInterval
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var tcpRelays: [UUID: CiphertextTCPRelay] = [:]
    private var udpRelays: [UUID: CiphertextUDPRelay] = [:]
    private var statistics = Statistics()
    private var stopped = false

    init(hostPort: NWEndpoint.Port, blockAllUDP: Bool = false, probeDelay: TimeInterval = 0) {
        self.hostPort = hostPort
        self.blockAllUDP = blockAllUDP
        self.probeDelay = probeDelay
    }

    func start() throws -> NWEndpoint.Port {
        let tcpReady = DispatchSemaphore(value: 0)
        let tcpIsReady = BlackholeBox(false)
        let reservation = try BlackholePortReservation()
        let tcpParameters = blackholeTCPParameters()
        tcpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: reservation.port)
        let tcp = try NWListener(using: tcpParameters)
        tcp.newConnectionHandler = { [weak self] connection in self?.acceptTCP(connection) }
        tcp.stateUpdateHandler = { state in
            if case .ready = state { tcpIsReady.update { $0 = true }; tcpReady.signal() }
            if case .failed = state { tcpReady.signal() }
        }
        tcpListener = tcp
        tcp.start(queue: queue)
        try waitBlackhole(tcpReady, "Transparent TCP proxy did not bind loopback")
        guard tcpIsReady.get(), let proxyPort = tcp.port else { throw BlackholeCheckFailure(description: "Transparent TCP proxy failed") }

        let udpReady = DispatchSemaphore(value: 0)
        let udpIsReady = BlackholeBox(false)
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: proxyPort)
        reservation.release()
        let udp = try NWListener(using: udpParameters)
        udp.newConnectionHandler = { [weak self] connection in self?.acceptUDP(connection) }
        udp.stateUpdateHandler = { state in
            if case .ready = state { udpIsReady.update { $0 = true }; udpReady.signal() }
            if case .failed = state { udpReady.signal() }
        }
        udpListener = udp
        udp.start(queue: queue)
        try waitBlackhole(udpReady, "Transparent UDP proxy did not bind the TCP proxy port")
        try requireBlackhole(udpIsReady.get(), "Transparent UDP proxy failed")
        return proxyPort
    }

    func snapshot() -> Statistics { queue.sync { statistics } }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            tcpListener?.cancel()
            udpListener?.cancel()
            let tcp = Array(tcpRelays.values), udp = Array(udpRelays.values)
            tcpRelays.removeAll()
            udpRelays.removeAll()
            tcp.forEach { $0.stop() }
            udp.forEach { $0.stop() }
        }
    }

    private func acceptTCP(_ connection: NWConnection) {
        guard !stopped, tcpRelays.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let relay = CiphertextTCPRelay(incoming: connection, hostPort: hostPort, queue: queue)
        relay.onClosed = { [weak self] in self?.tcpRelays.removeValue(forKey: id) }
        tcpRelays[id] = relay
        statistics.tcpConnections += 1
        relay.start()
    }

    private func acceptUDP(_ connection: NWConnection) {
        guard !stopped, udpRelays.count < 2 else { connection.cancel(); return }
        let id = UUID()
        let relay = CiphertextUDPRelay(incoming: connection, hostPort: hostPort, queue: queue)
        relay.hostProbeDelay = probeDelay
        relay.shouldForwardHostDatagram = { [weak self] data in
            guard let self, !self.stopped else { return false }
            if self.blockAllUDP || data.count > 1_080 {
                self.statistics.droppedHostDatagrams += 1
                self.statistics.droppedHostBytes += data.count
                if self.statistics.droppedSizes.count < 16 { self.statistics.droppedSizes.insert(data.count) }
                if self.statistics.firstDropAt == nil {
                    self.statistics.firstDropAt = SessionClock.now
                    self.firstDrop.signal()
                }
                return false
            }
            if data.count >= 1_024 {
                if self.statistics.allowedProbeSizes.count < 16 { self.statistics.allowedProbeSizes.insert(data.count) }
                if self.statistics.firstDropAt != nil { self.statistics.forwardedProbeSizedAfterDrop += 1 }
            }
            return true
        }
        relay.shouldForwardClientDatagram = { [weak self] _ in
            guard let self, !self.stopped else { return false }
            self.statistics.clientDatagrams += 1
            guard self.blockAllUDP else { return true }
            self.statistics.blockedClientDatagrams += 1
            if self.statistics.firstDropAt == nil {
                self.statistics.firstDropAt = SessionClock.now
                self.firstDrop.signal()
            }
            return false
        }
        relay.onClosed = { [weak self] in self?.udpRelays.removeValue(forKey: id) }
        udpRelays[id] = relay
        statistics.udpClients += 1
        relay.start()
    }
}

private func blackholePacket(sequence: UInt32, idr: Bool, interruptedStream: Bool = false, wholeFrameLoss: Bool = false) -> VideoPacket {
    var avcc = Data()
    // Make every P-frame fragment full-sized when testing sender-only failure evidence.
    let predictedBytes = wholeFrameLoss ? 8 * MediaFragment.maximumPayloadBytes - 12 : 8 * 1_024
    let bytes = interruptedStream ? (idr ? 32 : predictedBytes) : (idr ? 512 * 1_024 : 32)
    let nal = Data([idr ? 0x65 : 0x41]) + Data(repeating: 0x7D, count: bytes - 1)
    avcc.put(UInt32(nal.count))
    avcc.append(nal)
    return VideoPacket(sequence: sequence, sps: idr ? Data([0x67, 0x42, 0x00, 0x1F]) : Data(),
                       pps: idr ? Data([0x68, 0xCE, 0x06]) : Data(), avcc: avcc)
}

private func exerciseMediaBlackhole(blockAllUDP: Bool = false, probeDelay: TimeInterval = 0, interruptedStream: Bool = false, wholeFrameLoss: Bool = false) throws {
    let key = try PairingKey.generate()
    let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 12)
    let diagnostics = PerformanceDiagnostics(enabled: true)
    let hostQueue = DispatchQueue(label: "checks.media-blackhole.host")
    let reservation = try BlackholePortReservation()
    let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: reservation.port)
    let listener = try NWListener(using: parameters)
    let listenerReady = DispatchSemaphore(value: 0), committedTCP = DispatchSemaphore(value: 0)
    let predictedFrame = DispatchSemaphore(value: 0), controlPong = DispatchSemaphore(value: 0)
    let hostSession = BlackholeBox<MediaSession?>(nil), viewerSession = BlackholeBox<MediaSession?>(nil)
    let hostPeers = BlackholeBox<[Peer]>([]), errors = BlackholeBox<[String]>([]), states = BlackholeBox<[String]>([])
    let lossReports = BlackholeBox<[Double?]>([]), highestLoss = BlackholeBox<Double>(0)
    let reportFragments = BlackholeBox((settled: 0, lost: 0)), reportPongs = BlackholeBox(0)
    let reportPaths = BlackholeBox<[MediaSession.DiagnosticVideoPath]>([])
    let sequence = BlackholeBox<UInt32>(100), udpPreparations = BlackholeBox(0), tcpPreparations = BlackholeBox(0)
    let videoConnections = BlackholeBox(0), committed = BlackholeBox<[MediaStreamID]>([])
    let teardown = BlackholeBox(false), decodedFrames = BlackholeBox(0)
    let requireNewControlPong = BlackholeBox(false)
    let networkLoadReductions = BlackholeBox(0), deliveryHints = BlackholeBox(0)
    if wholeFrameLoss {
        let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
        let frame = try MediaFrame(header: MediaFrameHeader(stream: stream, frameID: 1, isIDR: false),
                                   packet: blackholePacket(sequence: 1, idr: false, interruptedStream: true, wholeFrameLoss: true))
        let fragments = try MediaFragment.fragment(frame: frame)
        try requireBlackhole(fragments.count == 8 && fragments.allSatisfy { $0.encode().count == MediaFragment.maximumDatagramBytes },
                             "Sender-only fixture left a partial fragment visible to the viewer")
    }

    func recordError(_ message: String) {
        guard !teardown.get() else { return }
        errors.update { if $0.count < 16 { $0.append(message) } }
    }
    func nextPacket(_ idr: Bool) -> VideoPacket {
        sequence.update { $0 += 1 }
        return blackholePacket(sequence: sequence.get(), idr: idr, interruptedStream: interruptedStream, wholeFrameLoss: wholeFrameLoss)
    }

    listener.newConnectionHandler = { connection in
        guard hostPeers.get().count < 8 else { recordError("Fixture host connection bound exceeded"); connection.cancel(); return }
        let peer = Peer(connection: connection, heartbeatInterval: 0.25)
        hostPeers.update { $0.append(peer) }
        peer.onClose = { recordError("host: \($0)") }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                if role == .video { videoConnections.update { $0 += 1 } }
                hostSession.get()?.acceptAuxiliary(peer, role: role)
                return
            }
            do {
                guard let port = listener.port else { throw BlackholeCheckFailure(description: "Host port disappeared") }
                let media = try MediaSession.host(control: peer, key: key, port: port.rawValue, settings: settings, relayRouting: wholeFrameLoss)
                hostSession.update { $0 = media }
                media.onPrepareRecovery = { $0(true) }
                media.onProduceRecoveryFrame = { [weak media] in media?.sendVideo(nextPacket(true)) }
                media.onResumeFrames = { [weak media] in media?.sendVideo(nextPacket(false)) }
                peer.onMessageHandled = { message, resume in
                    if message.kind == .mediaControl, let value = try? MediaControl.read(message.payload), value.operation == .prepare {
                        if value.path == "udp" { udpPreparations.update { $0 += 1 } }
                        if value.path == "tcp" { tcpPreparations.update { $0 += 1 } }
                    }
                    _ = media.receive(message)
                    resume()
                }
                media.start()
            } catch { recordError("Host setup: \(error)") }
        }
        peer.start()
    }
    listener.stateUpdateHandler = { if case .ready = $0 { listenerReady.signal() } }
    listener.start(queue: hostQueue)
    try waitBlackhole(listenerReady, "Host TLS listener did not bind loopback")
    guard let hostPort = listener.port else { throw BlackholeCheckFailure(description: "Host TLS port is missing") }
    reservation.release()
    let proxy = LoopbackMediaBlackhole(hostPort: hostPort, blockAllUDP: blockAllUDP, probeDelay: probeDelay)
    defer {
        teardown.update { $0 = true }
        viewerSession.get()?.stop()
        hostSession.get()?.stop()
        hostPeers.get().forEach { $0.close("blackhole fixture finished") }
        proxy.stop()
        listener.cancel()
    }
    let proxyPort = try proxy.start()
    let connection = NWConnection(host: "127.0.0.1", port: proxyPort,
                                  using: try MediaSecureTransport.tlsParameters(key: key, roles: [.control]))
    let client = Peer(connection: connection, heartbeatInterval: 0.25)
    defer { teardown.update { $0 = true }; client.close("blackhole fixture finished") }
    client.onClose = { recordError("viewer control: \($0)") }
    client.onRoundTripMilliseconds = { _ in if requireNewControlPong.get() { controlPong.signal() } }
    client.onReady = {
        do {
            let media = try MediaSession.viewer(control: client, key: key, host: "127.0.0.1", port: proxyPort.rawValue,
                                                settings: settings, udpEnabled: true, relayRouting: wholeFrameLoss)
            viewerSession.update { $0 = media }
            media.diagnostics = diagnostics
            media.onReduceLoad = { cause in if cause == .network { networkLoadReductions.update { $0 += 1 } } }
            media.onDatagramLoss = { fraction in
                lossReports.update { $0.append(fraction) }
                if let fraction { highestLoss.update { $0 = max($0, fraction) } }
            }
            media.onDiagnosticVideoPath = { path in reportPaths.update { $0.append(path) } }
            media.onDiagnosticUDPLoss = { settled, lost in
                let path = reportPaths.get().last
                if path != .trialUDP(relayed: false) && !(interruptedStream && path == .committed(.udp, relayedUDP: false)) {
                    recordError("UDP loss was settled outside its current trial or committed path")
                }
                reportFragments.update { $0.settled += settled; $0.lost += lost }
            }
            media.onDiagnosticUDPRoundTrip = { _ in reportPongs.update { $0 += 1 } }
            media.onVideo = { frame, complete in
                let expected = blackholePacket(sequence: frame.packet.sequence, idr: frame.header.isIDR, interruptedStream: interruptedStream, wholeFrameLoss: wholeFrameLoss)
                guard frame.packet.sps == expected.sps, frame.packet.pps == expected.pps, frame.packet.avcc == expected.avcc else {
                    recordError("Reassembled media changed bytes")
                    complete(false)
                    return
                }
                decodedFrames.update { $0 += 1 }
                complete(true)
                if !frame.header.isIDR { predictedFrame.signal() }
            }
            media.onCommitStream = { stream, packet in
                if packet.avcc != blackholePacket(sequence: packet.sequence, idr: true, interruptedStream: interruptedStream, wholeFrameLoss: wholeFrameLoss).avcc {
                    recordError("Committed IDR payload changed from the fixture")
                }
                committed.update { $0.append(stream) }
            }
            media.onState = { state in
                states.update { if $0.count < 32 { $0.append(state) } }
                print("BLACKHOLE STATE", state)
                if state == "TCP 视频" { committedTCP.signal() }
            }
            client.onMessageHandled = { message, resume in
                if message.kind == .mediaControl, let value = try? MediaControl.read(message.payload),
                   value.operation == .recover, value.mediaFailure == true { deliveryHints.update { $0 += 1 } }
                _ = media.receive(message)
                resume()
            }
            media.start()
        } catch { recordError("Viewer setup: \(error)") }
    }
    client.start()
    try waitBlackhole(proxy.firstDrop, "No encrypted UDP traffic reached the filter; states \(states.get()), errors \(errors.get())")
    // Discard pre-filter samples so the next window describes traffic after the block became effective.
    _ = diagnostics.drain()
    let droppedAt = proxy.snapshot().firstDropAt ?? SessionClock.now
    // UDP gets udpMediaFailureLimit attempts at decreasing quality before a blackholed media path moves to TCP.
    try waitBlackhole(committedTCP, "Live UDP probes with blackholed media never committed independent TCP; states \(states.get()), errors \(errors.get())", seconds: 15)
    try waitBlackhole(predictedFrame, "TCP committed an IDR but did not resume its P-frame chain", seconds: 3)
    requireNewControlPong.update { $0 = true }
    try waitBlackhole(controlPong, "TLS control stopped responding during media fallback", seconds: 2)
    if interruptedStream {
        let stats = proxy.snapshot()
        let paths = reportPaths.get()
        let summaries = diagnostics.drain()
        let pongs = summaries.filter { $0.metric == .mediaRoundTrip }.reduce(0) { $0 + $1.count }
        try requireBlackhole(stats.droppedHostDatagrams > 0 && stats.forwardedProbeSizedAfterDrop > 0 && pongs > 0,
                             "Interrupted video did not retain authenticated UDP liveness")
        try requireBlackhole(paths.contains(.committed(.udp, relayedUDP: false))
                             && paths.last == .committed(.tcp, relayedUDP: false),
                             "Intermittently working UDP did not move its broken P-frame chain to TCP: \(paths)")
        try requireBlackhole(udpPreparations.get() >= 3 && udpPreparations.get() <= 6 && tcpPreparations.get() == 1,
                             "Successful UDP IDRs bypassed the bounded interruption budget: \(udpPreparations.get())")
        if wholeFrameLoss {
            let fragments = reportFragments.get()
            // Each committed UDP IDR has one fragment; no dropped P-frame fragment can settle here.
            try requireBlackhole(fragments.settled == committed.get().count - 1 && fragments.lost == 0 && deliveryHints.get() >= 3,
                                 "Whole-frame loss lacked sender evidence or exposed P-frame fragments: settled \(fragments), hints \(deliveryHints.get())")
        }
        try requireBlackhole(errors.get().isEmpty, "Interrupted video damaged its control connection: \(errors.get())")
        print("INTERRUPTED UDP wholeFrameLoss=\(wholeFrameLoss) committedIDRs=\(committed.get().count - 1) udpPrepare=\(udpPreparations.get()) tcpPrepare=\(tcpPreparations.get()) authenticatedPongs=\(pongs) deliveryHints=\(deliveryHints.get()) elapsed=\(SessionClock.now - droppedAt)s")
        return
    }
    // One more sample window on TCP must clear the UDP loss figure.
    let reportsBeforeSettling = lossReports.get().count
    for _ in 0..<40 where lossReports.get().count < reportsBeforeSettling + 2 { Thread.sleep(forTimeInterval: 0.05) }

    let stats = proxy.snapshot()
    let pongSamples = diagnostics.drain().filter { $0.metric == .mediaRoundTrip }.reduce(0) { $0 + $1.count }
    let elapsed = SessionClock.now - droppedAt
    print("BLACKHOLE FILTER mode=\(blockAllUDP ? "all-udp" : "large-media") dropped=\(stats.droppedHostDatagrams) bytes=\(stats.droppedHostBytes) ciphertextSizes=\(stats.droppedSizes.sorted()) blockedClientDatagrams=\(stats.blockedClientDatagrams)")
    print("BLACKHOLE PROBES forwardedAfterDrop=\(stats.forwardedProbeSizedAfterDrop) ciphertextSizes=\(stats.allowedProbeSizes.sorted()) authenticatedRTTSamples=\(pongSamples)")
    print("BLACKHOLE LOSS highest=\(String(format: "%.3f", highestLoss.get())) last=\(String(describing: lossReports.get().last ?? nil))")
    print("BLACKHOLE COMMIT path=TCP 视频 elapsed=\(String(format: "%.3f", elapsed))s udpPrepare=\(udpPreparations.get()) tcpPrepare=\(tcpPreparations.get()) videoTLSConnections=\(videoConnections.get()) tcpRelays=\(stats.tcpConnections) networkLoadReductions=\(networkLoadReductions.get())")

    let fragments = reportFragments.get()
    let paths = reportPaths.get(), trial = MediaSession.DiagnosticVideoPath.trialUDP(relayed: false)
    try requireBlackhole(paths.first == .preparing && paths.last == .committed(.tcp, relayedUDP: false),
                         "Report missed preparation or the final independent TCP path: \(paths)")
    try requireBlackhole(paths.filter { $0 == trial }.count == udpPreparations.get()
                         && zip(paths, paths.dropFirst()).allSatisfy { $0 != trial || $1 == .preparing },
                         "Failed UDP trials were omitted, committed, or lost their individual boundaries: \(paths)")
    try requireBlackhole(reportPongs.get() == 0, "Uncommitted UDP probe pongs reached the video RTT report")
    if blockAllUDP {
        try requireBlackhole(stats.blockedClientDatagrams > 0, "Default UDP mode never attempted a real datagram")
        try requireBlackhole(udpPreparations.get() == 0 && tcpPreparations.get() == 1,
                             "A fully blocked UDP path prepared video or failed to choose one independent TCP stream")
        try requireBlackhole(elapsed >= 1 && elapsed < 4,
                             "Fully blocked UDP did not fall back within the probe budget plus TCP IDR delivery margin")
        try requireBlackhole(highestLoss.get() == 0, "UDP loss was reported although no UDP video was ever received")
        try requireBlackhole(fragments.settled == 0, "A completely blocked probe produced video fragment observations")
    } else {
        try requireBlackhole(stats.droppedHostDatagrams >= 100, "Fixture did not blackhole most large IDR fragments")
        try requireBlackhole(stats.forwardedProbeSizedAfterDrop >= 2 && pongSamples >= 2,
                             "Media fallback coincided with lost UDP liveness instead of surviving authenticated pongs")
        try requireBlackhole(networkLoadReductions.get() >= 1, "Actual media blackhole did not request network load reduction")
        try requireBlackhole(highestLoss.get() >= 0.5, "Dropped IDR fragments were not reported as UDP loss: \(highestLoss.get())")
        try requireBlackhole(fragments.lost > 0 && fragments.lost <= fragments.settled,
                             "Dropped IDR fragments did not reach session diagnostic counters: \(fragments)")
        try requireBlackhole(udpPreparations.get() == MediaPathPolicy.udpMediaFailureLimit && tcpPreparations.get() >= 1,
                             "UDP media was not retried at lower quality, or kept retrying instead of falling back")
        try requireBlackhole(networkLoadReductions.get() >= MediaPathPolicy.udpMediaFailureLimit,
                             "A failed UDP keyframe did not lower quality before the next UDP attempt")
    }
    try requireBlackhole(lossReports.get().last.map { $0 == nil } ?? true, "UDP loss kept showing after video moved to TCP")
    try requireBlackhole(videoConnections.get() >= 1 && committed.get().count == 1 && states.get().last == "TCP 视频",
                         "Fallback did not commit exactly one independent TCP stream")
    try requireBlackhole(!states.get().contains("UDP 视频") && !states.get().contains("TCP 兼容模式"),
                         "Fixture selected an unexpected path")
    try requireBlackhole(decodedFrames.get() >= 2 && errors.get().isEmpty,
                         "Control or media failed during the blackhole: \(errors.get())")
}

@main
private struct MediaBlackholeChecks {
    static func main() {
        var failures = 0
        for wholeFrameLoss in [false, true] {
            do {
                try exerciseMediaBlackhole(interruptedStream: true, wholeFrameLoss: wholeFrameLoss)
                print("PASS Repeated successful UDP IDRs cannot hide a broken predicted-frame chain, whole-frame loss \(wholeFrameLoss)")
            } catch {
                failures += 1
                print("FAIL Interrupted UDP playback, whole-frame loss \(wholeFrameLoss): \(error)")
            }
        }
        if CommandLine.arguments.contains("--unstable-only") { exit(failures > 0 ? 1 : 0) }
        for (blockAllUDP, probeDelay) in [(false, 0.0), (true, 0.0), (false, 0.3)] {
            let name = blockAllUDP ? "Fully blocked UDP probes fall back to independent TCP without preparing UDP video"
                : "Live UDP pongs with dropped large media fall back to independent TCP"
            do {
                try exerciseMediaBlackhole(blockAllUDP: blockAllUDP, probeDelay: probeDelay)
                print("PASS \(name), probe delay \(probeDelay)s")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
    }
}
