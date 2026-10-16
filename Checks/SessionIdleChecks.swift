import Foundation
import QuietDeskCore

func runSessionIdleChecks() {
    run("Idle pause occurs once after ten minutes and only focused activity resumes") {
        var policy = SessionIdlePolicy(now: 10)
        try check(!policy.tick(now: 609.99), "Paused before ten minutes")
        try check(policy.tick(now: 610) && policy.isPaused, "Ten minute idle session remained active")
        try check(!policy.tick(now: 900), "Repeated pause request")
        try check(!policy.activity(now: 901, focused: false) && policy.isPaused, "Background activity resumed transmission")
        try check(policy.activity(now: 902, focused: true) && !policy.isPaused, "Focused activity failed to resume")
        try check(!policy.tick(now: 1501.9) && policy.tick(now: 1502), "Resume did not start a new idle interval")
    }
    run("Foreground input postpones idle pause and a new session resets prior pause") {
        var policy = SessionIdlePolicy(now: 0)
        try check(!policy.activity(now: 599, focused: true), "Active input produced a resume")
        try check(!policy.tick(now: 600) && !policy.tick(now: 1198), "Input failed to extend idle interval")
        try check(policy.tick(now: 1199), "Idle deadline was not reached")
        policy = SessionIdlePolicy(now: 1200)
        try check(!policy.isPaused && !policy.tick(now: 1201), "Prior session pause leaked into reconnect")
        let request = SessionPauseRequest(paused: true)
        let decoded = try Wire.readJSON(SessionPauseRequest.self, Wire.json(.ping, request).payload)
        try check(decoded.id == request.id && decoded.paused, "Pause request changed on wire")
    }
    run("Only a new focus edge resumes, and automatic panel focus changes can be suppressed") {
        var policy = SessionIdlePolicy(now: 0)
        try check(!policy.focusChanged(now: 0, focused: true), "Initial focus reported a resume")
        try check(policy.tick(now: 600), "Focused inactivity did not pause")
        try check(!policy.focusChanged(now: 601, focused: true) && policy.isPaused, "Repeated foreground refresh resumed idle transmission")
        _ = policy.focusChanged(now: 602, focused: false)
        try check(!policy.focusChanged(now: 603, focused: true, suppressWake: true) && policy.isPaused, "Automatic panel dismissal resumed transmission")
        _ = policy.focusChanged(now: 604, focused: false)
        try check(policy.focusChanged(now: 605, focused: true) && !policy.isPaused, "User return focus edge was ignored")
        try check(!policy.tick(now: .nan) && !policy.tick(now: 1), "Invalid or reversed clock paused transmission")
    }
    run("Pause requests coalesce while a wake waits for the in-flight pause acknowledgement") {
        var state = SessionPauseTransmission()
        state.choose(paused: true)
        guard let pause = state.nextRequest() else { throw CheckFailure("Pause request missing") }
        state.choose(paused: false)
        try check(state.nextRequest() == nil && state.inputSuspended, "Wake bypassed pending pause")
        try check(!state.receive(SessionPauseResult(id: UUID(), paused: false)), "Unrelated reply resolved pause")
        try check(state.receive(SessionPauseResult(id: pause.id, paused: true)), "Pause acknowledgement rejected")
        guard let wake = state.nextRequest() else { throw CheckFailure("Wake did not follow pause confirmation") }
        try check(!wake.paused && wake.id != pause.id, "Wake retained old request identity")
        try check(state.receive(SessionPauseResult(id: wake.id, paused: false)) && state.inputSuspended, "Resume reply allowed input before new frame")
        guard let token = state.freshFrameToken else { throw CheckFailure("Fresh-frame barrier missing") }
        try check(!state.decodedFreshFrame(token: UUID()) && state.inputSuspended, "Old decode completed a newer resume")
        try check(state.decodedFreshFrame(token: token) && !state.inputSuspended, "New decoded keyframe failed to release input")
        try check(!state.receive(SessionPauseResult(id: pause.id, paused: true)), "Late duplicate pause reply was accepted")
    }
    run("Pause failures preserve actual host state and a second pause invalidates an old decode token") {
        var state = SessionPauseTransmission()
        state.choose(paused: true)
        guard let first = state.nextRequest() else { throw CheckFailure("Pause missing") }
        _ = state.receive(SessionPauseResult(id: first.id, paused: false, error: "fake failure"))
        try check(!state.inputSuspended && state.nextRequest() == nil, "Failed pause pretended to stop host video")
        state.choose(paused: true)
        let pause = state.nextRequest()!
        _ = state.receive(SessionPauseResult(id: pause.id, paused: true))
        state.choose(paused: false)
        let wake = state.nextRequest()!
        _ = state.receive(SessionPauseResult(id: wake.id, paused: true, error: "fake failure"))
        try check(state.inputSuspended && state.desiredPaused && state.freshFrameToken == nil, "Failed resume allowed old-frame input")
        state.choose(paused: false)
        let retry = state.nextRequest()!
        _ = state.receive(SessionPauseResult(id: retry.id, paused: false))
        let oldToken = state.freshFrameToken!
        state.choose(paused: true)
        try check(!state.decodedFreshFrame(token: oldToken) && state.inputSuspended, "Late frame reopened a newly paused session")
    }
    run("An idle wake over a new connection waits for the first keyframe without sending a resume to an unpaused host") {
        var ordinary = SessionPauseTransmission()
        try check(!ordinary.inputSuspended && ordinary.nextRequest() == nil, "Ordinary new connection changed behavior")
        ordinary.requireFreshFrame()
        try check(ordinary.inputSuspended && ordinary.nextRequest() == nil, "Idle reconnect opened input before a fresh frame")
        let previous = ordinary.freshFrameToken!
        ordinary.requireFreshFrame()
        try check(!ordinary.decodedFreshFrame(token: previous), "An older connection's decode released the new barrier")
        try check(ordinary.decodedFreshFrame(token: ordinary.freshFrameToken!) && !ordinary.inputSuspended,
                  "The new connection's first keyframe failed to release input")
    }
    run("A swallowed wake key never leaks repeats or its later release") {
        var gate = SessionWakeInputGate()
        var input = RemoteInput(kind: .keyDown); input.keyCode = 12
        try check(!gate.allows(input, suspended: true), "Wake key reached old frame")
        input.isRepeat = true
        try check(!gate.allows(input, suspended: false), "Wake-key repeat leaked after resume")
        input.kind = .keyUp
        try check(!gate.allows(input, suspended: false), "Wake key-up leaked without key-down")
        input.kind = .keyDown; input.isRepeat = false
        try check(gate.allows(input, suspended: false), "New key gesture stayed blocked")
    }
    run("Wake mouse gestures and modifiers stay quarantined through fresh-frame delivery") {
        var gate = SessionWakeInputGate()
        var input = RemoteInput(kind: .down); input.button = 0; input.flags = 1 << 20
        try check(!gate.allows(input, suspended: true), "Wake click reached old frame")
        input.kind = .drag
        try check(!gate.allows(input, suspended: false), "Wake drag leaked after resume")
        input.kind = .up
        try check(!gate.allows(input, suspended: false), "Wake mouse-up leaked after resume")
        input.kind = .keyDown; input.keyCode = 9
        try check(!gate.allows(input, suspended: false), "Held wake modifier affected a new remote key")
        input.kind = .flags; input.flags = 0
        try check(!gate.allows(input, suspended: false), "Wake modifier release leaked")
        input.kind = .keyUp
        try check(!gate.allows(input, suspended: false), "Blocked modified key release leaked")
        input.kind = .down
        try check(gate.allows(input, suspended: false), "New independent click remained blocked")
    }
    run("Session pause capability is optional and new message numbers preserve existing peers") {
        let legacy = Hello(name: "old", width: 1920, height: 1080, settings: .init(), canControl: true)
        let data = try Wire.json(.hello, legacy).payload
        try check(Wire.readJSON(Hello.self, data).sessionPause == nil, "Old host advertised pause")
        let current = Hello(name: "new", width: 1920, height: 1080, settings: .init(), canControl: true, sessionPause: true)
        try check(Wire.readJSON(Hello.self, Wire.json(.hello, current).payload).sessionPause == true, "New pause capability lost")
        try check(MessageKind.sessionPauseRequest.rawValue == 24 && MessageKind.sessionPauseResult.rawValue == 25 &&
                  MessageKind.sessionEffectsResult.rawValue == 23 && Wire.version == 1, "Legacy message numbering changed")
        try rejects("Non-boolean pause state accepted") {
            _ = try Wire.readJSON(SessionPauseResult.self, Data("{\"id\":\"00000000-0000-0000-0000-000000000000\",\"paused\":1}".utf8))
        }
    }
}
