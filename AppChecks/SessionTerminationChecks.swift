import Foundation
import Network
import QuietDeskCore

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message) }
}

private func wait(_ signal: DispatchSemaphore, seconds: Double = 5, _ message: String) throws {
    try require(signal.wait(timeout: .now() + seconds) == .success, message)
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.withLock { value } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

/// Binds only loopback and uses an ephemeral PSK, without application state or system permissions.
private final class Connection {
    let listener: NWListener
    let client: Peer
    let server = Box<Peer?>(nil)
    let serverReady = DispatchSemaphore(value: 0)
    let clientReady = DispatchSemaphore(value: 0)

    init() throws {
        let key = try PairingKey.generate()
        let parameters = SecureTransport.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0), failure = Box<String?>(nil)
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed(let error) = state { failure.update { $0 = error.localizedDescription }; ready.signal() }
        }
        listener.start(queue: DispatchQueue(label: "checks.termination.listener"))
        try wait(ready, "Loopback listener was not ready")
        if let error = failure.read() { listener.cancel(); throw Failure(error) }
        guard let port = listener.port else { throw Failure("Loopback listener has no port") }
        client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
    }

    func start() throws -> Peer {
        let server = self.server, serverReady = self.serverReady, clientReady = self.clientReady
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            server.update { $0 = peer }
            peer.onReady = { serverReady.signal() }
            peer.start()
        }
        client.onReady = { clientReady.signal() }
        client.start()
        try wait(clientReady, "Viewer did not authenticate")
        try wait(serverReady, "Host did not authenticate")
        return server.read()!
    }

    deinit { client.close(); server.read()?.close(); listener.cancel() }
}

@main
private struct SessionTerminationChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Optional capability preserves old hello decoding and legacy wire values") {
            let hello = Hello(name: "fixture", width: 1920, height: 1080, settings: .init(), canControl: true)
            let old = try JSONEncoder().encode(hello)
            let fields = try JSONSerialization.jsonObject(with: old) as? [String: Any]
            try require(fields?["sessionTerminationV1"] == nil, "Default hello changed the legacy capability payload")
            try require(try Wire.readJSON(Hello.self, old).sessionTerminationV1 == nil, "Old hello enabled new messages")
            let current = Hello(name: "fixture", width: 1920, height: 1080, settings: .init(), canControl: true, sessionTerminationV1: true)
            try require(try Wire.readJSON(Hello.self, JSONEncoder().encode(current)).sessionTerminationV1 == true,
                        "Advertised termination capability was lost")
            try require(MessageKind.sessionUnlockRequest.rawValue == 32 && MessageKind.sessionUnlockResult.rawValue == 33,
                        "Legacy message numbers changed")
        }

        run("Termination messages have a strict operation and bounded control payload") {
            for operation in [SessionTermination.Operation.subscribe, .ended] {
                let message = try SessionTermination(operation).message()
                let decoded = try Wire.decodeBody(Data(try message.framed().dropFirst(4)))
                try require(decoded.kind == .sessionTermination && SessionTermination.read(decoded.payload).operation == operation,
                            "Termination envelope did not round trip")
            }
            for payload in [Data("{}".utf8), Data("{\"operation\":\"retry\"}".utf8), Data(count: 4097)] {
                do { _ = try SessionTermination.read(payload) } catch { continue }
                throw Failure("Accepted an invalid ending notice")
            }
        }

        run("Send failure before readiness closes once without a network connection") {
            let peer = Peer(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
            let closed = DispatchSemaphore(value: 0), calls = Box(0)
            peer.onClose = { _ in calls.update { $0 += 1 }; closed.signal() }
            peer.closeAfterSessionTermination(notify: true, timeout: 0.02)
            try wait(closed, "Unready peer remained open")
            try require(!peer.closeIsRetryable, "Local ending became retryable")
            try require(closed.wait(timeout: .now() + 0.06) == .timedOut && calls.read() == 1,
                        "Send failure and timeout both ended the peer")
        }

        if !CommandLine.arguments.contains("--skip-network") {
            run("Revoked data handlers cannot block the final notice, which precedes EOF") {
                let connection = try Connection(), ended = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
                let events = Box<[String]>([]), dataCalls = Box(0)
                let host = try connection.start()
                let channel = SessionDataChannel(send: { host.send($0) }, onFreshFrame: { _ in })
                channel.configureClipboard { _ in dataCalls.update { $0 += 1 } }
                channel.invalidate()
                _ = try channel.receive(Message(.clipboardChunk, Data([1, 2, 3])))
                channel.sendReliableData(Message(.clipboardChunk, Data([1, 2, 3])))
                connection.client.onMessageHandled = { message, resume in
                    if message.kind == .sessionTermination, (try? SessionTermination.read(message.payload).operation) == .ended {
                        events.update { $0.append("ended") }; ended.signal()
                        // Exercise an asynchronous UI handler: EOF must not overtake its handling barrier.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { resume() }
                    } else { events.update { $0.append("unexpected") }; resume() }
                }
                connection.client.onClose = { _ in events.update { $0.append("closed") }; closed.signal() }
                host.closeAfterSessionTermination(notify: true)
                try wait(ended, "Final notice was lost after resource revocation")
                try wait(closed, "Host did not close after the notice")
                try require(events.read() == ["ended", "closed"] && dataCalls.read() == 0,
                            "EOF overtook the ending notice or revoked data escaped")
            }

            run("An unsubscribed legacy viewer receives no unknown control message") {
                let connection = try Connection(), closed = DispatchSemaphore(value: 0), messages = Box(0)
                let host = try connection.start()
                connection.client.onMessage = { _ in messages.update { $0 += 1 } }
                connection.client.onClose = { _ in closed.signal() }
                host.closeAfterSessionTermination(notify: false)
                try wait(closed, "Legacy session did not close")
                try require(messages.read() == 0, "A legacy viewer received the optional ending notice")
            }

            run("A stalled paced send cannot delay revocation beyond the shutdown bound") {
                let connection = try Connection(), closed = DispatchSemaphore(value: 0), closedCount = Box(0)
                let host = try connection.start()
                host.onClose = { _ in closedCount.update { $0 += 1 }; closed.signal() }
                host.setVideoPacing(VideoSendPacing(megabits: 1))
                host.send(Message(.video, Data(count: 15 * 1024 * 1024)))
                let start = SessionClock.now
                host.closeAfterSessionTermination(notify: true, timeout: 0.1)
                try wait(closed, seconds: 1, "Stalled send ignored the shutdown deadline")
                try require(SessionClock.now - start < 0.8 && !host.closeIsRetryable, "Bounded close was late or retryable")
                try require(closed.wait(timeout: .now() + 0.05) == .timedOut && closedCount.read() == 1,
                            "Cancelled send completion closed the peer twice")
            }

            run("An old delayed close does not close a later peer") {
                let old = try Connection(), oldClosed = DispatchSemaphore(value: 0)
                let oldHost = try old.start()
                oldHost.onClose = { _ in oldClosed.signal() }
                oldHost.closeAfterSessionTermination(notify: true, timeout: 0.2)
                try wait(oldClosed, "First peer remained open")
                let current = try Connection(), reply = DispatchSemaphore(value: 0), closed = Box(false)
                let currentHost = try current.start()
                current.client.onClose = { _ in closed.update { $0 = true } }
                current.client.onMessage = { message in if message.kind == .clipboard { reply.signal() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { currentHost.send(Message(.clipboard, Data([7]))) }
                try wait(reply, "Old peer timeout disrupted the new peer")
                try require(!closed.read(), "A late ending callback closed a different peer")
            }
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
