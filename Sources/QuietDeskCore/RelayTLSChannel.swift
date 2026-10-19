import Foundation
import Network
import Security

public enum RelayTransportError: Error, LocalizedError, Sendable {
    case network, certificate, timeout, cancelled, queueFull
    public var errorDescription: String? {
        switch self {
        case .network: return "中继网络连接失败或已关闭"
        case .certificate: return "中继服务证书校验或 TLS 握手失败"
        case .timeout: return "中继连接或响应超时"
        case .cancelled: return "中继连接已取消"
        case .queueFull: return "中继发送队列已满"
        }
    }
    public var retryable: Bool { self != .certificate && self != .cancelled }
}

// Callbacks and transport state use the supplied serial queue. Configure callbacks before start.
// This channel terminates only service TLS; raw bytes remain encrypted by desktop TLS/DTLS.
public final class RelayTLSChannel: @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onClose: ((Error) -> Void)?
    public let queue: DispatchQueue
    private let connection: NWConnection
    private var started = false
    private var ready = false
    private var closed = false
    private var handshakeID: UUID?
    private var readID: UUID?
    private var readCompletion: ((Result<RelayMessage, Error>) -> Void)?
    private var local: NWConnection?
    private var raw = false
    private let credit = NSLock()
    private var reservedBytes = 0
    private var creditClosed = false
    private var sends: [UUID: (bytes: Int, complete: (Bool) -> Void)] = [:]
    private static let maximumPendingBytes = 1_024 * 1_024

    public init(endpoint: RelayEndpoint, queue: DispatchQueue, certificateAuthorities: [Data] = []) throws {
        self.queue = queue
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_server_name(options, endpoint.host)
        if !certificateAuthorities.isEmpty {
            guard certificateAuthorities.count <= 8, certificateAuthorities.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 }) else {
                throw RelayServiceError.invalid
            }
            let authorities = try certificateAuthorities.map { data -> SecCertificate in
                guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw RelayServiceError.invalid }
                return certificate
            }
            // Explicit isolated anchors still require chain and hostname validation. The app
            // uses system trust by default; this does not change the machine's trust store.
            sec_protocol_options_set_verify_block(options, { _, supplied, complete in
                let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
                guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, endpoint.host as CFString)) == errSecSuccess,
                      SecTrustSetAnchorCertificates(trust, authorities as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { complete(false); return }
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.disableAckStretching = true; tcp.connectionTimeout = 10
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!,
                                  using: NWParameters(tls: tls, tcp: tcp))
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            let id = UUID(); handshakeID = id
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.ready = true; self.handshakeID = nil; self.onReady?()
                case .failed(let error):
                    if case .tls = error { self.finish(RelayTransportError.certificate) }
                    else { self.finish(RelayTransportError.network) }
                case .waiting(let error):
                    if case .tls = error { self.finish(RelayTransportError.certificate) }
                case .cancelled: self.finish(RelayTransportError.network)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.handshakeID == id else { return }
                self.finish(RelayTransportError.timeout)
            }
        }
    }

    public func send(_ message: RelayMessage, completion: @escaping (Bool) -> Void = { _ in }) {
        do { sendBytes(try message.framed(), completion: completion) }
        catch { queue.async { [weak self] in completion(false); self?.finish(error) } }
    }

    private func sendBytes(_ data: Data, completion: @escaping (Bool) -> Void) {
        let accepted = credit.withLock { () -> Bool in
            guard !creditClosed, !data.isEmpty, data.count <= 65_536,
                  data.count <= Self.maximumPendingBytes - reservedBytes else { return false }
            reservedBytes += data.count; return true
        }
        guard accepted else {
            queue.async { [weak self] in completion(false); self?.finish(RelayTransportError.queueFull) }
            return
        }
        queue.async { [self] in
            guard ready, !closed else { credit.withLock { reservedBytes -= data.count }; completion(false); return }
            let id = UUID()
            sends[id] = (data.count, completion)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, let pending = self.sends.removeValue(forKey: id) else { return }
                self.credit.withLock { self.reservedBytes -= pending.bytes }
                pending.complete(error == nil && !self.closed)
                if error != nil { self.finish(RelayTransportError.network) }
            })
        }
    }

    public func readMessage(timeout: TimeInterval = 45, completion: @escaping (Result<RelayMessage, Error>) -> Void) {
        queue.async { [self] in
            guard ready, !closed, !raw, readID == nil, timeout.isFinite, timeout > 0 else {
                completion(.failure(RelayTransportError.network)); return
            }
            let id = UUID(); readID = id; readCompletion = completion
            readExactly(4, id: id) { [weak self] prefix in
                guard let self else { return }
                do {
                    var reader = ByteReader(prefix)
                    let size: UInt32 = try reader.take()
                    guard size > 0, size <= RelayMessage.maximumBytes else { throw RelayServiceError.invalid }
                    self.readExactly(Int(size), id: id) { [weak self] body in
                        guard let self, self.readID == id else { return }
                        do {
                            let message = try RelayMessage.decode(body)
                            let callback = self.readCompletion; self.readCompletion = nil; self.readID = nil
                            callback?(.success(message))
                        } catch { self.finish(RelayServiceError.invalid) }
                    }
                } catch { self.finish(RelayServiceError.invalid) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.readID == id else { return }
                self.finish(RelayTransportError.timeout)
            }
        }
    }

    private func readExactly(_ count: Int, id: UUID, data: Data = Data(), completion: @escaping (Data) -> Void) {
        guard readID == id, !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { [weak self] part, _, ended, error in
            guard let self, self.readID == id, !self.closed else { return }
            guard error == nil, let part, !part.isEmpty else { self.finish(RelayTransportError.network); return }
            var received = data; received.append(part)
            if received.count == count { completion(received) }
            else if ended { self.finish(RelayTransportError.network) }
            else { self.readExactly(count, id: id, data: received, completion: completion) }
        }
    }

    public func forward(to local: NWConnection) {
        queue.async { [self] in
            guard ready, !closed, !raw, readID == nil else { finish(RelayServiceError.invalid); return }
            raw = true; self.local = local
            receiveRemoteBytes(); receiveLocalBytes()
        }
    }

    private func receiveRemoteBytes() {
        guard !closed, let local else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.finish(RelayTransportError.network); return }
            local.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil || ended { self.finish(RelayTransportError.network) }
                else { self.receiveRemoteBytes() }
            })
        }
    }

    private func receiveLocalBytes() {
        guard !closed, let local else { return }
        local.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.finish(RelayTransportError.network); return }
            self.sendBytes(data) { [weak self] succeeded in
                guard let self, !self.closed else { return }
                if !succeeded || ended { self.finish(RelayTransportError.network) }
                else { self.receiveLocalBytes() }
            }
        }
    }

    public func close() { queue.async { [self] in finish(RelayTransportError.cancelled) } }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true; ready = false; handshakeID = nil; readID = nil
        credit.withLock { creditClosed = true }
        connection.stateUpdateHandler = nil; connection.cancel()
        local?.stateUpdateHandler = nil; local?.cancel(); local = nil
        let callback = readCompletion; readCompletion = nil
        let pending = Array(sends.values); sends.removeAll()
        for send in pending { credit.withLock { reservedBytes -= send.bytes }; send.complete(false) }
        let closedCallback = onClose; onReady = nil; onClose = nil
        callback?(.failure(error)); closedCallback?(error)
    }

    deinit { connection.cancel(); local?.cancel() }
}
