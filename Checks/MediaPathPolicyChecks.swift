import Foundation
import QuietDeskCore

func runMediaPathPolicyChecks() {
    func sample(duration: TimeInterval = 1, active: Bool = true, count: Int = 60, frames: Int = 60,
                loss: Double? = 0, jitter: Double? = 0, queue: Double? = 0,
                encode: Double? = 4, decode: Double? = 3, delivery: Double? = nil, received: Double? = 1_000) -> MediaPathSample {
        MediaPathSample(duration: duration, mediaActive: active, networkSamples: count, decodedFrames: frames,
                        lossFraction: loss, jitterMilliseconds: jitter, queueMilliseconds: queue,
                        encodeMilliseconds: encode, decodeMilliseconds: decode,
                        deliveryMilliseconds: delivery, receivedMegabits: received)
    }

    run("Adaptive quality reduces and restores higher rates without replacing the user's ceiling") {
        let ceiling = StreamSettings(longestEdge: 1280, framesPerSecond: 240, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (1280, 720), now: 0)
        var time = 0.0
        for rate in [165, 144, 120, 90, 75, 60] {
            time += 3
            guard let next = quality.reduceLoad(for: .encoder, now: time) else { throw CheckFailure("No compute reduction") }
            try check(next.framesPerSecond == rate, "Higher-rate reduction skipped its next supported step")
            try check(quality.confirmApplied(next, now: time), "Reduced rate was not applied")
        }
        while time < 120, quality.effective != ceiling {
            time += 1
            if let next = quality.observe(sample(frames: 240, encode: 1, decode: 1), now: time) {
                try check(next.framesPerSecond <= 240 && StreamSettings.frameRates.contains(next.framesPerSecond),
                          "Recovery exceeded the chosen ceiling or selected an unsupported rate")
                _ = quality.confirmApplied(next, now: time)
            }
        }
        try check(quality.effective == ceiling && quality.upperBound == ceiling && quality.preferred == ceiling,
                  "Recovery failed to restore the chosen higher rate or overwrote the preference")
    }

    func udp() throws -> MediaPathPolicy {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("Initial probe missing") }
        _ = policy.probeSucceeded(id: id, now: 0.1)
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .udp, now: 0.2), "Initial decoded keyframe rejected")
        return policy
    }

    run("Alternate delivery-failure probes are single-use, pause-safe and retain later cooldown") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        let initial = policy.probeID!
        _ = policy.probeFailed(id: initial, now: 1)
        let cooldown = policy.nextRecoveryAt
        _ = policy.setPaused(true, now: 2)
        try check(policy.probeAlternateRoute(now: 3).isEmpty, "Paused alternate probe started")
        _ = policy.setPaused(false, now: 4)
        let actions = policy.probeAlternateRoute(now: 5)
        try check(!actions.isEmpty && policy.probeID != nil && policy.activePath == .tcp, "Alternate bypass lost active TCP")
        let alternate = policy.probeID!
        _ = policy.probeFailed(id: alternate, now: 6)
        try check(policy.nextRecoveryAt! > cooldown!, "Alternate failure reset backoff")
        try check(policy.probeAlternateRoute(now: 7).isEmpty && policy.tick(now: 20).isEmpty, "Repeated failure bypassed cooldown")
        _ = policy.stop()
        try check(policy.probeSucceeded(id: alternate, now: 21).isEmpty && policy.probeAlternateRoute(now: 22).isEmpty, "Late probe revived stopped session")
        var reliable = MediaPathPolicy(capable: false, now: 0)
        try check(reliable.probeAlternateRoute(now: 1).isEmpty, "TCP-only started UDP relay")
        var relayed = MediaPathPolicy(capable: true, now: 0, initialProbeTimeout: 5)
        _ = relayed.tick(now: 0)
        try check(relayed.tick(now: 2).isEmpty && relayed.probeID != nil, "Relay TLS setup inherited the direct-only deadline")
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
        try check(!policy.mediaBecameUsable(epoch: 0, path: .udp, now: 0.3) && policy.activePath == .tcp,
                  "Old frame committed a new path")
        try check(policy.mediaBecameUsable(epoch: 1, path: .udp, now: 0.4) && policy.activePath == .udp,
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
        try check(!policy.mediaBecameUsable(epoch: oldEpoch, path: .tcp, now: 1_001), "Old decode confirmed fallback")
        try check(!policy.mediaBecameUsable(epoch: policy.epoch, path: .udp, now: 1_001) && policy.phase == .switchingTCP,
                  "A late UDP keyframe confirmed the TCP fallback")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .tcp, now: 1_001) && policy.activePath == .tcp,
                  "Confirmed TCP did not become active")
    }

    run("A successful UDP probe with no complete media cannot pass the media trial") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let id = policy.probeID else { throw CheckFailure("No probe") }
        _ = policy.probeSucceeded(id: id, now: 0.1)
        policy.receivedPong(epoch: policy.epoch, now: 1)
        policy.receivedPong(epoch: policy.epoch, now: 2.1)
        try check(policy.tick(now: 2.1) == [.reduceLoad(.network), .retryUDP] && policy.targetPath == .udp,
                  "A silent UDP trial was not retried at a lower quality")
        // The retry gets its own trial window after the retry delay.
        policy.receivedPong(epoch: policy.epoch, now: 3); policy.receivedPong(epoch: policy.epoch, now: 3.9)
        try check(policy.tick(now: 4.0).isEmpty, "The retried trial was judged before its own window")
        policy.receivedPong(epoch: policy.epoch, now: 4.9)
        try check(policy.tick(now: 5.25) == [.reduceLoad(.network), .retryUDP], "A second silent trial was not retried")
        policy.receivedPong(epoch: policy.epoch, now: 6); policy.receivedPong(epoch: policy.epoch, now: 7); policy.receivedPong(epoch: policy.epoch, now: 8)
        try check(policy.tick(now: 8.5) == [.selectPath(.tcp, epoch: 2, reason: .mediaTimeout)],
                  "Pongs alone kept an unusable media path after repeated attempts")
    }
    run("Failed UDP media retries UDP at lower quality and falls back to TCP only after repeated failures") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        try check(policy.mediaFailed(epoch: 0, now: 0).isEmpty, "Initial preparation failure selected a path")
        _ = policy.tick(now: 0)
        try check(policy.mediaFailed(epoch: 0, now: 0.1).isEmpty, "Probe-stage failure was treated as media failure")
        guard let id = policy.probeID else { throw CheckFailure("No probe") }
        _ = policy.probeSucceeded(id: id, now: 0.2)
        let failedEpoch = policy.epoch
        try check(policy.mediaFailed(epoch: failedEpoch - 1, now: 0.3).isEmpty, "A stale media failure changed the path")
        try check(policy.mediaFailed(epoch: failedEpoch, now: 0.4) == [.retryUDP] && policy.udpMediaFailures == 1,
                  "A first UDP media failure did not retry UDP")
        try check(policy.mediaFailed(epoch: failedEpoch, now: 1.4) == [.retryUDP], "A second UDP media failure left UDP")
        let actions = policy.mediaFailed(epoch: failedEpoch, now: 2.4)
        try check(actions == [.selectPath(.tcp, epoch: failedEpoch + 1, reason: .mediaTimeout)]
                  && policy.nextRecoveryAt == 32.4 && policy.recoveryAttempt == 1,
                  "Repeated UDP media failures did not enter TCP cooldown")
        try check(policy.mediaFailed(epoch: failedEpoch, now: 2.5).isEmpty, "A repeated failure selected another epoch")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .tcp, now: 2.6), "TCP fallback could not commit")
        try check(policy.tick(now: 32.39).isEmpty, "Media failure skipped recovery cooldown")
        try check(policy.tick(now: 32.4).count == 1 && policy.phase == .probingRecovery,
                  "Media failure did not allow a later bounded recovery probe")
        var paused = try udp()
        _ = paused.setPaused(true, now: 1)
        try check(paused.mediaFailed(epoch: paused.epoch, now: 2).isEmpty, "Paused media was treated as a failed path")
        var legacy = MediaPathPolicy(capable: false, now: 0)
        try check(legacy.mediaFailed(epoch: 0, now: 1).isEmpty, "Legacy mode entered media recovery")
        // Committed UDP video in between proves the path again, so isolated failures never accumulate into TCP.
        var stable = try udp()
        for round in 0..<6 {
            let now = Double(round) * 10 + 1
            try check(stable.mediaFailed(epoch: stable.epoch, now: now) == [.retryUDP], "An isolated failure left UDP")
            try check(stable.mediaBecameUsable(epoch: stable.epoch, path: .udp, now: now + 1) || stable.phase == .udp || stable.phase == .trialUDP,
                      "Recovered UDP video was not accepted")
        }
        try check(stable.targetPath == .udp && stable.udpMediaFailures == 0, "Recovered failures still counted toward TCP")
        // A UDP trial started from TCP: recoveries committed on TCP between its retries keep the picture,
        // but neither prove UDP nor clear its failures, and each one gives the next UDP attempt its full window.
        var recovering = try udp()
        _ = recovering.tick(now: 1.1)
        _ = recovering.mediaBecameUsable(epoch: recovering.epoch, path: .tcp, now: 1.1)
        _ = recovering.tick(now: 31.1)
        guard let recoveryProbe = recovering.probeID else { throw CheckFailure("No recovery probe") }
        _ = recovering.probeSucceeded(id: recoveryProbe, now: 32)
        try check(recovering.mediaFailed(epoch: recovering.epoch, now: 32.5) == [.retryUDP] && recovering.udpMediaFailures == 1,
                  "A failed UDP keyframe during recovery did not retry UDP")
        for second in 33...35 { recovering.receivedPong(epoch: recovering.epoch, now: Double(second)) }
        try check(!recovering.mediaBecameUsable(epoch: recovering.epoch, path: .tcp, now: 35)
                  && recovering.udpMediaFailures == 1 && recovering.activePath == .tcp && recovering.phase == .trialUDP,
                  "A recovery committed on TCP counted as UDP video")
        recovering.receivedPong(epoch: recovering.epoch, now: 36)
        try check(recovering.tick(now: 36.5).isEmpty, "A TCP recovery that delayed the UDP retry cut its trial window short")
        recovering.receivedPong(epoch: recovering.epoch, now: 37)
        try check(recovering.tick(now: 37.1) == [.reduceLoad(.network), .retryUDP] && recovering.udpMediaFailures == 2,
                  "A silent UDP retry after a TCP recovery was not counted")
        let recoveringEpoch = recovering.epoch
        try check(recovering.mediaFailed(epoch: recoveringEpoch, now: 37.5) == [.selectPath(.tcp, epoch: recoveringEpoch + 1, reason: .mediaTimeout)],
                  "TCP recoveries between UDP retries let UDP keep failing past the limit")
    }
    run("Network degradation never changes the path; quality adaptation owns it") {
        var policy = try udp()
        for step in 1...20 {
            let now = Double(step) + 0.2
            policy.receivedPong(epoch: policy.epoch, now: now)
            try check(policy.observe(sample(loss: 0.3, delivery: 900), epoch: policy.epoch, now: now).isEmpty,
                      "Network degradation produced a path action")
        }
        try check(policy.targetPath == .udp && policy.phase == .trialUDP, "A degraded but working UDP path was abandoned")
        // Healthy windows still promote the trial once degradation clears.
        for step in 21...26 {
            let now = Double(step) + 0.2
            policy.receivedPong(epoch: policy.epoch, now: now)
            _ = policy.observe(sample(), epoch: policy.epoch, now: now)
        }
        try check(policy.phase == .udp, "Healthy UDP media did not pass its trial after degradation cleared")
    }
    run("Encoder and decoder pressure never touch the UDP path; quality adaptation lowers the load from the same sample") {
        for cause in [MediaBottleneck.encoder, .decoder] {
            var policy = try udp()
            let pressure = sample(queue: 200, encode: cause == .encoder ? 30 : 2, decode: cause == .decoder ? 30 : 2)
            for step in 1...12 {
                let now = Double(step) + 0.2
                policy.receivedPong(epoch: policy.epoch, now: now)
                try check(policy.observe(pressure, epoch: policy.epoch, now: now).isEmpty, "The path policy acted on compute pressure")
                try check(policy.targetPath == .udp && policy.tick(now: now).isEmpty,
                          "Compute pressure was treated as a network path failure")
            }
            var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
            var reduced: StreamSettings?
            for step in 1...3 { reduced = quality.observe(pressure, now: Double(step)) }
            try check(reduced != nil && quality.lastAdjustment == .compute(cause, milliseconds: 30),
                      "Quality adaptation did not lower the load with the measured codec time")
        }
    }

    run("UDP liveness loss still falls back to TCP, so a broken UDP path cannot stall video") {
        var policy = try udp()
        policy.receivedPong(epoch: policy.epoch, now: 1)
        try check(policy.tick(now: 1.9).isEmpty, "Liveness failed before one second without pongs")
        try check(policy.tick(now: 2.0) == [.selectPath(.tcp, epoch: 2, reason: .noPong)], "Lost UDP liveness kept UDP")
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
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .tcp, now: 1.1), "TCP fallback missing")
        try check(policy.tick(now: 31.09).isEmpty, "Recovery ignored 30-second cooldown")
        _ = policy.tick(now: 31.1)
        guard let id = policy.probeID else { throw CheckFailure("No recovery probe") }
        _ = policy.probeSucceeded(id: id, now: 32)
        try check(policy.activePath == .tcp && policy.phase == .trialUDP, "Probe alone activated UDP")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .udp, now: 32), "New keyframe was rejected")
        for step in 1...30 {
            let now = 32 + Double(step)
            policy.receivedPong(epoch: policy.epoch, now: now)
            _ = policy.observe(sample(), epoch: policy.epoch, now: now)
            if step < 5 { try check(policy.phase == .trialUDP, "Recovery skipped actual media trial") }
            if step == 5 { try check(policy.phase == .udp && policy.recoveryAttempt == 1, "Trial reset backoff too early") }
        }
        // Thirty healthy seconds are not proof: the logged relay alternated about once a minute this way.
        try check(policy.phase == .udp && policy.recoveryAttempt == 1, "A short healthy UDP run reset backoff")
        _ = policy.tick(now: 63.5)
        try check(policy.targetPath == .tcp && policy.recoveryAttempt == 2 && policy.nextRecoveryAt == 123.5,
                  "A UDP route that failed after a minute did not escalate its backoff")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .tcp, now: 63.6), "Second TCP fallback missing")
        _ = policy.tick(now: 123.5)
        guard let second = policy.probeID else { throw CheckFailure("No second recovery probe") }
        _ = policy.probeSucceeded(id: second, now: 124)
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .udp, now: 124), "Recovered keyframe was rejected")
        for step in 1...300 {
            let now = 124 + Double(step)
            policy.receivedPong(epoch: policy.epoch, now: now)
            _ = policy.observe(sample(active: step % 60 != 0), epoch: policy.epoch, now: now)
        }
        try check(policy.recoveryAttempt == 2, "Backoff reset before UDP lasted five minutes")
        _ = policy.tick(now: 425.5)
        try check(policy.targetPath == .tcp && policy.recoveryAttempt == 1 && policy.nextRecoveryAt == 455.5,
                  "UDP that lasted five minutes, including static moments, did not earn a fresh backoff")
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
        try check(quality.observe(sample(loss: 0.1), now: 0.5) == nil, "A loss window changed quality right after a change")
        let recommendation = quality.observe(sample(loss: 0.1), now: 1.5)
        // Severe loss halves the bitrate; at 8K-class sizes 30 Mbps is below the readable floor for 60 fps.
        let lower = StreamSettings(longestEdge: 8192, framesPerSecond: 30, megabits: 30)
        try check(recommendation == lower && quality.pending == lower && quality.effective == .highest,
                  "Recommendation changed actual settings before confirmation: \(String(describing: recommendation))")
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

    run("Without a measured codec time, compute adaptation reduces actual pixel load; network adaptation reduces bitrate first") {
        var compute = try MediaQualityPolicy(hostDefault: .highest, sourceLongestEdge: 1920, now: 0)
        let reduced = compute.reduceLoad(for: .encoder, now: 3)
        try check(reduced?.longestEdge == 1280 && reduced?.framesPerSecond == 60 && reduced?.megabits == 100,
                  "Compute adaptation wasted steps above the source size or reduced smoothness first")
        var network = try MediaQualityPolicy(hostDefault: .highest, sourceLongestEdge: 1920, now: 0)
        let networkReduced = network.reduceLoad(for: .network, now: 3)
        try check(networkReduced?.megabits == 60 && networkReduced?.longestEdge == 8192,
                  "Network adaptation changed pixels before bitrate")
    }

    run("Quality recovery requires decoded healthy windows that used the bitrate and never exceeds manual limits") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, now: 0)
        guard let lower = quality.reduceLoad(for: .network, now: 3) else { throw CheckFailure("No reduction") }
        try check(lower == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 5), "Congestion did not lower bitrate first")
        _ = quality.confirmApplied(lower, now: 3)
        for time in 4...20 {
            try check(quality.observe(sample(active: false, count: 0, frames: 0), now: Double(time)) == nil,
                      "Static time recovered quality")
        }
        for time in 21...40 {
            try check(quality.observe(sample(received: 1), now: Double(time)) == nil, "A quiet screen proved a higher bitrate")
        }
        var recovery: StreamSettings?
        for time in 41...50 where recovery == nil { recovery = quality.observe(sample(), now: Double(time)) }
        try check(recovery == ceiling && quality.preferred == ceiling, "Healthy recovery changed its ceiling")
        _ = quality.confirmApplied(ceiling, now: 50)
        for time in 51...70 { try check(quality.observe(sample(), now: Double(time)) == nil, "Quality exceeded ceiling") }
        let manual = StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 3)
        try check(try quality.chooseManually(manual, now: 71) == manual && quality.upperBound == manual,
                  "Manual setting did not replace the ceiling")
        _ = quality.confirmApplied(manual, now: 71)
        for time in 72...90 { try check(quality.observe(sample(), now: Double(time)) == nil, "Automatic quality exceeded manual choice") }
    }
    run("Media path switch causes keep unique, stable diagnostic codes") {
        let reasons: [MediaPathReason] = [.initialProbe, .recoveryProbe, .probeTimeout, .probeFailed,
                                          .noPong, .mediaTimeout, .networkDegraded, .epochExhausted]
        let causes: [MediaSwitchCause] = [.initial, .recovery, .retry, .auxiliaryClosed] + reasons.map { .policy($0) }
        try check(causes.map(\.diagnosticCode) == [1, 2, 3, 4, 10, 11, 12, 13, 14, 15, 16, 17],
                  "Logged path switch codes changed meaning")
    }

    run("Compute pressure uses window means, so decode bursts or one slow keyframe keep the current quality") {
        // Three frames queued behind each other twice, then one slow keyframe: the maximum exceeds a 60 fps budget.
        var burst = MediaComputeTiming()
        for value in [4.0, 9, 14, 4, 9, 14, 40] { burst.add(value) }
        var sustained = MediaComputeTiming()
        for _ in 0..<60 { sustained.add(18) }
        var invalid = MediaComputeTiming()
        invalid.add(.nan); invalid.add(-1)
        try check(MediaComputeTiming().mean == nil && invalid.mean == nil, "Missing or invalid timings produced a mean")
        var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        for time in 1...6 {
            try check(quality.observe(sample(encode: burst.mean, decode: burst.mean), now: Double(time)) == nil,
                      "Bursty but sustainable codec timing reduced quality")
        }
        // 18 ms is inside the 10% margin over a 60 fps frame; 21 ms is over it, and too slow for 50 fps at the floor.
        for time in 7...12 {
            try check(quality.observe(sample(encode: sustained.mean), now: Double(time)) == nil,
                      "An encoder just over the frame interval reduced quality")
        }
        var slower = MediaComputeTiming()
        for _ in 0..<60 { slower.add(21) }
        var reduction: StreamSettings?
        for time in 13...15 { reduction = quality.observe(sample(encode: slower.mean), now: Double(time)) }
        try check(reduction?.longestEdge == 3840, "Sustained encode cost too slow for the floor rate did not reduce pixels")
    }

    func codec(fps: Int, encode: Double?, decode: Double? = 2) -> MediaPathSample {
        MediaPathSample(duration: 1, mediaActive: true, networkSamples: 60, decodedFrames: fps, lossFraction: 0,
                        jitterMilliseconds: 0, queueMilliseconds: 0, encodeMilliseconds: encode, decodeMilliseconds: decode,
                        frameBudgetMilliseconds: 1_000 / Double(fps), receivedMegabits: 1_000)
    }

    run("At 120 fps an encoder needing 10 ms per frame keeps the full size and settles at 90 fps without oscillating") {
        // The reported case: a 3456 × 2234 host at original size, 120 fps and 100 Mbps over a clean relay.
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        var time = 0.0, changes: [StreamSettings] = []
        while time < 600 {
            time += 1
            if let next = quality.observe(codec(fps: quality.effective.framesPerSecond, encode: 10), now: time) {
                changes.append(next)
                try check(quality.confirmApplied(next, now: time), "Reduction was not applied")
            }
        }
        try check(changes == [StreamSettings(longestEdge: 8192, framesPerSecond: 90, megabits: 100)],
                  "A 10 ms encoder did not settle at the full size and 90 fps: \(changes)")
        try check(quality.lastAdjustment == .compute(.encoder, milliseconds: 10), "The cause of the reduction was not kept")
        // Both over the limit: the slower decoder is named with its own time.
        var both = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        for time in 1...3 { _ = both.observe(codec(fps: 120, encode: 10, decode: 12), now: Double(time)) }
        try check(both.lastAdjustment == .compute(.decoder, milliseconds: 12) && both.pending?.framesPerSecond == 75,
                  "The slower codec was not the one named or used")
        try check(MediaPathSample(duration: 1, mediaActive: true, networkSamples: 0, decodedFrames: 0,
                                  encodeMilliseconds: 6, decodeMilliseconds: 9).computeMilliseconds == 9
                  && codec(fps: 60, encode: nil, decode: 4).computeMilliseconds == 4
                  && codec(fps: 60, encode: nil, decode: nil).computeMilliseconds == nil, "The slower codec time was not used")
    }

    run("An encoder just over the frame interval delivers a few frames fewer and keeps the quality") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        for time in 1...30 {
            try check(quality.observe(codec(fps: 120, encode: 9.1), now: Double(time)) == nil, "9.1 ms at 120 fps reduced quality")
        }
        var reduced: StreamSettings?
        for time in 31...33 { reduced = quality.observe(codec(fps: 120, encode: 9.2), now: Double(time)) }
        try check(reduced?.framesPerSecond == 90 && reduced?.longestEdge == 8192, "10% over the frame interval did not lower the rate")
    }

    run("Near the 60 fps floor the size stays; clearly short of it, one size step drops and is not retried before the longest hold") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        var time = 0.0
        var first: StreamSettings?
        while first == nil, time < 10 { time += 1; first = quality.observe(codec(fps: 120, encode: 19), now: time) }
        // 19 ms sustains about 53 fps: straight to the 60 fps floor, keeping the size.
        try check(first == StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100), "Rate did not drop straight to the floor")
        _ = quality.confirmApplied(first!, now: time)
        for _ in 0..<30 {
            time += 1
            try check(quality.observe(codec(fps: 60, encode: 19), now: time) == nil, "About 53 of 60 fps reduced the size")
        }
        var reduced: StreamSettings?
        while reduced == nil, time < 60 { time += 1; reduced = quality.observe(codec(fps: 60, encode: 25), now: time) }
        try check(reduced == StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 100),
                  "40 fps at the floor did not drop one size step: \(String(describing: reduced))")
        _ = quality.confirmApplied(reduced!, now: time)
        try check(quality.lastAdjustment == .compute(.encoder, milliseconds: 25), "The size reduction lost its cause")
        let reducedAt = time
        // 2560 encodes in 13 ms: sustainable at 60 fps, without the headroom 75 fps needs.
        while time < reducedAt + MediaQualityPolicy.maximumUpgradeHold - 1 {
            time += 1
            try check(quality.observe(codec(fps: 60, encode: 13), now: time) == nil,
                      "A size measured too slow was retried, or the rate rose without headroom")
        }
        var retried: StreamSettings?
        while retried == nil, time < reducedAt + 400 { time += 1; retried = quality.observe(codec(fps: 60, encode: 13), now: time) }
        try check(retried?.longestEdge == 3840 && time == reducedAt + MediaQualityPolicy.maximumUpgradeHold,
                  "The slow size did not return once the longest hold passed")
        try check(quality.lastAdjustment == .raise, "The upgrade was not reported as one")
    }

    run("A chosen frame rate below 60 is its own floor, and raising the rate needs room in the measured codec time") {
        let low = StreamSettings(longestEdge: 8192, framesPerSecond: 30, megabits: 100)
        var thirty = try MediaQualityPolicy(hostDefault: low, preferred: low, appliedSize: (3456, 2234), now: 0)
        for time in 1...10 {
            try check(thirty.observe(codec(fps: 30, encode: 35), now: Double(time)) == nil, "About 29 of 30 fps reduced quality")
        }
        var reduced: StreamSettings?
        for time in 11...13 { reduced = thirty.observe(codec(fps: 30, encode: 40), now: Double(time)) }
        try check(reduced == StreamSettings(longestEdge: 2560, framesPerSecond: 30, megabits: 100),
                  "25 of a chosen 30 fps did not drop one size step")

        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        let applied = StreamSettings(longestEdge: 8192, framesPerSecond: 90, megabits: 100)
        var crowded = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: applied, appliedSize: (3456, 2234), now: 0)
        for time in 1...120 {
            try check(crowded.observe(codec(fps: 90, encode: 8), now: Double(time)) == nil, "120 fps was tried without codec headroom")
        }
        var roomy = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: applied, appliedSize: (3456, 2234), now: 0)
        var raised: StreamSettings?, time = 0
        while raised == nil, time < 60 { time += 1; raised = roomy.observe(codec(fps: 90, encode: 6), now: Double(time)) }
        try check(raised?.framesPerSecond == 120 && time == Int(MediaQualityPolicy.initialUpgradeHold),
                  "A codec with headroom did not return to 120 fps after the usual hold")
        var network = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        _ = network.reduceLoad(for: .network, now: 3)
        try check(network.lastAdjustment == .network, "A network reduction was not reported as one")
    }

    run("Quality upgrades that fail soon after applying back off exponentially until one proves stable") {
        let ceiling = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 30)
        let reduced = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 30)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: reduced, now: 0)
        var time = 0.0
        // Healthy one-second windows until the next level is applied; returns the healthy time it needed.
        func upgrade() throws -> Double {
            let started = time
            while time - started < 400 {
                time += 1
                if let next = quality.observe(sample(), now: time) {
                    try check(next == ceiling && quality.confirmApplied(next, now: time), "Upgrade was not applied")
                    return time - started
                }
            }
            throw CheckFailure("No upgrade within 400 seconds")
        }
        // Overload without a measured codec time (failed decodes): a measured one also keeps the size it
        // left from returning before the longest hold, which the next check covers.
        func overload() throws {
            let before = quality.effective
            for _ in 0..<10 {
                time += 1
                if let next = quality.reduceLoad(for: .decoder, now: time) {
                    try check(next.longestEdge < before.longestEdge && quality.confirmApplied(next, now: time),
                              "Decoder failures did not reduce pixels")
                    return
                }
            }
            throw CheckFailure("Decoder failures did not reduce quality")
        }
        // Each 2560 upgrade overloads within seconds and returns to 1920.
        var holds: [Double] = []
        for _ in 0..<7 { holds.append(try upgrade()); try overload() }
        try check(holds == [10, 20, 40, 80, 160, 300, 300], "Failed upgrades did not back off exponentially: \(holds)")
        try check(try upgrade() == 300, "Backoff did not stay at its maximum")
        for _ in 0..<30 { time += 1; try check(quality.observe(sample(), now: time) == nil, "Quality exceeded its ceiling") }
        try check(quality.upgradeHold == MediaQualityPolicy.initialUpgradeHold, "An upgrade that survived probation kept the long hold")
        try overload()
        try check(try upgrade() == 10, "Pressure after a proven upgrade inherited the old backoff")
        try overload(); _ = try upgrade(); try overload()
        try check(quality.upgradeHold == 40, "Renewed failures did not back off again")
        try check(try quality.chooseManually(ceiling, now: time) == ceiling && quality.confirmApplied(ceiling, now: time)
                  && quality.upgradeHold == MediaQualityPolicy.initialUpgradeHold, "A manual choice kept the automatic backoff")
        // A host-rejected upgrade never applied, so the next reduction is not counted as its failure.
        try overload()
        var proposal: StreamSettings?
        for _ in 0..<20 where proposal == nil { time += 1; proposal = quality.observe(sample(), now: time) }
        try check(proposal == ceiling, "Healthy windows did not propose an upgrade")
        quality.rejectPending(now: time)
        try overload()
        try check(quality.upgradeHold == MediaQualityPolicy.initialUpgradeHold, "A rejected upgrade was counted as failed")
    }

    run("Invalid measurements, rejected requests and suspension cannot accumulate quality changes") {
        var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        try check(quality.observe(sample(duration: 3, loss: .nan), now: 3) == nil, "NaN adapted quality")
        try check(quality.observe(sample(duration: 3, count: 1, loss: 1), now: 6) == nil, "Sparse network sample adapted quality")
        let proposed = quality.reduceLoad(for: .network, now: 6)
        try check(proposed != nil, "Direct recommendation missing")
        quality.rejectPending(now: 6)
        try check(quality.pending == nil && quality.effective == .highest
                  && quality.reduceLoad(for: .network, now: 7) == nil, "Rejection changed actual quality or skipped spacing")
        try check(quality.observe(sample(loss: 0.05), now: 9) == nil, "One congested window changed quality")
        quality.resetObservation(now: 20)
        try check(quality.observe(sample(loss: 0.05), now: 21) == nil, "Suspension retained congestion time")
        try rejects("Invalid settings were accepted") {
            _ = try MediaQualityPolicy(hostDefault: StreamSettings(framesPerSecond: 999), now: 0)
        }
    }

    run("Network adaptation trims bitrate on congestion, halves it on severe loss and keeps text readable") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 30)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1920, 1240), now: 0)
        try check(quality.observe(sample(loss: 0.05), now: 3) == nil, "One congested window changed quality")
        let trimmed = quality.observe(sample(loss: 0.05), now: 4)
        try check(trimmed == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20), "Congestion did not trim bitrate: \(String(describing: trimmed))")
        _ = quality.confirmApplied(trimmed!, now: 4)
        var steps: [StreamSettings] = []
        var time = 4.0
        for _ in 0..<6 {
            time += 1
            if let next = quality.observe(sample(loss: 0.2), now: time) { steps.append(next); _ = quality.confirmApplied(next, now: time) }
        }
        try check(steps == [StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 10),
                            StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 5),
                            StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 2),
                            StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 1)],
                  "Severe loss did not halve bitrate before lowering frame rate, then size: \(steps)")
        var tcp = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates, now: 0)
        func reliable(_ delivery: Double?) -> MediaPathSample {
            sample(count: 0, loss: nil, jitter: nil, queue: nil, delivery: delivery)
        }
        try check(tcp.observe(reliable(nil), now: 3) == nil && tcp.observe(reliable(nil), now: 4) == nil,
                  "TCP without delivery evidence adapted to the network")
        try check(tcp.observe(reliable(200), now: 5) == nil && tcp.observe(reliable(200), now: 6)?.megabits == 20,
                  "Growing TCP delivery time did not trim bitrate")
        var severe = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates, now: 0)
        try check(severe.observe(reliable(800), now: 2)?.megabits == 15, "A long TCP queue did not halve bitrate at once")
    }

    run("Bitrate ramps up in fine steps only while video fills it, and failed steps wait longer") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 60)
        let start = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 10)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: start,
                                             bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1240), now: 0)
        var time = 0.0, ladder: [Int] = []
        while time < 120, quality.effective != ceiling {
            time += 1
            if let next = quality.observe(sample(), now: time) {
                try check(next.longestEdge == 1920 && next.framesPerSecond == 60 && next.megabits <= 60, "Ramp exceeded the ceiling")
                ladder.append(next.megabits); _ = quality.confirmApplied(next, now: time)
            }
        }
        try check(ladder == [15, 20, 25, 40, 50, 60], "Bitrate did not ramp through fine steps: \(ladder)")
        var failing = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: start,
                                             bitRates: StreamSettings.adaptiveBitRates, now: 0)
        time = 0
        var up: StreamSettings?
        while up == nil { time += 1; up = failing.observe(sample(), now: time) }
        _ = failing.confirmApplied(up!, now: time)
        time += 1
        guard let down = failing.observe(sample(loss: 0.2), now: time) else { throw CheckFailure("Failed step was not reduced") }
        _ = failing.confirmApplied(down, now: time)
        try check(failing.bitrateHold == MediaQualityPolicy.initialBitrateHold * 2, "A bitrate step that failed soon did not back off")
        try check(failing.upgradeHold == MediaQualityPolicy.initialUpgradeHold, "A bitrate failure delayed frame rate or size upgrades")
    }

    run("A narrow path starts from a capped bitrate, and the output size teaches the real screen size") {
        let ceiling = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 60)
        let adaptive = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates, now: 0)
        try check(adaptive.startingSettings(maximumMegabits: 10) == StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 10),
                  "Conservative start changed more than bitrate")
        let legacy = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, now: 0)
        try check(legacy.startingSettings(maximumMegabits: 10).megabits == 8, "An older host received a step it cannot accept")
        let native = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        var known = try MediaQualityPolicy(hostDefault: native, preferred: native, bitRates: StreamSettings.adaptiveBitRates,
                                           appliedSize: (3456, 2234), now: 0)
        try check(known.reduceLoad(for: .network, severe: true, now: 2) == StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 30),
                  "A known laptop-sized source was treated as 8K and lost smoothness")
        // Scaling floors to even pixels: a 2940 × 1912 source at the 1920 edge is 1918 wide, not the whole screen.
        let wide = StreamSettings(longestEdge: 3840, framesPerSecond: 30, megabits: 30)
        let reduced = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 30)
        let rounded = reduced.dimensions(width: 2940, height: 1912)
        try check(rounded.0 == 1918, "Rounding fixture no longer loses pixels: \(rounded)")
        func firstUpgrade(_ policy: inout MediaQualityPolicy, after start: TimeInterval) -> StreamSettings? {
            var time = start, upgraded: StreamSettings?
            while time < start + 60, upgraded == nil { time += 1; upgraded = policy.observe(sample(), now: time) }
            return upgraded
        }
        var sharper = try MediaQualityPolicy(hostDefault: wide, preferred: wide, applied: reduced, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: rounded, now: 0)
        let restored = firstUpgrade(&sharper, after: 0)
        try check(restored?.longestEdge == 2560, "An output rounded below its edge capped the size: \(String(describing: restored))")
        // A larger output later (the shared display changed) lifts a size learned from a smaller screen.
        var grown = try MediaQualityPolicy(hostDefault: wide, preferred: wide, applied: reduced, bitRates: StreamSettings.adaptiveBitRates,
                                           appliedSize: (1280, 800), now: 0)
        try check(firstUpgrade(&grown, after: 0) == nil, "A 1280-wide screen was offered a larger size")
        try grown.synchronizeApplied(reduced, size: (1920, 1200), now: 100)
        let lifted = firstUpgrade(&grown, after: 100)
        try check(lifted?.longestEdge == 2560, "A larger screen stayed capped at its earlier size: \(String(describing: lifted))")
        try rejects("Unknown bitrate steps were accepted") { _ = try MediaQualityPolicy(hostDefault: native, bitRates: [7, 9], now: 0) }
    }

    run("Network condition classifies loss, delivery growth and queueing, and needs evidence") {
        try check(sample(loss: 0.12).networkCondition == .severe && sample(loss: 0.04).networkCondition == .congested
                  && sample(loss: 0.0).networkCondition == .healthy && sample(loss: 0.02).networkCondition == nil,
                  "UDP loss thresholds changed")
        try check(sample(queue: 150).networkCondition == .congested && sample(queue: 70).networkCondition == nil,
                  "Queue thresholds changed")
        func reliable(_ delivery: Double?) -> MediaPathSample { sample(count: 0, loss: nil, jitter: nil, queue: nil, delivery: delivery) }
        try check(reliable(600).networkCondition == .severe && reliable(200).networkCondition == .congested
                  && reliable(20).networkCondition == .healthy && reliable(nil).networkCondition == nil,
                  "Delivery thresholds changed")
        try check(sample(count: 2, loss: 0.5).networkCondition == nil, "Sparse UDP windows were classified")
    }

    run("Delivery estimator reports growth over its recent minimum and forgets an old baseline") {
        var estimator = MediaDeliveryEstimator()
        for index in 0..<5 { estimator.add(0.010, at: Double(index) * 0.1) }
        try check(estimator.takeWindow(at: 1) == 0, "A steady delivery time reported growth")
        for index in 0..<3 { estimator.add(0.210, at: 1 + Double(index) * 0.1) }
        try check(abs((estimator.takeWindow(at: 2) ?? 0) - 200) < 0.001, "Queueing growth was not measured")
        estimator.add(0.300, at: 2); estimator.add(0.300, at: 2.1)
        try check(estimator.takeWindow(at: 3) == nil, "Two frames produced a delivery figure")
        for index in 0..<3 { estimator.add(0.300, at: 40 + Double(index)) }
        try check(estimator.takeWindow(at: 43) == 0, "A baseline older than thirty seconds was kept")
        estimator.add(.nan, at: 44); estimator.add(-1, at: 44); estimator.add(100, at: 44)
        try check(estimator.takeWindow(at: 44) == nil, "Invalid delivery times were accepted")
    }
}
