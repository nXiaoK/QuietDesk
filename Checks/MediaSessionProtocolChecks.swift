import Foundation
import QuietDeskCore

func runMediaSessionProtocolChecks() {
    run("Media capability is optional and old message numbers remain stable") {
        let original = Hello(name: "legacy", width: 1920, height: 1080, settings: .init(), canControl: true)
        let decoded = try Wire.readJSON(Hello.self, JSONEncoder().encode(original))
        try check(decoded.mediaTransportV1 == nil, "Legacy hello enabled media transport")
        try check(decoded.relayTransportV1 == nil && decoded.relayDeviceID == nil, "Legacy hello enabled relay routing")
        let modern = Hello(name: "modern", width: 1920, height: 1080, settings: .init(), canControl: true, mediaTransportV1: true)
        try check(Wire.readJSON(Hello.self, JSONEncoder().encode(modern)).mediaTransportV1 == true, "Capability was lost")
        try check(MessageKind.hello.rawValue == 1 && MessageKind.sessionPauseResult.rawValue == 25,
                  "Existing wire identifiers changed")
        try check(MessageKind.mediaControl.rawValue == 26, "Media identifiers overlap existing messages")
    }
    run("Media negotiation rejects invalid credentials and incomplete switch transactions") {
        try MediaControl(.request).validate()
        let session = UUID(), token = Data(repeating: 0x51, count: 32)
        let offer = MediaControl(.offer, sessionID: session, token: token, datagramKey: token)
        try check(MediaControl.read(offer.message().payload).sessionID == session, "Offer changed")
        try rejects("Accepted a short media secret") {
            try MediaControl(.offer, sessionID: session, token: token, datagramKey: Data([1])).validate()
        }
        try rejects("Accepted a control-role auxiliary binding") {
            try MediaControl(.bind, sessionID: session, token: token, role: .control).validate()
        }
        try rejects("Accepted a switch without a transaction") {
            try MediaControl(.prepare, sessionID: session, transportEpoch: 1, codecEpoch: 1, path: "udp").validate()
        }
        try rejects("Accepted an unknown media path") {
            try MediaControl(.prepare, sessionID: session, transactionID: UUID(), transportEpoch: 1, codecEpoch: 1, path: "other").validate()
        }
        try MediaControl(.stats, sessionID: session, encodeMilliseconds: 4.2).validate()
        try rejects("Accepted non-finite encoder data") {
            try MediaControl(.stats, sessionID: session, encodeMilliseconds: .infinity).validate()
        }
        try rejects("Accepted media failure on an unrelated operation") {
            try MediaControl(.stats, sessionID: session, mediaFailure: true, encodeMilliseconds: 4).validate()
        }
    }
    run("Relay media capability and delivery hints remain optional and operation-scoped") {
        let session = UUID(), device = UUID()
        let hello = Hello(name: "relay", width: 1920, height: 1080, settings: .init(), canControl: true,
                          relayTransportV1: true, relayDeviceID: device)
        try check(Wire.readJSON(Hello.self, JSONEncoder().encode(hello)).relayDeviceID == device, "Relay identity changed")
        try check(MediaControl.read(MediaControl(.request).message().payload).relayRouting == nil, "Default request changed")
        try check(MediaControl.read(MediaControl(.request, relayRouting: true).message().payload).relayRouting == true, "Capability lost")
        try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, mediaFailure: true).validate()
        try rejects("Allowed relay capability on a transaction") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, relayRouting: true).validate()
        }
    }
    run("Auxiliary bindings are session-bound, expiring and consumed once per role") {
        let session = UUID(), token = Data(repeating: 0xA6, count: 32)
        var grant = try MediaBindingGrant(sessionID: session, token: token, now: 10)
        let video = MediaControl(.bind, sessionID: session, token: token, role: .video)
        try check(!grant.consume(video, now: .nan), "Non-finite clock accepted")
        try check(!grant.consume(MediaControl(.bind, sessionID: UUID(), token: token, role: .video), now: 11), "Cross-session token accepted")
        try check(!grant.consume(MediaControl(.bind, sessionID: session, token: Data(repeating: 0, count: 32), role: .video), now: 11), "Wrong token consumed grant")
        try check(grant.consume(video, now: 11), "Valid binding was rejected")
        try check(!grant.consume(video, now: 12), "Replayed binding replaced a channel")
        try check(grant.consume(MediaControl(.bind, sessionID: session, token: token, role: .bulk), now: 12), "Independent bulk role was rejected")
        var expired = try MediaBindingGrant(sessionID: session, token: token, now: 10)
        try check(!expired.consume(video, now: 26), "Expired token accepted")
    }
}
