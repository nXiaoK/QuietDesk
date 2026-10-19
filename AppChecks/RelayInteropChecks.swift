import Foundation
import Network
import QuietDeskCore

private final class RelayBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.withLock { value } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}
private struct RelayCheckFailure: Error { let message: String }
private func requireRelay(_ value: Bool, _ message: String) throws { if !value { throw RelayCheckFailure(message: message) } }
private func waitRelay(_ semaphore: DispatchSemaphore, _ message: String, seconds: Double = 10) throws {
    try requireRelay(semaphore.wait(timeout: .now() + seconds) == .success, message)
}
private struct Fixture: Decodable {
    private enum CodingKeys: String, CodingKey { case address, accessKey }
    let address: String
    let accessKey: Data
    var authorities: [Data] = []
    var endpoint: RelayEndpoint { get throws { try RelayEndpoint(address: address) } }
}

// The host media UDP listener reuses the TCP port number on every interface. Keep the TCP listener the
// system assigned and retry only when that number is already taken for UDP, so an unrelated local
// socket cannot silently turn a check into TCP-only media.
private func startRelayHostListener(_ parameters: NWParameters, queue: DispatchQueue,
                                    accept: @escaping (NWConnection) -> Void) throws -> NWListener {
    for _ in 0..<20 {
        let listener = try NWListener(using: parameters), ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = accept
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port else {
            listener.cancel(); throw RelayCheckFailure(message: "Synthetic desktop listener did not start")
        }
        if udpPortIsFree(port.rawValue) { return listener }
        listener.cancel()
    }
    throw RelayCheckFailure(message: "No synthetic desktop port was also free for UDP")
}

private func udpPortIsFree(_ port: UInt16) -> Bool {
    let ipv4 = socket(AF_INET, SOCK_DGRAM, 0), ipv6 = socket(AF_INET6, SOCK_DGRAM, 0)
    defer { close(ipv4); close(ipv6) }
    var any4 = sockaddr_in(), any6 = sockaddr_in6()
    any4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); any4.sin_family = sa_family_t(AF_INET); any4.sin_port = port.bigEndian
    any6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); any6.sin6_family = sa_family_t(AF_INET6); any6.sin6_port = port.bigEndian
    let free4 = withUnsafePointer(to: &any4) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ipv4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
    let free6 = withUnsafePointer(to: &any6) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ipv6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
    }
    return ipv4 >= 0 && ipv6 >= 0 && free4 && free6
}

private func relayPacket(_ sequence: UInt32, idr: Bool) -> VideoPacket {
    VideoPacket(sequence: sequence, sps: idr ? Data([0x67, 0x64]) : Data(), pps: idr ? Data([0x68]) : Data(),
                avcc: Data([0, 0, 0, 2, idr ? 0x65 : 0x41, 0x88]))
}

private func exerciseRelay(_ fixture: Fixture, udp: Bool, blocked: Bool = false, wrongPairing: Bool = false) throws {
    let queue = DispatchQueue(label: "checks.relay.host-listener")
    let key = try PairingKey.generate(), device = UUID()
    let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
    let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let hostPort = RelayBox<UInt16>(0)
    let online = DispatchSemaphore(value: 0), localReady = DispatchSemaphore(value: 0)
    let committed = DispatchSemaphore(value: 0), predicted = DispatchSemaphore(value: 0), data = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let hostMedia = RelayBox<MediaSession?>(nil), viewerMedia = RelayBox<MediaSession?>(nil), peers = RelayBox<[Peer]>([])
    let errors = RelayBox<[String]>([]), states = RelayBox<[String]>([]), sequence = RelayBox<UInt32>(0), bridgePort = RelayBox<UInt16?>(nil)
    let hostAgent = RelayBox<RelayHostRegistration?>(nil), hostReady = RelayBox(false), verifiedSource = RelayBox(false)
    let shuttingDown = RelayBox(false)
    let listener = try startRelayHostListener(parameters, queue: queue) { connection in
        let peer = Peer(connection: connection); peers.update { $0.append(peer) }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                hostMedia.read()?.acceptAuxiliary(peer, role: role); return
            }
            hostReady.update { $0 = true }
            verifiedSource.update { $0 = hostAgent.read()?.ownsLocalEndpoint(connection.endpoint) == true }
            do {
                let media = try MediaSession.host(control: peer, key: key, port: hostPort.read(), settings: settings)
                hostMedia.update { $0 = media }
                media.onPrepareRecovery = { $0(true) }
                media.onProduceRecoveryFrame = { [weak media] in
                    sequence.update { $0 += 1 }; media?.sendVideo(relayPacket(sequence.read(), idr: true))
                }
                media.onResumeFrames = { [weak media] in
                    sequence.update { $0 += 1 }; media?.sendVideo(relayPacket(sequence.read(), idr: false))
                }
                media.onReliableData = { message in
                    if message.kind == .clipboardCancel && message.payload == Data([1, 7, 255]) { data.signal() }
                }
                peer.onMessageHandled = { message, resume in _ = media.receive(message); resume() }
                media.start()
            } catch { errors.update { $0.append("Host media setup failed") } }
        }
        peer.start()
    }
    hostPort.update { $0 = listener.port!.rawValue }
    let agent = try RelayHostRegistration(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: device,
        ownerKey: PairingKey.generate().data, localPort: listener.port!.rawValue, certificateAuthorities: fixture.authorities)
    hostAgent.update { $0 = agent }
    agent.onStatus = { status in
        if case .online = status { online.signal() }
        if case .failed(let error) = status, !shuttingDown.read() { errors.update { $0.append("Registration failed: \(error.localizedDescription)") } }
    }
    agent.start()
    let bridge = try RelayViewerBridge(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: device,
        udpEnabled: udp, certificateAuthorities: fixture.authorities)
    bridge.onReady = { port in bridgePort.update { $0 = port }; localReady.signal() }
    bridge.onClose = { error in if !shuttingDown.read() && !wrongPairing { errors.update { $0.append("Bridge failed: \(error.localizedDescription)") } } }
    bridge.onDatagramFailure = { error in
        if !shuttingDown.read() && udp && !blocked { errors.update { $0.append("Datagram route failed: \(error.localizedDescription)") } }
    }
    defer {
        shuttingDown.update { $0 = true }; viewerMedia.read()?.stop(); hostMedia.read()?.stop()
        bridge.stop(); agent.stop(); peers.read().forEach { $0.close("relay synthetic check finished") }; listener.cancel()
    }
    try waitRelay(online, "Host registration did not authenticate")
    bridge.start(); try waitRelay(localReady, "Private viewer bridge did not bind")
    let viewerKey = wrongPairing ? try PairingKey.generate() : key
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bridgePort.read()!)!,
        using: try MediaSecureTransport.tlsParameters(key: viewerKey, roles: [.control]))
    let client = Peer(connection: connection, handshakeTimeout: 20)
    defer { client.close("relay synthetic check finished") }
    client.onClose = { _ in closed.signal() }
    client.onReady = {
        do {
            let media = try MediaSession.viewer(control: client, key: key, host: "127.0.0.1", port: bridgePort.read()!, settings: settings, udpEnabled: udp)
            viewerMedia.update { $0 = media }
            media.onVideo = { frame, complete in complete(true); if !frame.header.isIDR { predicted.signal() } }
            media.onCommitStream = { _, _ in committed.signal() }
            media.onState = { state in states.update { $0.append(state) } }
            client.onMessageHandled = { message, resume in _ = media.receive(message); resume() }
            media.start()
        } catch { errors.update { $0.append("Viewer media setup failed") } }
    }
    client.start()
    if wrongPairing {
        try waitRelay(closed, "Wrong Mac pairing key was not rejected", seconds: 30)
        try requireRelay(!hostReady.read() && viewerMedia.read() == nil, "Node credentials bypassed desktop pairing")
        return
    }
    try waitRelay(committed, "Relay media never committed: \(states.read()), \(errors.read())", seconds: 12)
    try waitRelay(predicted, "Relay media did not resume its P-frame chain")
    viewerMedia.read()?.sendReliableData(Message(.clipboardCancel, Data([1, 7, 255])))
    try waitRelay(data, "Relay bulk channel did not preserve reliable payload")
    try requireRelay(verifiedSource.read(), "Relayed host source was mistaken for an ordinary loopback client")
    let expected = udp && !blocked ? "UDP 视频" : "TCP 视频"
    for _ in 0..<100 where !states.read().contains(expected) { Thread.sleep(forTimeInterval: 0.01) }
    try requireRelay(states.read().contains(expected), "Wrong committed relay transport: \(states.read())")
    try requireRelay(errors.read().isEmpty, "Relayed session failed: \(errors.read())")
}

// Uses real inner TLS/DTLS and the real node, with fake video and no capture/input injection.
private func exerciseMixedRelay(_ fixture: Fixture, drop: Bool, blocked: Bool = false, cancelCandidate: Bool = false, decoderFailure: Bool = false) throws {
    let queue = DispatchQueue(label: "checks.relay.mixed-host")
    let key = try PairingKey.generate(), device = UUID()
    let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
    let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let hostPort = RelayBox<UInt16>(0)
    let online = DispatchSemaphore(value: 0), proxyReady = DispatchSemaphore(value: 0)
    let committed = DispatchSemaphore(value: 0), relayed = DispatchSemaphore(value: 0), requested = DispatchSemaphore(value: 0)
    let hostCommitted = DispatchSemaphore(value: 0)
    let fallback = DispatchSemaphore(value: 0), inputDone = DispatchSemaphore(value: 0)
    let host = RelayBox<MediaSession?>(nil), viewer = RelayBox<MediaSession?>(nil), peers = RelayBox<[Peer]>([])
    let agentBox = RelayBox<RelayHostRegistration?>(nil), bridgeBox = RelayBox<RelayViewerBridge?>(nil)
    let controls = RelayBox(0), sequence = RelayBox<UInt32>(0), requests = RelayBox(0), commits = RelayBox(0)
    let inputs = RelayBox<[UInt8]>([]), states = RelayBox<[String]>([]), shuttingDown = RelayBox(false)
    let held = RelayBox<((MediaSession.DatagramEndpoint?) -> Void)?>(nil)
    let listener = try startRelayHostListener(parameters, queue: queue) { connection in
        let peer = Peer(connection: connection); peers.update { $0.append(peer) }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                host.read()?.acceptAuxiliary(peer, role: role); return
            }
            controls.update { $0 += 1 }
            do {
                let media = try MediaSession.host(control: peer, key: key, port: hostPort.read(), settings: settings, relayRouting: true)
                host.update { $0 = media }
                media.isRelayedDatagram = { agentBox.read()?.ownsLocalDatagramEndpoint($0) == true }
                media.onPrepareRecovery = { $0(true) }
                media.onProduceRecoveryFrame = { [weak media] in
                    sequence.update { $0 += 1 }; media?.sendVideo(relayPacket(sequence.read(), idr: true))
                }
                media.onResumeFrames = { hostCommitted.signal() }
                peer.onMessageHandled = { message, resume in
                    if message.kind == .input, let value = message.payload.first {
                        inputs.update { $0.append(value) }; if inputs.read().count == 100 { inputDone.signal() }
                    } else { _ = media.receive(message) }
                    resume()
                }
                media.start()
            } catch { peer.close("Synthetic mixed media setup failed") }
        }
        peer.start()
    }
    hostPort.update { $0 = listener.port!.rawValue }
    let agent = try RelayHostRegistration(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: device,
        ownerKey: PairingKey.generate().data, localPort: listener.port!.rawValue, certificateAuthorities: fixture.authorities)
    agentBox.update { $0 = agent }
    agent.onStatus = { if case .online = $0 { online.signal() } }
    agent.start()
    let proxy = try RelayOpaqueProxy(target: listener.port!.rawValue)
    proxy.onReady = { proxyReady.signal() }; proxy.start()
    defer {
        shuttingDown.update { $0 = true }; viewer.read()?.stop(); host.read()?.stop(); agent.stop()
        bridgeBox.read()?.stop(); proxy.stop(); peers.read().forEach { $0.close() }; listener.cancel()
    }
    try waitRelay(online, "Mixed host did not register")
    try waitRelay(proxyReady, "Mixed direct proxy did not bind")
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port!)!,
        using: try MediaSecureTransport.tlsParameters(key: key, roles: [.control]))
    let client = Peer(connection: connection)
    defer { client.close() }
    client.onReady = {
        do {
            let media = try MediaSession.viewer(control: client, key: key, host: "127.0.0.1", port: proxy.port!, settings: settings, relayRouting: true)
            viewer.update { $0 = media }
            media.onVideo = { frame, complete in
                // A received frame whose decoder stalls is compute failure, not delivery failure.
                if decoderFailure, !frame.header.isIDR { return }
                complete(true)
            }
            media.onCommitStream = { _, _ in commits.update { $0 += 1 }; committed.signal() }
            media.onState = { state in
                states.update { $0.append(state) }
                if state == "中继 UDP 视频" { relayed.signal() }
            }
            media.onReliablePathFailure = { fallback.signal() }
            media.prepareAlternateDatagramPath = { [weak media] complete in
                requests.update { $0 += 1 }; requested.signal()
                if cancelCandidate { held.update { $0 = complete }; return }
                do {
                    let bridge = try RelayViewerBridge(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: device,
                        certificateAuthorities: fixture.authorities)
                    bridgeBox.update { $0 = bridge }
                    bridge.onReady = { [weak bridge] port in
                        complete(MediaSession.DatagramEndpoint(host: "127.0.0.1", port: port, retire: { [weak bridge] in bridge?.retireDatagramPath() }))
                    }
                    bridge.onClose = { _ in complete(nil) }
                    bridge.onDatagramFailure = { [weak media] _ in if !shuttingDown.read() { media?.networkPathChanged() } }
                    bridge.start()
                } catch { complete(nil) }
            }
            client.onMessageHandled = { message, resume in _ = media.receive(message); resume() }
            media.start()
        } catch { client.close("Synthetic mixed viewer setup failed") }
    }
    client.start()
    try waitRelay(committed, "Direct TCP never committed before testing its failure", seconds: 12)
    try waitRelay(hostCommitted, "Host did not finish its direct TCP commit")
    try requireRelay(states.read().contains("TCP 视频") && requests.read() == 0, "Healthy direct fallback contacted relay")
    if drop {
        proxy.dropVideo()
        sequence.update { $0 += 1 }; host.read()?.sendVideo(relayPacket(sequence.read(), idr: false))
        try waitRelay(requested, "Actual reliable delivery failure did not request an alternate", seconds: 10)
        if cancelCandidate {
            viewer.read()?.stop()
            Thread.sleep(forTimeInterval: 0.2)
            let before = commits.read()
            held.read()?(MediaSession.DatagramEndpoint(host: "127.0.0.1", port: 9))
            Thread.sleep(forTimeInterval: 0.3)
            try requireRelay(commits.read() == before && requests.read() == 1, "Late candidate resurrected stopped media")
            return
        }
        if blocked {
            try waitRelay(fallback, "Failed direct and relay video never reached bounded reliable fallback", seconds: 25)
            try requireRelay(commits.read() == 1 && !states.read().contains("中继 UDP 视频"), "Unusable candidate replaced the old image")
        } else {
            try waitRelay(relayed, "Direct control did not migrate its video to relay UDP: \(states.read())", seconds: 20)
            try requireRelay(proxy.droppedRecords > 0 && requests.read() == 1, "Mixed test did not exercise a real bounded alternate")
            host.read()?.setPaused(true); viewer.read()?.setPaused(true)
            Thread.sleep(forTimeInterval: 1.3)
            host.read()?.setPaused(false); viewer.read()?.setPaused(false)
            try waitRelay(relayed, "Relay video did not recover after pause", seconds: 10)
            // A closed alternate route is forgotten, so the next reliable failure can prepare a new one.
            bridgeBox.read()?.stop(); viewer.read()?.alternateDatagramPathClosed()
            try waitRelay(requested, "A closed relay route was never prepared again: \(states.read())", seconds: 15)
            try requireRelay(requests.read() == 2, "A closed relay route did not allow exactly one new preparation")
        }
    } else {
        if decoderFailure {
            sequence.update { $0 += 1 }; host.read()?.sendVideo(relayPacket(sequence.read(), idr: false))
            try waitRelay(committed, "A stalled decoder did not recover its reference chain", seconds: 10)
        }
        Thread.sleep(forTimeInterval: 6)
        try requireRelay(requests.read() == 0 && commits.read() == (decoderFailure ? 2 : 1), "Static or compute-limited media switched network routes")
    }
    for value in UInt8(0)..<UInt8(100) { client.send(Message(.input, Data([value]))) }
    try waitRelay(inputDone, "Direct control stopped responding while video was recovering")
    try requireRelay(inputs.read() == Array(UInt8(0)..<UInt8(100)) && controls.read() == 1,
                     "Video route change duplicated input or rebuilt the control peer")
}

private func rejectedRelay(_ fixture: Fixture, wrongKey: Bool) throws {
    let bridge = try RelayViewerBridge(endpoint: fixture.endpoint,
        accessKey: wrongKey ? PairingKey.generate().data : fixture.accessKey, deviceID: UUID(), certificateAuthorities: fixture.authorities)
    let ready = DispatchSemaphore(value: 0), rejected = DispatchSemaphore(value: 0), port = RelayBox<UInt16?>(nil), error = RelayBox<Error?>(nil)
    bridge.onReady = { value in port.update { $0 = value }; ready.signal() }
    bridge.onClose = { value in error.update { $0 = value }; rejected.signal() }
    bridge.start(); defer { bridge.stop() }
    try waitRelay(ready, "Rejected-node fixture could not bind its local bridge")
    let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port.read()!)!, using: .tcp)
    local.start(queue: DispatchQueue(label: "checks.relay.rejected-local")); defer { local.cancel() }
    try waitRelay(rejected, "Node authentication/offline failure had no explicit response")
    let expected: RelayServiceError = wrongKey ? .unauthorized : .offline
    try requireRelay(error.read() as? RelayServiceError == expected, "Node failure was misclassified")
}

@main private struct RelayInteropChecks {
    static func main() {
        var passed = 0, failed = 0
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            var fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("fixture.json")))
            fixture.authorities = [try Data(contentsOf: directory.appendingPathComponent("certificate.der"))]
            func run(_ name: String, _ body: () throws -> Void) {
                do { try body(); passed += 1; print("PASS \(name)") }
                catch { failed += 1; print("FAIL \(name): \(error)") }
            }
            if CommandLine.arguments.contains("--mixed") {
                run("Healthy direct TCP and static media never contact a configured relay") { try exerciseMixedRelay(fixture, drop: false) }
                run("Delivery failure migrates video to relay DTLS without rebuilding control or duplicating input") { try exerciseMixedRelay(fixture, drop: true) }
                run("A stalled decoder does not turn into a false network relay trial") { try exerciseMixedRelay(fixture, drop: false, decoderFailure: true) }
                run("Late alternate readiness cannot resurrect cancelled media") { try exerciseMixedRelay(fixture, drop: true, cancelCandidate: true) }
            } else if CommandLine.arguments.contains("--mixed-blocked") {
                run("Failed direct TCP and blocked relay UDP preserve the old frame and request bounded reliable fallback") { try exerciseMixedRelay(fixture, drop: true, blocked: true) }
            } else if CommandLine.arguments.contains("--udp-blocked") {
                run("Blocked relay UDP still commits independent end-to-end TCP video and reliable bulk") { try exerciseRelay(fixture, udp: true, blocked: true) }
            } else if CommandLine.arguments.contains("--private-udp-port") {
                run("A private node listen port cannot redirect public-endpoint DTLS forwarding") { try exerciseRelay(fixture, udp: true) }
            } else {
            run("Native endpoints preserve inner desktop TLS, independent TCP video and bulk through the Go relay") { try exerciseRelay(fixture, udp: false) }
            run("Native endpoints preserve inner desktop DTLS media through authenticated Go datagram routing") { try exerciseRelay(fixture, udp: true) }
            run("Relay access credentials cannot bypass a wrong desktop pairing key") { try exerciseRelay(fixture, udp: false, wrongPairing: true) }
            run("Incorrect node access credentials are explicit and nonretryable") { try rejectedRelay(fixture, wrongKey: true) }
            run("An offline device is never advertised as a connected desktop") { try rejectedRelay(fixture, wrongKey: false) }
            run("System certificate validation rejects an untrusted synthetic node without installing trust") {
                let queue = DispatchQueue(label: "checks.relay.system-trust")
                let rejected = DispatchSemaphore(value: 0), ready = RelayBox(false), error = RelayBox<Error?>(nil)
                let channel = try RelayTLSChannel(endpoint: fixture.endpoint, queue: queue)
                channel.onReady = { ready.update { $0 = true } }
                channel.onClose = { value in error.update { $0 = value }; rejected.signal() }
                channel.start(); defer { channel.close() }
                try waitRelay(rejected, "Untrusted node certificate did not fail")
                try requireRelay(!ready.read() && (error.read() as? RelayTransportError) == .certificate, "System trust was bypassed")
            }
            run("Immediate cancellation cannot publish a late bridge or registration readiness") {
                let ready = RelayBox(0)
                let bridge = try RelayViewerBridge(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: UUID(), certificateAuthorities: fixture.authorities)
                bridge.onReady = { _ in ready.update { $0 += 1 } }
                bridge.start(); bridge.stop()
                let host = try RelayHostRegistration(endpoint: fixture.endpoint, accessKey: fixture.accessKey, deviceID: UUID(),
                    ownerKey: PairingKey.generate().data, localPort: 9, certificateAuthorities: fixture.authorities)
                host.onStatus = { if case .online = $0 { ready.update { $0 += 1 } } }
                host.start(); host.stop()
                Thread.sleep(forTimeInterval: 0.2)
                try requireRelay(ready.read() == 0, "Cancelled bridge revived")
            }
            }
        } catch { failed += 1; print("FAIL Relay fixture setup") }
        print("Relay interoperability checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
