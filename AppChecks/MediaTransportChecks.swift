import Foundation
import Network
import Security
import QuietDeskCore

private struct MediaTransportCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class MediaTransportBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private func requireMedia(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MediaTransportCheckFailure(message) }
}

private func awaitMedia(_ semaphore: DispatchSemaphore, seconds: Double = 8, _ message: String) throws {
    try requireMedia(semaphore.wait(timeout: .now() + seconds) == .success, message)
}

private func mediaListener(_ parameters: NWParameters, queue: DispatchQueue) throws -> NWListener {
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    let failure = MediaTransportBox<NWError?>(nil)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.signal()
        case .failed(let error): failure.update { $0 = error }; ready.signal()
        default: break
        }
    }
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: queue)
    do {
        try awaitMedia(ready, "Loopback listener did not become ready")
        if let error = failure.read() { throw error }
        try requireMedia(listener.port != nil, "Loopback listener has no port")
        return listener
    } catch { listener.cancel(); throw error }
}

private func exerciseTLS(serverParameters: NWParameters, clientParameters: NWParameters, role: MediaChannelRole?) throws {
    let queue = DispatchQueue(label: "checks.media-tls")
    let listener = try mediaListener(serverParameters, queue: queue)
    let accepted = MediaTransportBox<NWConnection?>(nil)
    let serverReady = DispatchSemaphore(value: 0), clientReady = DispatchSemaphore(value: 0)
    let serverRole = MediaTransportBox<MediaChannelRole?>(nil), clientRole = MediaTransportBox<MediaChannelRole?>(nil)
    let failure = MediaTransportBox<String?>(nil)
    listener.newConnectionHandler = { connection in
        accepted.update { $0 = connection }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                serverRole.update { $0 = MediaSecureTransport.negotiatedRole(on: connection) }
                if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    if sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) != .TLSv12 {
                        failure.update { $0 = "TLS negotiated an unexpected version" }
                    }
                } else { failure.update { $0 = "TLS metadata missing" } }
                serverReady.signal()
            case .failed(let error): failure.update { $0 = "Server: \(error)" }; serverReady.signal()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    let client = NWConnection(host: "127.0.0.1", port: listener.port!, using: clientParameters)
    client.stateUpdateHandler = { state in
        switch state {
        case .ready:
            clientRole.update { $0 = MediaSecureTransport.negotiatedRole(on: client) }
            clientReady.signal()
        case .failed(let error): failure.update { $0 = "Client: \(error)" }; clientReady.signal()
        default: break
        }
    }
    defer { client.cancel(); accepted.read()?.cancel(); listener.cancel() }
    client.start(queue: queue)
    try awaitMedia(serverReady, "TLS server handshake timed out")
    try awaitMedia(clientReady, "TLS client handshake timed out")
    if let error = failure.read() { throw MediaTransportCheckFailure(error) }
    try requireMedia(serverRole.read() == role && clientRole.read() == role, "TLS ALPN role mismatch")
}

private func exerciseDTLS(wrongKey: Bool) throws {
    let queue = DispatchQueue(label: "checks.media-dtls")
    let key = Data(repeating: 0x49, count: 32), identity = Data("loopback-session".utf8)
    let listener = try mediaListener(MediaSecureTransport.dtlsParameters(sessionKey: key, identity: identity), queue: queue)
    let accepted = MediaTransportBox<NWConnection?>(nil)
    let serverReady = DispatchSemaphore(value: 0), clientReady = DispatchSemaphore(value: 0)
    let failed = DispatchSemaphore(value: 0), echoed = DispatchSemaphore(value: 0)
    let errors = MediaTransportBox<[String]>([])
    let readyCount = MediaTransportBox(0), received = MediaTransportBox<[Data]>([])
    let payloads = [Data([1]), Data(repeating: 0xA5, count: 1024), Data([2, 3, 4])]
    listener.newConnectionHandler = { connection in
        accepted.update { $0 = connection }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyCount.update { $0 += 1 }
                guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                      sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .DTLSv12 else {
                    errors.update { $0.append("DTLS 1.2 metadata missing") }; failed.signal(); return
                }
                serverReady.signal()
                func receive() {
                    connection.receiveMessage { data, _, complete, error in
                        if let error { errors.update { $0.append("Receive: \(error)") }; failed.signal(); return }
                        guard complete, let data else { errors.update { $0.append("Incomplete DTLS datagram") }; failed.signal(); return }
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error { errors.update { $0.append("Echo: \(error)") }; failed.signal() }
                        })
                        receive()
                    }
                }
                receive()
            case .failed(let error): errors.update { $0.append("Server: \(error)") }; failed.signal()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    let clientKey = wrongKey ? Data(repeating: 0x27, count: 32) : key
    let client = NWConnection(host: "127.0.0.1", port: listener.port!,
        using: try MediaSecureTransport.dtlsParameters(sessionKey: clientKey, identity: identity))
    client.stateUpdateHandler = { state in
        switch state {
        case .ready: readyCount.update { $0 += 1 }; clientReady.signal()
        case .failed(let error): errors.update { $0.append("Client: \(error)") }; failed.signal()
        default: break
        }
    }
    defer { client.cancel(); accepted.read()?.cancel(); listener.cancel() }
    client.start(queue: queue)
    if wrongKey {
        // DTLS may silently drop the unauthenticated handshake and keep retransmitting.
        // The application wrapper therefore enforces its own handshake deadline.
        _ = failed.wait(timeout: .now() + 1)
        try requireMedia(accepted.read() != nil, "Wrong-key check never reached the loopback listener")
        try requireMedia(readyCount.read() == 0 && received.read().isEmpty, "Wrong DTLS key reached ready or exposed payload")
        return
    }
    try awaitMedia(serverReady, "DTLS server handshake timed out: \(errors.read())")
    try awaitMedia(clientReady, "DTLS client handshake timed out: \(errors.read())")
    try requireMedia(client.maximumDatagramSize >= 1024, "Native DTLS effective datagram size is too small")
    func receive() {
        client.receiveMessage { data, _, complete, error in
            if let error { errors.update { $0.append("Client receive: \(error)") }; echoed.signal(); return }
            guard complete, let data else { errors.update { $0.append("Client received incomplete datagram") }; echoed.signal(); return }
            received.update { $0.append(data) }
            if received.read().count == payloads.count { echoed.signal() } else { receive() }
        }
    }
    receive()
    for payload in payloads {
        client.send(content: payload, completion: .contentProcessed { error in
            if let error { errors.update { $0.append("Client send: \(error)") }; echoed.signal() }
        })
    }
    try awaitMedia(echoed, "DTLS data echo timed out")
    try requireMedia(errors.read().isEmpty, "DTLS data transfer failed: \(errors.read())")
    try requireMedia(received.read() == payloads, "DTLS altered message boundaries or payload bytes")
}

private func exerciseBoundedDatagrams(cancelPending: Bool) throws {
    let queue = DispatchQueue(label: "checks.bounded-dtls")
    let key = Data(repeating: 0x39, count: 32), identity = Data("bounded-loopback".utf8)
    let listener = try mediaListener(MediaSecureTransport.dtlsParameters(sessionKey: key, identity: identity), queue: queue)
    let server = MediaTransportBox<BoundedDatagramPeer?>(nil)
    let clientQueue = DispatchQueue(label: "checks.bounded-dtls-client")
    let ready = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
    let completions = DispatchSemaphore(value: 0)
    let closeCount = MediaTransportBox(0), deliveryCount = MediaTransportBox(0), results = MediaTransportBox<[Bool]>([])
    let failure = MediaTransportBox<String?>(nil)
    listener.newConnectionHandler = { connection in
        do {
            let peer = try BoundedDatagramPeer(connection: connection)
            server.update { $0 = peer }
            peer.onDatagram = { data in peer.send(data) }
            peer.start()
        } catch { failure.update { $0 = "Server wrapper: \(error)" }; ready.signal() }
    }
    let connection = NWConnection(host: "127.0.0.1", port: listener.port!,
        using: try MediaSecureTransport.dtlsParameters(sessionKey: key, identity: identity))
    let client = try BoundedDatagramPeer(connection: connection, maximumPendingBytes: 2048, queue: clientQueue)
    client.onReady = { ready.signal() }
    client.onDatagram = { data in
        if data != Data(repeating: 0x44, count: 1024) { failure.update { $0 = "Wrapper changed payload bytes" } }
        deliveryCount.update { $0 += 1 }
        received.signal()
    }
    client.onClose = { _ in closeCount.update { $0 += 1 }; closed.signal() }
    defer { client.close(); server.read()?.close(); listener.cancel() }
    client.start()
    try awaitMedia(ready, "Bounded DTLS wrapper did not become ready")
    if let error = failure.read() { throw MediaTransportCheckFailure(error) }
    try requireMedia(client.maximumEffectiveDatagramBytes == 1024, "Wrapper lost its configured application payload limit")
    let completion: (Bool) -> Void = { value in results.update { $0.append(value) }; completions.signal() }
    if cancelPending {
        let blocked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        clientQueue.async { blocked.signal(); resume.wait() }
        try awaitMedia(blocked, "Could not isolate pending send callbacks")
        defer { resume.signal() }
        try requireMedia(client.send(Data(count: 1024), completion: completion), "First bounded send was rejected")
        try requireMedia(client.send(Data(count: 1024), completion: completion), "Second bounded send was rejected")
        try requireMedia(!client.send(Data([1]), completion: completion), "Pending send budget was exceeded")
        try requireMedia(client.pendingBytes == 2048, "Send credit was not reserved before queue dispatch")
        client.close("test cancellation")
        client.close("duplicate cancellation")
        resume.signal()
        for _ in 0..<3 { try awaitMedia(completions, "Cancelled send did not finish exactly once") }
        try awaitMedia(closed, "Wrapper cancellation did not close")
        clientQueue.sync {}
        try requireMedia(results.read() == [false, false, false] && client.pendingBytes == 0, "Cancellation leaked credit or reported successful stale sends")
        try requireMedia(closeCount.read() == 1 && deliveryCount.read() == 0, "Duplicate close or a stale datagram escaped cancellation")
    } else {
        try requireMedia(!client.send(Data(), completion: completion), "Empty media datagram was accepted")
        try requireMedia(!client.send(Data(count: 1025), completion: completion), "Oversized media datagram was accepted")
        try requireMedia(client.send(Data(repeating: 0x44, count: 1024), completion: completion), "Valid media datagram was rejected")
        for _ in 0..<3 { try awaitMedia(completions, "Media send completion was lost") }
        try awaitMedia(received, "Wrapper did not deliver the complete DTLS echo")
        clientQueue.sync {}
        try requireMedia(results.read().filter { $0 }.count == 1 && client.pendingBytes == 0, "Wrapper send result or credit was incorrect")
        if let error = failure.read() { throw MediaTransportCheckFailure(error) }
    }
}

private func exerciseHandshakeDeadline() throws {
    let queue = DispatchQueue(label: "checks.dtls-deadline")
    let identity = Data("deadline-loopback".utf8)
    let listener = try mediaListener(MediaSecureTransport.dtlsParameters(sessionKey: Data(repeating: 0x61, count: 32), identity: identity), queue: queue)
    let server = MediaTransportBox<BoundedDatagramPeer?>(nil)
    let ready = MediaTransportBox(false), closed = DispatchSemaphore(value: 0), reason = MediaTransportBox("")
    listener.newConnectionHandler = { connection in
        guard let peer = try? BoundedDatagramPeer(connection: connection, handshakeTimeout: 0.3) else { connection.cancel(); return }
        server.update { $0 = peer }
        peer.start()
    }
    let client = try BoundedDatagramPeer(connection: NWConnection(host: "127.0.0.1", port: listener.port!,
        using: MediaSecureTransport.dtlsParameters(sessionKey: Data(repeating: 0x62, count: 32), identity: identity)), handshakeTimeout: 0.3)
    client.onReady = { ready.update { $0 = true } }
    client.onClose = { value in reason.update { $0 = value }; closed.signal() }
    defer { client.close(); server.read()?.close(); listener.cancel() }
    client.start()
    try awaitMedia(closed, seconds: 2, "Wrong-key DTLS handshake ignored its application deadline")
    try requireMedia(!ready.read() && reason.read() == "媒体加密握手超时", "Wrong-key DTLS reached readiness or lost timeout reason")
    try requireMedia(!client.send(Data([1])) && client.pendingBytes == 0, "Closed DTLS wrapper accepted application data")
}

@main
private struct MediaTransportChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        run("Native media parameters reject malformed credentials and roles") {
            for count in [0, 1, 16, 31, 33, 64] {
                do { _ = try MediaSecureTransport.dtlsParameters(sessionKey: Data(count: count), identity: Data([1])) }
                catch { continue }
                throw MediaTransportCheckFailure("Accepted a non-256-bit session key")
            }
            for count in [0, 129] {
                do { _ = try MediaSecureTransport.dtlsParameters(sessionKey: Data(count: 32), identity: Data(count: count)) }
                catch { continue }
                throw MediaTransportCheckFailure("Accepted an invalid PSK identity")
            }
            let key = try PairingKey.generate()
            for roles: [MediaChannelRole] in [[], [.control, .control]] {
                do { _ = try MediaSecureTransport.tlsParameters(key: key, roles: roles) }
                catch { continue }
                throw MediaTransportCheckFailure("Accepted invalid ALPN roles")
            }
        }
        if !CommandLine.arguments.contains("--skip-network") {
            run("DTLS 1.2 PSK preserves bidirectional datagram payloads and boundaries") { try exerciseDTLS(wrongKey: false) }
            run("Wrong DTLS session keys cannot reach application readiness") { try exerciseDTLS(wrongKey: true) }
            run("Bounded DTLS wrapper delivers datagrams and enforces payload limits") { try exerciseBoundedDatagrams(cancelPending: false) }
            run("Bounded DTLS cancellation settles sends once and fences callbacks") { try exerciseBoundedDatagrams(cancelPending: true) }
            run("Wrong-key DTLS handshakes close at the application deadline") { try exerciseHandshakeDeadline() }
            for role in MediaChannelRole.allCases {
                run("TLS 1.2 PSK negotiates \(role.rawValue)") {
                    let key = try PairingKey.generate()
                    try exerciseTLS(serverParameters: MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases),
                        clientParameters: MediaSecureTransport.tlsParameters(key: key, roles: [role]), role: role)
                }
            }
            run("New ALPN listener accepts a legacy client without a negotiated role") {
                let key = try PairingKey.generate()
                try exerciseTLS(serverParameters: MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases),
                    clientParameters: SecureTransport.parameters(key: key), role: nil)
            }
            run("New ALPN client accepts a legacy listener without a negotiated role") {
                let key = try PairingKey.generate()
                try exerciseTLS(serverParameters: SecureTransport.parameters(key: key),
                    clientParameters: MediaSecureTransport.tlsParameters(key: key, roles: [.control]), role: nil)
            }
        }
        print("Media transport checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
