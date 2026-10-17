import Foundation
import Network
import QuietDeskCore

func runInteractiveTransportChecks() {
    run("Responsive acknowledgements are opt-in and preserve TCP no-delay") {
        let key = try PairingKey.generate()
        let original = SecureTransport.parameters(key: key)
        let enabled = SecureTransport.parameters(key: key, responsiveAcknowledgements: true)
        guard let originalTCP = original.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options,
              let enabledTCP = enabled.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options else {
            throw CheckFailure("Secure transport did not retain TCP")
        }
        try check(!originalTCP.disableAckStretching, "Default transport changed its ACK policy")
        try check(enabledTCP.disableAckStretching, "Opt-in did not reach the TCP options")
        try check(originalTCP.noDelay && enabledTCP.noDelay, "The ACK policy changed TCP no-delay")
    }

    if CommandLine.arguments.contains("--skip-network") { return }
    for (responsiveListener, responsiveClient) in [(false, true), (true, false), (true, true)] {
        run("TLS large frames, clipboard-like bytes, ACKs and heartbeats interoperate with responsive listener=\(responsiveListener), client=\(responsiveClient)") {
            let key = try PairingKey.generate()
            let parameters = SecureTransport.parameters(key: key, responsiveAcknowledgements: responsiveListener)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0), serverDone = DispatchSemaphore(value: 0), clientDone = DispatchSemaphore(value: 0)
            let serverRTT = DispatchSemaphore(value: 0), clientRTT = DispatchSemaphore(value: 0)
            let listenerFailure = Box<String?>(nil), server = Box<Peer?>(nil), unexpected = Box(false)
            let acceptedPolicy = Box<Bool?>(nil)
            let serverKinds = Box<[MessageKind]>([]), clientKinds = Box<[MessageKind]>([])
            var clientNAL = Data(); clientNAL.put(UInt32(286_720)); clientNAL.append(Data(repeating: 0x65, count: 286_720))
            var serverNAL = Data(); serverNAL.put(UInt32(262_144)); serverNAL.append(Data(repeating: 0x41, count: 262_144))
            let clientVideo = try VideoPacket(sequence: 101, sps: Data(), pps: Data(), avcc: clientNAL).encode()
            let serverVideo = try VideoPacket(sequence: 202, sps: Data(), pps: Data(), avcc: serverNAL).encode()
            let clientACK = Data([0, 0, 0, 101]), serverACK = Data([0, 0, 0, 202])
            let clientClipboard = Data(repeating: 0xA7, count: 262_144 + 32)
            let serverClipboard = Data(repeating: 0x3D, count: 262_144 + 32)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error): listenerFailure.set(error.localizedDescription); ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                acceptedPolicy.set((connection.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching)
                let peer = Peer(connection: connection, heartbeatInterval: 100)
                server.set(peer)
                peer.onReady = { [weak peer] in
                    peer?.send(Message(.video, serverVideo))
                    peer?.send(Message(.clipboardChunk, serverClipboard))
                }
                peer.onRoundTripMilliseconds = { value in
                    if !value.isFinite || value < 0 || value >= 30_000 { unexpected.set(true) }
                    serverRTT.signal()
                }
                peer.onMessage = { [weak peer] message in
                    switch message.kind {
                    case .video:
                        if message.payload != clientVideo || (try? VideoPacket.decode(message.payload).sequence) != 101 { unexpected.set(true) }
                        peer?.send(Message(.acknowledgement, clientACK))
                    case .clipboardChunk:
                        if message.payload != clientClipboard { unexpected.set(true) }
                    case .acknowledgement:
                        if message.payload != serverACK { unexpected.set(true) }
                    default: unexpected.set(true)
                    }
                    serverKinds.update { $0.append(message.kind); if $0.count == 3 { serverDone.signal() } }
                }
                peer.start()
            }
            listener.start(queue: DispatchQueue(label: "checks.interactive-transport"))
            defer { server.read()?.close(); listener.cancel() }
            try wait(ready, seconds: 5, "Interactive transport listener did not start")
            if let failure = listenerFailure.read() { throw CheckFailure(failure) }
            guard let port = listener.port else { throw CheckFailure("No interactive transport port") }

            let outbound = NWConnection(host: "127.0.0.1", port: port,
                using: SecureTransport.parameters(key: key, responsiveAcknowledgements: responsiveClient))
            let client = Peer(connection: outbound, heartbeatInterval: 100)
            defer { client.close() }
            client.onReady = { [weak client] in
                client?.send(Message(.video, clientVideo))
                client?.send(Message(.clipboardChunk, clientClipboard))
            }
            client.onRoundTripMilliseconds = { value in
                if !value.isFinite || value < 0 || value >= 30_000 { unexpected.set(true) }
                clientRTT.signal()
            }
            client.onMessage = { [weak client] message in
                switch message.kind {
                case .video:
                    if message.payload != serverVideo || (try? VideoPacket.decode(message.payload).sequence) != 202 { unexpected.set(true) }
                    client?.send(Message(.acknowledgement, serverACK))
                case .clipboardChunk:
                    if message.payload != serverClipboard { unexpected.set(true) }
                case .acknowledgement:
                    if message.payload != clientACK { unexpected.set(true) }
                default: unexpected.set(true)
                }
                clientKinds.update { $0.append(message.kind); if $0.count == 3 { clientDone.signal() } }
            }
            client.start()
            try wait(serverDone, "Server did not receive all mixed-setting data")
            try wait(clientDone, "Client did not receive all mixed-setting data")
            try wait(serverRTT, "Server heartbeat stopped with mixed ACK policies")
            try wait(clientRTT, "Client heartbeat stopped with mixed ACK policies")
            try check(acceptedPolicy.read() == responsiveListener,
                "Accepted connection did not retain the listener's ACK policy in its parameters")
            try check((outbound.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.disableAckStretching == responsiveClient,
                "Outbound connection did not retain its ACK policy in its parameters")
            let expected: [MessageKind] = [.video, .clipboardChunk, .acknowledgement]
            try check(serverKinds.read() == expected && clientKinds.read() == expected && !unexpected.read(),
                "The ACK policy changed message bytes, order, video sequence or heartbeat routing")
        }
    }
}
