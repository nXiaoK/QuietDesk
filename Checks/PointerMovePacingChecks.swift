import Foundation
import QuietDeskCore

func runPointerMovePacingChecks() {
    func move(_ value: Double) -> RemoteInput {
        var input = RemoteInput(kind: .move)
        input.x = value; input.y = 1 - value
        return input
    }

    func same(_ actual: RemoteInput?, _ expected: RemoteInput) throws -> Bool {
        guard let actual else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(actual) == encoder.encode(expected)
    }

    run("Pointer pacing sends the first move immediately and retains the complete latest payload") {
        var pacer = PointerMovePacer()
        let first = move(0.1)
        try check(try same(pacer.offer(first, now: 0), first), "First movement was delayed")
        try check(pacer.nextDelay(now: 0) == nil, "A sent move was still pending")
        _ = pacer.offer(move(0.2), now: 0.005)
        var latest = move(0.9)
        latest.flags = 0x20_000; latest.button = 2; latest.clicks = 3
        latest.keyCode = 42; latest.deltaX = 1.5; latest.deltaY = -2.5
        latest.isRepeat = true; latest.independentCapsLock = true
        try check(pacer.offer(latest, now: 0.01) == nil, "An early move exceeded the sending rate")
        try check(abs((pacer.nextDelay(now: 0.01) ?? -1) - (PointerMovePacer.interval - 0.01)) < 1e-12,
                  "Replacing the payload postponed its deadline")
        try check(pacer.takeDue(now: PointerMovePacer.interval - 0.000_001) == nil, "A timer emitted early")
        try check(try same(pacer.takeDue(now: PointerMovePacer.interval), latest), "Latest move lost fields or was not sent")
        try check(pacer.takeDue(now: PointerMovePacer.interval) == nil && pacer.nextDelay(now: 1) == nil,
                  "A coalesced move was emitted more than once")
    }

    run("125 Hz input uses approximately 60 Hz timer slots instead of dropping to 41 Hz") {
        var pacer = PointerMovePacer()
        var sends: [(TimeInterval, RemoteInput)] = []
        var now = 0.0
        if let input = pacer.offer(move(0), now: now) { sends.append((now, input)) }
        for index in 1...125 {
            let eventAt = Double(index) / 125
            while let delay = pacer.nextDelay(now: now), now + delay <= eventAt {
                now += delay
                if let input = pacer.takeDue(now: now) { sends.append((now, input)) }
            }
            now = eventAt
            if let input = pacer.offer(move(Double(index) / 125), now: now) { sends.append((now, input)) }
        }
        if let delay = pacer.nextDelay(now: now) {
            now += delay
            if let input = pacer.takeDue(now: now) { sends.append((now, input)) }
        }
        try check((60...62).contains(sends.count), "125 Hz input produced \(sends.count) moves instead of about 60 per second")
        for pair in zip(sends, sends.dropFirst()) {
            try check(abs(pair.1.0 - pair.0.0 - PointerMovePacer.interval) < 1e-10,
                      "Input timing changed the established timer cadence")
        }
        try check(sends.last?.1.x == 1 && pacer.nextDelay(now: now) == nil, "The final 125 Hz position was lost")
    }

    run("A stopped mouse still emits its final pending position without a later input event") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 0)
        let final = move(0.7)
        try check(pacer.offer(final, now: 0.004) == nil, "The final movement bypassed pacing")
        guard let delay = pacer.nextDelay(now: 0.004) else { throw CheckFailure("No timer was requested for the final position") }
        try check(try same(pacer.takeDue(now: 0.004 + delay), final), "Stopping the mouse discarded the final position")
        try check(pacer.takeDue(now: 1) == nil && pacer.nextDelay(now: 1) == nil, "An idle mouse replayed a previous move")
    }

    run("A late pointer timer sends one latest move without spending missed slots as a burst") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 0)
        _ = pacer.offer(move(0.4), now: 0.001)
        try check(pacer.takeDue(now: 1)?.x == 0.4, "A delayed timer lost the pending move")
        try check(pacer.offer(move(0.8), now: 1.001) == nil && pacer.takeDue(now: 1.002) == nil,
                  "Late timer credit created a burst")
        guard let delay = pacer.nextDelay(now: 1.002) else { throw CheckFailure("No deadline after a late timer") }
        try check(pacer.takeDue(now: 1.002 + delay)?.x == 0.8, "Late timer recovery lost new movement")
    }

    run("Flushing before buttons, dragging, scrolling and release leaves no old move after the event") {
        for kind in [RemoteInput.Kind.down, .drag, .scroll, .up] {
            var pacer = PointerMovePacer()
            var wire: [RemoteInput] = []
            if let input = pacer.offer(move(0), now: 0) { wire.append(input) }
            _ = pacer.offer(move(0.5), now: 0.001)
            if let input = pacer.flush(now: 0.002) { wire.append(input) }
            wire.append(RemoteInput(kind: kind))
            try check(wire.map(\.kind) == [.move, .move, kind] && wire[1].x == 0.5,
                      "Pending movement crossed a reliable \(kind) event")
            try check(pacer.flush(now: 0.002) == nil && pacer.takeDue(now: 1) == nil,
                      "A move was replayed after \(kind)")
        }
    }

    run("Cancel and reentry discard old movement and stale timer calls cannot replay it") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 0)
        _ = pacer.offer(move(0.2), now: 0.001)
        pacer.cancel(); pacer.cancel()
        try check(pacer.nextDelay(now: 0.002) == nil && pacer.takeDue(now: 0.002) == nil,
                  "Cancellation retained an old movement")
        try check(pacer.offer(move(0.8), now: 0.003)?.x == 0.8, "Reentry delayed the first fresh move")
        _ = pacer.offer(move(0.9), now: 0.004)
        try check(pacer.takeDue(now: PointerMovePacer.interval) == nil, "An old timer emitted the previous burst's move")
        try check(pacer.takeDue(now: 0.003 + PointerMovePacer.interval)?.x == 0.9,
                  "Reentry lost its new pending move")
    }

    run("Invalid or reversed times cannot replace pending movement or advance its deadline") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 10)
        _ = pacer.offer(move(0.4), now: 10.005)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 9, .greatestFiniteMagnitude] {
            try check(pacer.offer(move(0.9), now: invalid) == nil && pacer.takeDue(now: invalid) == nil
                      && pacer.nextDelay(now: invalid) == nil, "Invalid time changed pacing")
        }
        try check(pacer.takeDue(now: 10 + PointerMovePacer.interval)?.x == 0.4,
                  "Invalid time discarded or replaced the previous valid input")
    }

    run("An invalid boundary flush cancels pending movement instead of replaying it later") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 10)
        _ = pacer.offer(move(0.4), now: 10.005)
        try check(pacer.flush(now: 9) == nil && pacer.takeDue(now: 11) == nil,
                  "A failed flush replayed movement beyond a reliable event boundary")
    }

    run("Non-move events and invalid payloads never overwrite a valid pending pointer position") {
        var pacer = PointerMovePacer()
        _ = pacer.offer(move(0), now: 0)
        let pending = move(0.3)
        _ = pacer.offer(pending, now: 0.001)
        var badX = move(0); badX.x = .nan
        var badY = move(0); badY.y = 1.1
        var badKey = move(0); badKey.keyCode = 128
        var badDelta = move(0); badDelta.deltaX = .infinity
        for invalid in [RemoteInput(kind: .down), RemoteInput(kind: .drag), badX, badY, badKey, badDelta] {
            try check(pacer.offer(invalid, now: 0.005) == nil, "An invalid or non-move input was emitted")
        }
        try check(try same(pacer.takeDue(now: PointerMovePacer.interval), pending), "Rejected input poisoned the pending move")
    }
}
