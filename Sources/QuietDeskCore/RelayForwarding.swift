import Foundation
import Network

// A single service tunnel carries one unmodified desktop TCP connection.
final class RelayTCPForwarder {
    var onLocalReady: ((NWConnection) -> Void)?
    var onClose: ((Error) -> Void)?
    private let local: NWConnection
    private let channel: RelayTLSChannel
    private let request: RelayMessage
    private var localReady = false
    private var remoteReady = false
    private var forwarding = false
    private var closed = false

    init(local: NWConnection, channel: RelayTLSChannel, request: RelayMessage) {
        self.local = local; self.channel = channel; self.request = request
    }

    func start() {
        local.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.localReady = true; self.onLocalReady?(self.local); self.forwardIfReady()
            case .failed, .cancelled: self.finish(RelayTransportError.network)
            default: break
            }
        }
        channel.onReady = { [weak self] in
            guard let self, !self.closed else { return }
            self.channel.send(self.request)
            self.channel.readMessage(timeout: 12) { [weak self] result in
                guard let self, !self.closed else { return }
                switch result {
                case .success(let message):
                    if message.op == .error { self.finish(message.error ?? .invalid) }
                    else if message.op == .ready { self.remoteReady = true; self.forwardIfReady() }
                    else { self.finish(RelayServiceError.invalid) }
                case .failure(let error): self.finish(error)
                }
            }
        }
        channel.onClose = { [weak self] error in self?.finish(error) }
        local.start(queue: channel.queue); channel.start()
        channel.queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, !self.forwarding, !self.closed else { return }
            self.finish(RelayTransportError.timeout)
        }
    }

    private func forwardIfReady() {
        guard localReady, remoteReady, !forwarding, !closed else { return }
        forwarding = true; channel.forward(to: local)
    }

    func close() { finish(RelayTransportError.cancelled) }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true
        let callback = onClose; onClose = nil; onLocalReady = nil
        callback?(error)
        local.stateUpdateHandler = nil; local.cancel(); channel.close()
    }

    deinit { local.cancel(); channel.close() }
}

// Routing authentication is separate from the opaque desktop DTLS record inside payload.
final class RelayUDPPipe {
    var onReady: (() -> Void)?
    var onPayload: ((Data, @escaping (Bool) -> Void) -> Void)?
    var onClose: ((Error) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let id: Data
    private let key: Data
    private let side: UInt8
    private var sequence: UInt64 = 0
    private var replay = RelayReplayWindow()
    private var ready = false
    private var closed = false
    private var pendingBytes = 0
    private var sends: [UUID: (Int, (Bool) -> Void)] = [:]
    private var keepalive: DispatchSourceTimer?

    init(endpoint: RelayEndpoint, port: UInt16, id: Data, key: Data, side: UInt8, queue: DispatchQueue) throws {
        guard id.count == 16, key.count == 32, side <= 1, port > 0 else { throw RelayServiceError.invalid }
        self.id = id; self.key = key; self.side = side; self.queue = queue
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.send(Data()) { [weak self] success in
                    guard let self, !self.closed else { return }
                    if success { self.onReady?(); self.receive() }
                    else { self.finish(RelayTransportError.network) }
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 15, repeating: 15)
                timer.setEventHandler { [weak self] in self?.send(Data()) { _ in } }
                self.keepalive = timer; timer.resume()
            case .failed, .cancelled: self.finish(RelayTransportError.network)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ payload: Data, completion: @escaping (Bool) -> Void) {
        guard ready, !closed, sequence < .max, payload.count <= RelayDatagram.maximumPayloadBytes else { completion(false); return }
        do {
            sequence += 1
            let data = try RelayDatagram(side: side, sequence: sequence, id: id, payload: payload).encode(key: key)
            guard data.count <= connection.maximumDatagramSize, data.count <= 256 * 1024 - pendingBytes else { completion(false); return }
            pendingBytes += data.count
            let token = UUID(); sends[token] = (data.count, completion)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, let pending = self.sends.removeValue(forKey: token) else { return }
                self.pendingBytes -= pending.0; pending.1(error == nil && !self.closed)
                if error != nil { self.finish(RelayTransportError.network) }
            })
        } catch { completion(false); finish(error) }
    }

    private func receive() {
        guard !closed else { return }
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.finish(RelayTransportError.network); return }
            guard complete, let data, let packet = try? RelayDatagram.decode(data, key: self.key),
                  packet.id == self.id, packet.side == self.side, packet.downstream,
                  self.replay.accept(packet.sequence), !packet.payload.isEmpty else { self.receive(); return }
            guard let callback = self.onPayload else { self.receive(); return }
            let once = NSLock(); var finished = false
            callback(packet.payload) { [weak self] _ in
                let first = once.withLock { () -> Bool in if finished { return false }; finished = true; return true }
                guard first else { return }
                self?.queue.async { [weak self] in self?.receive() }
            }
        }
    }

    func close() { finish(RelayTransportError.cancelled) }
    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true; ready = false
        keepalive?.cancel(); keepalive = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let callbacks = Array(sends.values); sends.removeAll(); pendingBytes = 0
        for callback in callbacks { callback.1(false) }
        let callback = onClose; onClose = nil; onReady = nil; onPayload = nil; callback?(error)
    }
    deinit { keepalive?.cancel(); connection.cancel() }
}
