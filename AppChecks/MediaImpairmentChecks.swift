import Darwin
import Foundation
import Network
import QuietDeskCore

// Parameterized weak-network checks: real MediaSession endpoints over loopback TLS/DTLS, with a
// ciphertext proxy that drops, delays and rate-limits datagrams. The proxy never holds session keys.

private struct ImpairmentFailure: Error, CustomStringConvertible { let description: String }
// The loopback fixture itself could not be set up; the scenario did not run and may be tried again.
private struct FixtureUnavailable: Error, CustomStringConvertible { let description: String }

private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ImpairmentFailure(description: message()) }
}

// Deterministic per-direction randomness, so a failing scenario replays the same drop decisions.
private struct SplitMix64 {
    var state: UInt64
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

private struct Impairment {
    var loss = 0.0
    // Gilbert-Elliott bursts: probability of entering and of leaving the state that drops everything.
    var burst: (enter: Double, exit: Double)?
    var delay: TimeInterval = 0
    var jitter: TimeInterval = 0
    var bytesPerSecond: Double?
    var queueBytes = 64 * 1_024
    // Seconds after arming during which the link drops everything.
    var outage: ClosedRange<TimeInterval>?
    // Deterministic rule on (ciphertext size, index among datagrams of this direction since arming).
    var drop: (@Sendable (Int, Int) -> Bool)?
}

private func reservePort() throws -> (descriptor: Int32, port: NWEndpoint.Port) {
    for _ in 0..<20 {
        let udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP), tcp = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard udp >= 0, tcp >= 0 else {
            if udp >= 0 { close(udp) }; if tcp >= 0 { close(tcp) }
            throw ImpairmentFailure(description: "Could not create fixture port reservations")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let reserved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(udp, raw, length) == 0 && getsockname(udp, raw, &length) == 0 && bind(tcp, raw, length) == 0
            }
        }
        close(tcp)
        if reserved, let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)) { return (udp, port) }
        close(udp)
    }
    throw ImpairmentFailure(description: "No paired TCP/UDP fixture port was available")
}

private func plainTCP() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: nil, tcp: tcp)
}

private func waitUntilListening(_ listener: NWListener, queue: DispatchQueue) -> Bool {
    let settled = DispatchSemaphore(value: 0), ready = Shared(false)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.update { $0 = true }; settled.signal()
        case .failed, .cancelled: settled.signal()
        default: break
        }
    }
    listener.start(queue: queue)
    let listening = settled.wait(timeout: .now() + 5) == .success && ready.get()
    listener.stateUpdateHandler = nil
    if !listening { listener.cancel() }
    return listening
}

// Network.framework can refuse a loopback number that raw sockets just bound, for instance while many
// outbound connections hold it. Move to a fresh TCP/UDP pair instead of failing the scenario; the
// returned descriptor keeps the UDP number reserved until the caller closes it.
private func listenOnFreePair(queue: DispatchQueue, parameters: () throws -> NWParameters,
                              accept: @escaping (NWConnection, NWEndpoint.Port) -> Void)
    throws -> (listener: NWListener, port: NWEndpoint.Port, udpReservation: Int32) {
    for _ in 0..<40 {
        let reservation = try reservePort()
        let configured = try parameters()
        configured.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: reservation.port)
        let listener = try NWListener(using: configured)
        let port = reservation.port
        listener.newConnectionHandler = { accept($0, port) }
        if waitUntilListening(listener, queue: queue) { return (listener, port, reservation.descriptor) }
        close(reservation.descriptor)
    }
    throw FixtureUnavailable(description: "No loopback TCP/UDP port pair could be bound")
}

// Forwards TLS and DTLS ciphertext between the viewer and the host. TCP passes untouched; each UDP
// direction applies the armed impairment while keeping datagram boundaries and arrival order.
private final class ImpairmentProxy: @unchecked Sendable {
    struct Counts { var forwarded = 0, dropped = 0, bytes = 0 }
    private struct Direction {
        var random: SplitMix64
        var dropping = false
        var index = 0
        var busyUntil: TimeInterval = 0
        var lastRelease: TimeInterval = 0
        var counts = Counts()
    }
    private let queue = DispatchQueue(label: "checks.media-impairment.proxy", qos: .userInteractive)
    private let hostPort: NWEndpoint.Port
    private var listeners: [NWListener] = []
    private var connections: [NWConnection] = []
    private var toViewer: Direction, toHost: Direction
    private var downlink: Impairment?, uplink: Impairment?
    private var armedAt: TimeInterval = 0
    private var stopped = false

    init(hostPort: NWEndpoint.Port, seed: UInt64) {
        self.hostPort = hostPort
        toViewer = Direction(random: SplitMix64(state: seed))
        toHost = Direction(random: SplitMix64(state: seed ^ 0xA5A5_5A5A_DEAD_BEEF))
    }

    func start() throws -> NWEndpoint.Port {
        for _ in 0..<10 {
            let bound = try listenOnFreePair(queue: queue, parameters: plainTCP) { [weak self] connection, _ in
                self?.relayTCP(connection)
            }
            close(bound.udpReservation)
            let udpParameters = NWParameters.udp
            udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: bound.port)
            let udp = try NWListener(using: udpParameters)
            udp.newConnectionHandler = { [weak self] in self?.relayUDP($0) }
            if waitUntilListening(udp, queue: queue) {
                queue.sync { listeners = [bound.listener, udp] }
                return bound.port
            }
            bound.listener.cancel()
        }
        throw FixtureUnavailable(description: "Impairment proxy could not bind a TCP/UDP port pair")
    }

    /// `downlink` shapes host-to-viewer datagrams (video), `uplink` the viewer's feedback.
    func arm(downlink: Impairment?, uplink: Impairment?) {
        queue.sync {
            self.downlink = downlink; self.uplink = uplink
            armedAt = SessionClock.now
            toViewer.index = 0; toHost.index = 0
        }
    }

    func counts() -> (toViewer: Counts, toHost: Counts) { queue.sync { (toViewer.counts, toHost.counts) } }

    func stop() {
        queue.sync {
            stopped = true
            listeners.forEach { $0.cancel() }
            connections.forEach { $0.cancel() }
            listeners.removeAll(); connections.removeAll()
        }
    }

    private func pair(_ incoming: NWConnection, _ upstream: NWConnection, ready: @escaping () -> Void) {
        connections += [incoming, upstream]
        var pending = 2
        for connection in [incoming, upstream] {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: pending -= 1; if pending == 0 { ready() }
                case .failed, .cancelled: incoming.cancel(); upstream.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func relayTCP(_ incoming: NWConnection) {
        let upstream = NWConnection(host: "127.0.0.1", port: hostPort, using: plainTCP())
        pair(incoming, upstream) { [weak self] in
            self?.copyStream(from: incoming, to: upstream)
            self?.copyStream(from: upstream, to: incoming)
        }
    }

    private func copyStream(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, error == nil, let data, !data.isEmpty else { source.cancel(); destination.cancel(); return }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard sendError == nil, !complete else { source.cancel(); destination.cancel(); return }
                self?.copyStream(from: source, to: destination)
            })
        }
    }

    // One lane per relayed direction: datagrams leave in arrival order even when their timers are late.
    private final class Lane {
        let destination: NWConnection
        var pending: [(release: TimeInterval, data: Data)] = []
        var head = 0
        var scheduled = false
        init(_ destination: NWConnection) { self.destination = destination }
    }

    private func relayUDP(_ incoming: NWConnection) {
        let upstream = NWConnection(host: "127.0.0.1", port: hostPort, using: .udp)
        pair(incoming, upstream) { [weak self] in
            self?.copyDatagrams(from: incoming, lane: Lane(upstream), towardViewer: false)
            self?.copyDatagrams(from: upstream, lane: Lane(incoming), towardViewer: true)
        }
    }

    private func copyDatagrams(from source: NWConnection, lane: Lane, towardViewer: Bool) {
        source.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped, error == nil, let data, !data.isEmpty else { return }
            if let release = self.schedule(bytes: data.count, towardViewer: towardViewer) {
                lane.pending.append((release, data))
                self.drain(lane)
            }
            self.copyDatagrams(from: source, lane: lane, towardViewer: towardViewer)
        }
    }

    private func drain(_ lane: Lane) {
        guard !stopped else { return }
        let now = SessionClock.now
        while lane.head < lane.pending.count, lane.pending[lane.head].release <= now + 0.000_2 {
            lane.destination.send(content: lane.pending[lane.head].data, completion: .idempotent)
            lane.head += 1
        }
        if lane.head == lane.pending.count { lane.pending.removeAll(keepingCapacity: true); lane.head = 0; return }
        if lane.head >= 512 { lane.pending.removeFirst(lane.head); lane.head = 0 }
        guard !lane.scheduled else { return }
        lane.scheduled = true
        queue.asyncAfter(deadline: .now() + max(0.000_2, lane.pending[lane.head].release - now)) { [weak self] in
            lane.scheduled = false
            self?.drain(lane)
        }
    }

    // Returns when the datagram leaves the impaired link, or nil when the link drops it.
    private func schedule(bytes: Int, towardViewer: Bool) -> TimeInterval? {
        let now = SessionClock.now
        let model = towardViewer ? downlink : uplink
        var state = towardViewer ? toViewer : toHost
        defer { if towardViewer { toViewer = state } else { toHost = state } }
        func dropped() -> TimeInterval? { state.counts.dropped += 1; return nil }
        guard let model else { state.counts.forwarded += 1; state.counts.bytes += bytes; return now }
        let index = state.index
        state.index += 1
        if model.drop?(bytes, index) == true { return dropped() }
        if let outage = model.outage, outage.contains(now - armedAt) { return dropped() }
        if let burst = model.burst {
            if state.dropping { if state.random.unit() < burst.exit { state.dropping = false } }
            else if state.random.unit() < burst.enter { state.dropping = true }
            if state.dropping { return dropped() }
        }
        if model.loss > 0, state.random.unit() < model.loss { return dropped() }
        var release = now
        if let rate = model.bytesPerSecond {
            // A serializing bottleneck with a tail-drop queue.
            let start = max(now, state.busyUntil)
            guard (start - now) * rate + Double(bytes) <= Double(model.queueBytes) else { return dropped() }
            state.busyUntil = start + Double(bytes) / rate
            release = state.busyUntil
        }
        release += model.delay + (model.jitter > 0 ? state.random.unit() * model.jitter : 0)
        release = max(release, state.lastRelease)
        state.lastRelease = release
        state.counts.forwarded += 1; state.counts.bytes += bytes
        return release
    }
}

private func fixturePacket(sequence: UInt32, idr: Bool, bytes: Int) -> VideoPacket {
    let filler = UInt8(truncatingIfNeeded: sequence &* 31 &+ 7)
    let nal = Data([idr ? 0x65 : 0x41]) + Data(repeating: filler, count: max(1, bytes - 1))
    var avcc = Data()
    avcc.put(UInt32(nal.count))
    avcc.append(nal)
    return VideoPacket(sequence: sequence, sps: idr ? Data([0x67, 0x42, 0x00, 0x1F]) : Data(),
                       pps: idr ? Data([0x68, 0xCE, 0x06]) : Data(), avcc: avcc)
}

private struct Scenario {
    var name: String
    var settings = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 12)
    var seconds: TimeInterval = 4
    var idrBytes = 96 * 1_024
    // Bytes of predicted frame `index` at the currently applied settings; nil leaves the screen still.
    var frameBytes: @Sendable (StreamSettings, Int) -> Int? = { settings, _ in
        settings.megabits * 125_000 / settings.framesPerSecond * 6 / 10
    }
    var downlink: Impairment?
    var uplink: Impairment?
    var seed: UInt64 = 20_261_121
}

private struct Outcome {
    var decoded = 0
    var decodedBytes = 0
    var submitted = 0
    var creditBlocked = 0
    var recoveries = 0
    var states: [String] = []
    var reductions = 0
    var finalSettings: StreamSettings
    var longestGap: TimeInterval = 0
    var highestLoss = 0.0
    var errors: [String] = []
    var toViewer = ImpairmentProxy.Counts()
    var usedTCP: Bool { states.contains { $0 != "UDP 视频" && $0.contains("TCP") } }
    var summary: String {
        "decoded=\(decoded)/\(submitted) blocked=\(creditBlocked) recoveries=\(recoveries) reductions=\(reductions) "
            + "final=\(finalSettings.summary) longestGap=\(Int(longestGap * 1_000))ms loss=\(String(format: "%.3f", highestLoss)) "
            + "linkDropped=\(toViewer.dropped)/\(toViewer.dropped + toViewer.forwarded) tcp=\(usedTCP)"
    }
}

// The host stands in for capture and encoder: one frame per tick while the receiver grants credit,
// a keyframe when the session asks to recover. The viewer runs the app's quality policy on real samples.
private func play(_ scenario: Scenario) throws -> Outcome {
    let key = try PairingKey.generate()
    let work = DispatchQueue(label: "checks.media-impairment.work", qos: .userInteractive)
    let streaming = DispatchSemaphore(value: 0)
    let outcome = Shared(Outcome(finalSettings: scenario.settings))
    let hostMedia = Shared<MediaSession?>(nil), viewerMedia = Shared<MediaSession?>(nil), hostPeers = Shared<[Peer]>([])
    let finished = Shared(false)
    func fail(_ message: String) {
        guard !finished.get() else { return }
        outcome.update { if $0.errors.count < 8 { $0.errors.append(message) } }
    }

    // Synthetic encoder state, owned by `work`.
    var applied = scenario.settings, sequence: UInt32 = 0, frameIndex = 0
    var outstanding = Set<UInt32>(), window = MediaBufferLimits.legacyFrameWindow
    var producing = false, held = true, timer: DispatchSourceTimer?
    var sizes: [UInt32: (idr: Bool, bytes: Int)] = [:]
    let sizeLock = NSLock()
    func submit(idr: Bool, bytes: Int, to media: MediaSession) {
        sequence &+= 1
        outstanding.insert(sequence)
        sizeLock.withLock { sizes[sequence] = (idr, bytes) }
        outcome.update { $0.submitted += 1 }
        media.sendVideo(fixturePacket(sequence: sequence, idr: idr, bytes: bytes))
    }
    func tick() {
        guard producing, !held, let media = hostMedia.get() else { return }
        defer { frameIndex += 1 }
        guard let bytes = scenario.frameBytes(applied, frameIndex) else { return }
        guard outstanding.count < window else { outcome.update { $0.creditBlocked += 1 }; return }
        submit(idr: false, bytes: bytes, to: media)
    }
    func schedule() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: work)
        let interval = 1 / Double(applied.framesPerSecond)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
        source.setEventHandler { tick() }
        timer = source
        source.resume()
    }

    let bound = try listenOnFreePair(queue: DispatchQueue(label: "checks.media-impairment.host"), parameters: {
        try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
    }) { connection, port in
        let peer = Peer(connection: connection)
        hostPeers.update { $0.append(peer) }
        peer.onClose = { fail("host peer: \($0)") }
        peer.onReady = { [weak peer] in
            guard let peer else { return }
            if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                hostMedia.get()?.acceptAuxiliary(peer, role: role)
                return
            }
            do {
                let media = try MediaSession.host(control: peer, key: key, port: port.rawValue, settings: scenario.settings)
                hostMedia.update { $0 = media }
                media.onReceiveFrameWindow = { limit in work.async { window = limit ?? MediaBufferLimits.legacyFrameWindow } }
                media.onAcknowledged = { number in work.async { outstanding.remove(number) } }
                media.onPrepareRecovery = { complete in work.async { held = true; outstanding.removeAll(); complete(true) } }
                media.onProduceRecoveryFrame = { [weak media] in
                    work.async {
                        guard let media else { return }
                        if producing { outcome.update { $0.recoveries += 1 } }
                        submit(idr: true, bytes: scenario.idrBytes, to: media)
                    }
                }
                media.onResumeFrames = { work.async { held = false; if !producing { producing = true; schedule(); streaming.signal() } } }
                peer.onMessageHandled = { message, resume in _ = media.receive(message); resume() }
                media.start()
            } catch { fail("host setup: \(error)") }
        }
        peer.start()
    }
    let listener = bound.listener, hostPort = bound.port
    close(bound.udpReservation)
    let proxy = ImpairmentProxy(hostPort: hostPort, seed: scenario.seed)
    let proxyPort = try proxy.start()
    let client = Peer(connection: NWConnection(host: "127.0.0.1", port: proxyPort,
                                               using: try MediaSecureTransport.tlsParameters(key: key, roles: [.control])))
    defer {
        finished.update { $0 = true }
        work.sync { timer?.cancel(); timer = nil; producing = false }
        viewerMedia.get()?.stop(); hostMedia.get()?.stop()
        client.close("impairment fixture finished")
        hostPeers.get().forEach { $0.close("impairment fixture finished") }
        proxy.stop(); listener.cancel()
    }
    client.onClose = { fail("viewer control: \($0)") }
    var quality = try MediaQualityPolicy(hostDefault: scenario.settings, preferred: scenario.settings, applied: scenario.settings,
                                         bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1200), now: SessionClock.now)
    var lastDecodedAt: TimeInterval?
    // Stands in for the settings request and its confirmation over the control connection.
    func apply(_ next: StreamSettings) {
        let inPlace = next.framesPerSecond == applied.framesPerSecond && next.longestEdge == applied.longestEdge
        work.asyncAfter(deadline: .now() + 0.02) {
            guard !finished.get() else { return }
            applied = next
            hostMedia.get()?.updateSettings(next, restartsStream: !inPlace)
            viewerMedia.get()?.updateSettings(next, restartsStream: !inPlace)
            _ = quality.confirmApplied(next, now: SessionClock.now)
            outcome.update { $0.finalSettings = next }
            if !inPlace { schedule() }
        }
    }
    client.onReady = {
        do {
            let media = try MediaSession.viewer(control: client, key: key, host: "127.0.0.1", port: proxyPort.rawValue,
                                                settings: scenario.settings, udpEnabled: true)
            viewerMedia.update { $0 = media }
            media.onState = { state in outcome.update { if $0.states.last != state, $0.states.count < 64 { $0.states.append(state) } } }
            media.onDatagramLoss = { fraction in if let fraction { outcome.update { $0.highestLoss = max($0.highestLoss, fraction) } } }
            media.onLocalNetwork = { local in work.async { quality.setLocalNetwork(local, now: SessionClock.now) } }
            media.onReduceLoad = { cause in
                work.async {
                    outcome.update { $0.reductions += 1 }
                    if let next = quality.reduceLoad(for: cause, severe: cause == .network, now: SessionClock.now) { apply(next) }
                }
            }
            media.onSample = { sample in work.async { if let next = quality.observe(sample, now: SessionClock.now) { apply(next) } } }
            media.onVideo = { frame, complete in
                let expected = sizeLock.withLock { sizes.removeValue(forKey: frame.packet.sequence) }
                guard let expected, expected.idr == frame.header.isIDR,
                      frame.packet.avcc == fixturePacket(sequence: frame.packet.sequence, idr: expected.idr, bytes: expected.bytes).avcc else {
                    fail("frame \(frame.packet.sequence) changed in transit")
                    complete(false)
                    return
                }
                let now = SessionClock.now
                work.async {
                    if producing, let last = lastDecodedAt { outcome.update { $0.longestGap = max($0.longestGap, now - last) } }
                    lastDecodedAt = now
                }
                outcome.update { $0.decoded += 1; $0.decodedBytes += frame.packet.avcc.count }
                complete(true)
            }
            client.onMessageHandled = { message, resume in _ = media.receive(message); resume() }
            media.start()
        } catch { fail("viewer setup: \(error)") }
    }
    client.start()
    guard streaming.wait(timeout: .now() + 10) == .success else {
        throw ImpairmentFailure(description: "Video never started: \(outcome.get().states) \(outcome.get().errors)")
    }
    // Another process holding the UDP number leaves the unimpaired session on TCP: nothing to measure.
    guard outcome.get().states.last == "UDP 视频" else {
        throw FixtureUnavailable(description: "Clean loopback did not start on UDP: \(outcome.get().states)")
    }
    proxy.arm(downlink: scenario.downlink, uplink: scenario.uplink)
    Thread.sleep(forTimeInterval: scenario.seconds)
    var result = outcome.get()
    result.toViewer = proxy.counts().toViewer
    return result
}

@main
private struct MediaImpairmentChecks {
    static func main() {
        var failures = 0
        func run(_ scenario: Scenario, _ verify: ((Outcome) throws -> Void)?) {
            do {
                var attempt = 1
                var played: Outcome?
                while played == nil {
                    do { played = try play(scenario) }
                    catch let unavailable as FixtureUnavailable {
                        guard attempt < 3 else { throw unavailable }
                        attempt += 1
                        print("RETRY \(scenario.name): \(unavailable)")
                    }
                }
                guard let outcome = played else { return }
                print("IMPAIRMENT \(scenario.name): \(outcome.summary)")
                guard let verify else { return }
                try expect(outcome.errors.isEmpty, "session errors: \(outcome.errors)")
                try verify(outcome)
                print("PASS \(scenario.name)")
            } catch {
                failures += 1
                print("FAIL \(scenario.name): \(error)")
            }
        }

        // `--matrix` prints the measurements of a wider set of links without asserting on them, for
        // comparing transport changes; the default run is the pass/fail subset below.
        if CommandLine.arguments.contains("--matrix") {
            for scenario in matrix() { run(scenario, nil) }
            exit(failures > 0 ? 1 : 0)
        }

        run(Scenario(name: "A clean link keeps UDP, the chosen bitrate and an unbroken reference chain")) { outcome in
            try expect(!outcome.usedTCP && outcome.recoveries == 0, "A clean link recovered or left UDP: \(outcome.states)")
            try expect(outcome.finalSettings.megabits == 12, "A clean link lowered the bitrate")
            try expect(outcome.decoded >= 180, "A clean link delivered too few frames")
        }

        var light = Scenario(name: "Two percent random loss in both directions is repaired on UDP without lowering quality")
        light.downlink = Impairment(loss: 0.02)
        light.uplink = Impairment(loss: 0.02)
        run(light) { outcome in
            try expect(outcome.toViewer.dropped >= 20, "The proxy dropped too little to exercise repair")
            try expect(!outcome.usedTCP, "Light loss moved video off UDP: \(outcome.states)")
            try expect(outcome.finalSettings.megabits == 12, "Light loss lowered the bitrate")
            try expect(outcome.decoded >= 150 && outcome.recoveries <= 1, "Light loss broke playback")
        }

        if failures > 0 { exit(1) }
    }

    static func matrix() -> [Scenario] {
        var scenarios: [Scenario] = []
        for loss in [0.05, 0.10, 0.15] {
            var scenario = Scenario(name: "random loss \(Int(loss * 100))% both directions")
            scenario.seconds = 10
            scenario.downlink = Impairment(loss: loss); scenario.uplink = Impairment(loss: loss)
            scenarios.append(scenario)
        }
        var bursts = Scenario(name: "burst loss, mean five datagrams, about 5%")
        bursts.seconds = 10
        bursts.downlink = Impairment(burst: (0.01, 0.2)); bursts.uplink = Impairment(loss: 0.02)
        scenarios.append(bursts)
        var jitter = Scenario(name: "20 ms delay plus 40 ms jitter, no loss")
        jitter.seconds = 8
        jitter.downlink = Impairment(delay: 0.02, jitter: 0.04); jitter.uplink = Impairment(delay: 0.02, jitter: 0.04)
        scenarios.append(jitter)
        var narrow = Scenario(name: "4 Mbps bottleneck under a 12 Mbps stream")
        narrow.seconds = 12
        narrow.downlink = Impairment(delay: 0.015, bytesPerSecond: 500_000); narrow.uplink = Impairment(delay: 0.015)
        scenarios.append(narrow)
        var small = Scenario(name: "single-fragment frames with 5% loss")
        small.seconds = 8
        small.frameBytes = { _, _ in 600 }
        small.downlink = Impairment(loss: 0.05); small.uplink = Impairment(loss: 0.05)
        scenarios.append(small)
        var tail = Scenario(name: "one small frame a second, every second one lost whole")
        tail.seconds = 10
        tail.frameBytes = { _, index in index % 60 == 0 ? 600 : nil }
        let seen = Shared(0)
        tail.downlink = Impairment(delay: 0.01, drop: { bytes, _ in
            guard (640...760).contains(bytes) else { return false }
            seen.update { $0 += 1 }
            return seen.get() % 2 == 0
        })
        tail.uplink = Impairment(delay: 0.01)
        scenarios.append(tail)
        var outage = Scenario(name: "400 ms outage, then a 1 MB keyframe across 8% loss")
        outage.settings = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
        outage.seconds = 12
        outage.idrBytes = 1_024 * 1_024
        outage.downlink = Impairment(loss: 0.08, delay: 0.02, outage: 1.0...1.4)
        outage.uplink = Impairment(loss: 0.08, delay: 0.02, outage: 1.0...1.4)
        scenarios.append(outage)
        return scenarios
    }
}
