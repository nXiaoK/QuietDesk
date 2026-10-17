import Foundation
import Network
import Security

public enum SecureTransport {
    public static func connectionFailureReason(_ error: NWError) -> String? {
        guard case .posix(let code) = error else { return nil }
        switch code {
        case .ECONNREFUSED: return "对方拒绝连接，请确认已开启共享，并检查端口与端口映射"
        case .EHOSTUNREACH: return "无法到达对方主机，请检查地址、网络与防火墙"
        case .ENETUNREACH: return "网络不可达，请检查本机网络连接与路由"
        default: return nil
        }
    }

    public static func parameters(key: PairingKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data("quietdesk-v1".utf8)
        key.data.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData, DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        // Network.framework's external PSK path uses this TLS 1.2 AEAD suite.
        // There is no certificate validation bypass and no plaintext fallback.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

// All callbacks and mutable connection state belong to this peer's queue.
public final class Peer {
    public let queue = DispatchQueue(label: "quietdesk.peer", qos: .userInteractive)
    public var onReady: (() -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onMessageHandled: ((Message, @escaping () -> Void) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onTraffic: ((Int) -> Void)?
    public let trafficMeter = TrafficMeter()
    public var onRoundTripMilliseconds: ((Double) -> Void)?
    public private(set) var closeIsRetryable = false
    private let connection: NWConnection
    private var closed = false
    private var started = false
    private var ready = false
    private var lastReceived = SessionClock.now
    private var timer: DispatchSourceTimer?
    private var pendingBytes = 0
    private var deliverySequence: UInt64 = 0
    private var waitingForMessage = false
    private let idleTimeout: TimeInterval
    private let handshakeTimeout: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let diagnostics: PerformanceDiagnostics?
    private var roundTrip = RoundTripProbe()
    private var roundTripDiagnostic: (identifier: UInt64, token: PerformanceDiagnostics.Token)?
    private final class ReadBuffer {
        var data = Data()
        init(capacity: Int) { data.reserveCapacity(capacity) }
    }

    public init(connection: NWConnection, idleTimeout: TimeInterval = 30, handshakeTimeout: TimeInterval = 15, heartbeatInterval: TimeInterval = 5, diagnostics: PerformanceDiagnostics? = nil) {
        self.connection = connection
        self.idleTimeout = idleTimeout
        self.handshakeTimeout = handshakeTimeout
        self.heartbeatInterval = heartbeatInterval
        self.diagnostics = diagnostics
    }

    public func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if SessionClock.now - self.lastReceived > (self.ready ? self.idleTimeout : self.handshakeTimeout) {
                    self.finish(self.ready ? "连接超过 \(Int(self.idleTimeout)) 秒无数据" : "建立连接超时，请检查地址或远端状态")
                } else if self.ready {
                    self.sendHeartbeat()
                }
            }
            self.timer = timer
            timer.resume()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.lastReceived = SessionClock.now
                    self.onReady?()
                    if self.onRoundTripMilliseconds != nil { self.sendHeartbeat() }
                    self.receiveHeader()
                case .failed(let error):
                    if case .tls(let code) = error {
                        self.finish("TLS 握手失败：\(error.localizedDescription)", retryable: ![errSSLBadRecordMac, errSSLPeerDecryptError, errSSLPeerHandshakeFail].contains(code))
                    }
                    else { self.finish(SecureTransport.connectionFailureReason(error) ?? "连接失败：\(error.localizedDescription)") }
                case .waiting(let error):
                    if case .tls(let code) = error, [errSSLBadRecordMac, errSSLPeerDecryptError, errSSLPeerHandshakeFail].contains(code) {
                        self.finish("TLS 配对验证失败：\(error.localizedDescription)", retryable: false)
                    } else if let reason = SecureTransport.connectionFailureReason(error) {
                        self.finish(reason)
                    }
                case .cancelled: self.finish("连接已关闭")
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendHeartbeat() {
        let payload = onRoundTripMilliseconds == nil ? nil : roundTrip.begin(at: SessionClock.now)
        if let payload {
            roundTripDiagnostic = nil
            if let token = diagnostics?.start() {
                var reader = ByteReader(payload)
                if let identifier: UInt64 = try? reader.take() { roundTripDiagnostic = (identifier, token) }
            }
        }
        send(Message(.ping, payload ?? Data()))
    }

    public func send(_ message: Message, completion: ((Bool) -> Void)? = nil) {
        let queuedAt = diagnostics?.start()
        let kind = message.kind
        queue.async { [self] in
            guard ready, !closed else { completion?(false); return }
            let identifier = diagnosticIdentifier(for: message)
            diagnostics?.record(.sendQueue, since: queuedAt, kind: kind, identifier: identifier)
            do {
                let data = try message.framed()
                guard pendingBytes + data.count <= Wire.maximumMessageBytes * 2 else {
                    finish("网络发送队列已满")
                    completion?(false)
                    return
                }
                pendingBytes += data.count
                diagnostics?.recordValue(.pendingSendBytes, pendingBytes, kind: kind, identifier: identifier)
                let meter = trafficMeter
                let submittedAt = diagnostics?.start()
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let self, !self.closed {
                        self.diagnostics?.record(.sendCompletion, since: submittedAt, kind: kind, identifier: identifier)
                    }
                    if error == nil { meter.record(sentBytes: UInt64(data.count)) }
                    guard let self else { completion?(false); return }
                    self.pendingBytes -= data.count
                    if let error { self.finish("发送失败：\(error.localizedDescription)") }
                    self.onTraffic?(data.count)
                    completion?(error == nil && !self.closed)
                })
            } catch {
                finish(error.localizedDescription)
                completion?(false)
            }
        }
    }

    public func close(_ reason: String = "已断开连接", retryable: Bool = false) {
        queue.async { [weak self] in self?.finish(reason, retryable: retryable) }
    }

    private func finish(_ reason: String, retryable: Bool = true) {
        guard !closed else { return }
        closed = true
        closeIsRetryable = retryable
        timer?.cancel()
        timer = nil
        roundTripDiagnostic = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onReady = nil
        onMessage = nil
        onMessageHandled = nil
        onClose = nil
        onTraffic = nil
        onRoundTripMilliseconds = nil
    }

    private func receiveHeader() {
        let headerStartedAt = diagnostics?.start()
        readExactly(4) { [weak self] data in
            guard let self, !self.closed else { return }
            self.diagnostics?.record(.receiveHeaderWait, since: headerStartedAt)
            do {
                var reader = ByteReader(data)
                let size: UInt32 = try reader.take()
                guard size >= 1, size <= Wire.maximumMessageBytes else {
                    throw DeskError.invalid("无效的消息长度")
                }
                let bodyStartedAt = self.diagnostics?.start()
                self.readExactly(Int(size)) { [weak self] body in
                    guard let self else { return }
                    do {
                        let message = try Wire.decodeBody(body)
                        let identifier = self.diagnosticIdentifier(for: message)
                        self.diagnostics?.record(.receiveBody, since: bodyStartedAt, kind: message.kind, identifier: identifier)
                        switch message.kind {
                        case .ping: self.send(Message(.pong, message.payload.count == 8 ? message.payload : Data()))
                        case .pong:
                            if let milliseconds = self.roundTrip.complete(message.payload, at: SessionClock.now) {
                                if let diagnostic = self.roundTripDiagnostic {
                                    self.diagnostics?.record(.roundTrip, since: diagnostic.token, kind: .pong, identifier: diagnostic.identifier)
                                    self.roundTripDiagnostic = nil
                                }
                                self.onRoundTripMilliseconds?(milliseconds)
                            }
                        default:
                            if let handle = self.onMessageHandled {
                                self.deliverySequence &+= 1
                                let sequence = self.deliverySequence
                                self.waitingForMessage = true
                                let handlingStartedAt = self.diagnostics?.start()
                                let kind = message.kind
                                handle(message) { [weak self] in
                                    guard let self else { return }
                                    self.queue.async { [weak self] in
                                        guard let self, !self.closed, self.waitingForMessage,
                                              self.deliverySequence == sequence else { return }
                                        self.diagnostics?.record(.messageHandler, since: handlingStartedAt, kind: kind, identifier: identifier)
                                        self.waitingForMessage = false
                                        self.receiveHeader()
                                    }
                                }
                                return
                            }
                            self.onMessage?(message)
                        }
                        self.receiveHeader()
                    } catch { self.finish(error.localizedDescription, retryable: false) }
                }
            } catch { self.finish(error.localizedDescription, retryable: false) }
        }
    }

    private func diagnosticIdentifier(for message: Message) -> UInt64? {
        guard diagnostics?.isEnabled == true else { return nil }
        var reader = ByteReader(message.payload)
        switch message.kind {
        case .video:
            guard message.payload.count >= 13, let sequence: UInt32 = try? reader.take() else { return nil }
            return UInt64(sequence)
        case .acknowledgement:
            guard message.payload.count == 4, let sequence: UInt32 = try? reader.take() else { return nil }
            return UInt64(sequence)
        case .ping, .pong:
            guard message.payload.count == 8 else { return nil }
            return try? reader.take() as UInt64
        default: return nil
        }
    }

    private func readExactly(_ count: Int, accumulated: ReadBuffer? = nil, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        let buffer = accumulated ?? ReadBuffer(capacity: count)
        let remaining = count - buffer.data.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, remaining)) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                buffer.data.append(data)
                self.lastReceived = SessionClock.now
                self.trafficMeter.record(receivedBytes: UInt64(data.count))
                self.onTraffic?(data.count)
            }
            if buffer.data.count == count {
                completion(buffer.data)
            } else if let error {
                self.finish("接收失败：\(error.localizedDescription)")
            } else if ended {
                self.finish("对方已断开连接")
            } else {
                self.readExactly(count, accumulated: buffer, completion: completion)
            }
        }
    }

    deinit { timer?.cancel(); connection.cancel() }
}
