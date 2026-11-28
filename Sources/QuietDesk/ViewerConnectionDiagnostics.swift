import Foundation
import QuietDeskCore

/// The viewer's timer and the media queue share one ordering for route boundaries and counter samples.
final class ViewerConnectionDiagnostics: @unchecked Sendable {
    // Route transitions can split the regular one-second timer into very short drains.
    private static let minimumFrameSampleSeconds: TimeInterval = 0.5

    private struct RelaySample {
        let counter: RelayPeerTrafficCounter
        var previous = RelayPeerTrafficCounter.DetailedSnapshot()
    }

    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let recorder: ConnectionDiagnosticRecorder
    private var channel: SessionDataChannel?
    private var previous = (traffic: SessionDataChannel.ChannelTraffic(), legacyBytes: 0, frames: 0, settled: 0, lost: 0)
    private var sampledAt: TimeInterval
    private var relaySamples: [RelaySample] = []
    private var controlRelayed = false
    private var tailnet = false
    private var tailnetPath: String?
    private var node: String?
    private var videoPath = MediaSession.DiagnosticVideoPath.preparing
    private var peerPath = RelayPeerPathState.relay
    private var paused = false

    init(startedAt: Date = Date(), clock: @escaping () -> TimeInterval = { SessionClock.now }) {
        self.clock = clock
        sampledAt = clock()
        recorder = ConnectionDiagnosticRecorder(startedAt: startedAt, now: sampledAt,
            route: DiagnosticRoute(control: .unavailable, media: .negotiating))
    }

    func waiting(_ media: DiagnosticRoute.Media, node: String? = nil) {
        lock.withLock { changeRoute(DiagnosticRoute(control: .unavailable, media: media, node: node)) }
    }

    func attach(_ channel: SessionDataChannel, relayed: Bool, node: String?, tailnet: Bool = false) {
        lock.withLock {
            let now = clock()
            sample(at: now)
            self.channel = nil
            controlRelayed = relayed
            self.tailnet = tailnet
            tailnetPath = nil
            self.node = node
            videoPath = .preparing
            peerPath = .relay
            paused = false
            updateVideoRoute()
            self.channel = channel
            previous = (SessionDataChannel.ChannelTraffic(), 0, 0, 0, 0)
            sampledAt = now
        }
    }

    func attachRelayTrafficCounter(_ counter: RelayPeerTrafficCounter?) {
        lock.withLock {
            if let counter {
                guard !relaySamples.contains(where: { $0.counter === counter }) else { return }
                sample(at: clock())
                // A retiring bridge may still forward packets while its replacement is starting.
                relaySamples.append(RelaySample(counter: counter))
            } else {
                sample(at: clock())
                relaySamples.removeAll()
            }
        }
    }

    func setTailnetPath(peerPath: String?, relay _: String?) {
        lock.withLock {
            guard tailnet, channel != nil else { return }
            // The DERP region is display metadata, never evidence of forwarding by itself.
            let path = peerPath == "direct" || peerPath == "derp" ? peerPath : nil
            guard path != tailnetPath else { return }
            tailnetPath = path
            updateVideoRoute()
        }
    }

    func setVideoPath(_ path: MediaSession.DiagnosticVideoPath, on source: SessionDataChannel) {
        lock.withLock {
            guard source === channel else { return }
            videoPath = path
            updateVideoRoute()
        }
    }

    func setPeerPath(_ state: RelayPeerPathState) {
        lock.withLock {
            peerPath = state
            if channel != nil { updateVideoRoute() }
        }
    }

    func setPaused(_ value: Bool) {
        lock.withLock {
            guard paused != value else { return }
            paused = value
            if channel != nil { updateVideoRoute() }
        }
    }

    func recordControlRTT(_ milliseconds: Double) {
        lock.withLock { recorder.recordRoundTrip(milliseconds: milliseconds, at: clock()) }
    }

    func recordVideoRTT(_ milliseconds: Double, on source: SessionDataChannel) {
        lock.withLock {
            guard source === channel else { return }
            recorder.recordUDPRoundTrip(milliseconds: milliseconds, at: clock())
        }
    }

    func sample() { lock.withLock { sample(at: clock()) } }

    func detach() {
        lock.withLock {
            sample(at: clock())
            channel = nil
            relaySamples.removeAll()
        }
    }

    func finish(remoteName: String, endpointLabel: String = "", reason: String) -> ConnectionDiagnosticReport {
        lock.withLock {
            let now = clock()
            sample(at: now)
            channel = nil
            relaySamples.removeAll()
            return recorder.finish(remoteName: remoteName, endpointLabel: endpointLabel, reason: reason, at: now)
        }
    }

    private func sample(at now: TimeInterval) {
        guard let channel, now >= sampledAt else { return }
        let current = channel.diagnosticSnapshot()
        var breakdown = DiagnosticTrafficBreakdown()
        breakdown.controlChannel = Self.delta(current.traffic.controlTCP, previous.traffic.controlTCP)
        breakdown.videoChannel = Self.delta(current.traffic.videoTCP, previous.traffic.videoTCP)
        breakdown.bulkChannel = Self.delta(current.traffic.bulkTCP, previous.traffic.bulkTCP)
        var tcp = breakdown.controlChannel
        tcp.merge(breakdown.videoChannel)
        tcp.merge(breakdown.bulkChannel)

        let allUDP = Self.delta(current.traffic.mediaUDP, previous.traffic.mediaUDP)
        let udp = Self.delta(current.traffic.unrelayedMediaUDP, previous.traffic.unrelayedMediaUDP)
        let route = recorder.route
        switch route.control {
        case .direct: breakdown.directTCP = tcp; breakdown.directUDP = udp
        case .relay: breakdown.relayTCP = tcp; breakdown.directUDP = udp
        case .tailnet:
            switch route.tailnetPath {
            case "direct": breakdown.tailnetDirectTCP = tcp; breakdown.tailnetDirectUDP = udp
            case "derp": breakdown.tailnetDERPTCP = tcp; breakdown.tailnetDERPUDP = udp
            default: breakdown.tailnetUnknownTCP = tcp; breakdown.tailnetUnknownUDP = udp
            }
        case .unavailable: break
        }
        breakdown.videoChannel.merge(udp)
        if relaySamples.isEmpty {
            // A relayed UDP channel with no forwarding meter can only be observed at the media layer.
            breakdown.relayUDP = Self.delta(allUDP, udp)
        }
        for index in relaySamples.indices {
            let previous = relaySamples[index].previous
            let relay = relaySamples[index].counter.detailedSnapshot
            breakdown.relayUDP.add(sent: Self.delta(relay.relayedSent, previous.relayedSent),
                                   received: Self.delta(relay.relayedReceived, previous.relayedReceived))
            breakdown.punchedUDP.add(sent: Self.delta(relay.directSent, previous.directSent),
                                     received: Self.delta(relay.directReceived, previous.directReceived))
            relaySamples[index].previous = relay
        }
        breakdown.videoChannel.merge(breakdown.relayUDP)
        breakdown.videoChannel.merge(breakdown.punchedUDP)
        // Throughput and route benchmarks use the same application byte boundary as the live meter.
        var application = tcp
        application.merge(allUDP)
        let legacyBytes = max(0, current.legacyBytes - previous.legacyBytes)
        let (applicationBytes, overflow) = Int(clamping: application.totalBytes).addingReportingOverflow(legacyBytes)
        let seconds = now - sampledAt
        recorder.recordDetailedTraffic(breakdown, frames: current.frames - previous.frames, seconds: seconds, at: now,
                                       applicationBytes: overflow ? .max : applicationBytes,
                                       countsFrameSample: seconds >= Self.minimumFrameSampleSeconds)
        recorder.recordLoss(settled: current.settled - previous.settled, lost: current.lost - previous.lost, at: now)
        previous = current
        sampledAt = now
    }

    private static func delta(_ current: DiagnosticTrafficBucket, _ previous: DiagnosticTrafficBucket) -> DiagnosticTrafficBucket {
        .init(sentBytes: delta(current.sentBytes, previous.sentBytes),
              receivedBytes: delta(current.receivedBytes, previous.receivedBytes))
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func changeRoute(_ route: DiagnosticRoute) {
        guard recorder.route != route else { return }
        let now = clock()
        sample(at: now)
        recorder.changeRoute(route, at: now)
    }

    private func updateVideoRoute() {
        let media: DiagnosticRoute.Media
        var usesNode = controlRelayed
        switch videoPath {
        case .preparing: media = .negotiating
        case .trialUDP(let relayed):
            media = .udpTrial
            usesNode = usesNode || relayed
        case .committed(.shared, _): media = tailnet ? .tailnetCompatibleTCP : (controlRelayed ? .relayCompatibleTCP : .directCompatibleTCP)
        case .committed(.tcp, _): media = tailnet ? .tailnetTCP : (controlRelayed ? .relayTCP : .directTCP)
        case .committed(.udp, let relayed):
            usesNode = usesNode || relayed
            if relayed {
                if case .direct = peerPath { media = .punchedUDP }
                else { media = .relayUDP }
            } else { media = tailnet ? .tailnetUDP : .directUDP }
        }
        changeRoute(DiagnosticRoute(control: tailnet ? .tailnet : (controlRelayed ? .relay : .direct),
            media: paused ? .paused : media, node: usesNode ? node : nil, tailnetPath: tailnetPath))
    }
}
