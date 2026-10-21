import Foundation
import Network
import QuietDeskCore

// Drives the real RelayPeerAgent through a synthetic two-NAT network with a millisecond clock.
private final class SimulatedPeerNetwork {
    enum NAT { case fullCone, portRestricted, symmetric }
    final class Endpoint {
        let agent: RelayPeerAgent
        let privateAddress: RelayPeerAddress
        let publicIP: String
        let nat: NAT
        var mappings: [String: UInt16] = [:]
        var permissions: Set<String> = []
        var nextPort: UInt16
        var delivered: [Data] = []
        var states: [RelayPeerPathState] = []
        init(agent: RelayPeerAgent, privateAddress: RelayPeerAddress, publicIP: String, nat: NAT, firstPort: UInt16) {
            self.agent = agent; self.privateAddress = privateAddress; self.publicIP = publicIP; self.nat = nat; nextPort = firstPort
        }
    }

    let relay = RelayPeerAddress(host: "198.18.0.1", port: 7443)
    let viewer: Endpoint
    let host: Endpoint
    var directLatency: TimeInterval = 0.02
    var relayLatency: TimeInterval = 0.06
    var blackhole = false
    var sameLAN = false
    private(set) var milliseconds = 0
    var now: TimeInterval { Double(milliseconds) / 1000 }
    private var events: [(at: Int, run: () -> Void)] = []

    init(viewerNAT: NAT, hostNAT: NAT, mode: RelayPeerAssistMode = .automatic, hostMode: RelayPeerAssistMode = .automatic,
         sharedPublicIP: Bool = false, secret: Data = Data(repeating: 7, count: 32)) throws {
        let lease = Data(repeating: 3, count: 16)
        viewer = Endpoint(agent: try RelayPeerAgent(side: 0, leaseID: lease, secret: secret, mode: mode),
                          privateAddress: RelayPeerAddress(host: "10.0.0.2", port: 50_000), publicIP: "198.51.100.10", nat: viewerNAT, firstPort: 40_000)
        host = Endpoint(agent: try RelayPeerAgent(side: 1, leaseID: lease, secret: secret, mode: hostMode),
                        privateAddress: RelayPeerAddress(host: sharedPublicIP ? "10.0.0.3" : "192.168.1.3", port: 60_000),
                        publicIP: sharedPublicIP ? "198.51.100.10" : "203.0.113.20", nat: hostNAT, firstPort: 30_000)
    }

    func mapping(_ endpoint: Endpoint, toward destination: RelayPeerAddress) -> RelayPeerAddress {
        let key = endpoint.nat == .symmetric ? destination.description : "*"
        let port = endpoint.mappings[key] ?? { () -> UInt16 in
            let port = endpoint.nextPort; endpoint.nextPort += 1; endpoint.mappings[key] = port; return port
        }()
        endpoint.permissions.insert("\(port)|\(destination.host)|\(destination.port)")
        return RelayPeerAddress(host: endpoint.publicIP, port: port)
    }

    /// The node announces each side's relay-facing mapping plus the other side's interface address.
    func announce() {
        let viewerMapping = mapping(viewer, toward: relay), hostMapping = mapping(host, toward: relay)
        perform(viewer.agent.updateCandidates([RelayCandidate(kind: .srflx, address: hostMapping.host, port: hostMapping.port),
                                               RelayCandidate(kind: .host, address: host.privateAddress.host, port: host.privateAddress.port)], now: now), by: viewer)
        perform(host.agent.updateCandidates([RelayCandidate(kind: .srflx, address: viewerMapping.host, port: viewerMapping.port),
                                             RelayCandidate(kind: .host, address: viewer.privateAddress.host, port: viewer.privateAddress.port)], now: now), by: host)
    }

    func perform(_ actions: [RelayPeerAgent.Action], by sender: Endpoint) {
        let peer = sender === viewer ? host : viewer
        for action in actions {
            switch action {
            case .state(let state): sender.states.append(state)
            case .sendViaRelay(let data):
                schedule(relayLatency) { [self] in
                    let result = peer.agent.receive(data, from: nil, now: now)
                    perform(result.actions, by: peer)
                }
            case .send(let data, let destination): send(data, from: sender, to: destination)
            }
        }
    }

    func send(_ data: Data, from sender: Endpoint, to destination: RelayPeerAddress) {
        let peer = sender === viewer ? host : viewer
        let source: RelayPeerAddress
        if destination == peer.privateAddress {
            guard sameLAN else { return }
            source = sender.privateAddress
        } else {
            // No hairpinning: two Macs behind one public address only meet on their LAN addresses.
            guard destination.host == peer.publicIP, sender.publicIP != peer.publicIP else { return }
            source = mapping(sender, toward: destination)
        }
        schedule(directLatency) { [self] in
            guard !blackhole else { return }
            if destination != peer.privateAddress {
                guard peer.mappings.values.contains(destination.port) else { return }
                if peer.nat != .fullCone, !peer.permissions.contains("\(destination.port)|\(source.host)|\(source.port)") { return }
            }
            let result = peer.agent.receive(data, from: source, now: now)
            if let payload = result.payload { peer.delivered.append(payload) }
            perform(result.actions, by: peer)
        }
    }

    func sendVideo(_ payload: Data) -> Bool {
        guard let (packet, destination) = host.agent.sealData(payload) else { return false }
        send(packet, from: host, to: destination); return true
    }

    private func schedule(_ delay: TimeInterval, _ run: @escaping () -> Void) {
        events.append((milliseconds + Int((delay * 1000).rounded()), run))
    }

    func run(for seconds: TimeInterval) {
        let end = milliseconds + Int(seconds * 1000)
        while milliseconds < end {
            milliseconds += 10
            let due = events.filter { $0.at <= milliseconds }
            events.removeAll { $0.at <= milliseconds }
            due.forEach { $0.run() }
            if milliseconds % 50 == 0 {
                perform(viewer.agent.tick(now: now), by: viewer)
                perform(host.agent.tick(now: now), by: host)
            }
        }
    }

    var bothDirect: Bool {
        if case .direct = viewer.agent.state, case .direct = host.agent.state { return viewer.agent.selected != nil && host.agent.selected != nil }
        return false
    }
}

func runRelayPeerPathChecks() {
    run("Assisted relay messages stay optional, bounded and limited to literal addresses") {
        let id = Data(repeating: 1, count: 16)
        let legacy = try JSONEncoder().encode(RelayMessage(.datagram, accessKey: Data(count: 32), deviceID: UUID()))
        try check(!String(decoding: legacy, as: UTF8.self).contains("assist") && !String(decoding: legacy, as: UTF8.self).contains("candidates"),
                  "Unnegotiated relay messages changed their wire fields")
        let consent = RelayMessage(.assist, datagramID: id, candidates: [RelayCandidate(kind: .host, address: "192.168.1.8", port: 50_000),
                                                                         RelayCandidate(kind: .host, address: "2001:db8::8", port: 50_000)])
        let decoded = try RelayMessage.decode(Data(try consent.framed().dropFirst(4)))
        try check(decoded.candidates == consent.candidates, "Candidate consent did not round-trip")
        let peer = RelayMessage(.peerCandidates, datagramID: id, candidates: [RelayCandidate(kind: .srflx, address: "127.0.0.1", port: 9)])
        _ = try peer.framed()
        let invalid: [[RelayCandidate]] = [
            [RelayCandidate(kind: .host, address: "relay.example.com", port: 1)],
            [RelayCandidate(kind: .host, address: "127.0.0.1", port: 1)],
            [RelayCandidate(kind: .host, address: "fe80::1", port: 1)],
            [RelayCandidate(kind: .host, address: "fe80::1%en0", port: 1)],
            [RelayCandidate(kind: .host, address: "224.0.0.251", port: 1)],
            [RelayCandidate(kind: .host, address: "0.0.0.0", port: 1)],
            [RelayCandidate(kind: .host, address: "::ffff:192.0.2.1", port: 1)],
            [RelayCandidate(kind: .host, address: "192.0.2.1", port: 0)],
            [RelayCandidate(kind: .prflx, address: "192.0.2.1", port: 1)],
            [RelayCandidate(kind: .srflx, address: "192.0.2.1", port: 1)],
            Array(repeating: RelayCandidate(kind: .host, address: "192.0.2.1", port: 1), count: 5),
        ]
        for candidates in invalid {
            try rejects("Invalid candidate consent accepted: \(candidates)") { _ = try RelayMessage(.assist, datagramID: id, candidates: candidates).framed() }
        }
        try rejects("Unbounded peer candidate list accepted") {
            _ = try RelayMessage(.peerCandidates, datagramID: id, candidates: Array(repeating: RelayCandidate(kind: .srflx, address: "192.0.2.1", port: 1), count: 9)).framed()
        }
        try rejects("Candidate list without a lease accepted") { _ = try RelayMessage(.peerCandidates, candidates: []).framed() }
        try check(RelayCandidate.canonicalAddress("::FFFF:192.0.2.1", allowLoopback: false) == "192.0.2.1" &&
                  RelayCandidate.canonicalAddress("2001:DB8:0:0::1", allowLoopback: false) == "2001:db8::1" &&
                  RelayCandidate.canonicalAddress("127.0.0.1", allowLoopback: false) == nil &&
                  RelayCandidate.canonicalAddress("::1", allowLoopback: true) == "::1", "Candidate addresses were not canonicalized")
    }
    run("Direct-path packets are authenticated, path-bound and never replayed") {
        let lease = Data(repeating: 9, count: 16)
        let viewer = try RelayPeerAgent(side: 0, leaseID: lease, secret: Data(repeating: 1, count: 32), mode: .automatic)
        let host = try RelayPeerAgent(side: 1, leaseID: lease, secret: Data(repeating: 1, count: 32), mode: .automatic)
        let outsider = try RelayPeerAgent(side: 1, leaseID: lease, secret: Data(repeating: 2, count: 32), mode: .automatic)
        let target = RelayPeerAddress(host: "203.0.113.5", port: 4000), source = RelayPeerAddress(host: "198.51.100.5", port: 5000)
        let actions = viewer.updateCandidates([RelayCandidate(kind: .srflx, address: target.host, port: target.port)], now: 0)
        guard let probe = actions.compactMap({ action -> Data? in if case .send(let data, target) = action { return data }; return nil }).first,
              let attempt = actions.compactMap({ action -> Data? in if case .sendViaRelay(let data) = action { return data }; return nil }).first else {
            throw CheckFailure("Viewer did not punch and ask the host to punch")
        }
        try check(probe.count == RelayPeerAgent.overhead + 8 && RelayPeerAgent.isPeerPacket(probe), "Direct check packet changed shape")
        let answered = host.receive(probe, from: source, now: 0.01).actions
        try check(answered.contains { if case .send(_, source) = $0 { return true }; return false }, "Host did not answer a valid check")
        try check(host.receive(probe, from: source, now: 0.02).actions.isEmpty, "A replayed check was answered")
        try check(host.receive(attempt, from: source, now: 0.02).actions.isEmpty, "A relay-stream packet was accepted from the direct path")
        try check(outsider.receive(probe, from: source, now: 0.01).actions.isEmpty, "A packet authenticated under another session key")
        for index in [0, 4, 5, 13, 20, 31, 40, probe.count - 1] {
            var damaged = probe; damaged[index] ^= 1
            let fresh = try RelayPeerAgent(side: 1, leaseID: lease, secret: Data(repeating: 1, count: 32), mode: .automatic)
            try check(fresh.receive(damaged, from: source, now: 0).actions.isEmpty, "Modified direct packet byte \(index) authenticated")
        }
        try check(host.sealData(Data([23, 1])) == nil, "Host sent video directly before any nomination")
        let silent = try RelayPeerAgent(side: 1, leaseID: lease, secret: Data(repeating: 1, count: 32), mode: .off)
        try check(silent.receive(probe, from: source, now: 0).actions.isEmpty, "A host with assistance off answered a direct check")
    }
    run("Port-restricted NATs on both sides punch through and move video off the relay") {
        let network = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        network.announce(); network.run(for: 2)
        try check(network.bothDirect && network.viewer.agent.state == .direct(.srflx), "Simultaneous punching did not establish: \(network.viewer.states)")
        try check(network.viewer.states.first == .checking, "Viewer did not report its checking phase first")
        let direct = network.viewer.agent.directRoundTrip ?? 1, relay = network.viewer.agent.relayRoundTrip ?? 0
        try check(direct < 0.06 && relay > 0.1, "Round trips were not measured on their own paths: \(direct) \(relay)")
        try check(network.sendVideo(Data([23, 254, 253, 1])), "Nominated host did not route video directly")
        network.run(for: 0.1)
        try check(network.viewer.delivered == [Data([23, 254, 253, 1])], "Direct video payload was not delivered unchanged")
    }
    run("A symmetric NAT facing a port-restricted NAT stays on the relay and backs off") {
        let network = try SimulatedPeerNetwork(viewerNAT: .symmetric, hostNAT: .portRestricted)
        network.announce(); network.run(for: 6)
        try check(network.viewer.agent.state == .unreachable && network.viewer.agent.selected == nil && network.host.agent.selected == nil,
                  "Unpunchable NATs were reported as direct: \(network.viewer.states)")
        try check(!network.sendVideo(Data([23])), "Unreachable path still carried video")
        network.run(for: 25)
        try check(network.viewer.states.filter { $0 == .checking }.count == 1, "Retry did not wait for the 30-second backoff")
        network.run(for: 5)
        try check(network.viewer.states.filter { $0 == .checking }.count == 2, "Backoff never retried")
    }
    run("A symmetric NAT reaches a full-cone host through a learned peer-reflexive address") {
        let network = try SimulatedPeerNetwork(viewerNAT: .symmetric, hostNAT: .fullCone)
        network.announce(); network.run(for: 2)
        try check(network.bothDirect && network.host.agent.state == .direct(.prflx), "Peer-reflexive path was not learned: \(network.host.states)")
        try check(network.sendVideo(Data([23, 7])), "Host could not use the learned mapping")
        network.run(for: 0.1)
        try check(network.viewer.delivered == [Data([23, 7])], "Learned mapping did not deliver video")
    }
    run("Macs behind one public address meet on their LAN addresses") {
        let network = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted, sharedPublicIP: true)
        network.sameLAN = true; network.directLatency = 0.002
        network.announce(); network.run(for: 2)
        try check(network.bothDirect && network.viewer.agent.state == .direct(.host), "LAN candidate was not chosen: \(network.viewer.states)")
    }
    run("Automatic mode keeps a faster relay while On uses any working direct path") {
        let automatic = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        automatic.directLatency = 0.15; automatic.relayLatency = 0.03
        automatic.announce(); automatic.run(for: 3)
        try check(automatic.viewer.agent.state == .relayFaster && !automatic.bothDirect, "A slower direct path replaced a faster relay")
        let forced = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted, mode: .on)
        forced.directLatency = 0.15; forced.relayLatency = 0.03
        forced.announce(); forced.run(for: 3)
        try check(forced.bothDirect, "On mode refused a working direct path: \(forced.viewer.states)")
    }
    run("Automatic mode returns to the relay when the direct path degrades") {
        let network = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        network.announce(); network.run(for: 2)
        try check(network.bothDirect, "Direct path did not establish")
        network.directLatency = 0.2
        network.run(for: 4)
        try check(network.bothDirect, "One slow sample abandoned the direct path immediately")
        network.run(for: 4)
        try check(network.viewer.agent.state == .relayFaster && network.host.agent.selected == nil && !network.sendVideo(Data([23])),
                  "A persistently slower direct path kept carrying video: \(network.viewer.states)")
    }
    run("A dead direct path falls back to the warm relay within a second and retries later") {
        let network = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        network.announce(); network.run(for: 2)
        try check(network.bothDirect, "Direct path did not establish")
        network.blackhole = true
        network.run(for: 1.0)
        try check(network.viewer.agent.selected == nil && network.host.agent.selected == nil && !network.sendVideo(Data([23])),
                  "A blackholed direct path still carried video after a second")
        try check(network.viewer.agent.state == .unreachable && network.host.agent.state == .relay, "Fallback was not reported")
        network.blackhole = false
        network.run(for: 20)
        try check(!network.bothDirect, "Retry ignored the 30-second backoff")
        network.run(for: 12)
        try check(network.bothDirect, "The direct path never returned after the network recovered: \(network.viewer.states)")
    }
    run("Turning assistance off returns both Macs to the relay; turning it back on punches again") {
        let network = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        network.announce(); network.run(for: 2)
        try check(network.bothDirect, "Direct path did not establish")
        network.perform(network.viewer.agent.setMode(.off, now: network.now), by: network.viewer)
        network.run(for: 0.2)
        try check(network.viewer.agent.state == .relay && network.host.agent.state == .relay && !network.sendVideo(Data([23])),
                  "Off left video on the direct path")
        network.run(for: 5)
        try check(network.viewer.agent.state == .relay, "Off still punched")
        network.perform(network.viewer.agent.setMode(.automatic, now: network.now), by: network.viewer)
        network.run(for: 2)
        try check(network.bothDirect, "Re-enabled assistance did not punch again")
        let refusing = try SimulatedPeerNetwork(viewerNAT: .portRestricted, hostNAT: .portRestricted)
        refusing.announce(); refusing.run(for: 2)
        refusing.perform(refusing.host.agent.setMode(.off, now: refusing.now), by: refusing.host)
        refusing.run(for: 1)
        try check(refusing.viewer.agent.selected == nil && refusing.host.agent.selected == nil, "Host turning assistance off was ignored")
    }
}
