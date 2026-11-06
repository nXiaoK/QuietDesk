import Foundation
import Network

public enum RelayRegistrationStatus {
    case connecting, online, failed(Error)
}

// A binding is captured when a DTLS peer is admitted. Only the registration queue
// mutates leases, so its queued authentication cannot race a removal or port reuse.
final class RelayHostDatagramBindings {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var leases: [UUID: (port: UInt16, activate: (Data) -> Void)] = [:]

    init(queue: DispatchQueue) { self.queue = queue }

    func record(_ lease: UUID, port: UInt16, activate: @escaping (Data) -> Void) {
        lock.withLock { leases[lease] = (port, activate) }
    }

    func remove(_ lease: UUID) { _ = lock.withLock { leases.removeValue(forKey: lease) } }
    func removeAll() { lock.withLock { leases.removeAll() } }

    func binding(for port: UInt16) -> ((Data) -> Void)? {
        guard let lease = lock.withLock({ leases.first { $0.value.port == port }?.key }) else { return nil }
        return { [weak self] secret in
            guard let self else { return }
            queue.async {
                let current = self.lock.withLock { self.leases[lease] }
                if let current, current.port == port { current.activate(secret) }
            }
        }
    }
}

public final class RelayHostRegistration: @unchecked Sendable {
    public var onStatus: ((RelayRegistrationStatus) -> Void)?
    /// Outer path of the most recently authenticated assisted video route; reported on the registration queue.
    public var onPeerPath: ((RelayPeerPathState) -> Void)?
    public let peerTraffic = RelayPeerTrafficCounter()
    public let endpoint: RelayEndpoint
    public let deviceID: UUID
    private let accessKey: Data
    private let ownerKey: Data
    private let localPort: UInt16
    private let authorities: [Data]
    private let trustedCertificate: RelayNodeCertificate?
    private let queue: DispatchQueue
    private var channel: RelayTLSChannel?
    private var heartbeat: DispatchSourceTimer?
    private var registration: String?
    private var started = false
    private var stopped = false
    private var generation = UUID()
    private var retry = RetryBackoff()
    private var forwarders: [UUID: RelayTCPForwarder] = [:]
    private var routes: [Data: HostDatagramRoute] = [:]
    private let endpointLock = NSLock()
    private var localSources: [UUID: UInt16] = [:]
    private let datagramBindings: RelayHostDatagramBindings
    private var peerAssist: RelayPeerAssistMode
    private let peerInterfaceCandidates: Bool
    private var peerPath = RelayPeerPathState.relay

    public init(endpoint: RelayEndpoint, accessKey: Data, deviceID: UUID, ownerKey: Data, localPort: UInt16,
                certificateAuthorities: [Data] = [], trustedCertificate: RelayNodeCertificate? = nil,
                peerAssist: RelayPeerAssistMode = .off, peerInterfaceCandidates: Bool = true) throws {
        guard accessKey.count == 32, ownerKey.count == 32, localPort > 0 else { throw RelayServiceError.invalid }
        queue = DispatchQueue(label: "quietdesk.relay-host", qos: .userInitiated)
        datagramBindings = RelayHostDatagramBindings(queue: queue)
        self.endpoint = endpoint; self.accessKey = accessKey; self.deviceID = deviceID
        self.ownerKey = ownerKey; self.localPort = localPort; authorities = certificateAuthorities
        self.trustedCertificate = trustedCertificate; self.peerAssist = peerAssist
        self.peerInterfaceCandidates = peerInterfaceCandidates
    }

    public static func loopbackPort(of endpoint: NWEndpoint) -> UInt16? {
        guard case .hostPort(let host, let port) = endpoint, port.rawValue > 0 else { return nil }
        switch host {
        case .ipv4(let address):
            guard address.rawValue.first == 127 else { return nil }
            return port.rawValue
        case .ipv6(let address):
            let raw = [UInt8](address.rawValue)
            let isV6Loopback = raw.count == 16 && raw.dropLast().allSatisfy { $0 == 0 } && raw.last == 1
            let isMappedV4Loopback = raw.count == 16 && raw.prefix(10).allSatisfy { $0 == 0 }
                && raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127
            guard isV6Loopback || isMappedV4Loopback else { return nil }
            return port.rawValue
        case .name(let name, _):
            let base = name.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
            guard base == "127.0.0.1" || base == "::1" || base == "::ffff:127.0.0.1" || base == "localhost" else { return nil }
            return port.rawValue
        @unknown default:
            return nil
        }
    }

    private static func localEndpointPort(of connection: NWConnection) -> UInt16? {
        guard case .hostPort(_, let port) = connection.currentPath?.localEndpoint, port.rawValue > 0 else { return nil }
        return port.rawValue
    }

    public func datagramBinding(for endpoint: NWEndpoint) -> ((Data) -> Void)? {
        Self.loopbackPort(of: endpoint).flatMap { datagramBindings.binding(for: $0) }
    }

    /// Automatic/on switch immediately; turning assistance back on after "off" needs a new registration.
    public func setPeerAssistMode(_ mode: RelayPeerAssistMode) {
        queue.async { [self] in peerAssist = mode; routes.values.forEach { $0.setMode(mode) } }
    }

    private func reportPeerPath(_ state: RelayPeerPathState) {
        guard state != peerPath else { return }
        peerPath = state; onPeerPath?(state)
    }

    public func ownsLocalEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard let port = Self.loopbackPort(of: endpoint) else { return false }
        return endpointLock.withLock { localSources.values.contains(port) }
    }

    public func start() {
        queue.async { [self] in guard !started, !stopped else { return }; started = true; connect() }
    }

    private func connect() {
        guard !stopped, channel == nil else { return }
        let token = UUID(); generation = token
        onStatus?(.connecting)
        do {
            let connection = try RelayTLSChannel(endpoint: endpoint, queue: queue, certificateAuthorities: authorities,
                                                 trustedCertificate: trustedCertificate)
            channel = connection
            connection.onReady = { [weak self, weak connection] in
                guard let self, let connection, self.channel === connection, !self.stopped else { return }
                connection.send(RelayMessage(.register, accessKey: self.accessKey, deviceID: self.deviceID, ownerKey: self.ownerKey,
                                             assist: self.peerAssist != .off ? true : nil))
                connection.readMessage(timeout: 10) { [weak self, weak connection] result in
                    guard let self, let connection, self.channel === connection else { return }
                    switch result {
                    case .success(let message):
                        guard message.op == .registered, let registration = message.registration else {
                            self.disconnected(message.error ?? .invalid, channel: connection); return
                        }
                        self.registration = registration; self.onStatus?(.online)
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + 15, repeating: 15)
                        timer.setEventHandler { [weak connection] in connection?.send(RelayMessage(.ping)) }
                        self.heartbeat = timer; timer.resume()
                        self.readNext(connection)
                        self.queue.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
                            guard let self, let connection, self.channel === connection else { return }
                            self.retry.reset()
                        }
                    case .failure(let error): self.disconnected(error, channel: connection)
                    }
                }
            }
            connection.onClose = { [weak self, weak connection] error in
                guard let connection else { return }; self?.disconnected(error, channel: connection)
            }
            connection.start()
        } catch {
            onStatus?(.failed(error))
            if generation == token { generation = UUID() }
        }
    }

    private func readNext(_ connection: RelayTLSChannel) {
        connection.readMessage { [weak self, weak connection] result in
            guard let self, let connection, self.channel === connection, !self.stopped else { return }
            do {
                let message = try result.get()
                switch message.op {
                case .pong: break
                case .incoming:
                    guard let circuit = message.circuitID, let registration = self.registration else { throw RelayServiceError.invalid }
                    if self.forwarders.count < 16 {
                        let id = UUID()
                        let channel = try RelayTLSChannel(endpoint: self.endpoint, queue: self.queue, certificateAuthorities: self.authorities,
                                                          trustedCertificate: self.trustedCertificate)
                        let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.localPort)!, using: .tcp)
                        let forwarder = RelayTCPForwarder(local: local, channel: channel,
                            request: RelayMessage(.accept, accessKey: self.accessKey, deviceID: self.deviceID,
                                                  registration: registration, circuitID: circuit))
                        self.forwarders[id] = forwarder
                        forwarder.onLocalReady = { [weak self] connection in
                            guard let self, let port = Self.localEndpointPort(of: connection) else { return }
                            self.endpointLock.withLock { self.localSources[id] = port }
                        }
                        forwarder.onClose = { [weak self] _ in
                            guard let self else { return }
                            self.endpointLock.withLock { _ = self.localSources.removeValue(forKey: id) }
                            self.forwarders.removeValue(forKey: id)
                        }
                        forwarder.start()
                    }
                case .incomingDatagram:
                    guard let id = message.datagramID else { throw RelayServiceError.invalid }
                    if self.routes.count < 4, self.routes[id] == nil {
                        let assist = message.assist == true && self.peerAssist != .off ? self.peerAssist : nil
                        let route = try HostDatagramRoute(message: message, endpoint: self.endpoint, localPort: self.localPort, queue: self.queue,
                                                          assist: assist, counter: self.peerTraffic,
                                                          interfaceCandidates: self.peerInterfaceCandidates)
                        self.routes[id] = route
                        route.onConsent = { [weak self, weak connection] candidates in
                            guard let self, let connection, self.channel === connection else { return }
                            connection.send(RelayMessage(.assist, datagramID: id, candidates: candidates))
                        }
                        route.onPathState = { [weak self] state in self?.reportPeerPath(state) }
                        let lease = UUID()
                        route.onLocalReady = { [weak self, weak route] connection in
                            guard let self, let port = Self.localEndpointPort(of: connection) else { return }
                            self.datagramBindings.record(lease, port: port) { [weak route] secret in route?.enableAssist(secret: secret) }
                        }
                        route.onClose = { [weak self, weak route] in
                            guard let self, let route, self.routes[id] === route else { return }
                            self.datagramBindings.remove(lease)
                            self.routes.removeValue(forKey: id)
                            if route.assisted { self.reportPeerPath(.relay) }
                        }
                        route.start()
                    }
                case .datagramClosed:
                    if let id = message.datagramID { self.routes[id]?.close() }
                case .peerCandidates:
                    if let id = message.datagramID, let candidates = message.candidates { self.routes[id]?.receivePeerCandidates(candidates) }
                case .error: throw message.error ?? RelayServiceError.invalid
                default: throw RelayServiceError.invalid
                }
                self.readNext(connection)
            } catch { self.disconnected(error, channel: connection) }
        }
    }

    private func disconnected(_ error: Error, channel connection: RelayTLSChannel) {
        guard channel === connection else { return }
        channel = nil; registration = nil; generation = UUID()
        heartbeat?.cancel(); heartbeat = nil; connection.close(); closeRoutes()
        guard !stopped else { return }
        onStatus?(.failed(error))
        let mayRetry = (error as? RelayServiceError)?.retryable ?? (error as? RelayTransportError)?.retryable ?? false
        guard mayRetry else { return }
        let delay = retry.next(), token = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token, !self.stopped else { return }; self.connect()
        }
    }

    private func closeRoutes() {
        let forwards = Array(forwarders.values); forwarders.removeAll()
        let datagrams = Array(routes.values); routes.removeAll()
        endpointLock.withLock { localSources.removeAll() }
        datagramBindings.removeAll()
        for forward in forwards { forward.close() }
        for route in datagrams { route.close() }
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true; generation = UUID()
            heartbeat?.cancel(); heartbeat = nil
            let connection = channel; channel = nil; registration = nil; connection?.close(); closeRoutes()
        }
    }

    deinit { heartbeat?.cancel(); channel?.close() }
}

private final class HostDatagramRoute {
    var onClose: (() -> Void)?
    var onLocalReady: ((NWConnection) -> Void)?
    var onConsent: (([RelayCandidate]) -> Void)? {
        get { assistedPipe?.onConsent } set { assistedPipe?.onConsent = newValue }
    }
    var onPathState: ((RelayPeerPathState) -> Void)? {
        get { assistedPipe?.onPathState } set { assistedPipe?.onPathState = newValue }
    }
    var assisted: Bool { assistedPipe != nil }
    private let pipe: RelayDatagramPipe
    private let assistedPipe: RelayAssistedPipe?
    private let local: NWConnection
    private let queue: DispatchQueue
    private var closed = false
    private var pipeReady = false
    private var localReady = false

    init(message: RelayMessage, endpoint: RelayEndpoint, localPort: UInt16, queue: DispatchQueue,
         assist: RelayPeerAssistMode?, counter: RelayPeerTrafficCounter, interfaceCandidates: Bool) throws {
        guard let id = message.datagramID, let key = message.datagramKey, message.udpPort != nil else { throw RelayServiceError.invalid }
        self.queue = queue
        if let assist {
            let assisted = try RelayAssistedPipe(endpoint: endpoint, id: id, key: key, side: 1, mode: assist, queue: queue,
                                                 counter: counter, interfaceCandidates: interfaceCandidates)
            assistedPipe = assisted; pipe = assisted
        } else {
            assistedPipe = nil
            pipe = try RelayUDPPipe(endpoint: endpoint, port: endpoint.port, id: id, key: key, side: 1, queue: queue)
        }
        local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!, using: .udp)
    }
    func enableAssist(secret: Data) { assistedPipe?.enableAssist(secret: secret) }
    func receivePeerCandidates(_ candidates: [RelayCandidate]) { assistedPipe?.receivePeerCandidates(candidates) }
    func setMode(_ mode: RelayPeerAssistMode) { assistedPipe?.setMode(mode) }
    func start() {
        pipe.onReady = { [weak self] in self?.pipeReady = true; self?.receiveIfReady() }
        pipe.onPayload = { [weak self] data, complete in
            guard let self, self.localReady, !self.closed else { complete(false); return }
            self.onLocalReady?(self.local)
            self.local.send(content: data, completion: .contentProcessed { error in complete(error == nil) })
        }
        pipe.onClose = { [weak self] _ in self?.close() }
        local.pathUpdateHandler = { [weak self] _ in
            guard let self, self.localReady, !self.closed else { return }
            self.onLocalReady?(self.local)
        }
        local.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.localReady = true; self.onLocalReady?(self.local)
                self.pipe.start()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        local.start(queue: queue)
    }
    private var reading = false
    private var sending = 0
    private func receiveIfReady() {
        guard pipeReady, localReady, !closed, !reading, sending < 64 else { return }
        reading = true
        local.receiveMessage { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }; self.reading = false
            guard error == nil, complete, let data, !data.isEmpty, data.count <= RelayDatagram.maximumPayloadBytes else { self.close(); return }
            self.sending += 1
            self.pipe.send(data) { [weak self] succeeded in
                guard let self, !self.closed else { return }
                self.sending = max(0, self.sending - 1)
                if succeeded { self.receiveIfReady() } else { self.close() }
            }
            self.receiveIfReady()
        }
    }
    func close() {
        guard !closed else { return }; closed = true; reading = false; sending = 0
        pipe.onClose = nil; pipe.close(); local.pathUpdateHandler = nil; local.stateUpdateHandler = nil; local.cancel()
        let callback = onClose; onClose = nil; callback?()
    }
    deinit { local.cancel() }
}
