import CoreGraphics
import Foundation
import QuietDeskCore

func runScrollChecks() {
    run("Fine scrolling accumulates positive and negative subpixel movement") {
        for direction: Double in [-1, 1] {
            var scroll = ScrollAccumulator()
            var pixels: Int32 = 0
            for _ in 0..<100 {
                if let step = try scroll.accumulate(deltaX: 0, deltaY: direction * 0.2) {
                    try check(step.x == 0, "Vertical scrolling changed the horizontal axis")
                    pixels += step.y
                }
            }
            try check(pixels == Int32(direction * 20), "Fine scrolling was lost or changed direction")
        }
    }

    run("Scroll axes accumulate independently and preserve ordinary wheel deltas") {
        var scroll = ScrollAccumulator()
        try check(try scroll.accumulate(deltaX: 0.25, deltaY: -0.5) == nil, "Subpixel motion produced an empty event")
        let vertical = try scroll.accumulate(deltaX: 0.25, deltaY: -0.5)
        try check(vertical?.x == 0 && vertical?.y == -1, "Vertical accumulation affected horizontal remainder")
        let horizontal = try scroll.accumulate(deltaX: 0.5, deltaY: 0)
        try check(horizontal?.x == 1 && horizontal?.y == 0, "Horizontal remainder was lost")
        let wheel = try scroll.accumulate(deltaX: -24, deltaY: 36)
        try check(wheel?.x == -24 && wheel?.y == 36, "Ordinary mouse wheel amount or direction changed")
    }

    run("Reversing and releasing control do not leave delayed scroll movement") {
        var scroll = ScrollAccumulator()
        try check(try scroll.accumulate(deltaX: 0.75, deltaY: -0.75) == nil, "Partial scroll emitted pixels")
        try check(try scroll.accumulate(deltaX: -0.75, deltaY: 0.75) == nil, "Reversed motion did not cancel")
        try check(try scroll.accumulate(deltaX: 0, deltaY: 0) == nil, "Cancelled motion left a scroll event")
        _ = try scroll.accumulate(deltaX: -0.75, deltaY: 0.75)
        scroll.reset()
        try check(try scroll.accumulate(deltaX: -0.5, deltaY: 0.5) == nil, "Released control retained old movement")
        let pixels = try scroll.accumulate(deltaX: -0.5, deltaY: 0.5)
        try check(pixels?.x == -1 && pixels?.y == 1, "Fresh movement after reset was lost")
    }

    run("Scroll limits reject invalid values without changing pending movement") {
        var scroll = ScrollAccumulator()
        _ = try scroll.accumulate(deltaX: 0.5, deltaY: -0.5)
        for invalid in [Double.nan, .infinity, -.infinity, 3000.1, -3000.1, .greatestFiniteMagnitude] {
            try rejects("Accepted invalid horizontal scroll") { _ = try scroll.accumulate(deltaX: invalid, deltaY: 0.5) }
            try rejects("Accepted invalid vertical scroll") { _ = try scroll.accumulate(deltaX: 0.5, deltaY: invalid) }
        }
        let pending = try scroll.accumulate(deltaX: 0.5, deltaY: -0.5)
        try check(pending?.x == 1 && pending?.y == -1, "Rejected input altered pending movement")
        let limit = try scroll.accumulate(deltaX: 3000, deltaY: -3000)
        try check(limit?.x == 3000 && limit?.y == -3000, "Valid limits overflowed or were truncated")
    }

    run("Optional scroll detail round-trips, is absent from older messages and uses CoreGraphics phase numbers") {
        func roundTrip(_ input: RemoteInput) throws -> RemoteInput {
            let decoded = try Wire.readJSON(RemoteInput.self, try Wire.json(.input, input).payload)
            try decoded.validate()
            return decoded
        }
        var wheel = RemoteInput(kind: .scroll)
        wheel.deltaY = 36; wheel.lineDeltaX = -0.25; wheel.lineDeltaY = 3
        let lines = try roundTrip(wheel)
        try check(lines.lineDeltaX == -0.25 && lines.lineDeltaY == 3 && lines.deltaY == 36
                  && lines.scrollPhase == nil && lines.momentumPhase == nil, "Line wheel detail changed on the wire")
        for phase in [RemoteInput.ScrollPhase.mayBegin, .began, .changed, .ended, .cancelled] {
            var gesture = RemoteInput(kind: .scroll)
            gesture.deltaY = -2.5; gesture.scrollPhase = phase
            try check(try roundTrip(gesture).scrollPhase == phase, "Gesture phase changed on the wire")
        }
        for phase in [RemoteInput.MomentumPhase.began, .changed, .ended] {
            var momentum = RemoteInput(kind: .scroll)
            momentum.momentumPhase = phase
            try check(try roundTrip(momentum).momentumPhase == phase, "Momentum phase changed on the wire")
        }
        let plain = String(decoding: try Wire.json(.input, RemoteInput(kind: .scroll)).payload, as: UTF8.self)
        try check(!plain.contains("lineDelta") && !plain.contains("Phase"), "A scroll without detail carried new fields")
        let older = Data(#"{"kind":"scroll","x":0.5,"y":0.5,"button":0,"keyCode":0,"flags":0,"deltaX":0,"deltaY":-12,"clicks":1,"isRepeat":false}"#.utf8)
        let legacy = try Wire.readJSON(RemoteInput.self, older)
        try legacy.validate()
        try check(legacy.deltaY == -12 && legacy.lineDeltaX == nil && legacy.lineDeltaY == nil
                  && legacy.scrollPhase == nil && legacy.momentumPhase == nil, "An older viewer's scroll gained detail")
        let numbers = [RemoteInput.ScrollPhase.began.rawValue, RemoteInput.ScrollPhase.changed.rawValue,
                       RemoteInput.ScrollPhase.ended.rawValue, RemoteInput.ScrollPhase.cancelled.rawValue,
                       RemoteInput.ScrollPhase.mayBegin.rawValue,
                       RemoteInput.MomentumPhase.began.rawValue, RemoteInput.MomentumPhase.changed.rawValue,
                       RemoteInput.MomentumPhase.ended.rawValue]
        let system = [CGScrollPhase.began.rawValue, CGScrollPhase.changed.rawValue, CGScrollPhase.ended.rawValue,
                      CGScrollPhase.cancelled.rawValue, CGScrollPhase.mayBegin.rawValue,
                      CGMomentumScrollPhase.begin.rawValue, CGMomentumScrollPhase.continuous.rawValue,
                      CGMomentumScrollPhase.end.rawValue].map(Int.init)
        try check(numbers == system, "Wire phase numbers drifted from CoreGraphics")
    }

    run("Scroll detail is rejected on other inputs, when incomplete, mixed or out of range, or with unknown phases") {
        var invalid: [RemoteInput] = []
        for kind in [RemoteInput.Kind.move, .down, .keyDown] {
            var lines = RemoteInput(kind: kind); lines.lineDeltaX = 0; lines.lineDeltaY = 1; invalid.append(lines)
            var phase = RemoteInput(kind: kind); phase.scrollPhase = .began; invalid.append(phase)
            var momentum = RemoteInput(kind: kind); momentum.momentumPhase = .ended; invalid.append(momentum)
        }
        var oneAxis = RemoteInput(kind: .scroll); oneAxis.lineDeltaY = 1; invalid.append(oneAxis)
        var mixed = RemoteInput(kind: .scroll); mixed.lineDeltaX = 0; mixed.lineDeltaY = 1; mixed.scrollPhase = .changed
        invalid.append(mixed)
        var mixedMomentum = mixed; mixedMomentum.scrollPhase = nil; mixedMomentum.momentumPhase = .changed
        invalid.append(mixedMomentum)
        for value in [Double.nan, .infinity, -.infinity, RemoteInput.maximumLineDelta + 0.001, -RemoteInput.maximumLineDelta - 0.001] {
            var bad = RemoteInput(kind: .scroll); bad.lineDeltaX = value; bad.lineDeltaY = 0; invalid.append(bad)
            var badY = RemoteInput(kind: .scroll); badY.lineDeltaX = 0; badY.lineDeltaY = value; invalid.append(badY)
        }
        for input in invalid { try rejects("Accepted invalid scroll detail") { try input.validate() } }
        var limit = RemoteInput(kind: .scroll)
        limit.lineDeltaX = RemoteInput.maximumLineDelta; limit.lineDeltaY = -RemoteInput.maximumLineDelta
        try limit.validate()
        var both = RemoteInput(kind: .scroll); both.scrollPhase = .changed; both.momentumPhase = .changed
        try both.validate()
        for json in [#"{"kind":"scroll","x":0,"y":0,"button":0,"keyCode":0,"flags":0,"deltaX":0,"deltaY":0,"clicks":1,"isRepeat":false,"scrollPhase":3}"#,
                     #"{"kind":"scroll","x":0,"y":0,"button":0,"keyCode":0,"flags":0,"deltaX":0,"deltaY":0,"clicks":1,"isRepeat":false,"momentumPhase":4}"#] {
            try rejects("Decoded an unknown scroll phase") { _ = try Wire.readJSON(RemoteInput.self, Data(json.utf8)) }
        }
    }
}
