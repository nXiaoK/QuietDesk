import Foundation
import Network

/// Receives authenticated mapping peers from the host listener. Approval applies to an exact
/// address and port, or to a previously remote-controlled device identity. A data connection can
/// only name a live, approved lease on this host.
public final class PortMappingHost: @unchecked Sendable {
    public typealias Authorization = (PortMappingTarget, @escaping (Bool) -> Void) -> Void
    public typealias DeviceAuthorization = (PortMappingTarget, UUID?, @escaping (Bool) -> Void) -> Void
    public var onAuthorizationWithdrawn: ((PortMappingTarget) -> Void)?
    public var onActiveSessionsChanged: ((Bool) -> Void)?

    private final class Entry {
        enum Phase {
            case handshake
            case pending(PortMappingTarget, UUID?)
            case lease(UUID, PortMappingTarget, UUID?)
            case connecting(UUID, NWConnection)
            case streaming(UUID, PortMappingPipe)
            case closing
        }
        let id = UUID()
        let peer: Peer
        var phase = Phase.handshake
        init(_ peer: Peer) { self.peer = peer }
    }
    private let queue = DispatchQueue(label: "quietdesk.mapping.host", qos: .utility)
    private let authorize: DeviceAuthorization
    private let traffic: PortMappingTraffic
    private var entries: [UUID: Entry] = [:]
    private var stopped = false

    public convenience init(traffic: PortMappingTraffic = PortMappingTraffic(), authorize: @escaping Authorization) {
        self.init(traffic: traffic) { target, _, reply in authorize(target, reply) }
    }

    public init(traffic: PortMappingTraffic = PortMappingTraffic(), authorize: @escaping DeviceAuthorization) {
        self.traffic = traffic
        self.authorize = authorize
    }

    public func setDesktopActive(_ active: Bool) { traffic.setDesktopActive(active) }
    public var hasRecentPayload: Bool { traffic.hasRecentPayload }
    public func noteVideoDeliveryDelay(_ milliseconds: Double) { traffic.noteVideoDeliveryDelay(milliseconds) }

    /// Call synchronously from the admitted peer's onReady callback, before its first receive.
    public func accept(_ readyPeer: Peer) {
        guard readyPeer.prepareForMapping() else { readyPeer.close("端口映射未协商"); return }
        let entry = Entry(readyPeer)
        let id = entry.id
        readyPeer.onMessage = nil
        readyPeer.onMessageHandled = { [weak self, weak entry] message, done in
            self?.queue.async { [weak self, weak entry] in
                guard let self, let entry, self.entries[id] === entry else { return }
                do { try self.receive(message, on: entry, processed: done) }
                catch { self.remove(id, reason: error.localizedDescription) }
            }
        }
        readyPeer.onClose = { [weak self] reason in
            self?.queue.async { [weak self] in self?.remove(id, reason: reason) }
        }
        queue.async { [weak self] in
            guard let self, !self.stopped else { readyPeer.close("端口映射服务已关闭"); return }
            guard self.entries.count < 40 else { readyPeer.close("端口映射连接已满"); return }
            let wasEmpty = self.entries.isEmpty
            self.entries[id] = entry
            if wasEmpty { self.onActiveSessionsChanged?(true) }
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak entry] in
                guard let self, let entry, case .handshake = entry.phase else { return }
                self.remove(id, reason: "映射握手超时")
            }
        }
    }

    private func receive(_ message: Message, on entry: Entry, processed: @escaping () -> Void) throws {
        switch entry.phase {
        case .handshake:
            switch try PortMappingControl.read(message) {
            case .authorize(let target, let deviceID): startAuthorization(target, deviceID: deviceID, entry: entry)
            case .attach(let token): openTarget(token: token, entry: entry)
            default: throw DeskError.invalid("无效的端口映射握手")
            }
            processed()
        case .streaming(_, let pipe):
            try pipe.receive(message, processed: processed)
        case .closing: break
        default: throw DeskError.invalid("映射通道收到意外数据")
        }
    }

    private func startAuthorization(_ target: PortMappingTarget, deviceID: UUID?, entry: Entry) {
        let rules = entries.values.filter {
            switch $0.phase { case .pending, .lease: return true; default: return false }
        }
        guard rules.count < 8 else { reject(entry, .busy); return }
        entry.phase = .pending(target, deviceID)
        authorize(target, deviceID) { [weak self, weak entry] allowed in
            self?.queue.async { [weak self, weak entry] in
                guard let self, let entry, case .pending = entry.phase, self.entries[entry.id] === entry else { return }
                if allowed {
                    let token = UUID()
                    entry.phase = .lease(token, target, deviceID)
                    PortMappingControl.granted(token).send(to: entry.peer)
                } else { self.reject(entry, .denied) }
            }
        }
        queue.asyncAfter(deadline: .now() + 60) { [weak self, weak entry] in
            guard let self, let entry, case .pending = entry.phase else { return }
            self.reject(entry, .timeout)
        }
    }

    private func openTarget(token: UUID, entry: Entry) {
        var target: PortMappingTarget?
        var connections = 0
        for other in entries.values {
            switch other.phase {
            case .lease(let value, let service, _) where token == value: target = service
            case .connecting(let value, _) where token == value, .streaming(let value, _) where token == value:
                connections += 1
            default: break
            }
        }
        guard let target else { reject(entry, .denied); return }
        guard connections < 8 else { reject(entry, .busy); return }
        let params = NWParameters.tcp
        params.serviceClass = .background
        let socket = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!, using: params)
        entry.phase = .connecting(token, socket)
        socket.stateUpdateHandler = { [weak self, weak entry, weak socket] state in
            guard let self, let entry, let socket else { return }
            switch state {
            case .ready:
                guard case .connecting = entry.phase else { return }
                let pipe = PortMappingPipe(socket: socket, peer: entry.peer, queue: self.queue, traffic: self.traffic)
                entry.phase = .streaming(token, pipe)
                PortMappingControl.connected.send(to: entry.peer)
                pipe.startReading()
            case .failed, .waiting:
                // After both TCP FINs, Network.framework may report failure while
                // receive() still has buffered bytes. The pipe drains them through EOF.
                if case .connecting = entry.phase { self.reject(entry, .target) }
            default: break
            }
        }
        socket.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak entry] in
            guard let self, let entry, case .connecting = entry.phase else { return }
            self.reject(entry, .target)
        }
    }

    private func reject(_ entry: Entry, _ reason: PortMappingControl.Rejection) {
        let phase = entry.phase
        entry.phase = .closing
        cleanup(phase)
        PortMappingControl.rejected(reason).send(to: entry.peer) { [weak entry] _ in
            entry?.peer.close(reason.explanation)
        }
    }

    private func remove(_ id: UUID, reason: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        let phase = entry.phase
        entry.phase = .closing
        entry.peer.close(reason)
        cleanup(phase)
        if entries.isEmpty { onActiveSessionsChanged?(false) }
    }

    private func cleanup(_ phase: Entry.Phase) {
        switch phase {
        case .connecting(_, let socket): socket.stateUpdateHandler = nil; socket.cancel()
        case .streaming(_, let pipe): pipe.stop()
        case .pending(let target, _):
            let stillPending = entries.values.contains {
                if case .pending(let other, _) = $0.phase { return target == other }
                return false
            }
            if !stillPending { onAuthorizationWithdrawn?(target) }
        case .lease(let token, _, _):
            for entry in Array(entries.values) {
                switch entry.phase {
                case .connecting(let value, _) where token == value, .streaming(let value, _) where token == value:
                    remove(entry.id, reason: "此映射已关闭")
                default: break
                }
            }
        default: break
        }
    }

    public func revoke(_ target: PortMappingTarget) {
        queue.async { [weak self] in
            guard let self else { return }
            for entry in Array(self.entries.values) {
                switch entry.phase {
                case .pending(let service, _) where service == target, .lease(_, let service, _) where service == target:
                    self.reject(entry, .denied)
                default: break
                }
            }
        }
    }

    public func revokeDevice(_ deviceID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            for entry in Array(self.entries.values) {
                switch entry.phase {
                case .pending(_, let id) where id == deviceID, .lease(_, _, let id) where id == deviceID:
                    self.reject(entry, .denied)
                default: break
                }
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            for id in Array(entries.keys) { remove(id, reason: "端口映射服务已关闭") }
        }
    }
}
