import Foundation
import Network

/// One rule on the controlling Mac. The authenticated lease keeps its approved service available
/// across local TCP connections and owns the lifetime of its loopback listener.
public final class PortMappingViewer: @unchecked Sendable {
    public var onState: ((PortMappingState) -> Void)?
    private let endpoint: NWEndpoint
    private let params: NWParameters
    private let target: PortMappingTarget
    private let requestedPort: UInt16
    private let traffic: PortMappingTraffic
    private let deviceID: UUID?
    private let queue = DispatchQueue(label: "quietdesk.mapping.viewer", qos: .utility)
    private let statusLock = NSLock()
    private var alternateAllowed = false
    private var authenticatedRoute = false
    public var mayTryAlternateRoute: Bool { statusLock.withLock { alternateAllowed } }
    public var hasAuthenticatedRoute: Bool { statusLock.withLock { authenticatedRoute } }
    private var started = false
    private var stopped = false
    private var lease: Peer?
    private var token: UUID?
    private var listener: NWListener?
    private var boundPort: UInt16?
    private final class Flow {
        let id = UUID()
        let peer: Peer
        let local: NWConnection
        var pipe: PortMappingPipe?
        init(peer: Peer, local: NWConnection) { self.peer = peer; self.local = local }
    }
    private var flows: [UUID: Flow] = [:]
    private var waitingClients: [NWConnection] = []
    private var openingFlow: UUID?

    public init(host: String, port: UInt16, key: PairingKey, target: PortMappingTarget,
                localPort: UInt16, traffic: PortMappingTraffic, deviceID: UUID? = nil) throws {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port != .any else {
            throw DeskError.invalid("被控端地址或服务端口无效")
        }
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        params = try MediaSecureTransport.tlsParameters(key: key, roles: [.portMapping])
        self.target = target; requestedPort = localPort; self.traffic = traffic; self.deviceID = deviceID
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.onState?(.authorizing)
            let peer = self.newPeer(open: .authorize(self.target, deviceID: self.deviceID), onAuthenticated: { [weak self] in
                guard let self else { return }
                self.statusLock.withLock { self.authenticatedRoute = true }
            })
            self.lease = peer
            peer.onClose = { [weak self, weak peer] reason in
                let canRetry = peer?.allowsUnauthenticatedRouteRetry == true
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.statusLock.withLock { self.alternateAllowed = canRetry }
                    self.finish(.failed("映射通道已关闭（请确认对端支持 TCP 映射并已开启服务）：\(reason)"))
                }
            }
            peer.onMessageHandled = { [weak self] message, done in
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    do {
                        switch try PortMappingControl.read(message) {
                        case .granted(let token) where self.token == nil:
                            self.token = token
                            try self.listen()
                        case .rejected(let reason): self.finish(.failed(reason.explanation))
                        default: throw DeskError.invalid("映射授权回复无效")
                        }
                        done()
                    } catch { self.finish(.failed(error.localizedDescription)) }
                }
            }
            peer.start()
            self.queue.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard let self, !self.stopped, self.boundPort == nil else { return }
                self.finish(.failed("端口映射启动超时"))
            }
        }
    }

    private func newPeer(open: PortMappingControl, onAuthenticated: (() -> Void)? = nil) -> Peer {
        let connection = NWConnection(to: endpoint, using: params)
        let peer = Peer(connection: connection, qos: .utility)
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            onAuthenticated?()
            guard peer.prepareForMapping() else { peer.close("被控端未协商端口映射通道"); return }
            open.send(to: peer)
        }
        return peer
    }

    private func listen() throws {
        let localParameters = NWParameters.tcp
        localParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
        let listener = try NWListener(using: localParameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] local in
            guard let self, !self.stopped, self.flows.count + self.waitingClients.count < 8 else { local.cancel(); return }
            self.waitingClients.append(local)
            self.openNextClient()
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, !self.stopped, let listener else { return }
            switch state {
            case .ready:
                self.boundPort = listener.port?.rawValue
                self.publishListening()
            case .waiting(let error), .failed(let error):
                let reason = error == .posix(.EADDRINUSE) ? "本地端口已被占用，请更换本地端口" : "本地监听失败：\(error.localizedDescription)"
                self.finish(.failed(reason))
            default: break
            }
        }
        listener.start(queue: queue)
    }

    // Browsers often connect in bursts. Admit the next TLS handshake after the prior
    // target replies, so established streams remain concurrent without flooding host admission.
    private func openNextClient() {
        guard !stopped, openingFlow == nil, !waitingClients.isEmpty, let token else { return }
        let local = waitingClients.removeFirst()
        let peer = newPeer(open: .attach(token))
        let flow = Flow(peer: peer, local: local)
        flows[flow.id] = flow
        let id = flow.id
        openingFlow = id
        peer.onClose = { [weak self] reason in
            self?.queue.async { [weak self] in self?.closeFlow(id, reason: reason) }
        }
        peer.onMessageHandled = { [weak self, weak flow] message, done in
            self?.queue.async { [weak self, weak flow] in
                guard let self, let flow, self.flows[id] === flow else { return }
                do {
                    if let pipe = flow.pipe {
                        try pipe.receive(message, processed: done)
                    } else {
                        switch try PortMappingControl.read(message) {
                        case .connected:
                            let pipe = PortMappingPipe(socket: flow.local, peer: flow.peer, queue: self.queue, traffic: self.traffic)
                            flow.pipe = pipe
                            flow.local.stateUpdateHandler = { [weak self, weak pipe] state in
                                guard let pipe else { return }
                                if case .ready = state { pipe.startReading() }
                                if case .failed(let error) = state, !pipe.readingStarted {
                                    self?.closeFlow(id, reason: error.localizedDescription)
                                }
                            }
                            flow.local.start(queue: self.queue)
                            self.publishListening()
                            self.openingFlow = nil
                            self.openNextClient()
                        case .rejected(let reason): self.closeFlow(id, reason: reason.explanation)
                        default: throw DeskError.invalid("端口映射数据通道握手无效")
                        }
                        done()
                    }
                } catch { self.closeFlow(id, reason: error.localizedDescription) }
            }
        }
        peer.start()
        queue.asyncAfter(deadline: .now() + 25) { [weak self, weak flow] in
            guard let self, let flow, flow.pipe == nil else { return }
            self.closeFlow(id, reason: "连接被控端目标超时")
        }
    }

    private func closeFlow(_ id: UUID, reason: String) {
        guard let flow = flows.removeValue(forKey: id) else { return }
        flow.pipe?.stop()
        flow.local.cancel()
        flow.peer.close()
        if openingFlow == id {
            openingFlow = nil
            openNextClient()
        }
        if !stopped, let port = boundPort {
            if flow.pipe != nil { publishListening() }
            else { onState?(.targetFailed(port: port, reason: reason)) }
        }
    }

    private func publishListening() {
        if let port = boundPort {
            onState?(.listening(port: port, connections: flows.values.filter { $0.pipe != nil }.count))
        }
    }

    private func finish(_ state: PortMappingState) {
        guard !stopped else { return }
        stopped = true
        listener?.cancel(); listener = nil; boundPort = nil
        lease?.close(); lease = nil; token = nil
        for local in waitingClients { local.cancel() }
        waitingClients.removeAll()
        for id in Array(flows.keys) { closeFlow(id, reason: "映射已停用") }
        onState?(state)
        onState = nil
    }

    public func stop() {
        queue.async { [self] in finish(.stopped) }
    }

    deinit {
        listener?.cancel()
        lease?.close()
        for local in waitingClients { local.cancel() }
        for flow in flows.values { flow.local.cancel(); flow.peer.close() }
    }
}
