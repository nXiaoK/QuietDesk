import Foundation
import QuietDeskCore

func runInputGestureChecks() {
    run("Hello relativeMouseV1 and trackpadGesturesV1 backward compatibility and round-trip") {
        let legacyJSON = """
        {"version":\(Wire.version),"name":"LegacyHost","width":1920,"height":1080,"settings":{"longestEdge":1920,"framesPerSecond":60,"megabits":10},"canControl":true}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(Hello.self, from: legacyJSON)
        try legacy.validate()
        try check(legacy.relativeMouseV1 == nil && legacy.trackpadGesturesV1 == nil,
                  "Legacy Hello invented relativeMouseV1 or trackpadGesturesV1")

        let modern = Hello(
            name: "ModernHost",
            width: 2560,
            height: 1440,
            settings: StreamSettings(),
            canControl: true,
            relativeMouseV1: true,
            trackpadGesturesV1: true
        )
        let message = try Wire.json(.hello, modern)
        let decoded = try Wire.readJSON(Hello.self, message.payload)
        try decoded.validate()
        try check(decoded.relativeMouseV1 == true && decoded.trackpadGesturesV1 == true,
                  "Modern Hello lost relativeMouseV1 or trackpadGesturesV1")
    }

    run("RemoteInput relativeMouse and trackpad gesture validation") {
        // Valid relativeMouse move and drag
        var relMove = RemoteInput(kind: .move)
        relMove.x = 0.5; relMove.y = 0.5
        relMove.relativeMouse = true
        relMove.pointerDeltaX = 48.5; relMove.pointerDeltaY = -19.25
        relMove.pointerSequence = 7
        try relMove.validate()
        let encodedMove = try Wire.json(.input, relMove)
        let decodedMove = try Wire.readJSON(RemoteInput.self, encodedMove.payload)
        try check(decodedMove.relativeMouse == true && decodedMove.pointerDeltaX == 48.5 && decodedMove.pointerDeltaY == -19.25,
                  "Relative mouse move round-trip altered fields")

        // Relative mouse move without pointer deltas must fail validation
        var missingDelta = RemoteInput(kind: .move)
        missingDelta.relativeMouse = true
        try rejects("Accepted relativeMouse move without pointerDeltaX/Y") { try missingDelta.validate() }

        // Relative mouse on keyboard event must fail validation
        var keyRel = RemoteInput(kind: .keyDown)
        keyRel.keyCode = 12
        keyRel.relativeMouse = true
        try rejects("Accepted relativeMouse on keyboard event") { try keyRel.validate() }

        // Relative mouse anchor on click and scroll is valid
        var relClick = RemoteInput(kind: .down)
        relClick.x = 0.5; relClick.y = 0.5; relClick.relativeMouse = true
        try relClick.validate()

        // Valid magnify, rotate and smartMagnify
        var mag = RemoteInput(kind: .magnify)
        mag.x = 0.4; mag.y = 0.6; mag.magnification = 0.35; mag.gesturePhase = .changed; mag.pointerSequence = 8
        try mag.validate()

        var rot = RemoteInput(kind: .rotate)
        rot.x = 0.4; rot.y = 0.6; rot.rotation = -22.5; rot.gesturePhase = .began; rot.pointerSequence = 9
        try rot.validate()

        var smart = RemoteInput(kind: .smartMagnify)
        smart.x = 0.4; smart.y = 0.6; smart.pointerSequence = 10
        try smart.validate()

        // Out-of-bounds and cross-contaminated gesture fields must fail validation
        var hugeMag = mag; hugeMag.magnification = RemoteInput.maximumMagnification + 0.01
        try rejects("Accepted excessive magnification") { try hugeMag.validate() }

        var nanRot = rot; nanRot.rotation = .nan
        try rejects("Accepted NaN rotation") { try nanRot.validate() }

        var mixedGesture = mag; mixedGesture.rotation = 1.0
        try rejects("Accepted magnify carrying rotation") { try mixedGesture.validate() }

        var scrollWithMag = RemoteInput(kind: .scroll)
        scrollWithMag.magnification = 0.1
        try rejects("Accepted non-gesture event carrying magnification") { try scrollWithMag.validate() }

        var moveWithPhase = RemoteInput(kind: .move)
        moveWithPhase.gesturePhase = .began
        try rejects("Accepted move carrying gesturePhase") { try moveWithPhase.validate() }
    }

    run("PointerMovePacer coalesces relative-mouse deltas without merging across mode boundaries") {
        var pacer = PointerMovePacer(interval: 1.0 / 60.0)
        var first = RemoteInput(kind: .move)
        first.x = 0.5; first.y = 0.5; first.relativeMouse = true
        first.pointerDeltaX = 10; first.pointerDeltaY = -5
        let initial = pacer.offer(first, now: 1.0)
        try check(initial?.relativeMouse == true && initial?.pointerDeltaX == 10, "Initial relative move not emitted")

        var sub1 = first; sub1.pointerDeltaX = 12.5; sub1.pointerDeltaY = 4.0
        var sub2 = first; sub2.pointerDeltaX = -2.5; sub2.pointerDeltaY = 6.0
        try check(pacer.offer(sub1, now: 1.004) == nil, "Sub-interval relative move emitted early")
        try check(pacer.offer(sub2, now: 1.008) == nil, "Second sub-interval relative move emitted early")
        let coalesced = pacer.takeDue(now: 1.020)
        try check(coalesced?.relativeMouse == true && coalesced?.pointerDeltaX == 10.0 && coalesced?.pointerDeltaY == 10.0,
                  "Coalesced relative move lost accumulated deltas: \(String(describing: coalesced))")
    }
}
