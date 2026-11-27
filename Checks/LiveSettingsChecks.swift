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
        try check(decoded.id == request.id && decoded.settings == medium && decoded.inPlaceBitrateV1 == nil, "Request changed over wire")
        var adaptive = try VideoTuningSession(applied: initial, preferred: medium, supportsInPlaceBitrate: true)
        guard let optedIn = adaptive.nextRequest() else { throw CheckFailure("Missing adaptive request") }
        let adaptiveWire = try Wire.readJSON(StreamSettingsRequest.self, Wire.json(.streamSettingsRequest, optedIn).payload)
        try check(adaptiveWire.inPlaceBitrateV1 == true, "Adaptive viewer did not send the bitrate opt-in")
        let result = StreamSettingsResult(id: request.id, state: state(medium))
        let decodedResult = try Wire.readJSON(StreamSettingsResult.self, Wire.json(.streamSettingsResult, result).payload)
        try check(decodedResult.state == result.state, "Applied state changed over wire")
        try check(MessageKind.inputStatus.rawValue == 10 && MessageKind.clipboardCancel.rawValue == 17 && Wire.version == 1, "Legacy wire values changed")
    }

    run("The optional viewport bounds both encoded axes with even pixels") {
        let viewport = VideoViewport(width: 1101, height: 700)
        let request = StreamSettingsRequest(settings: high, viewport: viewport)
        let decoded = try Wire.readJSON(StreamSettingsRequest.self, Wire.json(.streamSettingsRequest, request).payload)
        try decoded.validate()
        try check(decoded.viewport == viewport && decoded.settings == high, "The viewport changed the selected quality tier")
        let legacy = StreamSettingsRequest(settings: high)
        try check(try Wire.readJSON(StreamSettingsRequest.self, Wire.json(.streamSettingsRequest, legacy).payload).viewport == nil,
                  "A legacy request gained a viewport")
        try rejects("An unbounded peer viewport was accepted") {
            try StreamSettingsRequest(settings: high, viewport: VideoViewport(width: 1101, height: Int.max)).validate()
        }
        try check(high.dimensions(width: 5120, height: 2880, viewport: viewport) == (1100, 618)
                  && high.dimensions(width: 2880, height: 5120, viewport: viewport) == (392, 700),
                  "Landscape and portrait output must fit within the available axes")
        try check(high.dimensions(width: 500, height: 300, viewport: viewport) == (500, 300), "A larger viewport upscaled the source")
    }

    run("A viewport-only request coalesces a resize and preserves the cap if removing it fails") {
        var tuning = try VideoTuningSession(applied: initial)
        let smaller = VideoViewport(width: 800, height: 600), larger = VideoViewport(width: 1200, height: 800)
        tuning.chooseViewport(smaller)
        guard let first = tuning.nextRequest() else { throw CheckFailure("A viewport-only update sent no request") }
        try check(first.viewport == smaller && first.settings == initial.settings, "A viewport update replaced the quality settings")
        tuning.chooseViewport(larger)
        try check(tuning.nextRequest() == nil, "A resize sent a second in-flight request")
        let firstState = VideoStreamState(settings: initial.settings, width: 800, height: 450)
        try check(try tuning.receive(.init(id: first.id, state: firstState)), "The first cap was not confirmed")
        guard let resize = tuning.nextRequest(), resize.viewport == larger else { throw CheckFailure("The newest resize did not survive") }
        try rejects("A successful reply exceeded the viewport it acknowledged") {
            _ = try tuning.receive(.init(id: resize.id, state: initial))
        }
        let resized = VideoStreamState(settings: initial.settings, width: 1200, height: 674)
        try check(try tuning.receive(.init(id: resize.id, state: resized)), "A valid resize reply was ignored")
        tuning.chooseViewport(nil)
        guard let clear = tuning.nextRequest(), clear.viewport == nil else { throw CheckFailure("Removing a cap sent no request") }
        _ = try tuning.receive(.init(id: clear.id, state: resized, error: "Configuration failed"))
        try check(tuning.appliedViewport == larger && tuning.nextRequest() == nil, "A failed removal changed the cap or kept retrying")
        tuning.chooseViewport(nil)
        guard let retry = tuning.nextRequest() else { throw CheckFailure("An explicit retry sent no request") }
        _ = try tuning.receive(.init(id: retry.id, state: initial))
        try check(tuning.appliedViewport == nil && tuning.applied == initial, "Removing the cap did not restore the full picture")
    }

    run("HEVC is requested only once chosen, survives later changes and is not asked again after a host keeps H.264") {
        var plain = try VideoTuningSession(applied: initial, preferred: medium)
        guard let first = plain.nextRequest() else { throw CheckFailure("A preferred quality sent no request") }
        try check(first.codec == nil && !String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("codec"),
                  "An H.264-only request named a codec")
        var tuning = try VideoTuningSession(applied: initial)
        tuning.chooseCodec(.hevc)
        guard let request = tuning.nextRequest() else { throw CheckFailure("Choosing HEVC alone sent no request") }
        try check(request.codec == .hevc && request.settings == initial.settings && tuning.nextRequest() == nil,
                  "The HEVC request was wrong or not coalesced")
        try check(try tuning.receive(StreamSettingsResult(id: request.id, state: initial, codec: .hevc)), "The HEVC reply was ignored")
        try check(tuning.appliedCodec == .hevc && tuning.desiredCodec == .hevc && tuning.nextRequest() == nil,
                  "An applied HEVC stream was requested again")
        try tuning.choose(StreamSettings(longestEdge: 1920, framesPerSecond: 15, megabits: 5))
        guard let bitrate = tuning.nextRequest() else { throw CheckFailure("A bitrate change sent no request") }
        try check(bitrate.codec == .hevc, "A later change dropped HEVC and would switch the host back to H.264")
        var fallback = try VideoTuningSession(applied: initial)
        fallback.chooseCodec(.hevc)
        guard let asked = fallback.nextRequest() else { throw CheckFailure("No HEVC request") }
        try check(try fallback.receive(StreamSettingsResult(id: asked.id, state: initial)), "The H.264 reply was ignored")
        try check(fallback.appliedCodec == .h264 && fallback.desiredCodec == .h264 && fallback.nextRequest() == nil,
                  "A host that kept H.264 was asked again")
        try fallback.choose(medium)
        try check(fallback.nextRequest()?.codec == nil, "A session that fell back still named a codec")
    }

    run("Codec fields are optional both ways so older peers keep decoding live quality and hello messages") {
        struct OlderRequest: Decodable { let id: UUID; let settings: StreamSettings }
        struct OlderResult: Decodable { let id: UUID; let state: VideoStreamState; let error: String? }
        let request = StreamSettingsRequest(settings: medium, codec: .hevc)
        let older = try JSONDecoder().decode(OlderRequest.self, from: JSONEncoder().encode(request))
        try check(older.id == request.id && older.settings == medium, "An older host could not read an HEVC request")
        let result = StreamSettingsResult(id: request.id, state: state(medium), codec: .hevc, restartsStream: false)
        let olderResult = try JSONDecoder().decode(OlderResult.self, from: JSONEncoder().encode(result))
        try check(olderResult.state == result.state && olderResult.error == nil, "An older viewer could not read a codec reply")
        let decodedInPlace = try Wire.readJSON(StreamSettingsResult.self, JSONEncoder().encode(result))
        try check(decodedInPlace.restartsStream == false, "In-place stream settings result lost restartsStream flag")
        try check(try Wire.readJSON(StreamSettingsRequest.self, JSONEncoder().encode(StreamSettingsRequest(settings: medium))).codec == nil
                  && Wire.readJSON(StreamSettingsResult.self, JSONEncoder().encode(StreamSettingsResult(id: request.id, state: initial))).codec == nil
                  && Wire.readJSON(StreamSettingsResult.self, JSONEncoder().encode(StreamSettingsResult(id: request.id, state: initial))).restartsStream == nil,
                  "A message without a codec did not mean H.264 or fabricated restartsStream")
        let unknown = #"{"id":"\#(UUID().uuidString)","settings":{"longestEdge":1920,"framesPerSecond":15,"megabits":3},"codec":"av1"}"#
        try rejects("An unknown codec was accepted") { _ = try Wire.readJSON(StreamSettingsRequest.self, Data(unknown.utf8)) }
        let hello = Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true, hevcVideoV1: true)
        let decodedHello = try Wire.readJSON(Hello.self, JSONEncoder().encode(hello))
        try decodedHello.validate()
        try check(decodedHello.hevcVideoV1 == true, "The HEVC capability was lost")
        let plainHello = Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true)
        try check(!String(decoding: try JSONEncoder().encode(plainHello), as: UTF8.self).contains("hevc")
                  && Wire.readJSON(Hello.self, JSONEncoder().encode(plainHello)).hevcVideoV1 == nil,
                  "A host without HEVC advertised it")
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

    run("A host that chose no default leaves it to the viewer: local paths get the smoother one, and neither is saved with the record") {
        let offered = StreamSettings.automaticDefault, local = StreamSettings.automaticLocalDefault
        // Both can be chosen in the settings pickers, and the stream can start at what the host offers
        // without a settings request first.
        for settings in [offered, local] {
            try settings.validateControlValues()
            try check(StreamSettings.longestEdges.contains(settings.longestEdge) && StreamSettings.frameRates.contains(settings.framesPerSecond)
                      && StreamSettings.bitRates.contains(settings.megabits), "A default cannot be shown in the pickers: \(settings.summary)")
        }
        try check(offered.legacyCompatible == offered && offered.framesPerSecond == 30 && local.framesPerSecond == 60
                  && local.longestEdge == offered.longestEdge, "The automatic defaults changed: \(offered.summary) and \(local.summary)")
        // About the bits per frame of the earlier default, 3 Mbps at 15 fps, or more.
        let earlier = Double(StreamSettings().megabits) / Double(StreamSettings().framesPerSecond)
        try check(Double(local.megabits) / Double(local.framesPerSecond) >= earlier
                  && Double(offered.megabits) / Double(offered.framesPerSecond) >= earlier * 0.8, "A default carries far fewer bits per frame than before")
        func ceiling(leftToViewer: Bool, localPath: Bool, extended: Bool = true, highRefresh: Bool = true) -> StreamSettings {
            ViewerQualityPolicy.defaultCeiling(offered: offered, leftToViewer: leftToViewer, localPath: localPath,
                                               supportsExtended: extended, supportsHighRefresh: highRefresh)
        }
        try check(ceiling(leftToViewer: true, localPath: true) == local, "A local path did not get the local default")
        try check(ceiling(leftToViewer: true, localPath: false) == offered, "A wide-area path did not keep what the host offers")
        // An owner's choice, and a host that says nothing, are kept on every path.
        let chosen = StreamSettings(longestEdge: 1920, framesPerSecond: 15, megabits: 3)
        try check(ViewerQualityPolicy.defaultCeiling(offered: chosen, leftToViewer: false, localPath: true,
                                                     supportsExtended: true, supportsHighRefresh: true) == chosen,
                  "A default the owner chose was replaced on a local path")
        // A peer that claims the flag without 60 fps support gets no more than it supports.
        try check(ceiling(leftToViewer: true, localPath: true, highRefresh: false) == local.extendedCompatible
                  && ceiling(leftToViewer: true, localPath: true, extended: false, highRefresh: false) == local.legacyCompatible
                  && local.extendedCompatible.framesPerSecond == 30, "The local default exceeded what the host supports")

        // The default of this connection is in effect but not saved; a choice made by hand is.
        var policy = ViewerQualityPolicy()
        let first = policy.settingsForConnection(hostDefault: local, defaultIsAutomatic: true, supportsExtended: true,
                                                 supportsHighRefresh: true, supportsHigherFrameRate: true)
        try check(first == local && !policy.maySaveCurrentChoice, "The automatic default would be saved with the record")
        policy.chooseManually(savePreference: policy.maySaveCurrentChoice)
        try check(!policy.confirm(local, maySave: policy.maySaveCurrentChoice) && policy.preferred == nil,
                  "Confirming the automatic default made it a saved choice")
        // The same record over a wide-area path next time starts from what the host offers there.
        try check(policy.settingsForConnection(hostDefault: offered, defaultIsAutomatic: true, supportsExtended: true,
                                               supportsHighRefresh: true, supportsHigherFrameRate: true) == offered,
                  "An earlier local session decided the default of a wide-area one")
        policy.chooseManually()
        try check(policy.confirm(high, maySave: policy.maySaveCurrentChoice) && policy.preferred == high, "A choice made by hand was not saved")
        try check(policy.settingsForConnection(hostDefault: local, defaultIsAutomatic: true, supportsExtended: true,
                                               supportsHighRefresh: true, supportsHigherFrameRate: true) == high && policy.maySaveCurrentChoice,
                  "The automatic default replaced a saved choice")
        // A default the owner chose keeps being saved on first use, as before.
        var explicit = ViewerQualityPolicy()
        _ = explicit.settingsForConnection(hostDefault: high, supportsExtended: true, supportsHighRefresh: true)
        try check(explicit.maySaveCurrentChoice, "A host default the owner chose is no longer saved")

        // On the wire the flag is optional: older hosts do not send it and older viewers ignore it.
        let hello = Hello(name: "host", width: 1920, height: 1080, settings: offered.legacyCompatible, canControl: true,
                          preferredSettings: offered.extendedCompatible, highRefreshVideoSettings: true,
                          preferredHighRefreshSettings: offered.highRefreshCompatible, higherFrameRateVideoV1: true,
                          preferredHigherFrameRateSettings: offered, automaticDefaultQualityV1: true)
        try hello.validate()
        let decoded = try Wire.readJSON(Hello.self, Wire.json(.hello, hello).payload)
        try check(decoded.automaticDefaultQualityV1 == true && decoded.preferredHigherFrameRateSettings == offered, "The flag did not round-trip")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as! [String: Any]
        object.removeValue(forKey: "automaticDefaultQualityV1")
        try check(try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: object)).automaticDefaultQualityV1 == nil,
                  "A hello without the flag did not read as an owner's choice")
        let chose = Hello(name: "host", width: 1920, height: 1080, settings: chosen, canControl: true)
        try check(!String(decoding: try JSONEncoder().encode(chose), as: UTF8.self).contains("automaticDefaultQualityV1"),
                  "A host with a chosen default sent the flag")
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

    run("Single-start initial negotiation capability is optional and confirms unchanged settings once") {
        let legacyHello = Hello(name: "legacy", width: 1920, height: 1080, settings: .init(), canControl: true)
        try check(Wire.readJSON(Hello.self, JSONEncoder().encode(legacyHello)).initialStreamNegotiationV1 == nil,
                  "Legacy hello unexpectedly advertised initialStreamNegotiationV1")
        let modernHello = Hello(name: "modern", width: 1920, height: 1080, settings: .init(), canControl: true,
                                initialStreamNegotiationV1: true)
        try check(Wire.readJSON(Hello.self, JSONEncoder().encode(modernHello)).initialStreamNegotiationV1 == true,
                  "Modern hello lost initialStreamNegotiationV1")

        var unchanged = try VideoTuningSession(applied: initial)
        try check(unchanged.nextRequest() == nil, "Unchanged tuning emitted an unsolicited legacy request")
        guard let confirm = unchanged.initialConfirmationRequest() else {
            throw CheckFailure("Initial confirmation request was nil for idle session")
        }
        try check(confirm.settings == initial.settings && confirm.codec == nil && unchanged.pending?.id == confirm.id,
                  "Initial confirmation altered settings or codec")
        try check(unchanged.initialConfirmationRequest() == nil, "Duplicate initial confirmation sent while pending")
        try check(try unchanged.receive(StreamSettingsResult(id: confirm.id, state: initial, restartsStream: false)),
                  "Initial confirmation result was rejected")
        try check(unchanged.pending == nil && unchanged.nextRequest() == nil,
                  "Completed initial confirmation left pending work")

        var upgraded = try VideoTuningSession(applied: initial, preferred: high)
        upgraded.chooseCodec(.hevc)
        guard let upgradedReq = upgraded.initialConfirmationRequest() else {
            throw CheckFailure("Initial confirmation dropped preferred upgrade")
        }
        try check(upgradedReq.settings == high && upgradedReq.codec == .hevc,
                  "Initial confirmation did not carry desired high settings and HEVC")
    }

    run("HEVC 4:4:4 negotiation, fallback settling, wire omission and saved connection preferences preserve compatibility") {
        let plainHello = Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true, hevcVideoV1: true)
        try check(!String(decoding: try JSONEncoder().encode(plainHello), as: UTF8.self).contains("hevc444VideoV1")
                  && Wire.readJSON(Hello.self, JSONEncoder().encode(plainHello)).hevc444VideoV1 == nil,
                  "Host without HEVC 4:4:4 advertised hevc444VideoV1")
        let trueColorHello = Hello(name: "host", width: 1920, height: 1080, settings: .init(), canControl: true,
                                   hevcVideoV1: true, hevc444VideoV1: true)
        let decodedHello = try Wire.readJSON(Hello.self, JSONEncoder().encode(trueColorHello))
        try decodedHello.validate()
        try check(decodedHello.hevc444VideoV1 == true, "HEVC 4:4:4 capability lost over wire")

        var tuning = try VideoTuningSession(applied: initial)
        tuning.chooseCodec(.hevc)
        let hevc420Req = tuning.nextRequest()!
        try check(hevc420Req.chromaSubsampling == nil
                  && !String(decoding: try JSONEncoder().encode(hevc420Req), as: UTF8.self).contains("chromaSubsampling"),
                  "4:2:0 HEVC request emitted unnecessary chromaSubsampling field")
        try check(try tuning.receive(StreamSettingsResult(id: hevc420Req.id, state: initial, codec: .hevc)),
                  "4:2:0 HEVC result rejected")

        tuning.chooseChromaSubsampling(.yuv444)
        guard let req444 = tuning.nextRequest() else { throw CheckFailure("Choosing 4:4:4 sent no request") }
        try check(req444.codec == .hevc && req444.chromaSubsampling == .yuv444, "4:4:4 request lacked HEVC or yuv444")
        try check(try tuning.receive(StreamSettingsResult(id: req444.id, state: initial, codec: .hevc, chromaSubsampling: .yuv444)),
                  "4:4:4 reply rejected")
        try check(tuning.appliedChroma == .yuv444 && tuning.desiredChroma == .yuv444 && tuning.nextRequest() == nil,
                  "Confirmed 4:4:4 stream did not settle")

        // Stepping back to 4:2:0 while currently on 4:4:4 must explicitly send .yuv420 so the host reconfigures.
        tuning.chooseChromaSubsampling(.yuv420)
        guard let stepDown = tuning.nextRequest() else { throw CheckFailure("Stepping down from 4:4:4 to 4:2:0 sent no request") }
        try check(stepDown.codec == .hevc && stepDown.chromaSubsampling == .yuv420,
                  "Stepping down from 4:4:4 did not explicitly carry yuv420")
        try check(try tuning.receive(StreamSettingsResult(id: stepDown.id, state: initial, codec: .hevc, chromaSubsampling: .yuv420)),
                  "4:2:0 step-down reply rejected")
        try check(tuning.appliedChroma == .yuv420 && tuning.desiredChroma == .yuv420 && tuning.nextRequest() == nil,
                  "4:2:0 step-down did not settle")

        // Host fallback (keeps 4:2:0 when 4:4:4 was requested) settles desiredChroma to avoid endless retries.
        tuning.chooseChromaSubsampling(.yuv444)
        let fallbackReq = tuning.nextRequest()!
        try check(try tuning.receive(StreamSettingsResult(id: fallbackReq.id, state: initial, codec: .hevc, chromaSubsampling: .yuv420)),
                  "4:2:0 fallback reply rejected")
        try check(tuning.appliedChroma == .yuv420 && tuning.desiredChroma == .yuv420 && tuning.nextRequest() == nil,
                  "Host fallback from 4:4:4 to 4:2:0 did not settle desiredChroma")

        // ConnectionRecord persists optional chromaSubsampling cleanly and ignores malformed values.
        let saved444 = ConnectionRecord(address: "studio.local", port: 5908, name: "Studio",
                                        videoSettings: medium, chromaSubsampling: .yuv444)
        let savedData = try JSONEncoder().encode(saved444)
        try check(try JSONDecoder().decode(ConnectionRecord.self, from: savedData) == saved444,
                  "ConnectionRecord lost chromaSubsampling")
        var raw = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        raw["chromaSubsampling"] = "yuv422_unknown"
        let recovered = try JSONDecoder().decode(ConnectionRecord.self, from: JSONSerialization.data(withJSONObject: raw))
        try check(recovered.id == saved444.id && recovered.chromaSubsampling == nil && recovered.videoSettings == medium,
                  "Malformed chromaSubsampling hid saved ConnectionRecord")
    }

    run("Single-start cursor negotiation attaches once to initial StreamSettingsRequest and validates field pairing") {
        let hello = Hello(name: "Studio", width: 2560, height: 1440, settings: .init(), canControl: true,
                          independentCursorV1: true, initialStreamNegotiationV1: true, initialCursorNegotiationV1: true)
        let decodedHello = try Wire.readJSON(Hello.self, Wire.json(.hello, hello).payload)
        try check(decodedHello.initialCursorNegotiationV1 == true, "Hello lost initialCursorNegotiationV1")
        let legacyHello = try Wire.readJSON(Hello.self, Wire.json(.hello, Hello(name: "Old", width: 1920, height: 1080,
                                                                               settings: .init(), canControl: true)).payload)
        try check(legacyHello.initialCursorNegotiationV1 == nil, "Legacy Hello unexpectedly set initialCursorNegotiationV1")

        let initial = VideoStreamState(settings: .init(longestEdge: 1920, framesPerSecond: 30, megabits: 10), width: 1920, height: 1080)
        var unchanged = try VideoTuningSession(applied: initial, preferred: initial.settings)
        let cursorID = UUID()
        unchanged.chooseInitialCursor(requestID: cursorID, enabled: true)
        // Video settings themselves did not change, so nextRequest stays nil while initialConfirmationRequest carries the cursor fields once.
        try check(unchanged.nextRequest() == nil, "Initial cursor alone triggered a manual-style video settings request")
        guard let confirmReq = unchanged.initialConfirmationRequest() else {
            throw CheckFailure("initialConfirmationRequest returned nil")
        }
        try confirmReq.validate()
        try check(confirmReq.cursorRequestID == cursorID && confirmReq.independentCursor == true,
                  "initialConfirmationRequest lost initial cursor negotiation")
        try check( try unchanged.receive(StreamSettingsResult(id: confirmReq.id, state: initial, restartsStream: false)),
                  "Initial confirmation reply rejected")
        try unchanged.choose(.init(longestEdge: 2560, framesPerSecond: 60, megabits: 20))
        guard let followUp = unchanged.nextRequest() else { throw CheckFailure("Follow-up request missing") }
        let encodedFollowUp = String(decoding: try JSONEncoder().encode(followUp), as: UTF8.self)
        try check(followUp.cursorRequestID == nil && followUp.independentCursor == nil
                  && !encodedFollowUp.contains("cursorRequestID") && !encodedFollowUp.contains("independentCursor"),
                  "Subsequent StreamSettingsRequest re-sent one-shot initial cursor fields")

        // Also attaches when initial video settings/codec differ from Hello (nextRequest path).
        var changed = try VideoTuningSession(applied: initial, preferred: .init(longestEdge: 2560, framesPerSecond: 60, megabits: 20))
        let secondCursorID = UUID()
        changed.chooseCodec(.hevc)
        changed.chooseInitialCursor(requestID: secondCursorID, enabled: false)
        guard let firstChanged = changed.nextRequest() else { throw CheckFailure("Changed startup sent no nextRequest") }
        try firstChanged.validate()
        try check(firstChanged.codec == .hevc && firstChanged.cursorRequestID == secondCursorID && firstChanged.independentCursor == false,
                  "Changed startup request missed HEVC or initial cursor fields")

        // Mismatched cursorRequestID / independentCursor is rejected on validation.
        try rejects("Mismatched cursorRequestID without independentCursor was accepted") {
            try StreamSettingsRequest(settings: .init(), cursorRequestID: UUID(), independentCursor: nil).validate()
        }
        try rejects("Mismatched independentCursor without cursorRequestID was accepted") {
            try StreamSettingsRequest(settings: .init(), cursorRequestID: nil, independentCursor: true).validate()
        }
    }
}
