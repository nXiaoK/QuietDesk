import Foundation
import QuietDeskCore

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
    }

    run("A simulated sleep gap expires idle and RTT state in the same continuous time domain") {
        let beforeSleep = SessionClock.now
        var idle = SessionIdlePolicy(now: beforeSleep)
        var probe = RoundTripProbe()
        guard let old = probe.begin(at: beforeSleep) else { throw CheckFailure("No pre-sleep probe") }
        let afterWake = beforeSleep + 3_600
        try check(idle.tick(now: afterWake) && idle.isPaused, "Sleep interval did not count toward idle pause")
        try check(probe.complete(old, at: afterWake) == nil, "Pre-sleep RTT survived a long sleep gap")
        try check(idle.activity(now: afterWake, focused: true), "Focused activity could not resume after wake")
        guard let current = probe.begin(at: afterWake) else { throw CheckFailure("No post-wake probe") }
        try check(probe.complete(old, at: afterWake + 0.01) == nil, "Old echo completed a post-wake probe")
        try check(probe.complete(current, at: afterWake + 0.02) != nil, "Fresh post-wake probe did not recover")
    }
}
