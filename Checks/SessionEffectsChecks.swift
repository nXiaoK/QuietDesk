import Foundation
import QuietDeskCore

private final class FakeSessionMuteIO: SessionMuteDeviceIO {
    var devices = ["speaker", "speaker"]
    var values = ["speaker": false, "alerts": true]
    var unsupported = Set<String>()
    var failedWrites: [String: Int] = [:]
    var writes: [(String, Bool)] = []
    func currentOutputDeviceUIDs() throws -> [String] { devices }
    func muteValue(for deviceUID: String) throws -> Bool {
        guard let value = values[deviceUID] else { throw DeskError.invalid("missing fake device") }
        return value
    }
    func canSetMute(for deviceUID: String) throws -> Bool { !unsupported.contains(deviceUID) }
    func setMuted(_ muted: Bool, for deviceUID: String) throws {
        writes.append((deviceUID, muted))
        if let remaining = failedWrites[deviceUID], remaining > 0 {
            failedWrites[deviceUID] = remaining - 1
            throw DeskError.invalid("fake device write failed")
        }
        values[deviceUID] = muted
    }
}

func runSessionEffectsChecks() {
    run("Session effects remain opt-in and carry matching replies or explicit state updates") {
        let old = Hello(name: "old", width: 1920, height: 1080, settings: .init(), canControl: true)
        let legacy = try Wire.readJSON(Hello.self, Wire.json(.hello, old).payload)
        try check(legacy.sessionEffects == nil, "An old endpoint enabled effects")
        let request = SessionEffectsRequest(state: SessionEffectsState(muted: true, privacy: true))
        let decoded = try Wire.readJSON(SessionEffectsRequest.self, Wire.json(.sessionEffectsRequest, request).payload)
        try check(decoded.id == request.id && decoded.state == request.state, "Request changed on wire")
        let update = try Wire.readJSON(SessionEffectsResult.self,
            Wire.json(.sessionEffectsResult, SessionEffectsResult(state: SessionEffectsState(), error: "local exit")).payload)
        try check(update.id == nil && !update.state.privacy && update.error == "local exit", "Local exit update lost")
        try check(MessageKind.deviceIdentity.rawValue == 21 && MessageKind.sessionEffectsRequest.rawValue == 22,
                  "Existing message values changed")
        try rejects("Non-boolean effects accepted") {
            _ = try Wire.readJSON(SessionEffectsState.self, Data("{\"muted\":\"true\",\"privacy\":false}".utf8))
        }
    }
    run("Session effects default off and strictly decode boolean values without changing legacy wire numbers") {
        try check(SessionEffectsState() == SessionEffectsState(muted: false, privacy: false), "Session effects enabled by default")
        let request = SessionEffectsRequest(state: .init(muted: true))
        let decoded = try JSONDecoder().decode(SessionEffectsRequest.self, from: JSONEncoder().encode(request))
        try check(decoded.id == request.id && decoded.state == request.state, "Session effect request changed")
        let result = SessionEffectsResult(id: request.id, state: .init(privacy: true), error: "fake failure")
        let reply = try JSONDecoder().decode(SessionEffectsResult.self, from: JSONEncoder().encode(result))
        try check(reply.id == request.id && reply.state == result.state && reply.error == result.error, "Actual effect state lost")
        for invalid in ["{}", "{\"muted\":1,\"privacy\":false}", "{\"muted\":false,\"privacy\":\"true\"}", "{\"muted\":null,\"privacy\":false}"] {
            try rejects("Invalid session effect state accepted") { _ = try JSONDecoder().decode(SessionEffectsState.self, from: Data(invalid.utf8)) }
        }
        try check(MessageKind.controlStatus.rawValue == 20 && MessageKind.deviceIdentity.rawValue == 21 && Wire.version == 1,
                  "Legacy wire values changed")
    }

    run("Mute preparation deduplicates output routes and does not modify any device") {
        let io = FakeSessionMuteIO()
        let prepared = try SessionMuteTransaction.prepare(using: io)
        try check(prepared.snapshots.count == 1 && !prepared.isMuted && io.writes.isEmpty, "Prepare changed real state or duplicated output")
        io.devices = ["speaker", "alerts"]
        io.unsupported.insert("speaker")
        try rejects("Unsupported mute path accepted") { _ = try SessionMuteTransaction.prepare(using: io) }
        try check(io.writes.isEmpty, "Unsupported device caused a partial write")
    }

    run("Mute restores only changes made by the session and preserves devices already muted") {
        let io = FakeSessionMuteIO()
        io.devices = ["speaker", "alerts"]
        var transaction = try SessionMuteTransaction.prepare(using: io)
        try transaction.mute(using: io)
        try check(transaction.isMuted && io.values["speaker"] == true && io.writes.count == 1, "Mute touched already muted output")
        try transaction.restore(using: io)
        try check(!transaction.isMuted && io.values["speaker"] == false && io.values["alerts"] == true, "Original mute state was not restored")
        try check(io.writes.count == 2, "Unexpected hardware writes")
    }

    run("Output or mute changes between prepare and apply are rejected before writing") {
        let io = FakeSessionMuteIO()
        var transaction = try SessionMuteTransaction.prepare(using: io)
        io.devices = ["alerts"]
        try rejects("Stale output device was muted") { try transaction.mute(using: io) }
        io.devices = ["speaker"]
        io.values["speaker"] = true
        try rejects("Stale mute baseline was applied") { try transaction.mute(using: io) }
        try check(io.writes.isEmpty, "Validation failed after a write")
    }

    run("A partial mute failure rolls back earlier changes and remains retryable") {
        let io = FakeSessionMuteIO()
        io.devices = ["alerts", "speaker"]
        io.values["alerts"] = false
        io.failedWrites["speaker"] = 1
        var transaction = try SessionMuteTransaction.prepare(using: io)
        try rejects("Fake failing mute succeeded") { try transaction.mute(using: io) }
        try check(io.values["alerts"] == false && io.values["speaker"] == false && !transaction.isMuted, "Partial mute left an output muted")
        try transaction.mute(using: io)
        try check(transaction.isMuted, "Failed mute could not be retried")
        try transaction.restore(using: io)
    }

    run("Failed restoration retains recovery ownership and external unmute is not overwritten") {
        let io = FakeSessionMuteIO()
        var transaction = try SessionMuteTransaction.prepare(using: io)
        try transaction.mute(using: io)
        io.failedWrites["speaker"] = 1
        try rejects("Fake failing restore succeeded") { try transaction.restore(using: io) }
        try check(transaction.isMuted, "Failed restore forgot the active mutation")
        io.values["speaker"] = false
        let previousWrites = io.writes.count
        try transaction.restore(using: io)
        try check(!transaction.isMuted && io.writes.count == previousWrites, "Restore overwrote an external unmute")
    }

    run("The surviving process can recover a mute from the prepared snapshot") {
        let io = FakeSessionMuteIO()
        io.devices = ["speaker", "alerts"]
        var original = try SessionMuteTransaction.prepare(using: io)
        let snapshot = try JSONDecoder().decode([SessionMuteSnapshot].self, from: JSONEncoder().encode(original.snapshots))
        try original.mute(using: io)
        var recovery = SessionMuteTransaction(recovering: snapshot)
        try recovery.restore(using: io)
        try check(io.values["speaker"] == false && io.values["alerts"] == true && !recovery.isMuted, "Cross-process recovery lost the original mute state")
    }
}
