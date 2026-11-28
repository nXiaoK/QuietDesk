import Foundation
import Network
import QuietDeskCore

func runRelayProtocolChecks() {
    run("Relay addresses normalize without permitting credentials, paths or plaintext schemes") {
        let first = try RelayEndpoint(address: "relay.example.COM:443")
        let second = try RelayEndpoint(address: "tls://relay.example.com:443")
        try check(first == second && first.credentialAccount == second.credentialAccount, "Equivalent relay nodes changed credential identity")
        try check(try RelayEndpoint(address: "tls://[::1]:7443").address == "tls://[::1]:7443", "IPv6 relay address changed")
        let encoded = try JSONEncoder().encode(first)
        try check(try JSONDecoder().decode(RelayEndpoint.self, from: encoded) == first, "Saved relay node changed")
        for address in ["", "http://relay.example.com", "tls://user:secret@relay.example.com", "tls://relay.example.com/path",
                        "tls://relay.example.com?secret=value", "tls://relay.example.com:0", "tls://relay.example.com:65536",
                        "tls://relay%40other.example.com", "tls://relay%2fother.example.com"] {
            try rejects("Invalid relay endpoint accepted") { _ = try RelayEndpoint(address: address) }
        }
    }
    run("Relay node aliases normalize and endpoint digests use the salted wire format") {
        let endpoint = try RelayEndpoint(address: "RELAY.example.com")
        let names = [endpoint.address: "  上海\n\u{0007}  节点 "]
        try check(RelayNodeNaming.shortTitle(for: endpoint, names: names) == "上海 节点", "Alias whitespace leaked into the UI")
        try check(RelayNodeNaming.fullTitle(for: endpoint, names: names) == "上海 节点（relay.example.com:443）",
                  "A custom title lost its address")
        try check(RelayNodeNaming.fullTitle(for: endpoint, names: [:]) == endpoint.address, "Unnamed titles changed")
        try check(RelayNodeNaming.sanitize("\n\u{001F}  ") == nil &&
                  RelayNodeNaming.sanitize(String(repeating: "沪", count: 41))?.count == 40, "Alias length or blank handling changed")
        let digest = RelayNodeNaming.endpointDigest(endpoint)
        let equivalent = try RelayEndpoint(address: "tls://relay.example.com:443")
        let other = try RelayEndpoint(address: "tls://relay.example.com:444")
        try check(digest == "114b34a468535a3ed9366021eb7e5ba7" && RelayNodeNaming.isEndpointDigest(digest) &&
                  !digest.contains(endpoint.host) && RelayNodeNaming.endpointDigest(equivalent) == digest &&
                  RelayNodeNaming.endpointDigest(other) != digest, "Node fingerprints changed across equivalent endpoints or exposed the address")
    }
    run("Relay node inspection message metadata is optional, bounded and distinguishes false from missing") {
        let key = Data(count: 32)
        let request = RelayMessage(.info, accessKey: key)
        let decodedRequest = try RelayMessage.decode(Data(try request.framed().dropFirst(4)))
        try check(decodedRequest.op == .info && decodedRequest.deviceID == nil && decodedRequest.accessKey == key,
                  "Node-only request required a target device")
        let info = RelayMessage(.nodeInfo, serverVersion: "0.7.56", capabilities: ["tcp", "dualProbe"], deviceOnline: false)
        let decodedInfo = try RelayMessage.decode(Data(try info.framed().dropFirst(4)))
        try check(decodedInfo.op == .nodeInfo && decodedInfo.serverVersion == "0.7.56" &&
                  decodedInfo.capabilities == ["tcp", "dualProbe"] && decodedInfo.deviceOnline == false, "Node metadata was lost")
        let legacy = Data(try RelayMessage(.registered, registration: String(repeating: "a", count: 64)).framed().dropFirst(4))
        let fields = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        try check(fields["serverVersion"] == nil && fields["capabilities"] == nil && fields["deviceOnline"] == nil,
                  "Absent metadata was added to an old registration message")
        try rejects("Authenticated query without an access key") { try RelayMessage(.info).validate() }
        var invalidDeviceQuery = request
        invalidDeviceQuery.deviceID = "not-a-uuid"
        try rejects("Invalid device ID accepted") { try invalidDeviceQuery.validate() }
        for invalid in [
            RelayMessage(.nodeInfo, serverVersion: ""),
            RelayMessage(.nodeInfo, serverVersion: String(repeating: "1", count: 65)),
            RelayMessage(.nodeInfo, serverVersion: "1.0.0\n"),
            RelayMessage(.nodeInfo, capabilities: Array(repeating: "tcp", count: 17)),
            RelayMessage(.nodeInfo, capabilities: ["\u{001B}"])
        ] {
            try rejects("Unbounded or unsafe node metadata accepted") { try invalid.validate() }
        }
    }
    run("Relay node version comparison preserves legacy and development build labels") {
        let app = "0.7.56"
        try check(RelayNodeVersionStatus.evaluate(serverVersion: app, currentAppVersion: app) == .upToDate(version: app) &&
                  RelayNodeVersionStatus.evaluate(serverVersion: "0.7.57", currentAppVersion: app) == .upToDate(version: "0.7.57") &&
                  RelayNodeVersionStatus.evaluate(serverVersion: "0.7.52", currentAppVersion: app) == .updatable(version: "0.7.52", currentAppVersion: app) &&
                  RelayNodeVersionStatus.evaluate(serverVersion: nil, currentAppVersion: app) == .legacyUnversioned &&
                  RelayNodeVersionStatus.evaluate(serverVersion: "0.7.56-dev", currentAppVersion: app).badgeText == "0.7.56-dev",
                  "Node version assessment misclassified a release or development build")
    }
    run("Relay device presence distinguishes authenticated answers from stored node membership") {
        let version: RelayNodeVersionStatus = .upToDate(version: "0.7.56")
        try check(RelayPeerNodeMatch.evaluate(deviceOnline: true, isConfigured: false, versionStatus: version) == .onlineShared,
                  "Live registration was hidden because it was missing from the saved digest list")
        try check(RelayPeerNodeMatch.evaluate(deviceOnline: false, isConfigured: true, versionStatus: version) == .configuredOffline &&
                  RelayPeerNodeMatch.evaluate(deviceOnline: false, isConfigured: false, versionStatus: version) == .notConfiguredOnHost,
                  "An authenticated offline answer lost the saved membership distinction")
        try check(RelayPeerNodeMatch.evaluate(deviceOnline: nil, isConfigured: true, versionStatus: version) == .configuredUnverified &&
                  RelayPeerNodeMatch.evaluate(deviceOnline: nil, isConfigured: true, versionStatus: .legacyUnversioned) == .configuredLegacy &&
                  RelayPeerNodeMatch.evaluate(deviceOnline: nil, isConfigured: false, versionStatus: .unknown) == .unknownLegacy &&
                  RelayPeerNodeMatch.evaluate(deviceOnline: nil, isConfigured: true, versionStatus: version, failure: "timeout") == .unreachable("timeout"),
                  "Stored membership implied presence without a live result")
    }
    run("Relay device and digest metadata preserves historical ConnectionRecord and Hello payloads") {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
        let legacy = ConnectionRecord(address: "192.0.2.1", port: 9999, name: "Mac")
        let legacyData = try encoder.encode(legacy)
        let legacyFields = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        try check(legacyFields["knownRelayDeviceID"] == nil && legacyFields["hostRelayNodeDigests"] == nil &&
                  decoder.decode(ConnectionRecord.self, from: legacyData) == legacy, "Historical connection fields changed")
        let endpoint = try RelayEndpoint(address: "relay.example.com")
        let digest = RelayNodeNaming.endpointDigest(endpoint), deviceID = UUID(), alternateID = UUID()
        var record = ConnectionRecord(address: legacy.address, port: legacy.port, name: legacy.name,
                                      knownRelayDeviceID: deviceID, hostRelayNodeDigests: [digest])
        try check(record.effectiveRelayDeviceID == deviceID && decoder.decode(ConnectionRecord.self, from: encoder.encode(record)) == record,
                  "Learned relay identity did not round-trip")
        record.relay = try RelayConnectionInfo(endpoint: endpoint, deviceID: alternateID)
        try check(record.effectiveRelayDeviceID == alternateID, "Learned identity overrode the explicit relay target")
        func hello(_ digests: [String]?) -> Hello {
            Hello(name: "Mac", width: 1920, height: 1080, settings: settings, canControl: true, relayNodeDigests: digests)
        }
        let legacyHelloFields = try JSONSerialization.jsonObject(with: encoder.encode(hello(nil))) as! [String: Any]
        try check(legacyHelloFields["relayNodeDigests"] == nil, "Default Hello sent an unknown field")
        for digests in [[], [digest]] {
            let decodedHello = try decoder.decode(Hello.self, from: encoder.encode(hello(digests)))
            try decodedHello.validate()
            try check(decodedHello.relayNodeDigests == digests, "Explicit digest list became absent")
        }
        try rejects("Unbounded host digest list accepted") { try hello(Array(repeating: digest, count: 33)).validate() }
        try rejects("Plaintext relay host leaked into Hello") { try hello([endpoint.address]).validate() }
    }
    run("Relay framed messages bind required fields and reject invalid or oversized routing material") {
        let original = RelayMessage(.incoming, circuitID: String(repeating: "a", count: 64))
        let framed = try original.framed()
        var prefix = ByteReader(Data(framed.prefix(4)))
        let length: UInt32 = try prefix.take()
        let decoded = try RelayMessage.decode(Data(framed.dropFirst(4)))
        try check(Int(length) == framed.count - 4 && decoded.circuitID == original.circuitID, "Relay framing changed")
        for message in [RelayMessage(.register), RelayMessage(.registered), RelayMessage(.incomingDatagram),
                        RelayMessage(.connect, accessKey: Data(count: 31), deviceID: UUID()),
                        RelayMessage(.incoming, circuitID: String(repeating: "g", count: 64))] {
            try rejects("Malformed relay message accepted") { _ = try message.framed() }
        }
        try rejects("Oversized relay body accepted") { _ = try RelayMessage.decode(Data(count: RelayMessage.maximumBytes + 1)) }
        try rejects("Unknown relay version accepted") { _ = try RelayMessage.decode(Data(#"{"version":2,"op":"ready"}"#.utf8)) }
        try rejects("Unknown server error reflected into the UI") { _ = try RelayMessage.decode(Data(#"{"version":1,"op":"error","error":"untrusted text"}"#.utf8)) }
        try check(!RelayServiceError.unauthorized.retryable && !RelayServiceError.ownerMismatch.retryable && RelayServiceError.offline.retryable,
                  "Fatal authentication errors became endless retries")
    }
    run("Relay datagrams match the server wire vector and reject every modified byte") {
        let key = Data(0..<32), id = Data(0..<16)
        let packet = try RelayDatagram(side: 1, downstream: true, sequence: 17, id: id, payload: Data([0, 128, 255]))
        let encoded = try packet.encode(key: key)
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        try check(hex == "5144523101010000000000000011000102030405060708090a0b0c0d0e0f00030080ff237a249d00e804b083a7d4c2647df028d8d3ce3bca945417f8517a1935c6cd9e", "Client/server authenticated wire contract diverged")
        let decoded = try RelayDatagram.decode(encoded, key: key)
        try check(decoded.id == id && decoded.sequence == 17 && decoded.downstream && decoded.payload == packet.payload, "Datagram metadata changed")
        for index in encoded.indices {
            var damaged = encoded; damaged[index] ^= 1
            try rejects("Modified routing or payload authenticated") { _ = try RelayDatagram.decode(damaged, key: key) }
        }
        try rejects("Wrong routing key authenticated") { _ = try RelayDatagram.decode(encoded, key: Data(repeating: 1, count: 32)) }
        try rejects("Unbounded UDP payload accepted") {
            _ = try RelayDatagram(side: 0, sequence: 1, id: id, payload: Data(count: RelayDatagram.maximumPayloadBytes + 1))
        }
    }
    run("Relay auxiliary UDP ports remain optional and follow the public endpoint offset") {
        let id = Data(count: 16), key = Data(count: 32)
        let endpoint = try RelayEndpoint(address: "relay.example.com:28443")
        var legacy = RelayMessage(.datagramReady, datagramID: id, datagramKey: key, udpPort: 7443)
        let legacyBody = Data(try legacy.framed().dropFirst(4))
        let legacyFields = try JSONSerialization.jsonObject(with: legacyBody) as! [String: Any]
        try check(legacyFields["probeUDPPort"] == nil && RelayMessage.decode(legacyBody).probePort(relativeTo: endpoint) == nil,
                  "A legacy relay lease advertised auxiliary probing")
        legacy.probeUDPPort = 7444
        let ready = try RelayMessage.decode(Data(try legacy.framed().dropFirst(4)))
        try check(ready.probeUDPPort == 7444 && ready.probePort(relativeTo: endpoint) == 28444,
                  "A private auxiliary port was used instead of its public offset")
        let lastPort = try RelayEndpoint(address: "relay.example.com:65535")
        try check(ready.probePort(relativeTo: lastPort) == nil, "A public auxiliary port overflowed")
        legacy.probeUDPPort = 7443
        try check(legacy.probePort(relativeTo: endpoint) == nil, "Main port was accepted as an auxiliary port")
        for invalid in [0, -1, 65_536] {
            legacy.probeUDPPort = invalid
            try rejects("An invalid auxiliary UDP port was accepted") { _ = try legacy.framed() }
        }
    }
    run("Relay IPv6 host candidates accept global unicast on eligible interfaces") {
        let global = IPv6Address("2001:db8::8")!.rawValue
        try check(RelayPeerLocalCandidates.isUsableIPv6Interface(name: "en0", ipv6: global), "Global IPv6 was excluded from Ethernet")
        for interface in ["awdl0", "llw0", "anpi1", "ipsec0", "gif0", "stf0", "xhc0", "pktap0", "UTUN5"] {
            try check(!RelayPeerLocalCandidates.isUsableIPv6Interface(name: interface, ipv6: global), "Excluded interface \(interface) supplied an IPv6 host candidate")
        }
        for address in ["::", "::1", "fe80::1", "fc00::1", "ff02::1", "::ffff:192.0.2.1"] {
            try check(!RelayPeerLocalCandidates.isUsableIPv6Interface(name: "en0", ipv6: IPv6Address(address)!.rawValue), "Non-global IPv6 was accepted: \(address)")
        }
        try check(!RelayPeerLocalCandidates.isUsableIPv6Interface(name: "en0", ipv6: Data([0x20])), "Truncated IPv6 was accepted")
    }
    run("Relay replay windows allow bounded reordering across 512 packets but never duplicate, zero or wrapped counters") {
        var window = RelayReplayWindow()
        for value: UInt64 in [1, 3, 2, 64, 65, 320, 200, 512, 70, 513] {
            try check(window.accept(value), "Fresh reordered datagram rejected")
        }
        for value: UInt64 in [0, 1, 2, 3, 64, 65, 70, 200, 320, 512, 513] {
            try check(!window.accept(value), "Replay revived an old relay packet")
        }
        try check(window.accept(.max) && !window.accept(1) && !window.accept(.max), "Counter exhaustion silently wrapped")
    }
    run("Relay connection metadata remains optional and contains no service or desktop credentials") {
        let direct = ConnectionRecord(address: "desktop.local", port: 5908, name: "Synthetic desktop")
        let directData = try JSONEncoder().encode(direct)
        let directJSON = try JSONSerialization.jsonObject(with: directData) as! [String: Any]
        try check(directJSON["relay"] == nil && (try JSONDecoder().decode(ConnectionRecord.self, from: directData)).relay == nil,
                  "A legacy direct record changed its JSON field range")
        let info = try RelayConnectionInfo(endpoint: RelayEndpoint(address: "relay.example.com:7443"), deviceID: UUID(), strategy: .automatic)
        var relayed = direct; relayed.relay = info
        let encoded = try JSONEncoder().encode(relayed)
        let decoded = try JSONDecoder().decode(ConnectionRecord.self, from: encoded)
        try check(decoded == relayed && decoded.id == direct.id, "Relay metadata lost record identity or old fields")
        let text = String(decoding: encoded, as: UTF8.self)
        for field in ["accessKey", "ownerKey", "pairingCode", "registration", "datagramKey"] {
            try check(!text.contains(field), "A credential entered connection metadata")
        }
        try rejects("Direct records acquired an active relay route") {
            _ = try RelayConnectionInfo(endpoint: info.endpoint, deviceID: info.deviceID, strategy: .direct)
        }
    }
    run("A failed relay fallback waits a bounded, growing cooldown before media can fall back again") {
        var cooldown = RelayFallbackCooldown()
        try check(cooldown.allows(now: 0), "A fresh target could not fall back to its relay")
        cooldown.failed(now: 100)
        try check(!cooldown.allows(now: 129.9) && cooldown.allows(now: 130), "The first relay failure did not wait 30 seconds")
        cooldown.failed(now: 130); cooldown.failed(now: 190); cooldown.failed(now: 310); cooldown.failed(now: 610)
        try check(!cooldown.allows(now: 909.9) && cooldown.allows(now: 910), "Repeated relay failures did not cap the cooldown at 300 seconds")
        cooldown.reset()
        try check(cooldown.allows(now: 0) && cooldown.failures == 0, "A successful relay session did not clear the cooldown")
    }
    func bindLoopback(_ type: Int32, port: UInt16, listen: Bool = false) -> (fd: Int32, port: UInt16, error: Int32) {
        let socket = Darwin.socket(AF_INET, type, 0)
        guard socket >= 0 else { return (-1, 0, errno) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 && (!listen || Darwin.listen(socket, 1) == 0)
            }
        }
        let error = bound ? 0 : errno
        guard bound else { close(socket); return (-1, 0, error) }
        return (socket, UInt16(bigEndian: address.sin_port), 0)
    }
    func bindUDP(_ port: UInt16) -> (Int32, UInt16)? {
        let result = bindLoopback(SOCK_DGRAM, port: port)
        return result.fd >= 0 ? (result.fd, result.port) : nil
    }
    func verifyBoundPair(_ port: UInt16) throws {
        let tcpProbe = bindLoopback(SOCK_STREAM, port: port)
        if tcpProbe.fd >= 0 { close(tcpProbe.fd); throw CheckFailure("The published port has no relay TCP listener") }
        if let (udpProbe, _) = bindUDP(port) { close(udpProbe); throw CheckFailure("The published port has no relay UDP listener") }
    }
    run("A taken loopback UDP number moves the viewer bridge to a fresh TCP/UDP pair instead of dropping relay UDP") {
        guard let (squatter, taken) = bindUDP(0) else { throw CheckFailure("Could not reserve a loopback UDP port") }
        defer { close(squatter) }
        let bridge = try RelayViewerBridge(endpoint: RelayEndpoint(address: "tls://127.0.0.1:9"), accessKey: Data(count: 32),
                                           deviceID: UUID(), preferredLoopbackPort: taken)
        let published = Box<UInt16?>(nil), closeError = Box<Error?>(nil), ready = DispatchSemaphore(value: 0)
        bridge.onReady = { published.set($0); ready.signal() }
        bridge.onClose = { closeError.set($0); ready.signal() }
        bridge.start()
        defer { bridge.stop() }
        try wait(ready, seconds: 5, "The bridge did not publish a loopback port")
        guard let port = published.read() else {
            let probe = bindLoopback(SOCK_STREAM, port: taken)
            if probe.fd >= 0 { close(probe.fd) }
            let reason = closeError.read().map { String(describing: $0) } ?? "nil"
            throw CheckFailure("The bridge closed instead of choosing another port (error: \(reason), port: \(taken), tcpBindErrno: \(probe.error))")
        }
        try check(port != taken, "The bridge published a port whose UDP number another socket holds")
        try verifyBoundPair(port)
    }
    run("A taken loopback TCP preferred port moves the viewer bridge to a fresh TCP/UDP pair instead of closing") {
        let tcp = bindLoopback(SOCK_STREAM, port: 0, listen: true)
        guard tcp.fd >= 0 else { throw CheckFailure("Could not reserve a loopback TCP port (\(tcp.error))") }
        defer { close(tcp.fd) }
        let bridge = try RelayViewerBridge(endpoint: RelayEndpoint(address: "tls://127.0.0.1:9"), accessKey: Data(count: 32),
                                           deviceID: UUID(), preferredLoopbackPort: tcp.port)
        let published = Box<UInt16?>(nil), closeError = Box<Error?>(nil), ready = DispatchSemaphore(value: 0)
        bridge.onReady = { published.set($0); ready.signal() }
        bridge.onClose = { closeError.set($0); ready.signal() }
        bridge.start()
        defer { bridge.stop() }
        try wait(ready, seconds: 5, "The bridge did not publish a loopback port")
        guard let port = published.read() else {
            let reason = closeError.read().map { String(describing: $0) } ?? "nil"
            throw CheckFailure("The bridge closed instead of choosing another port (error: \(reason), preferredTCP: \(tcp.port))")
        }
        try check(port != tcp.port, "The bridge published a TCP port another socket already holds")
        try verifyBoundPair(port)
    }
}
