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
        try MediaControl(.stats, sessionID: session, encodeMilliseconds: 4.2, deliveryMilliseconds: 180).validate()
        for delivery in [-1, .nan, .infinity, 60_001] {
            try rejects("Invalid delivery growth was accepted") {
                try MediaControl(.stats, sessionID: session, encodeMilliseconds: 4, deliveryMilliseconds: delivery).validate()
            }
        }
        try rejects("Delivery growth outside stats was accepted") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, deliveryMilliseconds: 10).validate()
        }
        // An older viewer decodes stats with the new field and still sees a valid encode figure.
        let encoded = try JSONEncoder().encode(MediaControl(.stats, sessionID: session, encodeMilliseconds: 4.2, deliveryMilliseconds: 180))
        try check(String(decoding: encoded, as: UTF8.self).contains("encodeMilliseconds"), "Stats lost the field older viewers require")
        let idleStats = MediaControl(.stats, sessionID: session, encodeMilliseconds: 0, deliveryMilliseconds: 195, encodeIdle: true)
        try idleStats.validate()
        let decodedIdle = try MediaControl.read(idleStats.message().payload)
        try check(decodedIdle.encodeIdle == true && decodedIdle.deliveryMilliseconds == 195 && decodedIdle.encodeMilliseconds == 0,
                  "Idle encode delivery stats changed in transit")
        try rejects("Accepted encodeIdle outside stats") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, encodeIdle: true).validate()
        }
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
    run("A media request can opt in to marked repairs and legacy requests omit the capability") {
        let legacy = try MediaControl.read(Data(#"{"operation":"request"}"#.utf8))
        let modern = try MediaControl.read(MediaControl(.request, markedRepairs: true, datagramInteractive: true,
                                                        dynamicFrameWindow: true, parityFEC: true).message().payload)
        try check(legacy.markedRepairs == nil && legacy.datagramInteractive == nil
                  && legacy.dynamicFrameWindow == nil && legacy.parityFEC == nil
                  && modern.markedRepairs == true && modern.datagramInteractive == true
                  && modern.dynamicFrameWindow == true && modern.parityFEC == true,
                  "Lost the viewer's repair, interactive datagram, dynamic window or parity FEC capability")
        let session = UUID(), token = Data(repeating: 0x33, count: 32)
        let offer = try MediaControl.read(MediaControl(.offer, sessionID: session, token: token, datagramKey: token,
                                                       datagramInteractive: true, dynamicFrameWindow: true, parityFEC: true).message().payload)
        try check(offer.datagramInteractive == true && offer.dynamicFrameWindow == true && offer.parityFEC == true,
                  "Lost offer datagramInteractive, dynamicFrameWindow or parityFEC capability")
        try rejects("Allowed datagramInteractive outside request/offer") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, datagramInteractive: true).validate()
        }
        try rejects("Allowed dynamicFrameWindow outside request/offer") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, dynamicFrameWindow: true).validate()
        }
        try rejects("Allowed parityFEC outside request/offer") {
            try MediaControl(.recover, sessionID: session, transportEpoch: 1, codecEpoch: 1, parityFEC: true).validate()
        }
        var move = RemoteInput(kind: .move); move.x = 0.25; move.y = 0.75; move.pointerSequence = 42
        try move.validate()
        var zeroSeq = move; zeroSeq.pointerSequence = 0
        try rejects("Accepted zero pointerSequence") { try zeroSeq.validate() }
        var keySeq = RemoteInput(kind: .keyDown); keySeq.keyCode = 1; keySeq.pointerSequence = 1
        try rejects("Accepted pointerSequence on keyboard event") { try keySeq.validate() }
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
