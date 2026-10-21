import Foundation
import Network

// The private loopback endpoints carry inner desktop TLS/DTLS records unchanged.
public final class RelayViewerBridge: @unchecked Sendable {
    public var onReady: ((UInt16) -> Void)?
    public var onClose: ((Error) -> Void)?
    public var onDatagramFailure: ((Error) -> Void)?
    public let endpoint: RelayEndpoint
    public let deviceID: UUID
    private let accessKey: Data
    private let authorities: [Data]
    private let trustedCertificate: RelayNodeCertificate?
    private let udpEnabled: Bool
    private let preferredLoopbackPort: UInt16?
    private var bindAttempts = 0
    private let queue = DispatchQueue(label: "quietdesk.relay-viewer", qos: .userInteractive)
    private var listener: NWListener?
    private var udpListener: NWListener?
    private var started = false
    private var stopped = false
    private var published = false
    private var forwarders: [UUID: RelayTCPForwarder] = [:]
    private var primary: UUID?
    private var datagramChannel: RelayTLSChannel?
    private var datagramLocal: NWConnection?
    private var datagramPipe: RelayUDPPipe?
    private var datagramHeartbeat: DispatchSourceTimer?
    private var datagramGeneration = UUID()
    private var datagramReading = false
    private var datagramReady = false
    private var pendingDatagrams: [Data] = []
    private let failureLock = NSLock()
    private var failure: Error?
    private var serviceSetupFailure = false

    public var lastFailure: Error? { failureLock.withLock { failure } }
    public var failedBeforeDesktopStream: Bool { failureLock.withLock { serviceSetupFailure } }

    /// `preferredLoopbackPort` only chooses the first loopback port tried; a taken UDP number still moves to a free pair.
    public init(endpoint: RelayEndpoint, accessKey: Data, deviceID: UUID, udpEnabled: Bool = true,
                certificateAuthorities: [Data] = [], trustedCertificate: RelayNodeCertificate? = nil,
                preferredLoopbackPort: UInt16? = nil) throws {
        guard accessKey.count == 32 else { throw RelayServiceError.invalid }
        self.endpoint = endpoint; self.accessKey = accessKey; self.deviceID = deviceID
        self.udpEnabled = udpEnabled; authorities = certificateAuthorities
        self.trustedCertificate = trustedCertificate; self.preferredLoopbackPort = preferredLoopbackPort
    }

    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }; started = true
            startTCPListener()
        }
    }

    private func startTCPListener() {
        bindAttempts += 1
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.disableAckStretching = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let preferred = bindAttempts == 1 ? preferredLoopbackPort.flatMap { NWEndpoint.Port(rawValue: $0) } : nil
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: preferred ?? .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.acceptTCP(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.fail(RelayTransportError.network); return }
                    if self.udpEnabled { self.startUDPListener(port: port) } else { self.publish(port.rawValue) }
                case .failed, .cancelled: self.fail(RelayTransportError.network)
                default: break
                }
            }
            listener.start(queue: queue)
        } catch { fail(RelayTransportError.network) }
    }

    private func startUDPListener(port: NWEndpoint.Port) {
        do {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            udpListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.acceptUDP(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.udpListener === listener, !self.stopped else { return }
                switch state {
                case .ready: self.publish(port.rawValue)
                case .failed: self.udpBindFailed(port)
                default: break
                }
            }
            listener.start(queue: queue)
        } catch { udpBindFailed(port) }
    }

    // The desktop session dials one port number for TCP and UDP. When another socket holds the UDP
    // number, move both listeners to a fresh pair instead of silently leaving relay video on TCP.
    private func udpBindFailed(_ port: NWEndpoint.Port) {
        udpListener?.stateUpdateHandler = nil; udpListener?.cancel(); udpListener = nil
        guard !published else { return }
        guard bindAttempts < 4 else { publish(port.rawValue); return }
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        startTCPListener()
    }

    private func publish(_ port: UInt16) {
        guard !published, !stopped else { return }; published = true; onReady?(port)
    }

    private func acceptTCP(_ connection: NWConnection) {
        guard !stopped, forwarders.count < 16 else { connection.cancel(); return }
        do {
            let id = UUID()
            if primary == nil { primary = id }
            let channel = try RelayTLSChannel(endpoint: endpoint, queue: queue, certificateAuthorities: authorities,
                                              trustedCertificate: trustedCertificate)
            let forwarder = RelayTCPForwarder(local: connection, channel: channel,
                request: RelayMessage(.connect, accessKey: accessKey, deviceID: deviceID))
            forwarders[id] = forwarder
            forwarder.onClose = { [weak self, weak forwarder] error in
                guard let self else { return }; self.forwarders.removeValue(forKey: id)
                if self.primary == id, !self.stopped { self.fail(error, serviceSetup: forwarder?.hasForwarded != true) }
            }
            forwarder.start()
        } catch { connection.cancel(); fail(error) }
    }

    private func acceptUDP(_ connection: NWConnection) {
        closeDatagram()
        let token = datagramGeneration
        datagramLocal = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.datagramLocal === connection, self.datagramGeneration == token, !self.stopped else { return }
            switch state {
            case .ready: self.receiveLocalDatagram(token: token)
            case .failed, .cancelled: self.datagramFailed(RelayTransportError.network, token: token)
            default: break
            }
        }
        connection.start(queue: queue)
        do {
            let channel = try RelayTLSChannel(endpoint: endpoint, queue: queue, certificateAuthorities: authorities,
                                              trustedCertificate: trustedCertificate)
            datagramChannel = channel
            channel.onReady = { [weak self, weak channel] in
                guard let self, let channel, self.datagramGeneration == token, !self.stopped else { return }
                channel.send(RelayMessage(.datagram, accessKey: self.accessKey, deviceID: self.deviceID))
                channel.readMessage(timeout: 10) { [weak self, weak channel] result in
                    guard let self, let channel, self.datagramGeneration == token, self.datagramChannel === channel, !self.stopped else { return }
                    do {
                        let message = try result.get()
                        if message.op == .error { throw message.error ?? .invalid }
                        guard message.op == .datagramReady, let id = message.datagramID, let key = message.datagramKey, message.udpPort != nil else {
                            throw RelayServiceError.invalid
                        }
                        // A node's listener port may be private behind NAT. Only the user-configured
                        // public service endpoint determines where routing datagrams are sent.
                        let pipe = try RelayUDPPipe(endpoint: self.endpoint, port: self.endpoint.port, id: id, key: key, side: 0, queue: self.queue)
                        self.datagramPipe = pipe
                        pipe.onReady = { [weak self, weak pipe] in
                            guard let self, let pipe, self.datagramGeneration == token, !self.stopped else { return }
                            self.datagramReady = true
                            let pending = self.pendingDatagrams; self.pendingDatagrams.removeAll()
                            for packet in pending {
                                pipe.send(packet) { [weak self] success in
                                    if !success { self?.datagramFailed(RelayTransportError.network, token: token) }
                                }
                            }
                        }
                        pipe.onPayload = { [weak self] data, complete in
                            guard let self, self.datagramGeneration == token, let local = self.datagramLocal, !self.stopped else { complete(false); return }
                            local.send(content: data, completion: .contentProcessed { error in complete(error == nil) })
                        }
                        pipe.onClose = { [weak self] error in self?.datagramFailed(error, token: token) }
                        pipe.start()
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + 15, repeating: 15)
                        timer.setEventHandler { [weak channel] in channel?.send(RelayMessage(.ping)) }
                        self.datagramHeartbeat = timer; timer.resume()
                        self.readDatagramHeartbeat(channel, token: token)
                    } catch { self.datagramFailed(error, token: token) }
                }
            }
            channel.onClose = { [weak self] error in self?.datagramFailed(error, token: token) }
            channel.start()
        } catch { datagramFailed(error, token: token) }
    }

    private func receiveLocalDatagram(token: UUID) {
        guard !stopped, datagramGeneration == token, !datagramReading, let local = datagramLocal else { return }
        datagramReading = true
        local.receiveMessage { [weak self] data, _, complete, error in
            guard let self, self.datagramGeneration == token, !self.stopped else { return }
            self.datagramReading = false
            guard error == nil, complete, let data, !data.isEmpty, data.count <= RelayDatagram.maximumPayloadBytes else {
                self.datagramFailed(RelayTransportError.network, token: token); return
            }
            if self.datagramReady, let pipe = self.datagramPipe {
                pipe.send(data) { [weak self] success in
                    guard let self, self.datagramGeneration == token else { return }
                    if success { self.receiveLocalDatagram(token: token) }
                    else { self.datagramFailed(RelayTransportError.network, token: token) }
                }
            } else {
                guard self.pendingDatagrams.count < 8 else { self.datagramFailed(RelayTransportError.queueFull, token: token); return }
                self.pendingDatagrams.append(data); self.receiveLocalDatagram(token: token)
            }
        }
    }

    private func readDatagramHeartbeat(_ channel: RelayTLSChannel, token: UUID) {
        channel.readMessage { [weak self, weak channel] result in
            guard let self, let channel, self.datagramGeneration == token, !self.stopped else { return }
            do {
                let message = try result.get()
                guard message.op == .pong else { throw message.error ?? .invalid }
                self.readDatagramHeartbeat(channel, token: token)
            } catch { self.datagramFailed(error, token: token) }
        }
    }

    private func datagramFailed(_ error: Error, token: UUID) {
        guard datagramGeneration == token, !stopped else { return }
        closeDatagram(); onDatagramFailure?(error)
    }

    public func retireDatagramPath() { queue.async { [self] in closeDatagram() } }

    private func closeDatagram() {
        datagramGeneration = UUID(); datagramReady = false; datagramReading = false; pendingDatagrams.removeAll()
        datagramHeartbeat?.cancel(); datagramHeartbeat = nil
        let channel = datagramChannel; datagramChannel = nil; channel?.close()
        let pipe = datagramPipe; datagramPipe = nil; pipe?.close()
        datagramLocal?.stateUpdateHandler = nil; datagramLocal?.cancel(); datagramLocal = nil
    }

    private func fail(_ error: Error, serviceSetup: Bool = true) {
        guard !stopped else { return }
        failureLock.withLock { failure = error; serviceSetupFailure = serviceSetup }
        closeAll(); onClose?(error)
    }

    private func closeAll() {
        stopped = true
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        udpListener?.stateUpdateHandler = nil; udpListener?.cancel(); udpListener = nil
        closeDatagram()
        let active = Array(forwarders.values); forwarders.removeAll()
        for forwarder in active { forwarder.close() }
    }

    public func stop() { queue.async { [self] in closeAll() } }
    deinit { listener?.cancel(); udpListener?.cancel(); datagramHeartbeat?.cancel(); datagramChannel?.close(); datagramLocal?.cancel() }
}
