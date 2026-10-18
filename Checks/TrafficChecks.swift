import Foundation
import Network
import QuietDeskCore

func runTrafficChecks() {
    run("Device history labels normalize empty and multiline names while preserving Unicode") {
        let raw = DeviceIdentity(id: UUID(), name: "  家里\nMac\t\u{0}  👨‍👩‍👧‍👦  ")
        try check(raw.displayName == "家里 Mac 👨‍👩‍👧‍👦" && raw.name.contains("\n"), "Normalization changed Unicode or the protocol name")
        try check(DeviceIdentity(id: UUID(), name: "\u{0}\n \t").displayName == "未命名 Mac", "An empty name made the history label blank")
        try rejects("Identity names bypassed the existing control message bound") {
            _ = try Wire.readJSON(DeviceIdentity.self, JSONEncoder().encode(DeviceIdentity(id: UUID(), name: String(repeating: "a", count: 5000))))
        }
    }

    run("Device identity exchange is optional and preserves legacy message numbers") {
        let old = Hello(name: "legacy", width: 1920, height: 1080, settings: .init(), canControl: true)
        let legacy = try Wire.readJSON(Hello.self, JSONEncoder().encode(old))
        try check(legacy.deviceID == nil && legacy.deviceIdentityExchange == nil,
                  "An old host enabled identity exchange")
        let id = UUID()
        let hello = Hello(name: "new", width: 1920, height: 1080, settings: .init(), canControl: true,
                          deviceID: id, deviceIdentityExchange: true)
        let decoded = try Wire.readJSON(Hello.self, JSONEncoder().encode(hello))
        try check(decoded.deviceID == id && decoded.deviceIdentityExchange == true, "Host identity changed")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as! [String: Any]
        json["deviceIdentityExchange"] = "true"
        try rejects("Accepted a non-boolean identity capability") {
            _ = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: json))
        }
        json["deviceIdentityExchange"] = true; json["deviceID"] = "not-a-uuid"
        try rejects("Accepted an invalid host identifier") {
            _ = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: json))
        }
        let identity = DeviceIdentity(id: id, name: "Mac")
        let message = try Wire.json(.deviceIdentity, identity)
        try check(Wire.readJSON(DeviceIdentity.self, message.payload) == identity, "Reverse identity changed")
        try rejects("Accepted an invalid reverse identifier") {
            _ = try Wire.readJSON(DeviceIdentity.self, Data("{\"id\":\"invalid\",\"name\":\"Mac\"}".utf8))
        }
        try check(MessageKind.controlStatus.rawValue == 20 && MessageKind.deviceIdentity.rawValue == 21 && Wire.version == 1,
                  "Existing protocol numbering changed")
    }

    run("Traffic endpoint keys normalize hosts but keep ports, domains and IP addresses separate") {
        let domain = try TrafficEndpoint(address: "  EXAMPLE.com ", port: 5908)
        try check(domain == TrafficEndpoint(address: "example.com", port: 5908), "Hostname case or whitespace split a route")
        try check(domain != TrafficEndpoint(address: "example.com", port: 5909), "Different ports merged")
        try check(domain != TrafficEndpoint(address: "192.0.2.1", port: 5908), "A domain was merged with an IP")
        let ipv6 = try TrafficEndpoint(address: "[2001:0DB8:0:0:0:0:0:1]", port: 5908)
        try check(ipv6 == TrafficEndpoint(address: "2001:db8::1", port: 5908)
                  && ipv6.label == "[2001:db8::1]:5908", "IPv6 key or display is ambiguous")
        try check(TrafficEndpoint(address: "fe80::1%en0", port: 5908) != TrafficEndpoint(address: "fe80::1%en1", port: 5908),
                  "Different IPv6 scopes merged")
    }
    run("Traffic endpoint validation also applies when loading history") {
        for address in ["", "https://example.com", "example.com/path", "a b", "bad\nname", "[not-an-ip]", "2001:broken::1", "::1%"] {
            try rejects("Invalid address accepted: \(address)") { _ = try TrafficEndpoint(address: address, port: 5908) }
        }
        try rejects("Port zero accepted") { _ = try TrafficEndpoint(address: "example.com", port: 0) }
        for value in ["{\"address\":\"example.com\",\"port\":0}", "{\"address\":\"example.com\",\"port\":65536}",
                      "{\"address\":\"x/y\",\"port\":5908}"] {
            try rejects("Invalid persisted endpoint accepted") { _ = try JSONDecoder().decode(TrafficEndpoint.self, from: Data(value.utf8)) }
        }
    }
    run("Host traffic keys use the actual source IP and listening port instead of ephemeral source ports") {
        let first = try TrafficEndpoint(remoteEndpoint: .hostPort(host: "192.0.2.5", port: 51001), listeningPort: 5908)
        let retry = try TrafficEndpoint(remoteEndpoint: .hostPort(host: "192.0.2.5", port: 62002), listeningPort: 5908)
        let otherPort = try TrafficEndpoint(remoteEndpoint: .hostPort(host: "192.0.2.5", port: 62002), listeningPort: 5909)
        let otherIP = try TrafficEndpoint(remoteEndpoint: .hostPort(host: "192.0.2.6", port: 51001), listeningPort: 5908)
        try check(first == retry && first != otherPort && first != otherIP, "Incoming connection attribution changed on retry or merged endpoints")
        try rejects("A non-IP endpoint was assigned a made-up address") {
            _ = try TrafficEndpoint(remoteEndpoint: .unix(path: "/tmp/fixture"), listeningPort: 5908)
        }
    }
    run("A known target endpoint counts before Hello without depending on a peer device identifier") {
        let endpoint = try TrafficEndpoint(address: "legacy.example", port: 5908)
        let meter = TrafficMeter(), total = Box(TrafficTotals())
        let session = TrafficSession(connectionID: meter.connectionID, endpoint: endpoint,
            onDelta: { route, delta in
                if route == endpoint { total.update { try! $0.add(delta) } }
            })
        meter.onUpdate = session.receive
        meter.record(sentBytes: 17, receivedBytes: 23)
        session.receive(meter.snapshot())
        try check(total.read() == TrafficTotals(sentBytes: 17, receivedBytes: 23), "Legacy traffic required device identity or counted twice")
        try session.bind(TrafficEndpoint(address: "LEGACY.example", port: 5908))
        try check(total.read() == TrafficTotals(sentBytes: 17, receivedBytes: 23), "Rebinding the same endpoint duplicated bytes")
    }

    run("Traffic buffers before endpoint binding and counts duplicate, stale and late snapshots exactly once") {
        let meter = TrafficMeter()
        let accumulated = Box(TrafficTotals())
        let endpoints = Box<[TrafficEndpoint]>([])
        let session = TrafficSession(connectionID: meter.connectionID, onDelta: { endpoint, delta in
            endpoints.update { $0.append(endpoint) }
            accumulated.update { try! $0.add(delta) }
        })
        meter.onUpdate = session.receive
        meter.record(sentBytes: 5, receivedBytes: 120)
        let beforeBinding = meter.snapshot()
        try check(accumulated.read() == TrafficTotals(), "Unbound endpoint traffic was attributed early")
        let endpoint = try TrafficEndpoint(address: "example.com", port: 5908)
        try session.bind(endpoint)
        try session.bind(endpoint)
        session.receive(beforeBinding)
        meter.record(sentBytes: 40, receivedBytes: 3)
        session.receive(beforeBinding)
        session.receive(TrafficSnapshot(connectionID: UUID(), totals: .init(sentBytes: 9000)))
        try check(accumulated.read() == TrafficTotals(sentBytes: 45, receivedBytes: 123), "Snapshots were lost or counted twice")
        try check(endpoints.read().allSatisfy { $0 == endpoint }, "Traffic moved to another endpoint")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in meter.record(sentBytes: 1, receivedBytes: 2) }
        try check(accumulated.read() == TrafficTotals(sentBytes: 145, receivedBytes: 323), "Concurrent snapshots duplicated or lost bytes")
        try rejects("A session changed endpoint") { try session.bind(TrafficEndpoint(address: "example.com", port: 5909)) }
    }

    run("A send completion retains the meter after its connection owner is released") {
        let bytes = try Message(.clipboard, Data(repeating: 7, count: 123)).framed().count
        let total = Box(TrafficTotals())
        var owner: TrafficMeter? = TrafficMeter()
        let session = TrafficSession(connectionID: owner!.connectionID, onDelta: { _, delta in total.update { try! $0.add(delta) } })
        try session.bind(TrafficEndpoint(address: "192.0.2.1", port: 5908))
        owner!.onUpdate = session.receive
        let completion = { [meter = owner!] in meter.record(sentBytes: UInt64(bytes)) }
        owner = nil
        completion()
        try check(total.read().sentBytes == 128 && total.read().receivedBytes == 0,
                  "A late send lost its original meter or application framing bytes")
    }

    run("Traffic integer overflow is reported without wrapping or partially updating counters") {
        var totals = TrafficTotals(sentBytes: .max, receivedBytes: 3)
        try rejects("Traffic wrapped at integer overflow") { try totals.add(.init(sentBytes: 1, receivedBytes: 9)) }
        try check(totals.sentBytes == .max && totals.receivedBytes == 3, "Overflow partially updated totals")
        let meter = TrafficMeter()
        meter.record(sentBytes: .max)
        meter.record(sentBytes: 1)
        try check(meter.snapshot().error != nil && meter.snapshot().totals.sentBytes == .max, "Overflow was hidden")
        try check(TrafficTotals(sentBytes: .max, receivedBytes: .max).totalBytes == Decimal(UInt64.max) * 2,
                  "The displayed combined total overflowed")
    }

    if !CommandLine.arguments.contains("--skip-network") {
        run("Directional meters count exact framed application bytes over authenticated loopback") {
            let key = try PairingKey.generate()
            let listener = try makeListener(key, queue: DispatchQueue(label: "checks.traffic"))
            guard let port = listener.port else { throw CheckFailure("No traffic check port") }
            let server = Box<Peer?>(nil)
            let clientTotals = Box(TrafficTotals()), serverTotals = Box(TrafficTotals())
            let clientLegacy = Box(0), serverLegacy = Box(0)
            let failure = Box<String?>(nil), done = DispatchSemaphore(value: 0)
            let examine = {
                if clientTotals.read() == TrafficTotals(sentBytes: 128, receivedBytes: 12),
                   serverTotals.read() == TrafficTotals(sentBytes: 12, receivedBytes: 128) { done.signal() }
            }
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection, heartbeatInterval: 100)
                server.set(peer)
                let endpoint = try! TrafficEndpoint(remoteEndpoint: connection.endpoint, listeningPort: port.rawValue)
                let session = TrafficSession(connectionID: peer.trafficMeter.connectionID, endpoint: endpoint,
                    onDelta: { _, delta in serverTotals.update { try! $0.add(delta) }; examine() })
                peer.trafficMeter.onUpdate = session.receive
                peer.onTraffic = { count in serverLegacy.update { $0 += count } }
                peer.onMessage = { [weak peer] message in
                    guard message.kind == .clipboard, message.payload == Data(repeating: 7, count: 123) else {
                        failure.set("Application payload changed"); done.signal(); return
                    }
                    peer?.send(Message(.input, Data(repeating: 8, count: 7)))
                }
                peer.start()
            }
            let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)), heartbeatInterval: 100)
            defer { client.close(); server.read()?.close(); listener.cancel() }
            let endpoint = try TrafficEndpoint(address: "127.0.0.1", port: port.rawValue)
            let session = TrafficSession(connectionID: client.trafficMeter.connectionID, endpoint: endpoint,
                onDelta: { _, delta in clientTotals.update { try! $0.add(delta) }; examine() })
            client.trafficMeter.onUpdate = session.receive
            client.onTraffic = { count in clientLegacy.update { $0 += count } }
            client.onReady = { [weak client] in client?.send(Message(.clipboard, Data(repeating: 7, count: 123))) }
            client.start()
            try wait(done, "Directional traffic snapshots were not completed")
            client.queue.sync {}
            server.read()?.queue.sync {}
            try check(failure.read() == nil, failure.read() ?? "Traffic exchange failed")
            try check(clientLegacy.read() == 140 && serverLegacy.read() == 140, "Legacy traffic callback behavior changed")
        }
    }
}
