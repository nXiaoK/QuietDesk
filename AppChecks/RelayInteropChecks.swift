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
    let listener = try NWListener(using: parameters)
    let listening = DispatchSemaphore(value: 0), online = DispatchSemaphore(value: 0), localReady = DispatchSemaphore(value: 0)
    let committed = DispatchSemaphore(value: 0), predicted = DispatchSemaphore(value: 0), data = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let hostMedia = RelayBox<MediaSession?>(nil), viewerMedia = RelayBox<MediaSession?>(nil), peers = RelayBox<[Peer]>([])
    let errors = RelayBox<[String]>([]), states = RelayBox<[String]>([]), sequence = RelayBox<UInt32>(0), bridgePort = RelayBox<UInt16?>(nil)
    let hostAgent = RelayBox<RelayHostRegistration?>(nil), hostReady = RelayBox(false), verifiedSource = RelayBox(false)
    let shuttingDown = RelayBox(false)
    listener.stateUpdateHandler = { if case .ready = $0 { listening.signal() } }
    listener.newConnectionHandler = { connection in
        let peer = Peer(connection: connection); peers.update { $0.append(peer) }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                hostMedia.read()?.acceptAuxiliary(peer, role: role); return
            }
            hostReady.update { $0 = true }
            verifiedSource.update { $0 = hostAgent.read()?.ownsLocalEndpoint(connection.endpoint) == true }
            do {
                let media = try MediaSession.host(control: peer, key: key, port: listener.port!.rawValue, settings: settings)
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
    listener.start(queue: queue)
    try waitRelay(listening, "Synthetic desktop listener did not start")
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
            if CommandLine.arguments.contains("--udp-blocked") {
                run("Blocked relay UDP still commits independent end-to-end TCP video and reliable bulk") { try exerciseRelay(fixture, udp: true, blocked: true) }
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
                Thread.sleep(forTimeInterval: 0.2)
                try requireRelay(ready.read() == 0, "Cancelled bridge revived")
            }
            }
        } catch { failed += 1; print("FAIL Relay fixture setup") }
        print("Relay interoperability checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
