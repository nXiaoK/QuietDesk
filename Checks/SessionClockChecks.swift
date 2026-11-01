import Foundation
@testable import QuietDeskCore

func runSessionClockChecks() {
    run("Session clock reports finite monotonic seconds") {
        let first = SessionClock.now
        var previous = first
        for _ in 0..<1_000 {
            let next = SessionClock.now
            try check(next.isFinite && next >= previous, "Session clock moved backwards")
            previous = next
        }
        Thread.sleep(forTimeInterval: 0.02)
        try check(SessionClock.now - first >= 0.015, "Session clock does not use elapsed seconds")
        let uptime = SessionClock.uptime
        Thread.sleep(forTimeInterval: 0.02)
        try check(SessionClock.uptime - uptime >= 0.015, "Uptime does not use elapsed seconds")
    }

    run("A simulated sleep gap expires idle and RTT state in the same continuous time domain") {
        let beforeSleep = SessionClock.now
        var idle = SessionIdlePolicy(now: beforeSleep)
        var probe = RoundTripProbe()
        guard let old = probe.begin(at: beforeSleep) else { throw CheckFailure("No pre-sleep probe") }
        let afterWake = beforeSleep + 3_600
        try check(idle.tick(now: afterWake, attended: false) && idle.isPaused, "Sleep interval did not count toward idle pause")
        try check(probe.complete(old, at: afterWake) == nil, "Pre-sleep RTT survived a long sleep gap")
        try check(idle.activity(now: afterWake, attended: true), "Attended activity could not resume after wake")
        guard let current = probe.begin(at: afterWake) else { throw CheckFailure("No post-wake probe") }
        try check(probe.complete(old, at: afterWake + 0.01) == nil, "Old echo completed a post-wake probe")
        try check(probe.complete(current, at: afterWake + 0.02) != nil, "Fresh post-wake probe did not recover")
    }

    run("Regular local ticks never extend a dead peer's liveness deadline") {
        var grace = LocalSchedulingGrace(now: 0)
        for tick in 1...100 {
            let now = Double(tick) * 0.1
            try check(!grace.observe(now: now, interval: 0.1, allowance: 1), "Regular tick looked suspended")
            try check(!grace.isActive(at: now), "Regular tick granted grace")
        }
    }
    run("A scheduling gap grants only a bounded fresh response window") {
        var grace = LocalSchedulingGrace(now: 0)
        try check(grace.observe(now: 60, interval: 0.1, allowance: 1), "Suspension was not detected")
        try check(grace.until == 61 && grace.isActive(at: 60), "Missing fresh response window")
        for tick in 1...10 { grace.observe(now: 60 + Double(tick) * 0.1, interval: 0.1, allowance: 1) }
        try check(!grace.isActive(at: 61), "Normal ticks extended grace indefinitely")
        try check(!grace.observe(now: .nan, interval: 0.1, allowance: 1), "Accepted NaN")
        try check(!grace.observe(now: 0, interval: 0.1, allowance: 1), "Accepted backwards time")
        try check(grace.observe(now: 120, interval: 0.1, allowance: 1), "A later local suspension was ignored")
    }
    run("Media liveness recovery does not invent a pong or permanently preserve a dead route") {
        var policy = MediaPathPolicy(capable: true, now: 0)
        _ = policy.tick(now: 0)
        guard let probe = policy.probeID else { throw CheckFailure("No probe") }
        _ = policy.probeSucceeded(id: probe, now: 0.1)
        _ = policy.mediaBecameUsable(epoch: policy.epoch, path: .udp, now: 0.2)
        policy.allowLivenessRecovery(now: 60)
        try check(policy.tick(now: 60).isEmpty, "Local stall immediately killed UDP")
        try check(policy.tick(now: 60.9).isEmpty, "Grace ended before a fresh pong could arrive")
        try check(!policy.tick(now: 61).isEmpty && policy.lastReason == .noPong, "Dead UDP survived grace")

        var pending = MediaPathPolicy(capable: true, now: 0)
        _ = pending.tick(now: 0)
        pending.allowLivenessRecovery(now: 60)
        try check(pending.tick(now: 60).isEmpty, "A pending probe expired at resume")
        try check(!pending.tick(now: 61).isEmpty && pending.lastReason == .probeTimeout, "Probe lost its timeout")
    }
}
