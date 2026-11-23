import Foundation
import Network
import QuietDeskCore

func runMultiSessionPolicyChecks() {
    run("Multi-session policy allows simultaneous incoming host and outgoing viewer sessions (A -> B -> D)") {
        try check(
            MultiSessionPolicy.allowsIncomingHostConnection(existingHostPeerActive: false, outgoingViewerSessionCount: 0),
            "Idle host should accept incoming controller"
        )
        try check(
            MultiSessionPolicy.allowsIncomingHostConnection(existingHostPeerActive: false, outgoingViewerSessionCount: 2),
            "Host controlling B -> D and B -> E must still accept incoming controller A -> B"
        )
        try check(
            !MultiSessionPolicy.allowsIncomingHostConnection(existingHostPeerActive: true, outgoingViewerSessionCount: 0),
            "Host with an active incoming controller must reject a second simultaneous incoming controller"
        )
        try check(
            MultiSessionPolicy.allowsOutgoingViewerConnection(hasIncomingHostConnection: true, activeBenchmarkRunning: false),
            "Mac currently controlled by A must still allow outgoing connections B -> D"
        )
        try check(
            !MultiSessionPolicy.allowsOutgoingViewerConnection(hasIncomingHostConnection: false, activeBenchmarkRunning: true),
            "Active route benchmark run still guards concurrent launch from benchmark runner"
        )
    }

    run("Multi-session target identity deduplicates same Mac while allowing distinct Macs (A -> B and A -> C)") {
        let recordB = UUID()
        let recordC = UUID()
        let relayB = UUID()
        let relayC = UUID()
        let sessionB = UUID()
        let sessionC = UUID()

        let targetB = RemoteSessionTargetIdentity(
            recordID: recordB,
            address: "Mac-B.local",
            port: 5908,
            relayDeviceID: relayB
        )
        let targetC = RemoteSessionTargetIdentity(
            recordID: recordC,
            address: "192.168.1.22",
            port: 5908,
            relayDeviceID: relayC
        )
        let active = [(id: sessionB, target: targetB), (id: sessionC, target: targetC)]

        // Same host case-insensitively or by relay device ID focuses existing session B.
        let duplicateByHost = RemoteSessionTargetIdentity(address: "mac-b.local", port: 5908)
        let duplicateByRelay = RemoteSessionTargetIdentity(relayDeviceID: relayB)
        let duplicateByRecord = RemoteSessionTargetIdentity(recordID: recordC, address: "10.0.0.8", port: 5908)
        try check(
            MultiSessionPolicy.existingSessionID(matching: duplicateByHost, in: active) == sessionB,
            "Duplicate host:port should match existing session B"
        )
        try check(
            MultiSessionPolicy.existingSessionID(matching: duplicateByRelay, in: active) == sessionB,
            "Duplicate relay device ID should match existing session B"
        )
        try check(
            MultiSessionPolicy.existingSessionID(matching: duplicateByRecord, in: active) == sessionC,
            "Saved record ID should match existing session C"
        )

        // Distinct Mac D opens a new session.
        let targetD = RemoteSessionTargetIdentity(address: "192.168.1.99", port: 5908)
        try check(
            MultiSessionPolicy.existingSessionID(matching: targetD, in: active) == nil,
            "Distinct target D must not collide with B or C"
        )
    }

    run("Multi-session port-mapping scoping preserves session rules of other connected Macs") {
        let deviceB = UUID()
        let deviceC = UUID()
        let stoppedWhenBDisconnects = MultiSessionPolicy.deviceIDsToStopSessionMappings(
            disconnectedDeviceID: deviceB,
            remainingConnectedDeviceIDs: [deviceC]
        )
        try check(
            stoppedWhenBDisconnects == [deviceB],
            "Disconnecting B while C stays connected must stop only B's session mappings"
        )

        let stoppedWhenDuplicateRemains = MultiSessionPolicy.deviceIDsToStopSessionMappings(
            disconnectedDeviceID: deviceB,
            remainingConnectedDeviceIDs: [deviceB, deviceC]
        )
        try check(
            stoppedWhenDuplicateRemains.isEmpty,
            "Session mappings stay active if device B still has a connected session"
        )

        try check(
            MultiSessionPolicy.isDesktopTrafficActive(hostPeerActive: false, viewerPeersActiveCount: 2)
                && MultiSessionPolicy.isDesktopTrafficActive(hostPeerActive: true, viewerPeersActiveCount: 0)
                && !MultiSessionPolicy.isDesktopTrafficActive(hostPeerActive: false, viewerPeersActiveCount: 0),
            "Desktop traffic priority aggregates across host and all viewer sessions"
        )
    }

    run("Encrypted loopback peers run A -> {B, C} and B -> D concurrently without crosstalk") {
        struct HostEndpoint {
            let name: String
            let key: PairingKey
            let listener: NWListener
            let port: UInt16
            let receivedInputs: Box<[Double]>
            let peers: Box<[Peer]>
        }

        func startHost(_ name: String) throws -> HostEndpoint {
            let key = try PairingKey.generate()
            let ready = DispatchSemaphore(value: 0)
            let listener = try NWListener(using: SecureTransport.parameters(key: key, responsiveAcknowledgements: true))
            let inputs = Box<[Double]>([])
            let peers = Box<[Peer]>([])
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection)
                peers.update { $0.append(peer) }
                peer.onReady = {
                    if let hello = try? Wire.json(.hello, Hello(name: name, width: 1440, height: 900, settings: .init(), canControl: true)) {
                        peer.send(hello)
                    }
                }
                peer.onMessage = { message in
                    if message.kind == .input, let input = try? Wire.readJSON(RemoteInput.self, message.payload) {
                        inputs.update { $0.append(input.x) }
                    }
                }
                peer.start()
            }
            listener.start(queue: DispatchQueue(label: "checks.multisession.\(name)"))
            try wait(ready, "Host \(name) listener ready")
            guard let port = listener.port?.rawValue else { throw CheckFailure("Missing port for \(name)") }
            return HostEndpoint(name: name, key: key, listener: listener, port: port, receivedInputs: inputs, peers: peers)
        }

        func connectViewer(label: String, to host: HostEndpoint, markerX: Double) throws -> (Peer, Box<String>) {
            let helloReady = DispatchSemaphore(value: 0)
            let remoteName = Box("")
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: host.port)!,
                using: SecureTransport.parameters(key: host.key, responsiveAcknowledgements: true)
            )
            let viewer = Peer(connection: connection)
            viewer.onMessage = { message in
                if message.kind == .hello, let hello = try? Wire.readJSON(Hello.self, message.payload) {
                    remoteName.set(hello.name)
                    var move = RemoteInput(kind: .move)
                    move.x = markerX
                    move.y = 0.5
                    if let wire = try? Wire.json(.input, move) {
                        viewer.send(wire)
                    }
                    helloReady.signal()
                }
            }
            viewer.start()
            try wait(helloReady, "Viewer \(label) received hello from \(host.name)")
            return (viewer, remoteName)
        }

        let hostB = try startHost("Host-B")
        let hostC = try startHost("Host-C")
        let hostD = try startHost("Host-D")
        defer {
            for item in [hostB, hostC, hostD] {
                item.peers.read().forEach { $0.close() }
                item.listener.cancel()
            }
        }

        // A controls B and C simultaneously, while B simultaneously controls D.
        let (viewerAB, nameAB) = try connectViewer(label: "A->B", to: hostB, markerX: 0.21)
        let (viewerAC, nameAC) = try connectViewer(label: "A->C", to: hostC, markerX: 0.42)
        let (viewerBD, nameBD) = try connectViewer(label: "B->D", to: hostD, markerX: 0.84)
        defer {
            viewerAB.close()
            viewerAC.close()
            viewerBD.close()
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if hostB.receivedInputs.read() == [0.21],
               hostC.receivedInputs.read() == [0.42],
               hostD.receivedInputs.read() == [0.84] {
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try check(nameAB.read() == "Host-B" && nameAC.read() == "Host-C" && nameBD.read() == "Host-D", "Wrong peer hello routing")
        try check(hostB.receivedInputs.read() == [0.21], "Host B did not receive isolated input from A")
        try check(hostC.receivedInputs.read() == [0.42], "Host C did not receive isolated input from A")
        try check(hostD.receivedInputs.read() == [0.84], "Host D did not receive isolated input from B while B was controlled by A")
    }
}
