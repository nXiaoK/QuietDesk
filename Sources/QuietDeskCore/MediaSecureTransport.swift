import Foundation
import Network
import Security

public enum MediaChannelRole: String, Codable, CaseIterable, Hashable, Sendable {
    case control, video, bulk

    public var applicationProtocol: String {
        switch self {
        case .control: return "quietdesk-control/1"
        case .video: return "quietdesk-media/1"
        case .bulk: return "quietdesk-bulk/1"
        }
    }
}

public enum MediaSecureTransport {
    public static func tlsParameters(key: PairingKey, roles: [MediaChannelRole], responsiveAcknowledgements: Bool = true) throws -> NWParameters {
        guard !roles.isEmpty, Set(roles).count == roles.count else { throw DeskError.invalid("媒体通道角色无效") }
        let parameters = SecureTransport.parameters(key: key, responsiveAcknowledgements: responsiveAcknowledgements)
        guard let tls = parameters.defaultProtocolStack.applicationProtocols.first(where: { $0 is NWProtocolTLS.Options }) as? NWProtocolTLS.Options else {
            throw DeskError.invalid("媒体 TLS 配置不可用")
        }
        for role in roles { sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, role.applicationProtocol) }
        return parameters
    }

    public static func dtlsParameters(sessionKey: Data, identity: Data) throws -> NWParameters {
        guard sessionKey.count == 32, !identity.isEmpty, identity.count <= 128 else {
            throw DeskError.invalid("媒体会话凭据无效")
        }
        let dtls = NWProtocolTLS.Options()
        sessionKey.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(dtls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData, DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_set_min_tls_protocol_version(dtls.securityProtocolOptions, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(dtls.securityProtocolOptions, .DTLSv12)
        sec_protocol_options_append_tls_ciphersuite(dtls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_peer_authentication_required(dtls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(dtls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_resumption_enabled(dtls.securityProtocolOptions, false)
        return NWParameters(dtls: dtls, udp: NWProtocolUDP.Options())
    }

    public static func negotiatedRole(on connection: NWConnection) -> MediaChannelRole? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        if #available(macOS 15.5, *) {
            guard let value = sec_protocol_metadata_copy_negotiated_protocol(metadata.securityProtocolMetadata) else { return nil }
            defer { free(UnsafeMutableRawPointer(mutating: value)) }
            let applicationProtocol = String(cString: value)
            return MediaChannelRole.allCases.first { $0.applicationProtocol == applicationProtocol }
        }
        guard let value = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata) else { return nil }
        let applicationProtocol = String(cString: value)
        return MediaChannelRole.allCases.first { $0.applicationProtocol == applicationProtocol }
    }
}

// Install callbacks before start. A supplied queue must be serial; all callbacks use it.
// This object cannot be restarted; a reconnect must use a new instance and session key.
public final class BoundedDatagramPeer: @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onDatagram: ((Data) -> Void)?
    public var onClose: ((String) -> Void)?

    private enum Phase { case created, starting, ready, closing, closed }
    private struct PendingSend {
        let bytes: Int
        let completion: ((Bool) -> Void)?
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let connection: NWConnection
    private let maximumDatagramBytes: Int
    private let maximumPendingBytes: Int
    private let handshakeTimeout: TimeInterval
    private var phase = Phase.created
    private var reservedBytes = 0
    private var effectiveDatagramBytes = 0
    private var sends: [UUID: PendingSend] = [:]
    private var closed = false

    public init(connection: NWConnection, maximumDatagramBytes: Int = 1024,
                maximumPendingBytes: Int = 256 * 1024, handshakeTimeout: TimeInterval = 2,
                queue: DispatchQueue? = nil) throws {
        guard connection.parameters.defaultProtocolStack.transportProtocol is NWProtocolUDP.Options,
              connection.parameters.defaultProtocolStack.applicationProtocols.contains(where: { $0 is NWProtocolTLS.Options }),
              (1...65_507).contains(maximumDatagramBytes), maximumPendingBytes >= maximumDatagramBytes,
              maximumPendingBytes <= 64 * 1024 * 1024,
              handshakeTimeout.isFinite, handshakeTimeout > 0 else {
            throw DeskError.invalid("加密媒体数据报配置无效")
        }
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "quietdesk.media-datagram", qos: .userInteractive)
        self.maximumDatagramBytes = maximumDatagramBytes
        self.maximumPendingBytes = maximumPendingBytes
        self.handshakeTimeout = handshakeTimeout
    }

    public var pendingBytes: Int { lock.withLock { reservedBytes } }
    public var endpoint: NWEndpoint { connection.endpoint }
    public var maximumEffectiveDatagramBytes: Int { lock.withLock { effectiveDatagramBytes } }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard phase == .created else { return false }
            phase = .starting
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in
            guard let self, !self.closeRequested else { return }
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed, !self.closeRequested else { return }
                switch state {
                case .ready:
                    let limit = min(self.maximumDatagramBytes, self.connection.maximumDatagramSize)
                    guard limit > 0 else { self.finish("系统未提供有效媒体数据报大小"); return }
                    let accepted = self.lock.withLock { () -> Bool in
                        guard self.phase == .starting else { return false }
                        self.effectiveDatagramBytes = limit
                        self.phase = .ready
                        return true
                    }
                    guard accepted else { return }
                    self.onReady?()
                    self.receive()
                case .failed(let error): self.finish("媒体加密连接失败：\(error.localizedDescription)")
                case .cancelled: self.finish("媒体连接已关闭")
                default: break
                }
            }
            self.connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.handshakeTimeout) { [weak self] in
                guard let self, self.lock.withLock({ self.phase == .starting }) else { return }
                self.finish("媒体加密握手超时")
            }
        }
    }

    // Credit is reserved before dispatching, so callers cannot enqueue unbounded Data closures.
    @discardableResult
    public func send(_ data: Data, completion: ((Bool) -> Void)? = nil) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard phase == .ready, !data.isEmpty, data.count <= effectiveDatagramBytes,
                  reservedBytes <= maximumPendingBytes - data.count else { return false }
            reservedBytes += data.count
            return true
        }
        guard accepted else {
            if let completion { queue.async { completion(false) } }
            return false
        }
        queue.async { [weak self] in
            guard let self else { completion?(false); return }
            guard !self.closed, !self.closeRequested else {
                self.release(data.count)
                completion?(false)
                return
            }
            let identifier = UUID()
            self.sends[identifier] = PendingSend(bytes: data.count, completion: completion)
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, let pending = self.sends.removeValue(forKey: identifier) else { return }
                self.release(pending.bytes)
                pending.completion?(error == nil && !self.closed && !self.closeRequested)
                if let error { self.finish("媒体发送失败：\(error.localizedDescription)") }
            })
        }
        return true
    }

    public func close(_ reason: String = "媒体连接已关闭") {
        let shouldClose = lock.withLock { () -> Bool in
            guard phase != .closing, phase != .closed else { return false }
            phase = .closing
            return true
        }
        if shouldClose { queue.async { [weak self] in self?.finish(reason) } }
    }

    private var closeRequested: Bool { lock.withLock { phase == .closing || phase == .closed } }

    private func receive() {
        guard !closed, !closeRequested else { return }
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self, !self.closed, !self.closeRequested else { return }
            if let error { self.finish("媒体接收失败：\(error.localizedDescription)"); return }
            guard complete, let data, !data.isEmpty, data.count <= self.maximumDatagramBytes else {
                self.finish("媒体数据报长度无效")
                return
            }
            self.onDatagram?(data)
            self.receive()
        }
    }

    private func release(_ bytes: Int) { lock.withLock { reservedBytes -= bytes } }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        lock.withLock { phase = .closed; effectiveDatagramBytes = 0 }
        connection.stateUpdateHandler = nil
        connection.cancel()
        let pending = Array(sends.values)
        sends.removeAll()
        for item in pending { release(item.bytes); item.completion?(false) }
        let callback = onClose
        onReady = nil
        onDatagram = nil
        onClose = nil
        callback?(reason)
    }

    deinit { connection.cancel() }
}
