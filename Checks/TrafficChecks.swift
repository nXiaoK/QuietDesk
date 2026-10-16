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

    run("Traffic buffers before identity and counts duplicate, stale and late snapshots exactly once") {
        let meter = TrafficMeter()
        let accumulated = Box(TrafficTotals())
        let identities = Box<[UUID]>([])
        let session = TrafficSession(connectionID: meter.connectionID, onDelta: { identity, delta in
            identities.update { $0.append(identity.id) }
            accumulated.update { try! $0.add(delta) }
        })
        meter.onUpdate = session.receive
        meter.record(sentBytes: 5, receivedBytes: 120)
        let beforeIdentity = meter.snapshot()
        try check(accumulated.read() == TrafficTotals(), "Unknown device traffic was attributed early")
        let identity = DeviceIdentity(id: UUID(), name: "same name")
        try session.bind(identity)
        try session.bind(identity)
        session.receive(beforeIdentity)
        meter.record(sentBytes: 40, receivedBytes: 3)
        session.receive(beforeIdentity)
        session.receive(TrafficSnapshot(connectionID: UUID(), totals: .init(sentBytes: 9000)))
        try check(accumulated.read() == TrafficTotals(sentBytes: 45, receivedBytes: 123), "Snapshots were lost or counted twice")
        try check(identities.read().allSatisfy { $0 == identity.id }, "Traffic moved to another device")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in meter.record(sentBytes: 1, receivedBytes: 2) }
        try check(accumulated.read() == TrafficTotals(sentBytes: 145, receivedBytes: 323), "Concurrent snapshots duplicated or lost bytes")
        try rejects("A session changed device identity") { try session.bind(DeviceIdentity(id: UUID(), name: identity.name)) }
    }

    run("A send completion retains the meter after its connection owner is released") {
        let bytes = try Message(.clipboard, Data(repeating: 7, count: 123)).framed().count
        let total = Box(TrafficTotals())
        var owner: TrafficMeter? = TrafficMeter()
        let session = TrafficSession(connectionID: owner!.connectionID, onDelta: { _, delta in total.update { try! $0.add(delta) } })
        try session.bind(DeviceIdentity(id: UUID(), name: "Mac"))
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
                peer.trafficMeter.onUpdate = { snapshot in serverTotals.set(snapshot.totals); examine() }
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
            client.trafficMeter.onUpdate = { snapshot in clientTotals.set(snapshot.totals); examine() }
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
