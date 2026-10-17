import Foundation
import Network
import QuietDeskCore

func runTransportChecks() {
    run("Connection refusal and unreachable networks have actionable failure reasons") {
        for code: POSIXErrorCode in [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH] {
            try check(SecureTransport.connectionFailureReason(.posix(code)) != nil, "Missing network failure reason")
        }
        try check(SecureTransport.connectionFailureReason(.posix(.EAGAIN)) == nil, "Transient wait was classified as fatal")
        try check(SecureTransport.connectionFailureReason(.tls(-9800)) == nil, "TLS error was classified as network failure")
    }

    if CommandLine.arguments.contains("--skip-network") { return }
    run("A refused loopback connection fails before the handshake timeout and remains retryable") {
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
        try check(peer.closeIsRetryable, "Network failure must retain automatic reconnect classification")
    }
}
