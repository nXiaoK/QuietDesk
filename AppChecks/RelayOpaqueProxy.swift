import Foundation
import Network
import QuietDeskCore

// Test-only ciphertext proxy. TLS endpoints retain all keys. No UDP listener is
// opened, and only video-role application records can be deliberately dropped.
final class RelayOpaqueProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "checks.relay.opaque-proxy")
    private let listener: NWListener
    private let target: NWEndpoint.Port
    private var pipes: [UUID: Pipe] = [:]
    private let lock = NSLock()
    private var drop = false
    private var dropped = 0
    var port: UInt16? { listener.port?.rawValue }
    var droppedRecords: Int { lock.withLock { dropped } }
    var onReady: (() -> Void)?

    init(target: UInt16) throws {
        self.target = NWEndpoint.Port(rawValue: target)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func dropVideo() { lock.withLock { drop = true } }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.onReady?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let pipe = Pipe(incoming: connection, target: self.target, queue: self.queue)
            self.pipes[id] = pipe
            pipe.shouldDrop = { [weak self] in
                guard let self else { return false }
                return self.lock.withLock { if self.drop { self.dropped += 1 }; return self.drop }
            }
            pipe.onClose = { [weak self] in self?.pipes.removeValue(forKey: id) }
            pipe.start()
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.async { [self] in
            listener.cancel()
            let current = Array(pipes.values); pipes.removeAll()
            for pipe in current { pipe.close() }
        }
    }
    private final class Pipe {
        let incoming: NWConnection
        let upstream: NWConnection
        let queue: DispatchQueue
        var shouldDrop: (() -> Bool)?
        var onClose: (() -> Void)?
        var ready = 0
        var closed = false
        var video = false
        var serverApplications = 0
        init(incoming: NWConnection, target: NWEndpoint.Port, queue: DispatchQueue) {
            self.incoming = incoming; self.queue = queue
            upstream = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
        }
        func start() {
            for connection in [incoming, upstream] {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.closed else { return }
                    if case .ready = state {
                        self.ready += 1
                        if self.ready == 2 { self.read(client: true); self.read(client: false) }
                    }
                    if case .failed = state { self.close() }
                }
                connection.start(queue: queue)
            }
        }
        func read(client: Bool) {
            let source = client ? incoming : upstream
            source.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] header, _, _, error in
                guard let self, !self.closed else { return }
                guard error == nil, let header, header.count == 5 else { self.close(); return }
                let bytes = [UInt8](header), length = Int(bytes[3]) * 256 + Int(bytes[4])
                guard length > 0, length <= 18_432 else { self.close(); return }
                source.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                    guard let self, !self.closed else { return }
                    guard error == nil, let payload, payload.count == length else { self.close(); return }
                    if client, bytes[0] == 22, payload.first == 1 {
                        self.video = payload.range(of: Data(MediaChannelRole.video.applicationProtocol.utf8)) != nil
                    }
                    if !client, bytes[0] == 23, self.video {
                        self.serverApplications += 1
                        // The first application record carries the auxiliary bind confirmation.
                        if self.serverApplications > 1, self.shouldDrop?() == true { self.read(client: client); return }
                    }
                    var record = header; record.append(payload)
                    let destination = client ? self.upstream : self.incoming
                    destination.send(content: record, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.closed else { return }
                        if error != nil { self.close() } else { self.read(client: client) }
                    })
                }
            }
        }
        func close() {
            guard !closed else { return }; closed = true
            incoming.stateUpdateHandler = nil; upstream.stateUpdateHandler = nil
            incoming.cancel(); upstream.cancel(); onClose?()
        }
    }
}
