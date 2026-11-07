import Foundation
import QuietDeskCore

/// The viewer's timer and the media queue share one ordering for route boundaries and counter samples.
final class ViewerConnectionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let recorder: ConnectionDiagnosticRecorder
    private var channel: SessionDataChannel?
    private var previous = (bytes: 0, frames: 0, settled: 0, lost: 0)
    private var sampledAt: TimeInterval
    private var controlRelayed = false
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

    func attach(_ channel: SessionDataChannel, relayed: Bool, node: String?) {
        lock.withLock {
            controlRelayed = relayed
            self.node = node
            videoPath = .preparing
            peerPath = .relay
            paused = false
            updateVideoRoute()
            self.channel = channel
            // Each authenticated attempt has a fresh channel. Its hello may already be in the counter.
            previous = (0, 0, 0, 0)
            sampledAt = clock()
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
        }
    }

    func finish(remoteName: String, reason: String) -> ConnectionDiagnosticReport {
        lock.withLock {
            let now = clock()
            sample(at: now)
            channel = nil
            return recorder.finish(remoteName: remoteName, reason: reason, at: now)
        }
    }

    private func sample(at now: TimeInterval) {
        guard let channel, now > sampledAt else { return }
        let current = channel.metricsSnapshot()
        recorder.recordTraffic(bytes: current.bytes - previous.bytes, frames: current.frames - previous.frames,
                               seconds: now - sampledAt, at: now)
        recorder.recordLoss(settled: current.settled - previous.settled, lost: current.lost - previous.lost, at: now)
        previous = current
        sampledAt = now
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
        case .committed(.shared, _): media = controlRelayed ? .relayCompatibleTCP : .directCompatibleTCP
        case .committed(.tcp, _): media = controlRelayed ? .relayTCP : .directTCP
        case .committed(.udp, let relayed):
            usesNode = usesNode || relayed
            if !relayed { media = .directUDP }
            else if case .direct = peerPath { media = .punchedUDP }
            else { media = .relayUDP }
        }
        changeRoute(DiagnosticRoute(control: controlRelayed ? .relay : .direct,
            media: paused ? .paused : media, node: usesNode ? node : nil))
    }
}
