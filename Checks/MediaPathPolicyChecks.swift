import Foundation
import QuietDeskCore

func runMediaPathPolicyChecks() {
    func sample(duration: TimeInterval = 1, active: Bool = true, count: Int = 60, frames: Int = 60,
                loss: Double? = 0, jitter: Double? = 0, queue: Double? = 0,
                encode: Double? = 4, decode: Double? = 3) -> MediaPathSample {
        MediaPathSample(duration: duration, mediaActive: active, networkSamples: count, decodedFrames: frames,
                        lossFraction: loss, jitterMilliseconds: jitter, queueMilliseconds: queue,
                        encodeMilliseconds: encode, decodeMilliseconds: decode)
    }

    func udp() throws -> MediaPathPolicy {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("Initial probe missing") }
        _ = policy.probeSucceeded(id: id, now: 0.1)
        try check(policy.mediaBecameUsable(epoch: policy.epoch, now: 0.2), "Initial decoded keyframe rejected")
        return policy
    }

    run("Legacy TCP never probes or changes quality through media-path actions") {
        var policy = MediaPathPolicy(capable: false, now: 0)
        try check(policy.tick(now: 0).isEmpty && policy.tick(now: 60).isEmpty, "Legacy peer was probed")
        try check(policy.observe(sample(duration: 3, loss: 1), epoch: 0, now: 63).isEmpty,
                  "Legacy peer enabled adaptive path actions")
        try check(policy.setPaused(true, now: 64).isEmpty && policy.phase == .legacyTCP
                  && policy.activePath == .tcp && policy.targetPath == .tcp, "Legacy default changed")
    }

    run("Initial probing times out at 1.5 seconds and recovery uses bounded exponential backoff") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        let initial = policy.tick(now: 0)
        guard let first = policy.probeID else { throw CheckFailure("No initial probe") }
        try check(initial == [.beginProbe(id: first, timeout: 1.5)] && policy.tick(now: 1.49).isEmpty,
                  "Initial timeout or duplicate probe incorrect")
        try check(policy.tick(now: 1.5) == [.cancelProbe(id: first)] && policy.phase == .tcp
                  && policy.nextRecoveryAt == 31.5, "Initial failure did not keep TCP for 30 seconds")
        try check(policy.probeSucceeded(id: first, now: 2).isEmpty, "Late success changed path")
        var deadline = 31.5
        for delay in [60.0, 120, 300, 300] {
            try check(policy.tick(now: deadline - 0.01).isEmpty, "Recovery ignored cooldown")
            let actions = policy.tick(now: deadline)
            guard let id = policy.probeID else { throw CheckFailure("Recovery probe missing") }
            try check(actions == [.beginProbe(id: id, timeout: 5)], "Recovery did not probe for five seconds")
            _ = policy.tick(now: deadline + 5)
            deadline += 5 + delay
            try check(policy.nextRecoveryAt == deadline, "Recovery delay did not back off to \(delay)")
        }
    }

    run("Path selection waits for a matching decoded epoch and rejects stale probe callbacks") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("No probe") }
        try check(policy.probeSucceeded(id: UUID(), now: 0.1).isEmpty, "Unknown probe succeeded")
        let selected = policy.probeSucceeded(id: id, now: 0.2)
        try check(selected == [.cancelProbe(id: id), .selectPath(.udp, epoch: 1, reason: .initialProbe)]
                  && policy.targetPath == .udp && policy.activePath == .tcp, "UDP became active before decoding")
        try check(!policy.mediaBecameUsable(epoch: 0, now: 0.3) && policy.activePath == .tcp,
                  "Old frame committed a new path")
        try check(policy.mediaBecameUsable(epoch: 1, now: 0.4) && policy.activePath == .udp,
                  "Matching keyframe did not activate UDP")
        try check(policy.probeFailed(id: id, now: 0.5).isEmpty, "Stale probe failure interrupted active media")
    }

    run("UDP liveness uses pongs while static frames and pause do not create media failures") {
        var policy = try udp()
        for time in 1...20 {
            let now = Double(time)
            policy.receivedPong(epoch: policy.epoch, now: now)
            _ = policy.observe(sample(active: false, count: 0, frames: 0), epoch: policy.epoch, now: now)
            try check(policy.tick(now: now).isEmpty && policy.activePath == .udp,
                      "A static desktop was treated as failed media")
        }
        _ = policy.setPaused(true, now: 20)
        try check(policy.tick(now: 1_000).isEmpty, "Intentional pause caused fallback")
        _ = policy.setPaused(false, now: 1_000)
        try check(policy.tick(now: 1_000.99).isEmpty, "Resume inherited a stale liveness timeout")
        let oldEpoch = policy.epoch
        let failed = policy.tick(now: 1_001)
        try check(failed == [.selectPath(.tcp, epoch: oldEpoch + 1, reason: .noPong)]
                  && policy.targetPath == .tcp && policy.activePath == .udp, "Missing pong did not request fast TCP fallback")
        try check(!policy.mediaBecameUsable(epoch: oldEpoch, now: 1_001), "Old decode confirmed fallback")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, now: 1_001) && policy.activePath == .tcp,
                  "Confirmed TCP did not become active")
    }

    run("A successful UDP probe with no complete media cannot pass the media trial") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("No probe") }
        _ = policy.probeSucceeded(id: id, now: 0.1)
        policy.receivedPong(epoch: policy.epoch, now: 1)
        policy.receivedPong(epoch: policy.epoch, now: 2.1)
        try check(policy.tick(now: 2.1) == [.selectPath(.tcp, epoch: 2, reason: .mediaTimeout)],
                  "Pongs alone kept an unusable media path")
    }

    run("Network degradation requires three effective seconds, reduces load, then trials TCP") {
        var policy = try udp()
        var actions: [MediaPathAction] = []
        for step in 1...6 {
            let now = Double(step) + 0.2
            policy.receivedPong(epoch: policy.epoch, now: now)
            actions = policy.observe(sample(loss: 0.1), epoch: policy.epoch, now: now)
            if step < 3 || step == 4 || step == 5 { try check(actions.isEmpty, "Degradation acted before its window") }
            if step == 3 { try check(actions == [.reduceLoad(.network)], "First degraded window did not reduce load") }
        }
        try check(actions == [.selectPath(.tcp, epoch: 2, reason: .networkDegraded)]
                  && policy.phase == .switchingTCP, "Persistent network failure did not trial TCP after load reduction")
        try check(policy.mediaBecameUsable(epoch: 2, now: 6.2) && policy.phase == .tcpTrial,
                  "TCP trial did not wait for usable media")
    }

    run("Encoder and decoder pressure reduce compute load without blaming the UDP path") {
        for cause in [MediaBottleneck.encoder, .decoder] {
            var policy = try udp()
            var reductions = 0
            for step in 1...12 {
                let now = Double(step) + 0.2
                policy.receivedPong(epoch: policy.epoch, now: now)
                let pressure = sample(queue: 200, encode: cause == .encoder ? 30 : 2, decode: cause == .decoder ? 30 : 2)
                let actions = policy.observe(pressure, epoch: policy.epoch, now: now)
                reductions += actions.filter { $0 == .reduceLoad(cause) }.count
                try check(policy.targetPath == .udp && policy.tick(now: now).isEmpty,
                          "Compute pressure was treated as a network path failure")
            }
            try check(reductions == 4, "Compute pressure did not use three-second windows")
        }
    }

    run("A load-reduction reconfiguration pause preserves the subsequent TCP trial decision") {
        var policy = try udp()
        var actions: [MediaPathAction] = []
        for step in 1...3 {
            let now = Double(step) + 0.2
            policy.receivedPong(epoch: policy.epoch, now: now)
            actions = policy.observe(sample(loss: 0.1), epoch: policy.epoch, now: now)
        }
        try check(actions == [.reduceLoad(.network)], "Initial reduction was not requested")
        _ = policy.observe(sample(active: false, count: 0, frames: 0), epoch: policy.epoch, now: 4.2)
        _ = policy.setPaused(true, now: 4.2)
        _ = policy.setPaused(false, now: 10)
        for step in 1...3 {
            let now = 10 + Double(step)
            policy.receivedPong(epoch: policy.epoch, now: now)
            actions = policy.observe(sample(loss: 0.1), epoch: policy.epoch, now: now)
            if step < 3 { try check(actions.isEmpty, "Pause retained the prior bad-time accumulator") }
        }
        try check(actions == [.selectPath(.tcp, epoch: 2, reason: .networkDegraded)],
                  "A configuration pause repeatedly restarted load reduction instead of trying TCP")
    }

    run("Sparse, invalid, duplicate and discontinuous observations cannot manufacture degradation") {
        var policy = try udp()
        let bad = sample(duration: 2, loss: 0.5)
        policy.receivedPong(epoch: 1, now: 2.2)
        try check(policy.observe(bad, epoch: 1, now: 2.2).isEmpty, "Two seconds caused degradation")
        for _ in 0..<100 { try check(policy.observe(bad, epoch: 1, now: 2.2).isEmpty, "Repeated sample accrued time") }
        try check(policy.observe(sample(loss: .nan), epoch: 1, now: 3.2).isEmpty, "NaN entered policy")
        try check(policy.observe(sample(duration: 2, loss: 0.5), epoch: 0, now: 4.2).isEmpty, "Old epoch entered policy")
        try check(policy.observe(sample(loss: 1), epoch: 1, now: 10).isEmpty, "A sampling gap joined old degradation")
        try check(policy.observe(sample(count: 1, loss: 1), epoch: 1, now: 11).isEmpty, "Sparse evidence was used")
        try check(policy.tick(now: .nan).isEmpty && policy.tick(now: 9).isEmpty, "Invalid or reversed clock advanced policy")
    }

    run("Recovery requires cooldown, a fresh probe, usable media and five healthy effective seconds") {
        var policy = try udp()
        _ = policy.tick(now: 1.1)
        try check(policy.mediaBecameUsable(epoch: policy.epoch, now: 1.1), "TCP fallback missing")
        try check(policy.tick(now: 31.09).isEmpty, "Recovery ignored 30-second cooldown")
        _ = policy.tick(now: 31.1)
        guard let id = policy.probeID else { throw CheckFailure("No recovery probe") }
        _ = policy.probeSucceeded(id: id, now: 32)
        try check(policy.activePath == .tcp && policy.phase == .trialUDP, "Probe alone activated UDP")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, now: 32), "New keyframe was rejected")
        for step in 1...30 {
            let now = 32 + Double(step)
            policy.receivedPong(epoch: policy.epoch, now: now)
            _ = policy.observe(sample(), epoch: policy.epoch, now: now)
            if step < 5 { try check(policy.phase == .trialUDP, "Recovery skipped actual media trial") }
            if step == 5 { try check(policy.phase == .udp && policy.recoveryAttempt == 1, "Trial reset backoff too early") }
        }
        try check(policy.phase == .udp && policy.recoveryAttempt == 0, "Sustained healthy UDP did not reset backoff")
    }

    run("Pausing or stopping a probe fences its callbacks and resumes with a different probe identity") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let old = policy.probeID else { throw CheckFailure("No probe") }
        try check(policy.setPaused(true, now: 0.5) == [.cancelProbe(id: old)], "Pause did not cancel its probe")
        try check(policy.probeSucceeded(id: old, now: 1).isEmpty && policy.tick(now: 100).isEmpty,
                  "Paused probe changed state")
        _ = policy.setPaused(false, now: 100)
        guard let current = policy.probeID else { throw CheckFailure("No resumed probe") }
        try check(current != old && policy.probeSucceeded(id: old, now: 100).isEmpty, "Old probe survived resume")
        try check(policy.stop() == [.cancelProbe(id: current)] && policy.stop().isEmpty,
                  "Stop did not cancel exactly once")
        try check(policy.tick(now: 200).isEmpty && policy.probeSucceeded(id: current, now: 200).isEmpty
                  && policy.activePath == nil, "Stopped policy was revived")
    }

    run("Exhausting transport epochs stops the policy instead of reusing epoch zero") {
        var policy = MediaPathPolicy(capable: true, now: 0, initialEpoch: .max)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("No probe at final epoch") }
        try check(policy.probeSucceeded(id: id, now: 0.1) == [.cancelProbe(id: id), .restartSession(reason: .epochExhausted)]
                  && policy.phase == .stopped && policy.epoch == .max && policy.activePath == nil,
                  "Exhausted epoch silently wrapped or selected media")
        try check(policy.stop().isEmpty && policy.tick(now: 1).isEmpty, "Exhausted policy restarted itself")
    }

    run("Media quality starts from saved preference or host default without a latency-based promotion") {
        let host = StreamSettings(longestEdge: 1920, framesPerSecond: 15, megabits: 3)
        let unsaved = try MediaQualityPolicy(hostDefault: host, now: 0)
        try check(unsaved.effective == host && unsaved.upperBound == host && unsaved.preferred == nil,
                  "Host default was promoted to maximum")
        let saved = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 12)
        let restored = try MediaQualityPolicy(hostDefault: host, preferred: saved, now: 0)
        try check(restored.effective == saved && restored.upperBound == saved && restored.preferred == saved,
                  "Saved ceiling was not restored")
    }

    run("Automatic quality recommendations wait for confirmation and never overwrite the preferred ceiling") {
        var quality = try MediaQualityPolicy(hostDefault: .highest, preferred: .highest, now: 0)
        var recommendation: StreamSettings?
        for time in 1...3 { recommendation = quality.observe(sample(loss: 0.1), now: Double(time)) }
        let lower = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        try check(recommendation == lower && quality.pending == lower && quality.effective == .highest,
                  "Recommendation changed actual settings before confirmation")
        try check(quality.preferred == .highest && quality.upperBound == .highest, "Automatic reduction changed preference")
        try check(quality.reduceLoad(for: .network, now: 10) == nil, "A pending request was overlapped")
        try check(!quality.confirmApplied(.init(), now: 10) && quality.pending == lower, "Unrelated reply resolved settings")
        try check(quality.confirmApplied(lower, now: 10) && quality.effective == lower && quality.pending == nil,
                  "Applied settings were not confirmed")
        try check(quality.preferred == .highest, "Confirmation persisted an automatic reduction")
    }

    run("Quality keeps actual applied settings separate from its ceiling and preserves newer pending recommendations") {
        let initial = StreamSettings(longestEdge: 1920, framesPerSecond: 15, megabits: 3)
        let initialQuality = try MediaQualityPolicy(hostDefault: .highest, preferred: .highest, applied: initial, now: 0)
        try check(initialQuality.effective == initial && initialQuality.upperBound == .highest
                  && initialQuality.preferred == .highest && initialQuality.pending == nil,
                  "Initial preference was reported as already applied")
        var quality = try MediaQualityPolicy(hostDefault: .highest, preferred: .highest, now: 0)
        guard let next = quality.reduceLoad(for: .network, now: 3) else { throw CheckFailure("No recommendation") }
        let previous = StreamSettings(longestEdge: 3840, framesPerSecond: 30, megabits: 30)
        try quality.synchronizeApplied(previous, now: 4)
        try check(quality.effective == previous && quality.pending == next
                  && quality.preferred == .highest && quality.upperBound == .highest,
                  "An older unmatched reply cleared a newer recommendation or changed preference")
        try quality.synchronizeApplied(next, now: 5)
        try check(quality.effective == next && quality.pending == nil && quality.upperBound == .highest,
                  "A matching actual update did not clear its recommendation")
        try rejects("Invalid actual settings were synchronized") {
            try quality.synchronizeApplied(StreamSettings(framesPerSecond: 999), now: 6)
        }
        try check(quality.effective == next, "Invalid actual settings replaced the confirmed state")
    }

    run("Compute adaptation reduces actual pixel load while network adaptation reduces bitrate first") {
        var compute = try MediaQualityPolicy(hostDefault: .highest, sourceLongestEdge: 1920, now: 0)
        let reduced = compute.reduceLoad(for: .encoder, now: 3)
        try check(reduced?.longestEdge == 1280 && reduced?.framesPerSecond == 60 && reduced?.megabits == 100,
                  "Compute adaptation wasted steps above the source size or reduced smoothness first")
        var network = try MediaQualityPolicy(hostDefault: .highest, sourceLongestEdge: 1920, now: 0)
        let networkReduced = network.reduceLoad(for: .network, now: 3)
        try check(networkReduced?.megabits == 60 && networkReduced?.longestEdge == 8192,
                  "Network adaptation changed pixels before bitrate")
    }

    run("Quality recovery requires decoded healthy windows and never exceeds manual limits") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, now: 0)
        guard let lower = quality.reduceLoad(for: .network, now: 3) else { throw CheckFailure("No reduction") }
        _ = quality.confirmApplied(lower, now: 3)
        for time in 4...20 {
            try check(quality.observe(sample(active: false, count: 0, frames: 0), now: Double(time)) == nil,
                      "Static time recovered quality")
        }
        var recovery: StreamSettings?
        for time in 21...30 { recovery = quality.observe(sample(), now: Double(time)) }
        try check(recovery == ceiling && quality.preferred == ceiling, "Healthy recovery changed its ceiling")
        _ = quality.confirmApplied(ceiling, now: 30)
        for time in 31...50 { try check(quality.observe(sample(), now: Double(time)) == nil, "Quality exceeded ceiling") }
        let manual = StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 3)
        try check(try quality.chooseManually(manual, now: 51) == manual && quality.upperBound == manual,
                  "Manual setting did not replace the ceiling")
        _ = quality.confirmApplied(manual, now: 51)
        for time in 52...70 { try check(quality.observe(sample(), now: Double(time)) == nil, "Automatic quality exceeded manual choice") }
    }

    run("Invalid measurements, rejected requests and suspension cannot accumulate quality changes") {
        var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        try check(quality.observe(sample(duration: 3, loss: .nan), now: 3) == nil, "NaN adapted quality")
        try check(quality.observe(sample(duration: 3, count: 1, loss: 1), now: 6) == nil, "Sparse network sample adapted quality")
        let proposed = quality.reduceLoad(for: .network, now: 6)
        try check(proposed != nil, "Direct recommendation missing")
        quality.rejectPending(now: 6)
        try check(quality.pending == nil && quality.effective == .highest
                  && quality.reduceLoad(for: .network, now: 8) == nil, "Rejection changed actual quality or skipped cooldown")
        _ = quality.observe(sample(duration: 2, loss: 1), now: 8)
        quality.resetObservation(now: 20)
        try check(quality.observe(sample(loss: 1), now: 21) == nil, "Suspension retained degradation time")
        try rejects("Invalid settings were accepted") {
            _ = try MediaQualityPolicy(hostDefault: StreamSettings(framesPerSecond: 999), now: 0)
        }
    }
}
