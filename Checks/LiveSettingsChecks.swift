import Foundation
import VideoToolbox
import QuietDeskCore

func runLiveSettingsChecks() {
    let initial = VideoStreamState(settings: .init(), width: 1920, height: 1080)
    let low = StreamSettings(longestEdge: 1280, framesPerSecond: 10, megabits: 1)
    let medium = StreamSettings(longestEdge: 2560, framesPerSecond: 15, megabits: 5)
    let high = StreamSettings.highest
    func state(_ settings: StreamSettings) -> VideoStreamState {
        let (w, h) = settings.dimensions(width: 5120, height: 2880)
        return VideoStreamState(settings: settings, width: w, height: h)
    }

    run("Live quality requests validate allowed values and preserve wire message numbers") {
        try low.validateControlValues(); try high.validateControlValues()
        for invalid in [StreamSettings(longestEdge: -1), .init(framesPerSecond: 0), .init(framesPerSecond: 61), .init(framesPerSecond: 241), .init(megabits: 1000)] {
            try rejects("Invalid quality parameters accepted") { try invalid.validateControlValues() }
        }
        let request = StreamSettingsRequest(settings: medium)
        let message = try Wire.json(.streamSettingsRequest, request)
        let decoded = try Wire.readJSON(StreamSettingsRequest.self, message.payload)
        try check(decoded.id == request.id && decoded.settings == medium, "Request changed over wire")
        let result = StreamSettingsResult(id: request.id, state: state(medium))
        let decodedResult = try Wire.readJSON(StreamSettingsResult.self, Wire.json(.streamSettingsResult, result).payload)
        try check(decodedResult.state == result.state, "Applied state changed over wire")
        try check(MessageKind.inputStatus.rawValue == 10 && MessageKind.clipboardCancel.rawValue == 17 && Wire.version == 1, "Legacy wire values changed")
    }

    run("Higher frame rates round-trip through live requests and replies while defaults stay unchanged") {
        try check(StreamSettings().framesPerSecond == 15 && StreamSettings.highest.framesPerSecond == 60,
                  "Adding manual rates changed the default or initial RTT selection")
        for rate in [75, 90, 120, 144, 165, 240] {
            let settings = StreamSettings(framesPerSecond: rate)
            try settings.validateControlValues()
            let request = StreamSettingsRequest(settings: settings)
            let decoded = try Wire.readJSON(StreamSettingsRequest.self, Wire.json(.streamSettingsRequest, request).payload)
            try check(decoded.settings == settings, "Request lost \(rate) fps")
            let result = StreamSettingsResult(id: request.id, state: state(settings))
            let reply = try Wire.readJSON(StreamSettingsResult.self, Wire.json(.streamSettingsResult, result).payload)
            try reply.state.validate()
            try check(reply.state == result.state, "Reply lost \(rate) fps")
        }
    }

    run("Higher-rate hello fields keep old 30 and 60 fps defaults valid and require an explicit capability") {
        let settings = StreamSettings(longestEdge: 8192, framesPerSecond: 240, megabits: 100)
        let hello = Hello(name: "host", width: 3840, height: 2160, settings: settings.legacyCompatible,
            canControl: true, preferredSettings: settings.extendedCompatible,
            highRefreshVideoSettings: true, preferredHighRefreshSettings: settings.highRefreshCompatible,
            higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: settings)
        let data = try JSONEncoder().encode(hello)
        let decoded = try Wire.readJSON(Hello.self, data)
        try decoded.validate()
        try check(decoded.preferredHigherFrameRateSettings == settings && decoded.higherFrameRateVideoV1 == true,
                  "Higher-rate host preference was lost")
        struct PreviousHello: Decodable {
            let settings: StreamSettings
            let preferredSettings: StreamSettings?
            let preferredHighRefreshSettings: StreamSettings?
        }
        let previous = try JSONDecoder().decode(PreviousHello.self, from: data)
        try check(previous.settings == settings.legacyCompatible
                  && previous.preferredSettings == settings.extendedCompatible
                  && previous.preferredHighRefreshSettings == settings.highRefreshCompatible,
                  "A higher-rate default leaked into an old JSON field")
        for value in [previous.settings, previous.preferredSettings!, previous.preferredHighRefreshSettings!] {
            try check([10, 15, 30, 60].contains(value.framesPerSecond), "Old parser would reject the default frame rate")
        }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "higherFrameRateVideoV1")
        object.removeValue(forKey: "preferredHigherFrameRateSettings")
        let older = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: object))
        try older.validate()
        try check(older.higherFrameRateVideoV1 == nil && older.preferredHigherFrameRateSettings == nil,
                  "Absent capability enabled higher rates")
        object["higherFrameRateVideoV1"] = "true"
        try rejects("Malformed higher-rate capability accepted") {
            _ = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: object))
        }
        try rejects("Unbounded higher-rate preference accepted") {
            try Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true,
                      higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: .init(framesPerSecond: 241)).validate()
        }
        try rejects("Higher rate accepted in a compatibility field") {
            try Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true,
                      highRefreshVideoSettings: true, preferredHighRefreshSettings: settings).validate()
        }
    }

    run("Old-host fallback and media startup preserve a saved higher rate until a manual choice is confirmed") {
        let settings = StreamSettings(longestEdge: 8192, framesPerSecond: 240, megabits: 100)
        var policy = ViewerQualityPolicy(preferred: settings)
        let fallback = policy.settingsForConnection(hostDefault: .init(), supportsExtended: true, supportsHighRefresh: true)
        try check(fallback == settings.highRefreshCompatible && !policy.maySaveCurrentChoice,
                  "Old high-refresh host received a higher rate or allowed fallback to overwrite the saved choice")
        policy.chooseManually(savePreference: policy.maySaveCurrentChoice)
        try check(!policy.confirm(fallback, maySave: policy.maySaveCurrentChoice) && policy.preferred == settings,
                  "Starting media adaptation erased the saved higher rate")
        try check(policy.settingsForConnection(hostDefault: .init(), supportsExtended: true, supportsHighRefresh: false)
                  == settings.extendedCompatible, "Extended-only fallback changed")
        try check(policy.settingsForConnection(hostDefault: .init(), supportsExtended: false)
                  == settings.legacyCompatible, "Legacy fallback changed")
        try check(policy.settingsForConnection(hostDefault: .init(), supportsExtended: true, supportsHighRefresh: true,
                                              supportsHigherFrameRate: true) == settings,
                  "Reconnect to an updated host did not restore the saved rate")
        policy.chooseManually()
        try check(policy.confirm(fallback, maySave: policy.maySaveCurrentChoice) && policy.preferred == fallback,
                  "An explicit manual 60 fps choice could not replace the saved preference")
    }

    run("Higher-rate edits coalesce and a failed earlier change retains the latest choice") {
        let base = StreamSettings(framesPerSecond: 60)
        var tuning = try VideoTuningSession(applied: state(base))
        try tuning.choose(StreamSettings(framesPerSecond: 120))
        let first = tuning.nextRequest()!
        let latest = StreamSettings(framesPerSecond: 240)
        try tuning.choose(latest)
        try check(tuning.nextRequest() == nil, "Higher-rate edits sent concurrent requests")
        try check(tuning.receive(StreamSettingsResult(id: first.id, state: state(base), error: "Synthetic encoder refusal")),
                  "Failed earlier request was not acknowledged")
        try check(tuning.applied.settings == base && tuning.desired == latest, "Failure replaced the latest higher-rate choice")
        let next = tuning.nextRequest()!
        try check(next.settings == latest, "Latest rate was not retried after the earlier request")
        try check(tuning.receive(StreamSettingsResult(id: next.id, state: state(latest))), "Higher-rate reply was not applied")
    }

    run("Unnegotiated higher-rate replies cannot change applied settings or clear the pending request") {
        let base = StreamSettings(framesPerSecond: 60)
        var tuning = try VideoTuningSession(applied: state(base), preferred: low)
        let pending = tuning.nextRequest()!
        let higher = StreamSettings(framesPerSecond: 240)
        try rejects("Old host reply was allowed to raise the frame rate without negotiation") {
            _ = try tuning.receive(StreamSettingsResult(id: pending.id, state: state(higher)), maximumFrameRate: 60)
        }
        try check(tuning.applied.settings == base && tuning.pending?.id == pending.id && tuning.desired == low,
                  "Rejected reply mutated applied settings, pending request or saved intent")
        try check(!tuning.receive(StreamSettingsResult(id: UUID(), state: state(higher)), maximumFrameRate: 60),
                  "A stale reply bypassed request matching")
        try check(tuning.receive(StreamSettingsResult(id: pending.id, state: state(low)), maximumFrameRate: 60),
                  "Valid reply could not finish after rejecting an unnegotiated rate")
    }

    run("Higher-rate connection preferences keep the old field readable and ignore invalid optional values") {
        let settings = StreamSettings(longestEdge: 8192, framesPerSecond: 240, megabits: 100)
        let record = ConnectionRecord(address: "home.test", port: 5908, name: "Home", videoSettings: settings)
        let data = try JSONEncoder().encode(record)
        try check(JSONDecoder().decode(ConnectionRecord.self, from: data) == record, "Higher-rate record did not round-trip")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let old = try JSONDecoder().decode(StreamSettings.self, from: JSONSerialization.data(withJSONObject: object["videoSettings"]!))
        try check(old == settings.highRefreshCompatible, "An old reader would receive an unsupported saved rate")
        object["higherFrameRateVideoSettings"] = ["framesPerSecond": 241, "longestEdge": 8192, "megabits": 100]
        let invalid = try JSONDecoder().decode(ConnectionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try check(invalid.id == record.id && invalid.videoSettings == old, "Invalid optional settings hid the connection record")
        object["higherFrameRateVideoSettings"] = "invalid"
        try check(JSONDecoder().decode(ConnectionRecord.self, from: JSONSerialization.data(withJSONObject: object)).videoSettings == old,
                  "Malformed optional settings hid the legacy preference")
        object.removeValue(forKey: "higherFrameRateVideoSettings")
        try check(JSONDecoder().decode(ConnectionRecord.self, from: JSONSerialization.data(withJSONObject: object)).videoSettings == old,
                  "An old record was assumed to contain a higher-rate preference")
    }

    run("Native resolution preserves source pixels within decoder limits without upscaling") {
        for (width, height, expectedWidth, expectedHeight) in [
            (6016, 3384, 6016, 3384), (5120, 2880, 5120, 2880), (1279, 719, 1278, 718),
            (1440, 2560, 1440, 2560), (8192, 8192, 6000, 6000), (16000, 9000, 8000, 4500),
            (32768, 1080, 8192, 270)
        ] {
            let (w, h) = high.dimensions(width: width, height: height)
            try check(w == expectedWidth && h == expectedHeight, "Native dimensions changed for \(width) × \(height)")
            try VideoStreamState(settings: high, width: w, height: h).validate()
            try check(w <= width && h <= height, "Native mode enlarged the source")
        }
        try check(high.summary.contains("原分辨率") && high.megabits == 100 && high.framesPerSecond == 60, "Native quality label or bitrate missing")
    }

    run("New hosts send legacy initial settings and optional extended defaults without changing old JSON fields") {
        struct LegacyHello: Decodable {
            let version: Int
            let name: String
            let width: Int
            let height: Int
            let settings: StreamSettings
            let canControl: Bool
            let liveSettings: Bool?
        }
        let compatible = high.legacyCompatible
        try check(compatible == StreamSettings(longestEdge: 3840, framesPerSecond: 30, megabits: 12), "Legacy initial ceiling changed")
        let hello = Hello(name: "host", width: 3840, height: 2160, settings: compatible,
                          canControl: true, preferredSettings: high.extendedCompatible,
                          highRefreshVideoSettings: true, preferredHighRefreshSettings: high)
        let data = try JSONEncoder().encode(hello)
        let legacy = try JSONDecoder().decode(LegacyHello.self, from: data)
        try check(legacy.version == 1 && legacy.settings == compatible && legacy.liveSettings == true,
                  "New host broke old control values")
        let decoded = try Wire.readJSON(Hello.self, data)
        try decoded.validate()
        try check(decoded.extendedVideoSettings == true && decoded.preferredSettings == high.extendedCompatible && decoded.preferredHighRefreshSettings == high, "Extended host default lost")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "extendedVideoSettings")
        object.removeValue(forKey: "preferredSettings")
        object.removeValue(forKey: "highRefreshVideoSettings")
        object.removeValue(forKey: "preferredHighRefreshSettings")
        let oldHost = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: object))
        try check(oldHost.extendedVideoSettings == nil && oldHost.preferredSettings == nil && oldHost.settings == compatible,
                  "Old host was assumed to support native quality")
        try rejects("Invalid advertised host default accepted") {
            try Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true,
                      preferredSettings: .init(megabits: 1000)).validate()
        }
    }

    run("First low RTT selects highest once before or after session information") {
        var early = ViewerQualityPolicy()
        early.observeRoundTrip(9.9)
        try check(early.settingsForConnection(hostDefault: initial.settings, supportsExtended: true, supportsHighRefresh: true) == initial.settings,
                  "Session default changed before policy decision")
        try check(early.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == high, "Early RTT was lost")
        early.observeRoundTrip(1)
        try check(early.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Auto quality ran more than once")

        var late = ViewerQualityPolicy()
        _ = late.settingsForConnection(hostDefault: initial.settings, supportsExtended: true, supportsHighRefresh: true)
        try check(late.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Missing RTT enabled highest quality")
        late.observeRoundTrip(0)
        try check(late.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == high, "Late RTT did not apply")
    }

    run("High refresh settings negotiate separately and preserve older saved preferences") {
        let hello = Hello(name: "new host", width: 3840, height: 2160, settings: high.legacyCompatible,
                          canControl: true, preferredSettings: high.extendedCompatible,
                          highRefreshVideoSettings: true, preferredHighRefreshSettings: high)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as! [String: Any]
        let oldDefault = try JSONDecoder().decode(StreamSettings.self,
            from: JSONSerialization.data(withJSONObject: object["preferredSettings"]!))
        try check(StreamSettings.legacyFrameRates.contains(oldDefault.framesPerSecond)
                  && StreamSettings.extendedBitRates.contains(oldDefault.megabits), "Old host default exceeded 0.9 limits")
        var saved = ViewerQualityPolicy(preferred: high)
        try check(saved.settingsForConnection(hostDefault: .init(), supportsExtended: true) == high.extendedCompatible
                  && !saved.maySaveCurrentChoice, "0.9 fallback erased a 60 fps saved choice")
        var automatic = ViewerQualityPolicy()
        automatic.observeRoundTrip(2)
        try check(automatic.takeInitialAutomaticSettings(supportsExtended: true) == high.extendedCompatible,
                  "New settings were sent without high-refresh capability")
        var old = object
        old.removeValue(forKey: "highRefreshVideoSettings")
        old.removeValue(forKey: "preferredHighRefreshSettings")
        let decoded = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: old))
        try check(decoded.highRefreshVideoSettings == nil && decoded.preferredHighRefreshSettings == nil,
                  "Missing capability enabled high refresh")
    }

    run("Saved and manual preferences take precedence and first high RTT cannot later trigger an upgrade") {
        var saved = ViewerQualityPolicy(preferred: low)
        saved.observeRoundTrip(1)
        try check(saved.settingsForConnection(hostDefault: high, supportsExtended: true, supportsHighRefresh: true) == low,
                  "Host default replaced saved preference")
        try check(saved.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Auto quality replaced saved preference")

        var manual = ViewerQualityPolicy()
        manual.observeRoundTrip(1)
        manual.chooseManually()
        try check(manual.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Late hello or RTT replaced manual choice")

        var slow = ViewerQualityPolicy()
        slow.observeRoundTrip(.nan); slow.observeRoundTrip(-1); slow.observeRoundTrip(.infinity)
        try check(slow.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Invalid RTT consumed the decision")
        slow.observeRoundTrip(10)
        slow.observeRoundTrip(1)
        try check(slow.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "First RTT threshold was not strict")
        slow.observeRoundTrip(1)
        try check(slow.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Later fast sample changed settled default")

        var oldHost = ViewerQualityPolicy()
        oldHost.observeRoundTrip(1)
        try check(oldHost.takeInitialAutomaticSettings(supportsExtended: false) == nil, "Native quality sent to an old host")
    }

    run("Reconnect restores confirmed quality without reopening initial automatic selection") {
        var policy = ViewerQualityPolicy()
        policy.observeRoundTrip(2)
        try check(policy.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == high, "Initial auto setting missing")
        try check(policy.confirm(high, maySave: policy.maySaveCurrentChoice), "Confirmed auto quality not persisted")
        policy.discardUnfinishedSample()
        try check(policy.settingsForConnection(hostDefault: low, supportsExtended: true, supportsHighRefresh: true) == high, "Reconnect lost confirmed quality")
        policy.observeRoundTrip(1)
        try check(policy.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Reconnect reran automatic selection")

        var interrupted = ViewerQualityPolicy()
        interrupted.observeRoundTrip(2)
        interrupted.discardUnfinishedSample()
        _ = interrupted.settingsForConnection(hostDefault: low, supportsExtended: true, supportsHighRefresh: true)
        try check(interrupted.takeInitialAutomaticSettings(supportsExtended: true, supportsHighRefresh: true) == nil, "Failed peer's unconsumed RTT leaked into reconnect")
    }

    run("Legacy fallback preserves an extended saved preference until a manual choice is confirmed") {
        var policy = ViewerQualityPolicy(preferred: high)
        let fallback = policy.settingsForConnection(hostDefault: low, supportsExtended: false)
        let fallbackMaySave = policy.maySaveCurrentChoice
        try check(fallback == high.legacyCompatible && !fallbackMaySave, "Old-host fallback was not protected")
        policy.chooseManually()
        try check(!policy.confirm(fallback, maySave: fallbackMaySave) && policy.preferred == high,
                  "In-flight fallback reply erased original preference after a manual edit")
        try check(policy.confirm(low, maySave: policy.maySaveCurrentChoice) && policy.preferred == low,
                  "Confirmed manual legacy choice was not saved")
        try check(policy.settingsForConnection(hostDefault: high, supportsExtended: true, supportsHighRefresh: true) == low,
                  "New host replaced manually saved legacy quality")
    }

    run("Rapid quality edits coalesce while only one request is in flight") {
        var session = try VideoTuningSession(applied: initial)
        try session.choose(low)
        guard let first = session.nextRequest() else { throw CheckFailure("No first request") }
        try session.choose(medium); try session.choose(high)
        try check(session.nextRequest() == nil && session.applied == initial, "Unconfirmed settings published or concurrent request sent")
        try check(session.receive(StreamSettingsResult(id: first.id, state: state(low))), "First result not accepted")
        try check(session.desired == high, "Newer choice was overwritten by older acknowledgement")
        guard let second = session.nextRequest() else { throw CheckFailure("Latest choice not sent") }
        try check(second.settings == high && second.id != first.id, "Intermediate choice was queued")
        try check(session.receive(StreamSettingsResult(id: second.id, state: state(high))), "Latest result not accepted")
        try check(session.nextRequest() == nil && session.applied.settings == high, "Configuration did not settle")
    }

    run("Failed quality changes restore actual values without discarding newer edits") {
        var session = try VideoTuningSession(applied: initial)
        try session.choose(low)
        guard let first = session.nextRequest() else { throw CheckFailure("No request") }
        _ = try session.receive(StreamSettingsResult(id: first.id, state: initial, error: "simulated rejection"))
        try check(session.desired == initial.settings && session.pending == nil && session.nextRequest() == nil, "Failed values kept retrying")
        try session.choose(low)
        guard let next = session.nextRequest() else { throw CheckFailure("No next request") }
        try session.choose(high)
        _ = try session.receive(StreamSettingsResult(id: next.id, state: initial, error: "simulated rejection"))
        try check(session.nextRequest()?.settings == high, "New edit lost after failed prior request")
    }

    run("Late and duplicate quality replies cannot resolve a different pending request") {
        var session = try VideoTuningSession(applied: initial, preferred: low)
        guard let first = session.nextRequest() else { throw CheckFailure("Saved preference was not requested") }
        try check(!session.receive(StreamSettingsResult(id: UUID(), state: state(high))), "Unrelated reply accepted")
        _ = try session.receive(StreamSettingsResult(id: first.id, state: state(low)))
        try session.choose(high)
        guard let second = session.nextRequest() else { throw CheckFailure("No second request") }
        try check(!session.receive(StreamSettingsResult(id: first.id, state: state(low))) && session.pending?.id == second.id, "Old reply cleared newer request")
        var reconnected = try VideoTuningSession(applied: initial, preferred: low)
        try check(!reconnected.receive(StreamSettingsResult(id: second.id, state: state(high))), "Reply from prior session accepted")
        try check(reconnected.nextRequest()?.settings == low, "Reconnect did not restore last confirmed preference")
    }

    run("Invalid quality acknowledgements leave applied and pending state intact") {
        var session = try VideoTuningSession(applied: initial, preferred: low)
        guard let request = session.nextRequest() else { throw CheckFailure("No request") }
        try rejects("Odd resolution accepted") {
            _ = try session.receive(StreamSettingsResult(id: request.id, state: VideoStreamState(settings: low, width: 1279, height: 720)))
        }
        try check(session.applied == initial && session.pending?.id == request.id, "Malformed result mutated state")
        try rejects("Oversized resolution accepted") { try VideoStreamState(settings: low, width: 8192, height: 8192).validate() }
    }

    run("Legacy connection records load without quality preferences and new preferences round trip") {
        var record = ConnectionRecord(address: "home.test", port: 5908, name: "Home")
        let oldData = try JSONEncoder().encode(record)
        let oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        try check(oldObject["videoSettings"] == nil, "Empty preference changed legacy JSON")
        try check(JSONDecoder().decode(ConnectionRecord.self, from: oldData).videoSettings == nil, "Legacy record failed to load")
        record.videoSettings = high
        let data = try JSONEncoder().encode(record)
        try check(JSONDecoder().decode(ConnectionRecord.self, from: data).videoSettings == high, "Saved quality lost")
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(Set(object.keys) == Set(["id", "address", "port", "name", "lastConnected", "videoSettings"]), "Credential fields added to history")
    }

    run("One decoder accepts consecutive encoders with changing resolution, frame rate and bitrate") {
        let decoder = VideoDecoder()
        defer { decoder.stop() }
        var sequence: UInt32 = 0
        let configurations: [(Int, Int, StreamSettings)] = [(320, 180, low), (640, 360, high), (640, 360, medium), (320, 180, low)]
        for (width, height, settings) in configurations {
            var pixel: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
            guard status == noErr, let pixel else { throw CheckFailure("Cannot create synthetic frame") }
            CVPixelBufferLockBaseAddress(pixel, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                if let pointer = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                    memset(pointer, plane == 0 ? 80 : 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let encoder = try VideoEncoder(width: width, height: height, settings: settings)
            let completed = DispatchSemaphore(value: 0), error = Box<String?>(nil)
            let firstPacket = Box(true)
            encoder.onOutput = { result in
                do {
                    let packet = try result.get()
                    if firstPacket.read() && (packet.sps.isEmpty || packet.pps.isEmpty) { error.set("New encoder missing keyframe parameters") }
                    firstPacket.set(false)
                    decoder.decode(try VideoPacket.decode(packet.encode())) { result in
                        switch result {
                        case .success(let frame):
                            if CVPixelBufferGetWidth(frame) != width || CVPixelBufferGetHeight(frame) != height { error.set("Resolution switch decoded incorrectly") }
                        case .failure(let issue): error.set(issue.localizedDescription)
                        }
                        completed.signal()
                    }
                } catch let issue { error.set(issue.localizedDescription); completed.signal() }
            }
            for index in 0..<2 {
                sequence &+= 1
                try encoder.encode(pixel, time: CMTime(value: Int64(sequence), timescale: 30), sequence: sequence, forceKeyFrame: index == 0)
                try wait(completed, "New encoder did not produce a decodable frame")
                try check(error.read() == nil, error.read() ?? "Codec switch failed")
            }
            encoder.stop()
        }
    }
}
