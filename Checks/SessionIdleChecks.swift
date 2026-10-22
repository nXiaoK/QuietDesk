import Foundation
import QuietDeskCore

func runSessionIdleChecks() {
    run("Idle pause occurs once after ten minutes away and only attended activity resumes") {
        var policy = SessionIdlePolicy(now: 10)
        try check(!policy.tick(now: 609.99, attended: false), "Paused before ten minutes")
        try check(policy.tick(now: 610, attended: false) && policy.isPaused, "Ten minutes away left the session active")
        try check(!policy.tick(now: 900, attended: false), "Repeated pause request")
        try check(!policy.activity(now: 901, attended: false) && policy.isPaused, "Background activity resumed transmission")
        try check(policy.activity(now: 902, attended: true) && !policy.isPaused, "Attended activity failed to resume")
        try check(!policy.tick(now: 1501.9, attended: false) && policy.tick(now: 1502, attended: false),
                  "Resume did not start a new idle interval")
    }
    run("Foreground input postpones idle pause and a new session resets prior pause") {
        var policy = SessionIdlePolicy(now: 0)
        try check(!policy.activity(now: 599, attended: true), "Active input produced a resume")
        try check(!policy.tick(now: 600, attended: false) && !policy.tick(now: 1198, attended: false),
                  "Input failed to extend idle interval")
        try check(policy.tick(now: 1199, attended: false), "Idle deadline was not reached")
        policy = SessionIdlePolicy(now: 1200)
        try check(!policy.isPaused && !policy.tick(now: 1201, attended: false), "Prior session pause leaked into reconnect")
        let request = SessionPauseRequest(paused: true)
        let decoded = try Wire.readJSON(SessionPauseRequest.self, Wire.json(.ping, request).payload)
        try check(decoded.id == request.id && decoded.paused, "Pause request changed on wire")
    }
    run("A focused, visible session window never pauses, however long it goes without input") {
        var policy = SessionIdlePolicy(now: 0)
        try check(!policy.attentionChanged(now: 0, attended: true), "Initial attention reported a resume")
        var now = 0.0
        while now < 8 * 3_600 {
            now += 1
            try check(!policy.tick(now: now, attended: true) && !policy.isPaused, "Attended inactivity paused at \(now) s")
        }
        try check(!policy.activity(now: now, attended: true), "Input while attended reported a resume")
    }
    run("Away time starts when attention ends, so ten minutes away pause even after hours attended") {
        var policy = SessionIdlePolicy(now: 0)
        _ = policy.attentionChanged(now: 0, attended: true)
        try check(!policy.tick(now: 5_000, attended: true), "Attended session paused")
        // A focus or visibility change can land between one-second ticks.
        try check(!policy.attentionChanged(now: 5_000.5, attended: false), "Leaving reported a resume")
        try check(!policy.tick(now: 5_600.4, attended: false) && !policy.isPaused, "Paused before ten minutes away")
        try check(policy.tick(now: 5_600.5, attended: false) && policy.isPaused, "Ten minutes away did not pause")
        try check(!policy.tick(now: 5_700, attended: true) && policy.isPaused, "An attended tick resumed without a return")
        try check(policy.attentionChanged(now: 5_701, attended: true) && !policy.isPaused, "Returning did not resume")
        try check(!policy.tick(now: 9_000, attended: true), "The resumed, attended session paused again")
    }
    run("A focused window behind a lock, a sleeping display or another Space is away, and showing it again resumes") {
        var policy = SessionIdlePolicy(now: 0)
        _ = policy.attentionChanged(now: 0, attended: true)
        // The window stays key while the screen locks; the model reports it as not attended.
        _ = policy.attentionChanged(now: 100, attended: false)
        try check(!policy.tick(now: 699, attended: false) && policy.tick(now: 700, attended: false),
                  "Ten minutes behind a lock or a sleeping display did not pause")
        try check(policy.attentionChanged(now: 1_000, attended: true) && !policy.isPaused, "Unlocking did not resume")
    }
    run("Only a new attention edge resumes, and automatic panel focus changes can be suppressed") {
        var policy = SessionIdlePolicy(now: 0)
        try check(!policy.attentionChanged(now: 0, attended: true), "Initial attention reported a resume")
        _ = policy.attentionChanged(now: 1, attended: false)
        try check(policy.tick(now: 601, attended: false), "Ten minutes away did not pause")
        try check(!policy.attentionChanged(now: 602, attended: false) && policy.isPaused, "Repeated background refresh resumed idle transmission")
        try check(!policy.attentionChanged(now: 603, attended: true, suppressWake: true) && policy.isPaused,
                  "Automatic panel dismissal resumed transmission")
        try check(!policy.attentionChanged(now: 604, attended: true) && policy.isPaused, "Repeated attention refresh resumed idle transmission")
        _ = policy.attentionChanged(now: 605, attended: false)
        try check(policy.attentionChanged(now: 606, attended: true) && !policy.isPaused, "User return edge was ignored")
        try check(!policy.tick(now: .nan, attended: false) && !policy.tick(now: 1, attended: false),
                  "Invalid or reversed clock paused transmission")
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
