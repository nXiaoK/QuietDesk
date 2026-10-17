import Foundation
import Network
import QuietDeskCore

func runPeerDeliveryChecks() {
    if CommandLine.arguments.contains("--skip-network") { return }
    run("Optional Peer message completion preserves ordering and ignores stale or duplicate continuations") {
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.peer-delivery"))
        let server = Box<Peer?>(nil), delivered = Box<[Data]>([]), resumes = Box<[() -> Void]>([])
        let fallbackCalls = Box(0)
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0), third = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { _ in fallbackCalls.update { $0 += 1 } }
            peer.onMessageHandled = { message, resume in
                delivered.update { $0.append(message.payload) }
                resumes.update { $0.append(resume) }
                switch delivered.read().count {
                case 1: first.signal()
                case 2: second.signal()
                default: third.signal()
                }
            }
            peer.onClose = { _ in closed.signal() }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No delivery test port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 100)
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.onReady = {
            for byte: UInt8 in [1, 2, 3] { client.send(Message(.input, Data([byte]))) }
        }
        client.start()
        try wait(first, "First message was not delivered")
        try check(second.wait(timeout: .now() + 0.2) == .timedOut, "Next message bypassed asynchronous completion")
        let resumeFirst = resumes.read()[0]
        DispatchQueue.global().async { resumeFirst(); resumeFirst() }
        try wait(second, "Completion did not resume delivery")
        resumeFirst()
        try check(third.wait(timeout: .now() + 0.2) == .timedOut, "Stale completion resumed a newer message")
        resumes.read()[1]()
        try wait(third, "Second completion did not resume delivery")
        try check(delivered.read() == [Data([1]), Data([2]), Data([3])] && fallbackCalls.read() == 0,
                  "Optional handler changed message order or called the legacy handler")
        server.read()?.close()
        try wait(closed, "Server did not close while waiting for message completion")
        resumes.read()[2]()
        server.read()?.queue.sync {}
        try check(server.read()?.onMessageHandled == nil && delivered.read().count == 3, "Closed peer resumed message delivery")
    }
}
