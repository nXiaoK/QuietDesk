import Foundation
import Network
import Security
import QuietDeskCore

func runTransportChecks() {
    run("Connection refusal and unreachable networks have actionable failure reasons") {
        for code: POSIXErrorCode in [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH] {
            try check(SecureTransport.connectionFailureReason(.posix(code)) != nil, "Missing network failure reason")
        }
        try check(SecureTransport.connectionFailureReason(.posix(.EAGAIN)) == nil, "Transient wait was classified as fatal")
        try check(SecureTransport.connectionFailureReason(.tls(-9800)) == nil, "TLS error was classified as network failure")
    }

    run("Pairing TLS failures before readiness stop reconnecting") {
        for code in [errSSLBadRecordMac, errSSLPeerDecryptError, errSSLPeerHandshakeFail] {
            let failure = SecureTransport.tlsFailure(code: code, description: "test", afterReady: false)
            try check(!failure.retryable && failure.reason == "TLS 握手失败：test", "Pairing failure changed classification")
        }
    }

    run("Other TLS failures before readiness remain retryable") {
        let failure = SecureTransport.tlsFailure(code: errSSLProtocol, description: "test", afterReady: false)
        try check(failure.retryable && failure.reason == "TLS 握手失败：test", "Transient handshake failure stopped reconnecting")
    }

    run("TLS failures in established sessions remain retryable with a session reason") {
        for code in [errSSLBadRecordMac, errSSLPeerDecryptError, errSSLPeerHandshakeFail, errSSLProtocol] {
            let failure = SecureTransport.tlsFailure(code: code, description: "test", afterReady: true)
            try check(failure.retryable && failure.reason == "连接加密校验失败：test", "Session failure was classified as a pairing failure")
        }
    }

    if CommandLine.arguments.contains("--skip-network") { return }
    run("A refused loopback connection stops automatic reconnect before the handshake timeout") {
        let key = try PairingKey.generate()
        let queue = DispatchQueue(label: "checks.refused-connection")
        let listener = try makeListener(key, queue: queue)
        guard let port = listener.port else { throw CheckFailure("No port") }
        let cancelled = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { cancelled.signal() }
        }
        listener.cancel()
        try wait(cancelled, seconds: 5, "Listener did not close")

        let peer = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), handshakeTimeout: 15, heartbeatInterval: 0.1)
        let closed = DispatchSemaphore(value: 0)
        let reason = Box<String?>(nil)
        peer.onClose = { message in reason.set(message); closed.signal() }
        defer { peer.close() }
        peer.start()
        try wait(closed, seconds: 4, "Refused connection waited for the handshake timeout")
        try check(reason.read() == SecureTransport.connectionFailureReason(.posix(.ECONNREFUSED)), "Refusal reason was not specific")
        try check(!peer.closeIsRetryable, "A closed listening port kept automatic reconnect active")
    }
    run("Stopping a host listener ends retries when the replacement connection is refused") {
        let key = try PairingKey.generate()
        let queue = DispatchQueue(label: "checks.stopped-host")
        let listener = try makeListener(key, queue: queue)
        guard let port = listener.port else { throw CheckFailure("No port") }
        let server = Box<Peer?>(nil)
        let ready = DispatchSemaphore(value: 0), disconnected = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            server.set(peer)
            peer.onReady = { ready.signal() }
            peer.start()
        }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)))
        client.onClose = { _ in disconnected.signal() }
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.start()
        try wait(ready, "Host connection did not become ready")
        let cancelled = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .cancelled = $0 { cancelled.signal() } }
        listener.cancel()
        try wait(cancelled, "Host listener did not stop")
        server.read()?.close("host stopped sharing")
        try wait(disconnected, "Viewer did not observe host closure")
        try check(client.closeIsRetryable, "An ordinary connection drop lost its transient retry path")

        let replacement = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 0.1)
        let refused = DispatchSemaphore(value: 0)
        replacement.onClose = { _ in refused.signal() }
        defer { replacement.close() }
        replacement.start()
        try wait(refused, seconds: 4, "Closed host kept the replacement connection waiting")
        try check(!replacement.closeIsRetryable, "Closed host scheduled another automatic reconnect")
    }

}
