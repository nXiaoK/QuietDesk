import Foundation
import QuietDeskCore

func runMediaPathPolicyChecks() {
    func sample(duration: TimeInterval = 1, active: Bool = true, count: Int = 60, frames: Int = 60,
                loss: Double? = 0, jitter: Double? = 0, queue: Double? = 0,
                encode: Double? = 4, decode: Double? = 3, delivery: Double? = nil, received: Double? = 1_000,
                local: Bool = false, roundTrip: Double? = nil) -> MediaPathSample {
        MediaPathSample(duration: duration, mediaActive: active, networkSamples: count, decodedFrames: frames,
                        lossFraction: loss, jitterMilliseconds: jitter, queueMilliseconds: queue,
                        encodeMilliseconds: encode, decodeMilliseconds: decode,
                        deliveryMilliseconds: delivery, receivedMegabits: received,
                        isLocalNetwork: local, roundTripMilliseconds: roundTrip)
    }

    run("UDP probes measure their own send time after loss and keep delayed answers in flight") {
        var challenges = MediaDatagramChallenges()
        let lost = Data([1]), next = Data([2]), slow = Data([3]), newer = Data([4])
        challenges.sent(lost, at: 0)
        challenges.sent(next, at: 0.2)
        try check(challenges.answer(Data([5]), at: 0.205) == nil, "A different nonce supplied a sample")
        try check(abs((challenges.answer(next, at: 0.205)?.roundTrip ?? 0) - 0.005) < 0.000_001,
                  "The second probe inherited the first probe's delay")
        try check(challenges.answer(next, at: 0.206) == nil, "A replayed echo supplied another sample")

        challenges.sent(slow, at: 0.4)
        challenges.sent(newer, at: 0.6)
        let delayed = challenges.answer(slow, at: 0.67)
        try check(delayed?.sentAt == 0.4 && abs((delayed?.roundTrip ?? 0) - 0.27) < 0.000_001,
                  "A subsequent probe invalidated a 270 ms response")
        try check(challenges.answer(lost, at: 1.125) == nil, "An expired nonce supplied a sample")
        challenges.clear()
        try check(challenges.answer(newer, at: 1.25) == nil, "A previous generation supplied a sample after reset")
    }

    run("Local links keep the chosen native high frame rate despite codec load, loss or direct reduction requests") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3024, 1964), now: 0)
        quality.setLocalNetwork(true, now: 0)
        for time in 1...30 {
            let now = Double(time)
            try check(quality.observe(sample(loss: 1, jitter: 100, queue: 500, encode: 80, decode: 60,
                                             delivery: 20, local: true, roundTrip: 3), now: now) == nil,
                      "A low-delay local link reduced quality for loss or codec pressure")
            for cause in [MediaBottleneck.network, .encoder, .decoder] {
                try check(quality.reduceLoad(for: cause, severe: true, computeMilliseconds: 80, now: now) == nil,
                          "A direct reduction bypassed local delay observation")
            }
        }
        try check(quality.effective == ceiling && quality.upperBound == ceiling && quality.preferred == ceiling,
                  "Local adaptation replaced the requested quality")
    }

    run("Either local RTT or delivery delay at 80 ms must persist for two seconds before each reduction") {
        for useRoundTrip in [false, true] {
            let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
            var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling,
                                               bitRates: StreamSettings.adaptiveBitRates, appliedSize: (3024, 1964), now: 0)
            quality.setLocalNetwork(true, now: 0)
            for time in 1...10 {
                try check(quality.observe(sample(delivery: 79.999, local: true, roundTrip: 79.999), now: Double(time)) == nil,
                          "Local delay below 80 ms caused a reduction")
            }
            let delayed = sample(frames: 0, loss: 1, encode: 80, decode: 60, delivery: useRoundTrip ? 20 : 80,
                                 local: true, roundTrip: useRoundTrip ? 80 : 3)
            try check(quality.observe(delayed, now: 11) == nil, "Local overload reduced quality before two seconds")
            guard let first = quality.observe(delayed, now: 12) else { throw CheckFailure("Sustained local delay did not reduce load") }
            try check(first == StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 60)
                      && quality.lastAdjustment == .localLatency, "Local delay reduced size or reported codec pressure first")
            try check(quality.confirmApplied(first, now: 12), "Local reduction was not confirmed")
            try quality.synchronizeApplied(first, size: (3024, 1964), now: 12)
            try check(quality.observe(delayed, now: 13) == nil, "One delayed window caused repeated local reductions")
            try check(quality.observe(delayed, now: 14)?.megabits == 40, "The next two seconds did not reduce bitrate again")
            try check(quality.preferred == ceiling && quality.upperBound == ceiling, "Local delay overwrote the user's ceiling")
        }
    }

    run("After local delay reduces the load, quiet windows keep it and filled ones climb one bitrate step at a time") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling,
                                           bitRates: StreamSettings.adaptiveBitRates, appliedSize: (3024, 1964), now: 0)
        quality.setLocalNetwork(true, now: 0)
        let delayed = sample(local: true, roundTrip: 120)
        _ = quality.observe(delayed, now: 1)
        guard let reduced = quality.observe(delayed, now: 2), reduced.megabits == 60 else {
            throw CheckFailure("Local delay did not reduce the bitrate")
        }
        try check(quality.confirmApplied(reduced, now: 2), "Local reduction was not confirmed")
        let quiet = sample(received: 0.1, local: true, roundTrip: 3)
        for time in 3...40 {
            try check(quality.observe(quiet, now: Double(time)) == nil, "A quiet low-delay screen restored bitrate after local delay")
        }
        let filled = sample(received: 30, local: true, roundTrip: 3)
        for time in 41...43 {
            try check(quality.observe(filled, now: Double(time)) == nil, "Local recovery raised bitrate before four filled seconds")
        }
        guard let step = quality.observe(filled, now: 44) else { throw CheckFailure("Filled low-delay windows did not raise bitrate") }
        try check(step == StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 80) && quality.lastAdjustment == .raise,
                  "Local recovery jumped past the next bitrate step")
        try check(quality.confirmApplied(step, now: 44), "Local bitrate step was not confirmed")
        let busier = sample(received: 40, local: true, roundTrip: 3)
        for time in 45...47 {
            try check(quality.observe(busier, now: Double(time)) == nil, "Local recovery repeated a step before four filled seconds")
        }
        try check(quality.observe(busier, now: 48) == ceiling, "The next filled seconds did not restore the ceiling")
    }

    run("Sparse TCP heartbeats reduce sustained local RTT without replaying a single measurement") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        for delivery: Double? in [nil, 0] {
            var quality = try MediaQualityPolicy(hostDefault: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                               appliedSize: (3024, 1964), now: 0)
            quality.setLocalNetwork(true, now: 0)
            for time in 1...5 {
                try check(quality.observe(sample(count: 0, delivery: delivery, local: true,
                                                 roundTrip: time == 1 ? 200 : nil), now: Double(time)) == nil,
                          "A single TCP heartbeat was replayed as sustained delay")
            }
            guard let reduced = quality.observe(sample(count: 0, delivery: delivery, local: true, roundTrip: 200), now: 6),
                  reduced.megabits == 60 else { throw CheckFailure("Two fresh TCP heartbeats did not reduce sustained RTT") }
            _ = quality.confirmApplied(reduced, now: 6)
            try quality.synchronizeApplied(reduced, now: 6)
            for time in 7...16 {
                try check(quality.observe(sample(count: 0, delivery: 0, local: true), now: Double(time)) == nil,
                          "Low relative delivery delay restored quality without a new healthy RTT")
            }
            for time in 17...19 {
                try check(quality.observe(sample(count: 0, delivery: 0, local: true,
                                                 roundTrip: time == 17 ? 3 : nil), now: Double(time)) == nil,
                          "A healthy TCP heartbeat skipped the bitrate recovery hold")
            }
            try check(quality.observe(sample(count: 0, delivery: 0, local: true), now: 20)?.megabits == 80,
                      "A fresh healthy TCP heartbeat did not allow stepwise recovery")
        }
    }

    run("Sparse RTT evidence expires and mixed delay sources do not manufacture a continuous run") {
        for intermediateDelivery: Double? in [nil, 0, 200] {
            var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
            quality.setLocalNetwork(true, now: 0)
            _ = quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 1)
            for time in 2...7 {
                try check(quality.observe(sample(delivery: time == 2 ? intermediateDelivery : 0, local: true), now: Double(time)) == nil,
                          "Missing RTT or one delayed delivery window manufactured sustained delay")
            }
            try check(quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 8) == nil,
                      "A late heartbeat reused expired RTT evidence")
            for time in 9...12 { _ = quality.observe(sample(delivery: 0, local: true), now: Double(time)) }
            try check(quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 13) != nil,
                      "Two new timely heartbeats did not rebuild sustained RTT evidence")
        }
        var stalled = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        stalled.setLocalNetwork(true, now: 0)
        try check(stalled.observe(sample(duration: 5, delivery: 0, local: true, roundTrip: 200), now: 5) == nil,
                  "One heartbeat in a long sampling window caused a reduction")
    }

    run("Pending settings clear RTT congestion runs while retaining the recovery veto until a fresh measurement") {
        for applied in [false, true] {
            let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
            var quality = try MediaQualityPolicy(hostDefault: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                               appliedSize: (3024, 1964), now: 0)
            quality.setLocalNetwork(true, now: 0)
            _ = quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 1)
            guard let reduced = quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 2) else {
                throw CheckFailure("The pending RTT reduction was not created")
            }
            try check(quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 3) == nil,
                      "A pending request was replaced by RTT pressure")
            if applied { _ = quality.confirmApplied(reduced, now: 3) }
            else { quality.rejectPending(now: 3) }
            try quality.synchronizeApplied(applied ? reduced : ceiling, now: 3)
            for time in 4...7 {
                try check(quality.observe(sample(delivery: 0, local: true), now: Double(time)) == nil,
                          "Settings completion erased the high RTT recovery veto")
            }
            try check(quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 8) == nil,
                      "Settings completion retained old congestion evidence")
            try check(quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 9) != nil,
                      "Fresh RTT evidence could not reduce again after settings completion")
        }
    }

    run("Route, pause and manual resets discard the previous route's RTT recovery veto") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        let lower = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        for reset in 0...2 {
            var quality = try MediaQualityPolicy(hostDefault: ceiling, applied: lower, now: 0)
            quality.setLocalNetwork(true, now: 0)
            _ = quality.observe(sample(delivery: 0, local: true, roundTrip: 200), now: 1)
            switch reset {
            case 0:
                quality.setLocalNetwork(false, now: 2); quality.setLocalNetwork(true, now: 2)
            case 1: quality.resetObservation(now: 2)
            default:
                _ = try quality.chooseManually(ceiling, now: 2); quality.rejectPending(now: 2)
            }
            for time in 3...4 {
                try check(quality.observe(sample(delivery: 0, local: true), now: Double(time)) == nil,
                          "A reset reused the old recovery duration")
            }
            try check(quality.observe(sample(delivery: 0, local: true), now: 5) == ceiling,
                      "A reset retained the old RTT recovery veto")
        }
    }

    run("A local delay reduction soon after a bitrate step doubles the time the next step needs") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling,
                                           bitRates: StreamSettings.adaptiveBitRates, appliedSize: (3024, 1964), now: 0)
        quality.setLocalNetwork(true, now: 0)
        let delayed = sample(local: true, roundTrip: 120), filled = sample(received: 50, local: true, roundTrip: 3)
        _ = quality.observe(delayed, now: 1)
        guard let reduced = quality.observe(delayed, now: 2) else { throw CheckFailure("Local delay did not reduce the bitrate") }
        _ = quality.confirmApplied(reduced, now: 2)
        for time in 3...5 { _ = quality.observe(filled, now: Double(time)) }
        guard let step = quality.observe(filled, now: 6), step.megabits == 80 else { throw CheckFailure("Expected one local bitrate step") }
        _ = quality.confirmApplied(step, now: 6)
        _ = quality.observe(delayed, now: 7)
        guard let again = quality.observe(delayed, now: 8), again.megabits == 60, quality.lastAdjustment == .localLatency else {
            throw CheckFailure("Delay after the step did not reduce it again")
        }
        try check(quality.bitrateHold == MediaQualityPolicy.initialBitrateHold * 2, "A failed local step did not double its hold")
        _ = quality.confirmApplied(again, now: 8)
        for time in 9...15 {
            try check(quality.observe(filled, now: Double(time)) == nil, "A failed local step was retried before its doubled hold")
        }
        try check(quality.observe(filled, now: 16)?.megabits == 80, "The doubled hold did not allow the next step")
    }

    run("A new local route or a manual choice ends stepwise local recovery") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        for manual in [false, true] {
            var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling,
                                               bitRates: StreamSettings.adaptiveBitRates, appliedSize: (3024, 1964), now: 0)
            quality.setLocalNetwork(true, now: 0)
            let delayed = sample(local: true, roundTrip: 120), quiet = sample(received: 0.1, local: true, roundTrip: 3)
            _ = quality.observe(delayed, now: 1)
            guard let reduced = quality.observe(delayed, now: 2) else { throw CheckFailure("Local delay did not reduce the bitrate") }
            _ = quality.confirmApplied(reduced, now: 2)
            for time in 3...10 {
                try check(quality.observe(quiet, now: Double(time)) == nil, "Quiet windows restored a delay-limited route")
            }
            if manual {
                try check(try quality.chooseManually(ceiling, now: 11) == ceiling, "The manual choice was not requested")
                quality.rejectPending(now: 12)
            } else {
                quality.setLocalNetwork(false, now: 11)
                quality.setLocalNetwork(true, now: 12)
            }
            for time in 13...14 {
                try check(quality.observe(quiet, now: Double(time)) == nil, "Recovery skipped its three low-delay seconds")
            }
            try check(quality.observe(quiet, now: 15) == ceiling, "Stepwise recovery outlived a new route or manual choice")
        }
    }

    run("Three decoded low-delay local seconds restore the entire ceiling despite old codec cooldown") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 120, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling,
                                           applied: StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 20),
                                           appliedSize: (3024, 1964), now: 0)
        guard let reduced = quality.reduceLoad(for: .encoder, computeMilliseconds: 25, now: 3) else {
            throw CheckFailure("Expected old-path codec reduction")
        }
        _ = quality.confirmApplied(reduced, now: 3)
        quality.setLocalNetwork(true, now: 3)
        for time in 4...10 {
            try check(quality.observe(sample(delivery: 50, local: true, roundTrip: 3), now: Double(time)) == nil,
                      "A 50 ms local measurement proved recovery")
        }
        let healthy = sample(loss: 1, encode: 80, decode: 60, delivery: 49.999, received: 0.1, local: true, roundTrip: 3)
        try check(quality.observe(healthy, now: 11) == nil && quality.observe(healthy, now: 12) == nil,
                  "Local recovery did not wait three seconds")
        try check(quality.observe(healthy, now: 13) == ceiling && quality.lastAdjustment == .raise,
                  "Local recovery inherited old cooldown, codec limits, or one-step upgrades")
        try check(quality.confirmApplied(ceiling, now: 13), "Local recovery did not confirm")
        try quality.synchronizeApplied(ceiling, size: (3024, 1964), now: 13)
        for time in 14...20 {
            try check(quality.observe(healthy, now: Double(time)) == nil, "Local recovery repeated at the ceiling")
        }
    }

    run("Local recovery respects a lower manual ceiling and can restore an initially lower stream") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
        var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        _ = try quality.chooseManually(ceiling, now: 1)
        _ = quality.confirmApplied(ceiling, now: 1)
        try quality.synchronizeApplied(StreamSettings(longestEdge: 1280, framesPerSecond: 15, megabits: 3), now: 2)
        quality.setLocalNetwork(true, now: 2)
        for time in 3...4 {
            try check(quality.observe(sample(local: true, roundTrip: 3), now: Double(time)) == nil,
                      "Initial local recovery skipped observation")
        }
        try check(quality.observe(sample(local: true, roundTrip: 3), now: 5) == ceiling
                  && quality.upperBound == ceiling && quality.preferred == ceiling,
                  "Local recovery exceeded the lower manual choice")
    }

    run("Inactive, invalid and intermediate local samples break continuous RTT delay evidence") {
        let interruptions = [sample(active: false, local: true, roundTrip: 200),
                             sample(local: true, roundTrip: .nan), sample(local: true, roundTrip: 60),
                             sample(local: true, roundTrip: 3)]
        for interruption in interruptions {
            var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
            quality.setLocalNetwork(true, now: 0)
            let delayed = sample(local: true, roundTrip: 500)
            try check(quality.observe(delayed, now: 1) == nil && quality.observe(interruption, now: 2) == nil
                      && quality.pending == nil, "An incomplete local delay run reduced quality")
            try check(quality.observe(delayed, now: 3) == nil, "Interrupted local delay evidence was retained")
            try check(quality.observe(delayed, now: 4) != nil, "A new two-second local delay run did not reduce quality")
        }
        var gap = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        gap.setLocalNetwork(true, now: 0)
        _ = gap.observe(sample(local: true, roundTrip: 200), now: 1)
        try check(gap.observe(sample(local: true, roundTrip: 200), now: 10) == nil,
                  "A sampling gap completed an old local delay run")
        try check(gap.observe(sample(local: true, roundTrip: 200), now: 11) != nil, "Complete post-gap evidence did not reduce quality")
    }

    run("Quiet or unmeasured local windows cannot accumulate recovery") {
        let reduced = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 3)
        let interruptions = [sample(local: true), sample(active: false, local: true, roundTrip: 3),
                             sample(frames: 0, local: true, roundTrip: 3), sample(local: true, roundTrip: 50),
                             sample(delivery: 150, local: true, roundTrip: 3), sample(local: true, roundTrip: -.infinity)]
        for interruption in interruptions {
            var quality = try MediaQualityPolicy(hostDefault: .highest, applied: reduced, now: 0)
            quality.setLocalNetwork(true, now: 0)
            let healthy = sample(local: true, roundTrip: 3)
            _ = quality.observe(healthy, now: 1); _ = quality.observe(healthy, now: 2)
            try check(quality.observe(interruption, now: 3) == nil, "An unproven local window restored quality")
            try check(quality.observe(healthy, now: 4) == nil && quality.observe(healthy, now: 5) == nil,
                      "Interrupted local recovery evidence was retained")
            try check(quality.observe(healthy, now: 6) == .highest, "A complete local recovery run did not restore the ceiling")
        }
    }

    run("Local route changes reset evidence and pending or failed requests require fresh observation") {
        var quality = try MediaQualityPolicy(hostDefault: .highest, now: 0)
        quality.setLocalNetwork(true, now: 0)
        let delayed = sample(local: true, roundTrip: 200)
        _ = quality.observe(delayed, now: 1)
        _ = quality.observe(sample(), now: 2)
        try check(!quality.isLocalNetwork, "The current sample did not leave local mode")
        for time in 3...4 {
            try check(quality.observe(delayed, now: Double(time)) == nil, "A route change reused previous delay evidence")
        }
        guard let reduction = quality.observe(delayed, now: 5) else { throw CheckFailure("New local route did not complete observation") }
        quality.setLocalNetwork(false, now: 6)
        quality.setLocalNetwork(true, now: 7)
        for time in 8...14 {
            try check(quality.observe(delayed, now: Double(time)) == nil && quality.pending == reduction,
                      "A pending settings change was overwritten")
        }
        quality.rejectPending(now: 14)
        try quality.synchronizeApplied(.highest, now: 14)
        try check(quality.observe(delayed, now: 15) == nil, "Failed requests retained delay evidence")
        try check(quality.observe(delayed, now: 16) == reduction, "Failed local reduction could not be retried after fresh evidence")
        _ = quality.confirmApplied(reduction, now: 16)
        quality.setLocalNetwork(false, now: 17)
        try check(quality.reduceLoad(for: .encoder, computeMilliseconds: 25, now: 19) != nil,
                  "Leaving the local route disabled the existing nonlocal codec policy")
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
    run("Successful UDP recovery keyframes do not erase repeated playback interruptions") {
        var policy = try udp()
        let epoch = policy.epoch
        for step in 1...3 {
            let now = Double(step)
            policy.receivedPong(epoch: epoch, now: now)
            let actions = policy.mediaInterrupted(epoch: epoch, now: now)
            if step < 3 {
                try check(actions.isEmpty, "A single interruption abandoned UDP before its bounded recovery budget")
                _ = policy.mediaBecameUsable(epoch: epoch, path: .udp, now: now + 0.1)
            } else {
                try check(actions == [.selectPath(.tcp, epoch: epoch + 1, reason: .networkDegraded)]
                          && policy.nextRecoveryAt == now + 30, "Repeated interrupted playback stayed on UDP")
            }
        }
        try check(policy.mediaInterrupted(epoch: epoch, now: 3.2).isEmpty, "A stale interruption replaced the fallback epoch")
        try check(policy.mediaBecameUsable(epoch: policy.epoch, path: .tcp, now: 3.3), "Interruption fallback could not commit TCP")
        try check(policy.tick(now: 32.99).isEmpty && policy.tick(now: 33).count == 1,
                  "Interruption fallback bypassed or lost the normal UDP recovery cooldown")
    }
    run("Isolated playback interruptions, normal pause and invalid callbacks do not exhaust UDP") {
        var isolated = try udp()
        for now in [1.0, 12, 23, 34] {
            isolated.receivedPong(epoch: isolated.epoch, now: now)
            try check(isolated.mediaInterrupted(epoch: isolated.epoch, now: now).isEmpty, "Isolated interruptions accumulated forever")
            _ = isolated.mediaBecameUsable(epoch: isolated.epoch, path: .udp, now: now + 0.1)
        }
        var paused = try udp()
        _ = paused.mediaInterrupted(epoch: paused.epoch, now: 1)
        _ = paused.mediaInterrupted(epoch: paused.epoch, now: 2)
        _ = paused.setPaused(true, now: 3)
        try check(paused.mediaInterrupted(epoch: paused.epoch, now: 4).isEmpty, "Paused playback counted as interrupted")
        _ = paused.setPaused(false, now: 5)
        try check(paused.mediaInterrupted(epoch: paused.epoch, now: 6).isEmpty, "Resume retained pre-pause interruptions")
        for now in [Double.nan, .infinity, 5] {
            try check(paused.mediaInterrupted(epoch: paused.epoch, now: now).isEmpty, "An invalid clock counted as interrupted playback")
        }
        try check(paused.mediaInterrupted(epoch: paused.epoch - 1, now: 7).isEmpty, "An old path counted as interrupted playback")
        _ = paused.stop()
        try check(paused.mediaInterrupted(epoch: paused.epoch, now: 8).isEmpty, "Late interruption revived a stopped policy")
        var legacy = MediaPathPolicy(capable: false, now: 0)
        try check(legacy.mediaInterrupted(epoch: 0, now: 1).isEmpty, "Legacy TCP enabled UDP interruption policy")
    }
    run("Initial UDP preparation cannot manufacture playback interruptions") {
        var initial = MediaPathPolicy(capable: true, now: 0)
        _ = initial.tick(now: 0)
        let id = initial.probeID!
        _ = initial.probeSucceeded(id: id, now: 0.1)
        for now in [0.2, 0.3, 0.4] {
            try check(initial.mediaInterrupted(epoch: initial.epoch, now: now).isEmpty, "An uncommitted UDP trial counted as interrupted playback")
        }
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
        try check(quality.observe(sample(delivery: 600), now: 0.5) == nil, "A severe window changed quality right after a change")
        let recommendation = quality.observe(sample(delivery: 600), now: 1.5)
        // A severe queue halves the bitrate; at 8K-class sizes 30 Mbps is below the readable floor for 60 fps.
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

    run("A matched quality reply with a host clamp lets congestion adaptation continue") {
        let limit = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 30)
        let requested = StreamSettings(longestEdge: 3840, framesPerSecond: 60, megabits: 100)
        let state = VideoStreamState(settings: limit, width: 2560, height: 1440)
        var tuning = try VideoTuningSession(applied: state)
        var quality = try MediaQualityPolicy(hostDefault: limit, now: 0)
        try tuning.choose(requested)
        _ = try quality.chooseManually(requested, now: 1)
        guard let request = tuning.nextRequest() else { throw CheckFailure("No quality request") }
        let result = StreamSettingsResult(id: request.id, state: state, error: nil)
        guard let completed = try tuning.completeRequest(result) else { throw CheckFailure("The host's capped reply was not accepted") }
        quality.receiveSettingsResult(result, for: completed.settings, now: 2)
        try check(quality.pending == nil && quality.preferred == requested && quality.upperBound == limit,
                  "The reply did not settle the request and learn the host limit")
        try quality.synchronizeApplied(limit, size: (1920, 1080), now: 3)
        try check(quality.upperBound == limit, "A smaller display changed the configured limit")
        try check(quality.reduceLoad(for: .network, severe: true, now: 12)?.megabits == 12,
                  "Congestion could not reduce the capped bitrate")
        try quality.synchronizeApplied(requested, now: 13)
        try check(quality.upperBound == requested, "The host later reported supporting the higher settings")
    }

    run("An older quality reply preserves a newer choice until it is applied") {
        let initial = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 30)
        let requested = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 60)
        let newer = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8)
        let state = VideoStreamState(settings: initial, width: 1920, height: 1080)
        for applied in [initial, newer] {
            var tuning = try VideoTuningSession(applied: state, preferred: requested)
            var quality = try MediaQualityPolicy(hostDefault: initial, now: 0)
            _ = try quality.chooseManually(requested, now: 1)
            guard let request = tuning.nextRequest() else { throw CheckFailure("No quality request") }
            try tuning.choose(newer)
            _ = try quality.chooseManually(newer, now: 2)
            let result = StreamSettingsResult(id: request.id, state: VideoStreamState(settings: applied, width: 1920, height: 1080),
                                              error: applied == initial ? "调整失败" : nil)
            guard let completed = try tuning.completeRequest(result) else { throw CheckFailure("No completed request") }
            quality.receiveSettingsResult(result, for: completed.settings, now: 3)
            let next = tuning.nextRequest()?.settings
            try check(quality.pending == next && quality.effective == applied, "The policy disagreed with the queued choice")
        }
    }

    run("A compatibility session can start below its advertised Windows quality") {
        let advertised = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 50)
        let legacy = advertised.legacyCompatible
        let rates = StreamSettings.bitRates + [advertised.megabits]
        var quality = try MediaQualityPolicy(hostDefault: advertised, applied: legacy, bitRates: rates, now: 0)
        let start = quality.startingSettings(maximumMegabits: 10)
        try check(start == StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 8),
                  "Compatibility startup did not retain pixels while capping the rate")
        let applied = VideoStreamState(settings: start, width: 2560, height: 1440)
        quality.receiveSettingsResult(StreamSettingsResult(id: UUID(), state: applied, error: nil), for: start, now: 1)
        for time in 2...120 {
            if let next = quality.observe(sample(received: Double(quality.effective.megabits)), now: Double(time)) {
                _ = quality.confirmApplied(next, now: Double(time))
            }
        }
        try check(quality.effective == advertised && quality.preferred == nil,
                  "The conservative start displaced the advertised quality or persisted a preference")
    }

    run("Compatibility quality recovers to a host's confirmed 20 or 50 Mbps rate") {
        for rate in [20, 50] {
            let active = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: rate)
            let initial = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 12)
            var quality = try MediaQualityPolicy(hostDefault: active, applied: initial, now: 0)
            let state = VideoStreamState(settings: active, width: 1920, height: 1080)
            quality.receiveSettingsResult(StreamSettingsResult(id: UUID(), state: state, error: nil), for: active, now: 1)
            guard let lower = quality.reduceLoad(for: .network, now: 3) else { throw CheckFailure("No bitrate reduction") }
            try check(lower.megabits == (rate == 20 ? 12 : 30), "The compatibility range did not reduce bitrate")
            _ = quality.confirmApplied(lower, now: 3)
            for time in 4...120 {
                if let next = quality.observe(sample(received: Double(quality.effective.megabits)), now: Double(time)) {
                    _ = quality.confirmApplied(next, now: Double(time))
                }
            }
            try check(quality.effective == active, "Recovery stalled before the host's \(rate) Mbps setting")
        }
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

    run("Near the 60 fps floor the size stays; clearly short of it, one size step drops and returns only once the codec got faster") {
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
        // 2560 encodes in 13 ms: sustainable at 60 fps, without the headroom 75 fps needs. The larger size has
        // 1.8 times the pixels, about 24 ms a frame, so it would be left again: it is not retried at all.
        while time < reducedAt + MediaQualityPolicy.maximumUpgradeHold * 3 {
            time += 1
            try check(quality.observe(codec(fps: 60, encode: 13), now: time) == nil,
                      "A size the codec still cannot keep up with was retried, or the rate rose without headroom")
        }
        // The estimate may be wrong, so an unchanged codec still gets the size back once the longest wait passed.
        var unchanged = quality, unchangedTime = time, late: StreamSettings?
        while late == nil, unchangedTime < reducedAt + MediaQualityPolicy.maximumSlowSizeHold + 60 {
            unchangedTime += 1
            late = unchanged.observe(codec(fps: 60, encode: 13), now: unchangedTime)
        }
        try check(late?.longestEdge == 3840 && unchangedTime == reducedAt + MediaQualityPolicy.maximumSlowSizeHold,
                  "An unchanged codec was not given the size once after the longest wait: \(unchangedTime - reducedAt) s")
        // The codec now needs 10 ms, about 18 ms at the larger size: within what keeps a size at the floor.
        var retried: StreamSettings?
        let fasterAt = time
        while retried == nil, time < fasterAt + 60 { time += 1; retried = quality.observe(codec(fps: 60, encode: 10), now: time) }
        try check(retried?.longestEdge == 3840 && retried?.framesPerSecond == 60, "A faster codec did not bring the slow size back")
        try check(quality.lastAdjustment == .raise, "The upgrade was not reported as one")
    }

    run("A slow size retried in vain waits twice as long each time, and one that lasts as long as its wait starts over") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        let smaller = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 100)
        // The next size step above 2560; on this 3456-wide screen it is the whole screen again.
        let larger = StreamSettings(longestEdge: 3840, framesPerSecond: 60, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        var time = 0.0
        // The larger size needs 25 ms a frame. Leaves it and returns the time that took.
        func leave() throws -> Double {
            let started = time
            while time < started + 20 {
                time += 1
                if let next = quality.observe(codec(fps: 60, encode: 25), now: time) {
                    try check(next == smaller && quality.confirmApplied(next, now: time), "Compute pressure did not leave the size")
                    return time - started
                }
            }
            throw CheckFailure("The slow size was kept")
        }
        // The smaller size encodes in 4 ms, which predicts that the larger one fits although it does not: only
        // the wait holds a retry back. Returns how long after leaving the larger size was requested again.
        func retry() throws -> Double {
            let started = time
            while time < started + 2 * MediaQualityPolicy.maximumSlowSizeHold {
                time += 1
                if let next = quality.observe(codec(fps: 60, encode: 4), now: time) {
                    try check(next == larger && quality.confirmApplied(next, now: time), "The retry was not the larger size")
                    return time - started
                }
            }
            throw CheckFailure("The slow size was never retried")
        }
        _ = try leave()
        var waits: [Double] = []
        for _ in 0..<6 { waits.append(try retry()); _ = try leave() }
        try check(waits == [300, 600, 1_200, 2_400, 3_600, 3_600], "Retries in vain did not wait twice as long each time: \(waits)")
        // Carrying frames for less than the hour this retry waited does not prove the size.
        func carry(_ seconds: TimeInterval) throws {
            for _ in 0..<Int(seconds) {
                time += 1
                try check(quality.observe(codec(fps: 60, encode: 12), now: time) == nil, "A sustainable size was changed")
            }
        }
        _ = try retry()
        try carry(MediaQualityPolicy.maximumSlowSizeHold - 60)
        _ = try leave()
        try check(try retry() == MediaQualityPolicy.maximumSlowSizeHold, "A retry that did not last its wait shortened the next one")
        // Carrying them for the whole hour does: the size is no longer a slow one.
        try carry(MediaQualityPolicy.maximumSlowSizeHold)
        _ = try leave()
        try check(try retry() == 300, "A size that had lasted kept the long wait")
        // A manual choice forgets what was measured before it.
        _ = try leave()
        try check(try quality.chooseManually(ceiling, now: time) == ceiling && quality.confirmApplied(ceiling, now: time),
                  "The manual choice was not applied")
        _ = try leave()
        try check(try retry() == 300, "A manual choice kept the earlier wait")
    }

    run("A display of another shape is not held to the sizes measured too slow on the previous one") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100)
        let smaller = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 100)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3456, 2234), now: 0)
        var time = 0.0, reduced: StreamSettings?
        while reduced == nil, time < 20 { time += 1; reduced = quality.observe(codec(fps: 60, encode: 25), now: time) }
        try check(reduced == smaller && quality.confirmApplied(smaller, now: time), "Compute pressure did not leave the size")
        // The host switched to a 16:9 display. Its sizes hold other pixel counts, so 13 ms here blocks nothing.
        try quality.synchronizeApplied(smaller, size: (2560, 1440), now: time)
        var raised: StreamSettings?
        let switchedAt = time
        while raised == nil, time < switchedAt + 60 { time += 1; raised = quality.observe(codec(fps: 60, encode: 13), now: time) }
        try check(raised?.longestEdge == 3840 && time - switchedAt == MediaQualityPolicy.initialUpgradeHold,
                  "The new display inherited a slow size: \(String(describing: raised)) after \(time - switchedAt) s")
    }

    run("A session starts from the size the pair's codecs sustained last time, on a picture of the same shape only") {
        // A 3456 × 2234 host whose hello shows its default 1920 picture; the viewer's saved choice is the original size.
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60), hello = StreamSettings()
        func policy(helloSize: (Int, Int) = (1920, 1240), sustained: SustainedVideoSize? = nil) throws -> MediaQualityPolicy {
            try MediaQualityPolicy(hostDefault: hello, preferred: ceiling, applied: hello, bitRates: StreamSettings.adaptiveBitRates,
                                   appliedSize: helloSize, sustained: sustained, now: 0)
        }
        var time = 0.0
        func apply(_ settings: StreamSettings, to quality: inout MediaQualityPolicy) throws {
            _ = quality.confirmApplied(settings, now: time)
            try quality.synchronizeApplied(settings, size: settings.dimensions(width: 3456, height: 2234), now: time)
        }
        // Feeds one-second windows and returns the size changes the policy asked for, with their times.
        func run(_ quality: inout MediaQualityPolicy, seconds: Int, encode: Double) throws -> [(edge: Int, at: Double)] {
            var changes: [(edge: Int, at: Double)] = []
            for _ in 0..<seconds {
                time += 1
                guard let next = quality.observe(codec(fps: 60, encode: encode), now: time) else { continue }
                if next.longestEdge != quality.effective.longestEdge { changes.append((next.longestEdge, time)) }
                try apply(next, to: &quality)
            }
            return changes
        }
        // Without history the session starts at the ceiling, and its codecs, at 25 ms a frame, have to leave it
        // (three seconds of such windows are what a reduction takes).
        var first = try policy()
        let fresh = first.startingSettings(maximumMegabits: 20)
        try check(first.sustainedSize == nil && fresh == StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 20),
                  "A pair without history did not start at its ceiling: \(fresh)")
        try apply(fresh, to: &first)
        try check(try run(&first, seconds: 3, encode: 25).map(\.edge) == [2560], "Compute pressure did not leave the full screen")
        guard let kept = first.sustainedSize, kept.longestEdge == 2560, abs(kept.aspect - 2234.0 / 3456) < 0.001 else {
            throw CheckFailure("The size the codecs sustained was not reported: \(String(describing: first.sustainedSize))")
        }
        // The next session begins there with the bitrate cap of its path, and waits before trying more.
        time = 0
        var second = try policy(sustained: kept)
        let start = second.startingSettings(maximumMegabits: 20)
        try check(start == StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20) && second.sustainedSize?.longestEdge == 2560,
                  "The next session did not start from the sustained size: \(start)")
        try apply(start, to: &second)
        let hold = MediaQualityPolicy.maximumUpgradeHold
        let retry = try run(&second, seconds: Int(hold), encode: 8)
        try check(retry.map(\.edge) == [3840] && retry.first?.at == hold, "The size left last time did not wait its turn: \(retry)")
        // That request produced the whole 3456-wide screen. Leaving it again doubles the wait, so the size
        // remembered by its setting is the one the screen really has.
        let left = try run(&second, seconds: 3, encode: 25)
        try check(left.map(\.edge) == [2560], "The retried size was kept at 25 ms a frame")
        let again = try run(&second, seconds: Int(hold) * 2, encode: 8)
        try check(again.map(\.edge) == [3840] && again.first!.at - left.first!.at == hold * 2,
                  "A retry in vain did not double the wait of a size resumed from the record: \(again)")
        // Once it carried frames for as long as it waited, the pair has no smaller size to start from.
        try check(try run(&second, seconds: Int(hold) * 2, encode: 12).isEmpty && second.sustainedSize == nil,
                  "A size that lasted is still remembered as too slow")
        // Another shape is another display, and a screen no larger than the sustained size has nothing above it.
        let otherShape = try policy(helloSize: (1920, 1080), sustained: kept)
        try check(otherShape.startingSettings(maximumMegabits: 20).longestEdge == 8192 && otherShape.sustainedSize == nil,
                  "A 16:9 display started from the size measured on a 3:2 one")
        var smaller = try policy(sustained: kept)
        try smaller.synchronizeApplied(smaller.startingSettings(maximumMegabits: 20), size: (1728, 1117), now: 0)
        try check(smaller.sustainedSize == nil, "A screen smaller than the sustained size kept a slow size above itself")
        // The record keeps it, and a value it cannot use does not hide the record.
        let record = ConnectionRecord(address: "home.test", port: 5908, name: "Home", sustainedVideoSize: kept)
        let data = try JSONEncoder().encode(record)
        try check(try JSONDecoder().decode(ConnectionRecord.self, from: data) == record, "The record lost the sustained size")
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        raw["sustainedVideoSize"] = ["longestEdge": 2000, "aspect": 0.6464]
        let recovered = try JSONDecoder().decode(ConnectionRecord.self, from: JSONSerialization.data(withJSONObject: raw))
        try check(recovered.id == record.id && recovered.sustainedVideoSize == nil, "An unusable sustained size was kept or hid the record")
    }

    run("A viewer whose decoder falls behind at the floor rate gives up 4:4:4 before the size; a slow encoder keeps it") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (3840, 2160), now: 0)
        quality.synchronizeTrueColor(true)
        var time = 0.0
        // One window in which the viewer's decoder is the slower codec; applies what the policy asks for,
        // the way the coordinator does.
        func step(decode: Double) -> (settings: StreamSettings, trueColor: Bool?)? {
            time += 1
            guard let next = quality.observe(codec(fps: 60, encode: 2, decode: decode), now: time) else { return nil }
            let chroma = quality.pendingTrueColor
            _ = quality.confirmApplied(next, now: time)
            if let chroma { quality.synchronizeTrueColor(chroma) }
            return (next, chroma)
        }
        func firstChange(decode: Double, within seconds: Int) -> (settings: StreamSettings, trueColor: Bool?)? {
            for _ in 0..<seconds { if let change = step(decode: decode) { return change } }
            return nil
        }
        // A hardware encoder is no faster in 4:2:0, so a host that needs 30 ms a frame keeps 4:4:4 and the size goes.
        var hostBound = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                               appliedSize: (3840, 2160), now: 0)
        hostBound.synchronizeTrueColor(true)
        var smallerPicture: StreamSettings?
        for second in 1...5 where smallerPicture == nil { smallerPicture = hostBound.observe(codec(fps: 60, encode: 30), now: Double(second)) }
        try check(smallerPicture?.longestEdge == 2560 && hostBound.pendingTrueColor == nil && !hostBound.leftTrueColor,
                  "A slow encoder gave up 4:4:4, or kept the size: \(String(describing: smallerPicture))")
        // The viewer needs 30 ms to decode a 4K frame in 4:4:4: the chroma goes and the size stays.
        let left = firstChange(decode: 30, within: 5)
        try check(left?.settings == ceiling && left?.trueColor == false && !quality.trueColor && quality.leftTrueColor,
                  "4:4:4 was not given up before the size: \(String(describing: left))")
        try check(quality.lastAdjustment == .compute(.decoder, milliseconds: 30), "Giving up 4:4:4 lost its cause")
        let leftAt = time
        // In 4:2:0 the same size decodes in 15 ms, so 4:4:4 cost twice as much and would be left again: not retried.
        try check(firstChange(decode: 15, within: Int(MediaQualityPolicy.maximumUpgradeHold) * 3) == nil,
                  "4:4:4 was retried although the codec did not get faster")
        guard let kept = quality.sustainedSize, kept.leftTrueColor, kept.longestEdge == 8192,
              abs((kept.trueColorCost ?? 0) - 2) < 0.01 else {
            throw CheckFailure("The chroma given up was not reported: \(String(describing: quality.sustainedSize))")
        }
        // At 8 ms in 4:2:0 it fits, and comes back with the size unchanged.
        let back = firstChange(decode: 8, within: 60)
        try check(back?.settings == ceiling && back?.trueColor == true && quality.trueColor && quality.lastAdjustment == .raise,
                  "4:4:4 did not return once it fit: \(String(describing: back))")
        // Left again at 30 ms although 4:2:0 takes 8 ms: 4:4:4 costs more than was measured before, and that
        // newer cost keeps it from being retried until the longest wait has passed.
        let again = firstChange(decode: 30, within: 5)
        try check(again?.trueColor == false, "4:4:4 at 30 ms a frame was kept")
        let secondLeftAt = time
        try check(firstChange(decode: 8, within: Int(MediaQualityPolicy.maximumUpgradeHold) * 3) == nil,
                  "A retry that failed did not teach what 4:4:4 costs")
        let late = firstChange(decode: 8, within: Int(MediaQualityPolicy.maximumSlowSizeHold))
        try check(late?.trueColor == true && time - secondLeftAt == MediaQualityPolicy.maximumSlowSizeHold,
                  "4:4:4 was not given one retry after the longest wait: \(time - secondLeftAt) s")
        // When 4:2:0 is short of the floor rate as well, the size goes next.
        try check(firstChange(decode: 30, within: 5)?.trueColor == false, "4:4:4 at 30 ms a frame was kept")
        let smaller = firstChange(decode: 25, within: 5)
        try check(smaller?.settings.longestEdge == 2560 && smaller?.trueColor == nil, "The size did not go after the chroma")
        // Below 60 fps no cost is measured (a Mac host's encoder paces itself there), so only the wait holds a
        // retry back: each retry in vain doubles it.
        let slowCeiling = StreamSettings(longestEdge: 8192, framesPerSecond: 30, megabits: 60)
        var paced = try MediaQualityPolicy(hostDefault: slowCeiling, preferred: slowCeiling, bitRates: StreamSettings.adaptiveBitRates,
                                           appliedSize: (3840, 2160), now: 0)
        paced.synchronizeTrueColor(true)
        var pacedTime = 0.0, lastLeft = 0.0, waits: [Double] = []
        while waits.count < 3, pacedTime < 4_000 {
            pacedTime += 1
            // 50 ms to decode in 4:4:4 is 20 of the chosen 30 fps; 20 ms in 4:2:0 keeps up.
            guard let next = paced.observe(codec(fps: 30, encode: 2, decode: paced.trueColor ? 50 : 20), now: pacedTime),
                  let chroma = paced.pendingTrueColor else { continue }
            _ = paced.confirmApplied(next, now: pacedTime)
            paced.synchronizeTrueColor(chroma)
            if chroma { waits.append(pacedTime - lastLeft) } else { lastLeft = pacedTime }
        }
        try check(waits == [300, 600, 1_200], "4:4:4 retries in vain did not double their wait: \(waits)")
        // A host whose encoder refuses 4:4:4 on a retry is not asked again.
        var refused = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (3840, 2160), sustained: kept, choosesTrueColor: true, now: 0)
        try check(refused.leftTrueColor && refused.startingSettings(maximumMegabits: 20).longestEdge == 8192,
                  "The next session did not start without 4:4:4 at the full size")
        var asked: StreamSettings?, clock = 0.0
        while asked == nil, clock < 400 { clock += 1; asked = refused.observe(codec(fps: 60, encode: 8), now: clock) }
        try check(asked == ceiling && refused.pendingTrueColor == true && clock == MediaQualityPolicy.maximumUpgradeHold,
                  "A resumed session did not retry 4:4:4 after its wait: \(clock)")
        _ = refused.confirmApplied(ceiling, now: clock)
        refused.synchronizeTrueColor(false)
        try check(!refused.leftTrueColor && refused.sustainedSize == nil, "A refused 4:4:4 is still waiting to be retried")
        // Someone who did not choose 4:4:4 this time is not held to it, and older records read as before.
        let plain = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3840, 2160), sustained: kept, now: 0)
        try check(!plain.leftTrueColor, "A 4:2:0 choice resumed a 4:4:4 fallback")
        let data = try JSONEncoder().encode(kept)
        try check(try JSONDecoder().decode(SustainedVideoSize.self, from: data) == kept, "The chroma fallback did not round-trip")
        let old = try JSONDecoder().decode(SustainedVideoSize.self, from: Data(#"{"longestEdge":2560,"aspect":0.5625}"#.utf8))
        try check(!old.leftTrueColor && old.trueColorCost == nil, "A record without the chroma fields did not read as 4:4:4 kept")
    }

    run("Preferring the picture size lowers the rate to 30 fps before the size goes, and giving it up returns the rate") {
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (3840, 2160), prefersSharpness: true, now: 0)
        quality.synchronizeTrueColor(true)
        var time = 0.0
        func firstChange(_ policy: inout MediaQualityPolicy, encode: Double, within seconds: Int) -> (settings: StreamSettings, trueColor: Bool?)? {
            for _ in 0..<seconds {
                time += 1
                guard let next = policy.observe(codec(fps: policy.effective.framesPerSecond, encode: encode), now: time) else { continue }
                let chroma = policy.pendingTrueColor
                _ = policy.confirmApplied(next, now: time)
                if let chroma { policy.synchronizeTrueColor(chroma) }
                return (next, chroma)
            }
            return nil
        }
        // 25 ms a frame is 40 fps: the rate drops to 30 and the whole 4:4:4 picture stays.
        let slower = firstChange(&quality, encode: 25, within: 5)
        try check(slower?.settings == StreamSettings(longestEdge: 8192, framesPerSecond: 30, megabits: 60)
                  && slower?.trueColor == nil && quality.trueColor, "The rate did not drop first: \(String(describing: slower))")
        try check(firstChange(&quality, encode: 25, within: 60) == nil, "25 ms a frame at 30 fps changed something else")
        // Clearly short of 30 fps as well: the size goes, and a slow encoder keeps 4:4:4.
        let size = firstChange(&quality, encode: 45, within: 5)
        try check(size?.settings == StreamSettings(longestEdge: 2560, framesPerSecond: 30, megabits: 60) && size?.trueColor == nil
                  && quality.trueColor, "The size did not go last, or 4:4:4 went with it: \(String(describing: size))")
        try check(quality.sustainedSize?.sharpnessFirst == true, "What was sustained did not say under which preference")
        // Giving the preference up returns the rate it lowered with the next window.
        quality.setPrefersSharpness(false, now: time)
        let restored = firstChange(&quality, encode: 12, within: 2)
        try check(restored?.settings.framesPerSecond == 60 && quality.lastAdjustment == .raise, "The lowered rate did not return")
        // Without the preference a 4K picture at 25 ms a frame goes to 2560 and stays there at 13 ms. Choosing
        // the preference tries the whole picture again at once, and this time the rate gives way.
        var plain = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                           appliedSize: (3840, 2160), now: 0)
        time = 0
        try check(firstChange(&plain, encode: 25, within: 5)?.settings.longestEdge == 2560, "Compute pressure did not leave the size")
        try plain.synchronizeApplied(plain.effective, size: (2560, 1440), now: time)
        try check(firstChange(&plain, encode: 13, within: 400) == nil, "The size came back although the codec was no faster")
        plain.setPrefersSharpness(true, now: time)
        let whole = firstChange(&plain, encode: 13, within: 15)
        try check(whole?.settings.longestEdge == 3840 && whole?.settings.framesPerSecond == 60, "The preference did not retry the size")
        try plain.synchronizeApplied(plain.effective, size: (3840, 2160), now: time)
        let kept = firstChange(&plain, encode: 25, within: 5)
        try check(kept?.settings.longestEdge == 3840 && kept?.settings.framesPerSecond == 30, "The rate did not give way for the size")
        // A size measured under one preference is not where a session under the other starts.
        guard let record = SustainedVideoSize(longestEdge: 2560, aspect: 0.5625, sharpnessFirst: true) else { throw CheckFailure("Bad fixture") }
        let other = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3840, 2160), sustained: record, now: 0)
        let same = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, appliedSize: (3840, 2160), sustained: record,
                                          prefersSharpness: true, now: 0)
        try check(other.startingSettings(maximumMegabits: 20).longestEdge == 8192 && same.startingSettings(maximumMegabits: 20).longestEdge == 2560,
                  "A session started from a size measured under the other preference")
        try check(try JSONDecoder().decode(SustainedVideoSize.self, from: JSONEncoder().encode(record)) == record,
                  "The preference did not round-trip with the sustained size")
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
        try check(quality.observe(sample(delivery: 200), now: 9) == nil, "One congested window changed quality")
        quality.resetObservation(now: 20)
        try check(quality.observe(sample(delivery: 200), now: 21) == nil, "Suspension retained congestion time")
        try rejects("Invalid settings were accepted") {
            _ = try MediaQualityPolicy(hostDefault: StreamSettings(framesPerSecond: 999), now: 0)
        }
    }

    run("Network adaptation trims bitrate on congestion, halves it on a severe queue and keeps text readable") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 30)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1920, 1240), now: 0)
        try check(quality.observe(sample(loss: 0.05, queue: 70), now: 3) == nil, "One congested window changed quality")
        let trimmed = quality.observe(sample(loss: 0.05, queue: 70), now: 4)
        try check(trimmed == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20), "Congestion did not trim bitrate: \(String(describing: trimmed))")
        _ = quality.confirmApplied(trimmed!, now: 4)
        var steps: [StreamSettings] = []
        var time = 4.0
        for _ in 0..<6 {
            time += 1
            if let next = quality.observe(sample(loss: 0.2, queue: 70), now: time) { steps.append(next); _ = quality.confirmApplied(next, now: time) }
        }
        try check(steps == [StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 10),
                            StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 5),
                            StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 2),
                            StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 1)],
                  "Heavy loss with a growing queue did not halve bitrate before lowering frame rate, then size: \(steps)")
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
        guard let down = failing.observe(sample(delivery: 600), now: time) else { throw CheckFailure("Failed step was not reduced") }
        _ = failing.confirmApplied(down, now: time)
        try check(failing.bitrateHold == MediaQualityPolicy.initialBitrateHold * 2, "A bitrate step that failed soon did not back off")
        try check(failing.upgradeHold == MediaQualityPolicy.initialUpgradeHold, "A bitrate failure delayed frame rate or size upgrades")
        // When both pixel and bitrate upgrades are in probation, a subsequent bitrate step does not erase pixel probation,
        // and quiet screens do not trigger pixel upgrades while bitrate is below the ceiling.
        let mixedCeiling = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 60)
        let mixedStart = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 10)
        var mixed = try MediaQualityPolicy(hostDefault: mixedCeiling, preferred: mixedCeiling, applied: mixedStart,
                                           bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1200), now: 0)
        for quietTime in 1...30 {
            try check(mixed.observe(sample(received: 0.2), now: Double(quietTime)) == nil,
                      "A quiet screen below the bitrate ceiling triggered an upgrade")
        }
        var mixedTime = 30.0, mixedBitrate: StreamSettings?
        for _ in 0..<4 where mixedBitrate == nil {
            mixedTime += 1
            mixedBitrate = mixed.observe(sample(received: 8), now: mixedTime)
        }
        // At t=34 (4 filled seconds), bitrate upgrades first (10 -> 15) instead of being blocked by the 10-second pixel hold.
        try check(mixedBitrate == StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 15) && mixedTime == 34,
                  "Bitrate upgrade was blocked by the longer pixel hold: \(String(describing: mixedBitrate))")
        _ = mixed.confirmApplied(mixedBitrate!, now: mixedTime)
        // If the stream no longer fills 50% of 15 Mbps (e.g. 5 Mbps at 30 fps) until pixel rate rises, allow pixel upgrade at 15 Mbps once filled earlier,
        // or when filled at 15 Mbps for 10 seconds after a pixel upgrade, test combined probation:
        var bothProbation = try MediaQualityPolicy(hostDefault: mixedCeiling, preferred: mixedCeiling,
                                                   applied: StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 40),
                                                   bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1200), now: 0)
        var pTime = 0.0, firstUp: StreamSettings?
        while firstUp == nil, pTime < 20 { pTime += 1; firstUp = bothProbation.observe(sample(received: 10), now: pTime) }
        try check(firstUp == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 40), "Expected FPS upgrade first when bitrate is not filled")
        _ = bothProbation.confirmApplied(firstUp!, now: pTime)
        var secondUp: StreamSettings?
        while secondUp == nil, pTime < 30 { pTime += 1; secondUp = bothProbation.observe(sample(received: 30), now: pTime) }
        try check(secondUp == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 50), "Expected bitrate upgrade within probation")
        _ = bothProbation.confirmApplied(secondUp!, now: pTime)
        pTime += 1
        guard let bothReduced = bothProbation.observe(sample(delivery: 600), now: pTime) else { throw CheckFailure("Expected reduction after combined upgrade") }
        _ = bothProbation.confirmApplied(bothReduced, now: pTime)
        try check(bothProbation.bitrateHold == MediaQualityPolicy.initialBitrateHold * 2
                  && bothProbation.upgradeHold == MediaQualityPolicy.initialUpgradeHold * 2,
                  "A bitrate upgrade inside pixel probation erased the pixel upgrade backoff")
    }

    run("After network reductions the bitrate returns to half of what the route carried within seconds, and a failed step halves that goal") {
        // Small enough that 1 Mbps keeps the picture readable, so only the bitrate moves.
        let ceiling = StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 30)
        func settledAndCollapsed() throws -> (MediaQualityPolicy, Double) {
            var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                                 appliedSize: (1280, 800), now: 0)
            var time = 0.0
            for _ in 0..<31 { time += 1; _ = quality.observe(sample(frames: 30, received: 1), now: time) }
            try check(quality.settledMegabits == 30, "The route did not settle at its ceiling")
            for _ in 0..<6 {
                time += 1
                if let next = quality.observe(sample(frames: 30, delivery: 600), now: time) { _ = quality.confirmApplied(next, now: time) }
            }
            try check(quality.effective == StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 1),
                      "A severe queue did not take the bitrate down: \(quality.effective)")
            return (quality, time)
        }
        // A quiet screen fills nothing, yet the route is taken back to half of the 30 Mbps it carried.
        var (quality, time) = try settledAndCollapsed()
        let started = time
        var steps: [Int] = []
        while time < started + 120, quality.effective.megabits < 15 {
            time += 1
            if let next = quality.observe(sample(frames: 30, received: 0.2), now: time) {
                steps.append(next.megabits)
                _ = quality.confirmApplied(next, now: time)
            }
        }
        try check(steps == [2, 4, 8, 15] && time - started == 16, "The bitrate did not double back to half in 16 s: \(steps) in \(time - started) s")
        // Beyond half, a quiet screen proves nothing, as before.
        for _ in 0..<60 {
            time += 1
            try check(quality.observe(sample(frames: 30, received: 0.2), now: time) == nil, "A quiet screen raised the bitrate beyond half")
        }
        // A step back up that congestion ends within its probation halves the goal and doubles the wait.
        var (marginal, clock) = try settledAndCollapsed()
        var first: StreamSettings?
        while first == nil, clock < 60 { clock += 1; first = marginal.observe(sample(frames: 30, received: 0.2), now: clock) }
        try check(first?.megabits == 2 && marginal.confirmApplied(first!, now: clock), "Recovery did not begin with one doubling")
        var failed: StreamSettings?
        while failed == nil, clock < 70 { clock += 1; failed = marginal.observe(sample(frames: 30, delivery: 600), now: clock) }
        try check(failed?.megabits == 1 && marginal.confirmApplied(failed!, now: clock), "Congestion did not end the step")
        let failedAt = clock
        var climb: [(megabits: Int, after: Double)] = []
        for _ in 0..<120 {
            clock += 1
            if let next = marginal.observe(sample(frames: 30, received: 0.2), now: clock) {
                climb.append((next.megabits, clock - failedAt))
                _ = marginal.confirmApplied(next, now: clock)
            }
        }
        try check(climb.map(\.megabits) == [2, 4, 6] && climb.first?.after == 8,
                  "A failed step did not halve the goal to 6 Mbps and wait 8 s: \(climb)")
    }

    run("Bitrate increases needed to restore frame rate respect failed-step backoff on a marginal link") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 15)
        let sustainable = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 3)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, applied: sustainable,
                                             bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1200), now: 0)
        var lastReduction = 0
        var waits: [Int] = []
        for second in 1...386 {
            // Scrolling at 1.4 Mbps qualifies for pixel recovery but does not fill half the 3 Mbps target.
            // A 4 Mbps probe makes this path lose packets before the requested 60 fps becomes affordable:
            // loss that arrives with an upgrade still on probation takes the upgrade back.
            let probing = quality.effective.megabits == 4
            let observation = probing ? sample(loss: 0.05) : sample(received: 1.4)
            let now = Double(second)
            if let next = quality.observe(observation, now: now) {
                try check(quality.confirmApplied(next, now: now), "Host confirmation failed")
                if probing {
                    try check(next == sustainable, "Congestion did not restore the sustainable level")
                    lastReduction = second
                } else {
                    try check(next.megabits == 4 && next.framesPerSecond == 30, "Unexpected recovery step")
                    waits.append(second - lastReduction)
                }
            }
        }
        try check(waits == [10, 10, 16, 32, 64, 120, 120],
                  "Pixel recovery bypassed the bitrate retry delay: \(waits)")
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

    run("A reconnect soon after a session starts from the bitrate that route settled at, and only then") {
        var memory = MediaStartingBitrate()
        let direct = "direct|home.test|5908", relay = "relay|node.test|7443|device"
        try check(memory.maximum(route: direct, fallback: 20, now: 0) == 20, "An unknown route did not use the default cap")
        memory.remember(3, reducing: false, route: direct, now: 100)
        memory.remember(50, reducing: false, route: relay, now: 100)
        try check(memory.maximum(route: direct, fallback: 20, now: 160) == 3 && memory.maximum(route: relay, fallback: 15, now: 160) == 50,
                  "A fresh session's settled bitrate was not resumed, or routes were mixed")
        try check(memory.maximum(route: "relay|other.test|7443|device", fallback: 15, now: 160) == 15, "Another route used this route's bitrate")
        let expiry = 100 + MediaStartingBitrate.lifetime
        try check(memory.maximum(route: direct, fallback: 20, now: expiry - 1) == 3 && memory.maximum(route: direct, fallback: 20, now: expiry) == 20
                  && memory.maximum(route: direct, fallback: 20, now: 50) == 20,
                  "A stale or future entry still set the starting bitrate")
        // A session that ended on its way down may have met a worse path: it can lower the default, never raise it.
        memory.remember(50, reducing: true, route: relay, now: 200)
        memory.remember(3, reducing: true, route: direct, now: 200)
        try check(memory.maximum(route: relay, fallback: 15, now: 210) == 15 && memory.maximum(route: direct, fallback: 20, now: 210) == 3,
                  "A session that ended while reducing raised the default starting cap, or lost its lower level")
        memory.remember(0, reducing: false, route: direct, now: 220); memory.remember(8, reducing: false, route: direct, now: .nan)
        try check(memory.maximum(route: direct, fallback: 20, now: 230) == 3, "An invalid value replaced a valid one")
        for index in 0..<40 { memory.remember(4, reducing: false, route: "direct|host-\(index)|5908", now: 300 + Double(index)) }
        try check(memory.maximum(route: "direct|host-39|5908", fallback: 20, now: 400) == 4
                  && memory.maximum(route: "direct|host-0|5908", fallback: 20, now: 400) == 20,
                  "The memory was unbounded or dropped its newest route")
        // The remembered value only caps the start; the ceiling still bounds it.
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 30)
        let capped = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates, now: 0)
        try check(capped.startingSettings(maximumMegabits: 3).megabits == 3 && capped.startingSettings(maximumMegabits: 50) == ceiling,
                  "A remembered bitrate exceeded the chosen ceiling or was not applied")
    }

    run("A bitrate counts as settled only after thirty seconds in effect, not while climbing or collapsing") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1920, 1200), now: 0)
        for second in 1...29 { _ = quality.observe(sample(received: 1), now: Double(second)) }
        try check(quality.settledMegabits == nil, "A bitrate settled before it was held for thirty seconds")
        _ = quality.observe(sample(received: 1), now: 30); _ = quality.observe(sample(received: 1), now: 31)
        try check(quality.settledMegabits == 20, "A bitrate held for thirty seconds did not settle: \(String(describing: quality.settledMegabits))")
        // A collapse in the last seconds of a session leaves the settled level where it was.
        var time = 31.0
        for _ in 0..<3 {
            time += 1
            if let next = quality.observe(sample(delivery: 600), now: time) { _ = quality.confirmApplied(next, now: time) }
        }
        try check(quality.effective.megabits < 10 && quality.settledMegabits == 20, "A collapse of a few seconds replaced the settled bitrate")
        // The lower level becomes the settled one only after it lasted as well.
        for _ in 0..<32 { time += 1; _ = quality.observe(sample(received: 0.2), now: time) }
        try check(quality.settledMegabits == quality.effective.megabits, "A sustained lower bitrate did not become the settled one")
        // Another route, and time spent suspended, do not count towards settling.
        quality.setLocalNetwork(true, now: time)
        try check(quality.settledMegabits == nil, "A route change kept the previous route's settled bitrate")
        quality.setLocalNetwork(false, now: time)
        for _ in 0..<20 { time += 1; _ = quality.observe(sample(received: 0.2), now: time) }
        quality.resetObservation(now: time)
        for _ in 0..<20 { time += 1; _ = quality.observe(sample(received: 0.2), now: time) }
        try check(quality.settledMegabits == nil, "Time before a suspension counted towards a settled bitrate")
    }

    run("Network condition follows delay growth; loss and jitter count only with it, and all need evidence") {
        try check(sample(loss: 0.12).networkCondition == .healthy && sample(loss: 0.04).networkCondition == .healthy
                  && sample(jitter: 80).networkCondition == .healthy && sample(loss: 0.12).measuredLoss == 0.12,
                  "Loss or jitter without delay growth was classified as congestion")
        try check(sample(loss: 0.12, queue: 70).networkCondition == .severe && sample(loss: 0.04, queue: 70).networkCondition == .congested
                  && sample(loss: 0.02, queue: 70).networkCondition == nil && sample(loss: 0.12, delivery: 90).networkCondition == .severe,
                  "Loss corroborated by delay growth changed its thresholds")
        try check(sample(queue: 150).networkCondition == .congested && sample(queue: 70).networkCondition == nil,
                  "Queue thresholds changed")
        func reliable(_ delivery: Double?) -> MediaPathSample { sample(count: 0, loss: nil, jitter: nil, queue: nil, delivery: delivery) }
        try check(reliable(600).networkCondition == .severe && reliable(200).networkCondition == .congested
                  && reliable(20).networkCondition == .healthy && reliable(nil).networkCondition == nil,
                  "Delivery thresholds changed")
        try check(sample(count: 2, loss: 0.5).networkCondition == nil && sample(count: 2, loss: 0.5).measuredLoss == nil,
                  "Sparse UDP windows were classified")
        // Transfers sharing the path yield on any stress, including what quality adaptation tolerates.
        try check(sample(loss: 0.04).showsPathStress && sample(jitter: 40).showsPathStress && reliable(200).showsPathStress
                  && !sample().showsPathStress && !sample(count: 2, loss: 0.5).showsPathStress && !reliable(20).showsPathStress,
                  "Path stress for background transfers changed")
    }

    run("A loss probe changes only the bitrate while the picture stays readable, and goes further when the path is still full") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 12)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1920, 1200), now: 0)
        // Recoveries interrupt what arrives, so a path that carries 4 Mbps shows less: three quarters of
        // that would need 30 fps, which restarts the stream. The probe stops at the lowest readable bitrate.
        _ = quality.observe(sample(loss: 0.5, received: 2.6), now: 1)
        let probe = quality.observe(sample(loss: 0.5, received: 2.6), now: 2)
        try check(probe == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 3),
                  "The loss probe restarted the stream instead of lowering the bitrate alone: \(String(describing: probe))")
        _ = quality.confirmApplied(probe!, now: 2)
        // The loss stays and the path delivers as much as before: it is full below the probe too, so the
        // next step follows at once and may now lower the frame rate.
        try check(quality.observe(sample(loss: 0.45, received: 2.8), now: 3) == nil
                  && quality.observe(sample(loss: 0.45, received: 2.8), now: 4) == nil, "The probe was judged early")
        let further = quality.observe(sample(loss: 0.45, received: 2.8), now: 5)
        try check(further == StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 2) && quality.toleratedLoss == 0,
                  "A path that stayed full under the probe was not lowered further at once: \(String(describing: further))")
        // At the readable floor already, the full reduction is the only probe left.
        let low = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 3)
        var floor = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: low, bitRates: StreamSettings.adaptiveBitRates,
                                           appliedSize: (1920, 1200), now: 0)
        _ = floor.observe(sample(loss: 0.3, received: 3), now: 1)
        try check(floor.observe(sample(loss: 0.3, received: 3), now: 2) == StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 2),
                  "Heavy loss at the readable floor had no probe left")
    }

    run("Loss without delay growth keeps the quality, and upgrades continue under it") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
        let start = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 10)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: start,
                                             bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1200), now: 0)
        var raised: [Int] = []
        for second in 1...40 {
            guard let next = quality.observe(sample(loss: 0.06, jitter: 60), now: Double(second)) else { continue }
            try check(next.megabits > quality.effective.megabits, "Moderate loss or jitter alone lowered the bitrate: \(next)")
            raised.append(next.megabits); _ = quality.confirmApplied(next, now: Double(second))
        }
        try check(raised == [15, 20] && quality.effective == ceiling && quality.toleratedLoss == 0,
                  "A lossy but uncongested path did not reach its ceiling: \(raised)")
    }

    run("Heavy loss that ignores a lower bitrate is the path's own: the settings return and it is tolerated") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
        var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1920, 1200), now: 0)
        try check(quality.observe(sample(loss: 0.15, received: 12), now: 1) == nil, "One heavy-loss window changed quality")
        // The probe lowers what is actually sent: three quarters of the 12 Mbps received, not of the 20 Mbps target.
        let probe = quality.observe(sample(loss: 0.15, received: 12), now: 2)
        try check(probe == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8) && quality.lastAdjustment == .network,
                  "Sustained heavy loss did not probe a lower bitrate: \(String(describing: probe))")
        _ = quality.confirmApplied(probe!, now: 2)
        try check(quality.observe(sample(loss: 0.16, received: 7), now: 3) == nil
                  && quality.observe(sample(loss: 0.14, received: 7), now: 4) == nil, "The loss probe was judged before three seconds")
        let restored = quality.observe(sample(loss: 0.15, received: 7), now: 5)
        try check(restored == ceiling && quality.lastAdjustment == .raise && quality.toleratedLoss >= 0.15,
                  "Loss that stayed at a lower bitrate did not restore the settings: \(String(describing: restored))")
        _ = quality.confirmApplied(ceiling, now: 5)
        for second in 6...40 {
            try check(quality.observe(sample(loss: 0.17, received: 12), now: Double(second)) == nil,
                      "Tolerated loss lowered the quality again")
        }
        // Clearly more loss than the path showed before is new evidence.
        var again: StreamSettings?
        for second in 41...43 where again == nil { again = quality.observe(sample(loss: 0.4, received: 12), now: Double(second)) }
        try check(again?.megabits == 8, "Loss far above the tolerated level did not probe again: \(String(describing: again))")
        // A new route or a manual choice forgets what the old path tolerated.
        quality.rejectPending(now: 43)
        _ = try quality.chooseManually(ceiling, now: 44)
        try check(quality.toleratedLoss == 0, "A manual choice kept the previous path's loss tolerance")
    }

    run("Heavy loss that falls with the bitrate was congestion: the reduction stays") {
        let ceiling = StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
        for stillFull in [false, true] {
            var quality = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                                 appliedSize: (1920, 1200), now: 0)
            _ = quality.observe(sample(loss: 0.3, received: 8), now: 1)
            // What arrived is what a full path carries: the probe goes to three quarters of it in one step,
            // not through the 20 Mbps target's own ladder and not further than congestion requires.
            guard let probe = quality.observe(sample(loss: 0.3, received: 8), now: 2) else { throw CheckFailure("No loss probe") }
            try check(probe == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 6),
                      "A policed path was not probed just below what it delivered: \(probe)")
            _ = quality.confirmApplied(probe, now: 2)
            // Either the loss is gone, or it stays while the path still delivers all it did before.
            let after = stillFull ? sample(loss: 0.3, received: 8) : sample(loss: 0.01, received: 3.9)
            for second in 3...5 {
                let next = quality.observe(after, now: Double(second))
                try check(next == nil || next!.megabits < probe.megabits, "A congested path got its bitrate back: \(String(describing: next))")
                if let next { _ = quality.confirmApplied(next, now: Double(second)) }
            }
            try check(quality.toleratedLoss == 0 && quality.effective.megabits <= 6, "Congestion loss was tolerated")
        }
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

    run("UDP pacing scales with weak WAN bitrates and jitter estimator filters single spikes while detecting sustained jitter") {
        let rate1 = MediaSession.udpPacingBytesPerSecond(megabits: 1) * 8 / 1_000_000
        let rate3 = MediaSession.udpPacingBytesPerSecond(megabits: 3) * 8 / 1_000_000
        let rate6 = MediaSession.udpPacingBytesPerSecond(megabits: 6) * 8 / 1_000_000
        let rate12 = MediaSession.udpPacingBytesPerSecond(megabits: 12) * 8 / 1_000_000
        try check(abs(rate1 - 2.0) < 1e-6 && abs(rate3 - 4.8) < 1e-6 && abs(rate6 - 9.6) < 1e-6 && abs(rate12 - 19.2) < 1e-6,
                  "Weak WAN UDP pacing remained floored at 12 Mbps: \(rate1), \(rate3), \(rate6), \(rate12)")
        let burst1 = MediaSession.udpPacingBurstBytes(megabits: 1)
        try check(burst1 >= Double(MediaFragment.maximumDatagramBytes + 1) * 4 && burst1 <= 8_192,
                  "Weak WAN UDP burst exceeded bounds: \(burst1)")
        let span = MediaSession.udpPacingSpan(payloadBytes: 4 * MediaFragment.maximumPayloadBytes, megabits: 3)
        let expectedWireBytes = Double(4 * MediaFragment.maximumPayloadBytes + 4 * (1 + MediaFragment.encodedHeaderBytes))
        try check(abs(span - expectedWireBytes / MediaSession.udpPacingBytesPerSecond(megabits: 3)) < 1e-9,
                  "UDP pacing span omitted wire header overhead")

        var jitter = MediaJitterEstimator()
        jitter.observeRoundTrip(0.010)
        try check(jitter.takeWindowMilliseconds() == nil, "Single RTT sample produced jitter")
        jitter.observeRoundTrip(0.010)
        try check(jitter.takeWindowMilliseconds() == 0, "Steady RTT reported jitter")
        try check(jitter.takeWindowMilliseconds() == nil, "Idle window replayed stale jitter")
        // One isolated 50 ms spike must stay below the 30 ms congestion threshold.
        jitter.observeRoundTrip(0.060)
        jitter.observeRoundTrip(0.010)
        guard let spikeJitter = jitter.takeWindowMilliseconds(), spikeJitter < 30 else {
            throw CheckFailure("Isolated RTT spike exceeded the 30 ms congestion threshold")
        }
        // Sustained 60 ms variation reaches >= 30 ms within a one-second probe cadence.
        for rtt in [0.075, 0.015, 0.080, 0.015] { jitter.observeRoundTrip(rtt) }
        guard let sustained = jitter.takeWindowMilliseconds(), sustained >= 30 else {
            throw CheckFailure("Sustained RTT variation did not cross the 30 ms congestion threshold")
        }
        try check(sample(jitter: sustained).showsPathStress && !sample(jitter: spikeJitter).showsPathStress
                  && sample(jitter: sustained).networkCondition == .healthy,
                  "Measured UDP jitter did not mark path stress, or was taken for congestion")
        jitter.reset()
        try check(jitter.takeWindowMilliseconds() == nil, "Reset jitter estimator retained old samples")
    }

    run("Degraded desktop sessions escape low-resolution bitrate deadlocks, classify non-LAN hosts and give encoder burst headroom") {
        // 1. Encoder DataRateLimits gives 1.5x 1-second burst headroom while staying strictly under MediaSession's 1.6x UDP pacer.
        for megabits in [1, 6, 15, 20, 60] {
            let limitBytes = Double(VideoEncoder.dataRateLimitBytes(megabits: megabits))
            let averageBytes = Double(megabits) * 125_000
            let udpPacerBytes = MediaSession.udpPacingBytesPerSecond(megabits: megabits)
            try check(abs(limitBytes - averageBytes * 1.5) < 1 && limitBytes < udpPacerBytes,
                      "Encoder DataRateLimits (\(limitBytes)) misaligned with average (\(averageBytes)) or UDP pacer (\(udpPacerBytes))")
        }

        // 2. Host classification distinguishes LAN/Bonjour/loopback from WAN, CGNAT/Overlay (100.64.0.0/10) and public IPv6.
        for local in ["127.0.0.1", "::1", "localhost", "mac-studio.local", "macbook", "192.168.1.20", "10.0.0.8", "172.16.5.4", "172.31.255.1", "fd12:3456::1", "fe80::1%en0"] {
            try check(MediaQualityPolicy.isLikelyLocalHost(local), "Expected local classification for \(local)")
        }
        for remote in ["100.64.0.1", "100.101.202.3", "172.32.0.1", "203.0.113.10", "remote.example.com", "240e:3b0:1234::8"] {
            try check(!MediaQualityPolicy.isLikelyLocalHost(remote), "Expected WAN/overlay classification for \(remote)")
        }

        // 3. Catch-22 recovery during active desktop scrolling: degraded to 1920@30 / 6 Mbps with ceiling 8192@60 / 60 Mbps (3456×2234 Retina).
        // Desktop scrolling produces ~2.2 Mbps (< 50% of 6 Mbps, so filledDuration stays 0), yet exceeds minimumBitsPerPixel so activeDuration advances.
        let ceiling = StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 60)
        let degraded = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 6)
        var desktop = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: degraded,
                                             bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1920, 1240), now: 0)
        var now = 0.0
        var trajectory: [StreamSettings] = []
        while now < 150, desktop.effective.dimensions(width: 3456, height: 2234) != (3456, 2234) || desktop.effective.framesPerSecond < 60 {
            now += 1
            // Simulate realistic desktop scrolling bitrate (~35% of current cap, always >= minimumBPP but < 50% filledShare).
            let desktopMbps = max(2.2, Double(desktop.effective.megabits) * 0.35)
            if let next = desktop.observe(sample(received: desktopMbps), now: now) {
                trajectory.append(next)
                _ = desktop.confirmApplied(next, now: now)
                let size = next.dimensions(width: 3456, height: 2234)
                try desktop.synchronizeApplied(next, size: size, now: now)
            }
        }
        try check(desktop.effective.dimensions(width: 3456, height: 2234) == (3456, 2234) && desktop.effective.framesPerSecond == 60,
                  "Active desktop session remained trapped below native Retina quality: \(trajectory), final=\(desktop.effective)")

        // 4. Quiet coding desktop degraded to 1280@30 / 2 Mbps recovers gently once sustained healthy time reaches degradedPixelRecoveryHold (45s).
        let severeDegraded = StreamSettings(longestEdge: 1280, framesPerSecond: 30, megabits: 2)
        var quietCoding = try MediaQualityPolicy(hostDefault: ceiling, preferred: ceiling, applied: severeDegraded,
                                                 bitRates: StreamSettings.adaptiveBitRates, appliedSize: (1280, 828), now: 0)
        for t in 1...44 {
            try check(quietCoding.observe(sample(received: 0.3), now: Double(t)) == nil,
                      "Quiet degraded screen recovered prematurely at t=\(t)s")
        }
        guard let step1 = quietCoding.observe(sample(received: 0.3), now: 45) else {
            throw CheckFailure("Sustained 45s healthy degraded session made zero recovery progress")
        }
        try check(step1.megabits > severeDegraded.megabits || step1.framesPerSecond > severeDegraded.framesPerSecond,
                  "Expected bitrate or FPS step toward sharpest desktop quality, got \(step1)")
    }
    run("Mapped transfers only trim bitrate under sustained transport credit pressure and recover after transfer") {
        let ceiling = StreamSettings(longestEdge: 1280, framesPerSecond: 60, megabits: 8)
        func sample(_ state: MappedTransferState?, fps: Int = 40, rate: Double = 8, compute: Double = 2) -> MediaPathSample {
            MediaPathSample(duration: 1, mediaActive: true, networkSamples: 0, decodedFrames: fps,
                            encodeMilliseconds: compute, decodeMilliseconds: 2, deliveryMilliseconds: 20,
                            receivedMegabits: rate, mappedTransfer: state)
        }
        var quality = try MediaQualityPolicy(hostDefault: ceiling, bitRates: StreamSettings.adaptiveBitRates,
                                             appliedSize: (1280, 720), now: 0)
        for tick in 1...6 {
            try check(quality.observe(sample(tick < 4 ? nil : .transferring), now: Double(tick)) == nil,
                      "A mapped transfer or low frame rate alone reduced desktop quality")
        }
        try check(quality.observe(sample(.waitingForVideoCredit), now: 7) == nil, "A single blocked window reduced quality")
        try check(quality.observe(sample(.waitingForVideoCredit, fps: 60), now: 8) == nil, "Full frame rate lost bitrate")
        try check(quality.observe(sample(.waitingForVideoCredit, rate: 1), now: 9) == nil, "Quiet content lost bitrate")
        try check(quality.observe(sample(.waitingForVideoCredit, compute: 23), now: 10) == nil, "A compute-bound window counted as link pressure")
        try check(quality.observe(sample(.waitingForVideoCredit), now: 11) == nil, "Mixed evidence accumulated")
        var reduced = ceiling
        reduced.megabits = 6
        try check(quality.observe(sample(.waitingForVideoCredit), now: 12) == reduced, "Stable frame credit pressure did not step down bitrate")
        try check(quality.confirmApplied(reduced, now: 12), "Could not confirm bitrate step")
        for tick in 13...50 {
            try check(quality.observe(sample(.transferring, fps: 60, rate: 6), now: Double(tick)) == nil,
                      "Healthy frames during the same transfer caused another quality transition")
        }
        var restored = false
        for tick in 51...75 {
            if quality.observe(sample(nil, fps: 60, rate: 6), now: Double(tick)) == ceiling { restored = true; break }
        }
        try check(restored, "Completing the mapped transfer left the video below its preferred ceiling")
    }

}
