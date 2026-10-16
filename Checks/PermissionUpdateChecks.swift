import Foundation
import Network
import QuietDeskCore

func runPermissionUpdateChecks() {
    run("Live control status is opt-in, strictly typed and preserves all existing message numbers") {
        let hello = Hello(name: "home", width: 1920, height: 1080, settings: .init(), canControl: false)
        let data = try JSONEncoder().encode(hello)
        try check(Wire.readJSON(Hello.self, data).controlStatusUpdates == true, "Host capability missing")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "controlStatusUpdates")
        try check(Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: legacy)).controlStatusUpdates == nil, "Old host opted into new control messages")
        for allowed in [false, true] {
            let message = try Wire.json(.controlStatus, ControlStatus(canControl: allowed))
            try check(Wire.readJSON(ControlStatus.self, message.payload).canControl == allowed, "Control permission changed in transit")
        }
        for invalid in ["{}", "{\"canControl\":\"true\"}", "{\"canControl\":1}", "{\"canControl\":null}"] {
            try rejects("Invalid permission state accepted") { _ = try Wire.readJSON(ControlStatus.self, Data(invalid.utf8)) }
        }
        try check(MessageKind.clipboardCancel.rawValue == 17 && MessageKind.streamSettingsResult.rawValue == 19 && MessageKind.controlStatus.rawValue == 20 && Wire.version == 1, "Existing protocol numbering changed")
    }

    if !CommandLine.arguments.contains("--skip-network") {
        run("Permission updates and clipboard traffic share one authenticated session without reconnecting") {
            let key = try PairingKey.generate()
            let listener = try makeListener(key, queue: DispatchQueue(label: "checks.permissions"))
            let server = Box<Peer?>(nil), connections = Box(0), states = Box<[Bool]>([])
            let failure = Box<String?>(nil), copied = Box(false), done = DispatchSemaphore(value: 0)
            let bytes = Data(repeating: 87, count: 256_000)
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection)
                connections.update { $0 += 1 }
                server.set(peer)
                peer.onMessage = { [weak peer] message in
                    guard message.kind == .controlStatus, message.payload.isEmpty else { failure.set("Invalid subscription"); done.signal(); return }
                    do {
                        peer?.send(try Wire.json(.controlStatus, ControlStatus(canControl: false)))
                        peer?.send(Message(.clipboard, bytes))
                        peer?.send(try Wire.json(.controlStatus, ControlStatus(canControl: true)))
                        peer?.send(try Wire.json(.controlStatus, ControlStatus(canControl: false)))
                    } catch { failure.set(error.localizedDescription); done.signal() }
                }
                peer.start()
            }
            guard let port = listener.port else { throw CheckFailure("No permission test port") }
            let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
            defer { client.close(); server.read()?.close(); listener.cancel() }
            client.onReady = { [weak client] in client?.send(Message(.controlStatus)) }
            client.onMessage = { message in
                do {
                    if message.kind == .controlStatus {
                        let state = try Wire.readJSON(ControlStatus.self, message.payload)
                        states.update { $0.append(state.canControl) }
                        if states.read().count == 3 { done.signal() }
                    } else if message.kind == .clipboard { copied.set(message.payload == bytes) }
                } catch { failure.set(error.localizedDescription); done.signal() }
            }
            client.start()
            try wait(done, "Permission updates were not received")
            try check(failure.read() == nil && states.read() == [false, true, false] && copied.read(), "Permission changes interrupted session traffic")
            try check(connections.read() == 1, "Permission changes reconnected the transport")
        }
    }
}
