import Foundation
import QuietDeskCore

func runCursorProtocolChecks() {
    let cursorID = UUID(), requestID = UUID(), sessionID = UUID()
    let first = MediaStreamID(sessionID: sessionID, transportEpoch: 1, codecEpoch: 1)
    let second = MediaStreamID(sessionID: sessionID, transportEpoch: 2, codecEpoch: 2)

    // This fixture tests the protocol's PNG header checks. Real image decoding belongs to AppChecks.
    func png(width: UInt32 = 32, height: UInt32 = 32) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        data.put(UInt32(13)); data.append(Data("IHDR".utf8))
        data.put(width); data.put(height)
        data.append(contentsOf: [8, 6, 0, 0, 0]); data.put(UInt32(0))
        return data
    }

    func image(_ data: Data? = nil, width: Int = 32, height: Int = 32,
               logicalWidth: Double = 16, logicalHeight: Double = 16,
               x: Double = 2.5, y: Double = 3.5) throws -> CursorImage {
        try CursorImage(png: data ?? png(), pixelWidth: width, pixelHeight: height,
                        logicalWidth: logicalWidth, logicalHeight: logicalHeight, hotSpotX: x, hotSpotY: y)
    }

    func replacing(_ source: Data, offset: Int, bytes: Data) -> Data {
        var result = source
        let start = result.startIndex + offset
        result.replaceSubrange(start..<(start + bytes.count), with: bytes)
        return result
    }

    func bits(_ value: UInt64) -> Data { var data = Data(); data.put(value); return data }

    func status(epoch: UInt32 = 1, enabled: Bool = true, id: UUID? = nil) -> CursorControl {
        CursorControl(.status, requestID: requestID, cursorID: id ?? cursorID, epoch: epoch, enabled: enabled)
    }

    func binding(_ stream: MediaStreamID, epoch: UInt32 = 1, enabled: Bool = true, id: UUID? = nil) -> CursorControl {
        CursorControl(.binding, cursorID: id ?? cursorID, epoch: epoch, enabled: enabled, stream: stream)
    }

    run("Independent cursor capability is optional and preserves all existing message identifiers") {
        let legacy: [String: Any] = ["version": 1, "name": "legacy", "width": 1920, "height": 1080,
            "settings": ["longestEdge": 1920, "framesPerSecond": 15, "megabits": 3], "canControl": true]
        let decoded = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: legacy))
        try check(decoded.independentCursorV1 == nil && decoded.mediaTransportV1 == nil,
                  "Missing cursor capability enabled the new mode")
        let modern = Hello(name: "modern", width: 1920, height: 1080, settings: .init(), canControl: true,
                           mediaTransportV1: true, independentCursorV1: true)
        try check(Wire.readJSON(Hello.self, Wire.json(.hello, modern).payload).independentCursorV1 == true,
                  "Cursor capability was lost")
        var malformed = legacy; malformed["independentCursorV1"] = 1
        try rejects("Numeric cursor capability accepted") {
            _ = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: malformed))
        }
        let oldKinds: [MessageKind] = [.hello, .video, .acknowledgement, .input, .ping, .pong, .clipboard,
            .requestClipboard, .releaseInput, .inputStatus, .clipboardSettings, .clipboardBegin, .clipboardEntry,
            .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel, .streamSettingsRequest,
            .streamSettingsResult, .controlStatus, .deviceIdentity, .sessionEffectsRequest, .sessionEffectsResult,
            .sessionPauseRequest, .sessionPauseResult, .mediaControl, .mediaFrame, .mediaFeedback]
        try check(oldKinds.enumerated().allSatisfy { $0.element.rawValue == UInt8($0.offset + 1) }
                  && MessageKind.cursorControl.rawValue == 29 && MessageKind.cursorShape.rawValue == 30
                  && MessageKind.cursorPosition.rawValue == 31 && Wire.version == 1, "Cursor messages renumbered the old protocol")
    }

    run("Cursor requests, statuses and media bindings preserve their distinct identities") {
        let request = CursorControl(.request, requestID: requestID, enabled: true)
        let values = [request, status(), status(epoch: 2, enabled: false), binding(second)]
        for value in values {
            let message = try value.message()
            let decoded = try CursorControl.read(message.payload)
            try check(message.kind == .cursorControl && decoded.operation == value.operation
                      && decoded.requestID == value.requestID && decoded.cursorID == value.cursorID
                      && decoded.epoch == value.epoch && decoded.enabled == value.enabled
                      && decoded.stream == value.stream && decoded.reason == value.reason, "Cursor control identity changed on the wire")
        }
        let laterRequest = UUID()
        let laterStatus = CursorControl(.status, requestID: laterRequest, cursorID: cursorID, epoch: 2, enabled: false)
        try check(try CursorControl.read(laterStatus.message().payload).requestID == laterRequest
                  && CursorControl.read(laterStatus.message().payload).requestID != requestID,
                  "Distinct status replies lost their request identities")
        try check(try CursorControl.read(binding(second).message().payload).stream?.stream == second,
                  "Binding did not retain both transport and codec epochs")
    }

    run("Cursor controls reject missing identities, zero epochs and mixed operation fields") {
        let invalid = [CursorControl(.request, enabled: true),
            CursorControl(.request, requestID: requestID, cursorID: cursorID, enabled: true),
            CursorControl(.request, requestID: requestID, enabled: true, stream: first),
            CursorControl(.request, requestID: requestID, enabled: true, reason: .unavailable),
            CursorControl(.status, cursorID: cursorID, epoch: 1, enabled: true),
            CursorControl(.status, requestID: requestID, epoch: 1, enabled: true),
            CursorControl(.status, requestID: requestID, cursorID: cursorID, epoch: 0, enabled: true),
            CursorControl(.status, requestID: requestID, cursorID: cursorID, epoch: 1, enabled: true, stream: first),
            CursorControl(.binding, requestID: requestID, cursorID: cursorID, epoch: 1, enabled: true, stream: first),
            CursorControl(.binding, cursorID: cursorID, epoch: 1, enabled: true),
            CursorControl(.binding, cursorID: cursorID, epoch: 1, enabled: true,
                          stream: MediaStreamID(sessionID: sessionID, transportEpoch: 0, codecEpoch: 1)),
            CursorControl(.binding, cursorID: cursorID, epoch: 1, enabled: true,
                          stream: MediaStreamID(sessionID: sessionID, transportEpoch: 1, codecEpoch: 0))]
        for value in invalid { try rejects("Invalid cursor operation accepted") { _ = try value.message() } }
        try rejects("Oversized cursor control accepted") { _ = try CursorControl.read(Data(count: 4097)) }
        let wrongEnabled: [String: Any] = ["operation": "request", "requestID": requestID.uuidString, "enabled": 1]
        try rejects("Numeric cursor enable flag accepted") {
            _ = try CursorControl.read(JSONSerialization.data(withJSONObject: wrongEnabled))
        }
    }

    run("Cursor image header validation bounds PNG dimensions, byte size, logical scale and hotspot") {
        let valid = try image()
        try check(valid.pixelWidth == 32 && valid.logicalWidth == 16 && valid.hotSpotX == 2.5,
                  "Valid image metadata changed")
        for dimension in [0, 257, Int.max] {
            try rejects("Invalid cursor pixel width accepted") { _ = try image(width: dimension) }
            try rejects("Invalid cursor pixel height accepted") { _ = try image(height: dimension) }
        }
        for value in [Double.nan, .infinity, -.infinity, 0, 0.49, 256.1] {
            try rejects("Invalid logical cursor width accepted") { _ = try image(logicalWidth: value) }
            try rejects("Invalid logical cursor height accepted") { _ = try image(logicalHeight: value) }
        }
        for value in [Double.nan, .infinity, -.infinity, -0.1, 16.1] {
            try rejects("Invalid cursor hotspot X accepted") { _ = try image(x: value) }
            try rejects("Invalid cursor hotspot Y accepted") { _ = try image(y: value) }
        }
        try rejects("Huge PNG IHDR width bypassed declared dimensions") { _ = try image(png(width: UInt32.max)) }
        try rejects("Huge PNG IHDR height bypassed declared dimensions") { _ = try image(png(height: UInt32.max)) }
        try rejects("Mismatched declared cursor dimensions accepted") { _ = try image(width: 16) }
        try rejects("Truncated IHDR accepted") { _ = try image(Data(png().prefix(32))) }
        try rejects("Unknown image signature accepted") { _ = try image(Data(repeating: 0, count: 33)) }
        var wrongLength = Data(); wrongLength.put(UInt32(14))
        try rejects("Wrong IHDR length accepted") { _ = try image(replacing(png(), offset: 8, bytes: wrongLength)) }
        try rejects("Wrong PNG first chunk accepted") { _ = try image(replacing(png(), offset: 12, bytes: Data("IDAT".utf8))) }
        var maximum = png(); maximum.append(Data(count: CursorImage.maximumBytes - maximum.count))
        try check(try image(maximum).png.count == CursorImage.maximumBytes, "Image byte limit rejected its inclusive endpoint")
        maximum.append(0)
        try rejects("Cursor image exceeded its byte bound") { _ = try image(maximum) }
    }

    run("Cursor shape binary framing round trips known and unknown images and sliced data") {
        for value in [try CursorShape(cursorID: cursorID, epoch: 7, revision: 9, image: image()),
                      try CursorShape(cursorID: cursorID, epoch: 7, revision: 10, image: nil)] {
            let encoded = value.encode(), decoded = try CursorShape.decode(encoded)
            try check(decoded.cursorID == value.cursorID && decoded.epoch == value.epoch
                      && decoded.revision == value.revision && decoded.image == value.image, "Cursor shape round trip changed data")
            let padded = Data([1, 2, 3, 4]) + encoded + Data([5, 6])
            let slice = padded[4..<(4 + encoded.count)]
            try check(slice.startIndex != 0 && CursorShape.decode(slice).image == value.image, "Sliced cursor shape assumed a zero data index")
            for length in 0..<encoded.count {
                try rejects("Cursor shape truncation accepted at \(length)") { _ = try CursorShape.decode(encoded.prefix(length)) }
            }
            try rejects("Trailing cursor shape bytes accepted") { _ = try CursorShape.decode(encoded + Data([0])) }
        }
    }

    run("Cursor shape binary flags, floating metadata and image lengths cannot bypass validation") {
        let encoded = try CursorShape(cursorID: cursorID, epoch: 1, revision: 1, image: image()).encode()
        for offset in [0, 2, 3] {
            try rejects("Invalid cursor shape envelope accepted") {
                _ = try CursorShape.decode(replacing(encoded, offset: offset, bytes: Data([0xFF])))
            }
        }
        try rejects("Zero cursor shape epoch accepted") { _ = try CursorShape.decode(replacing(encoded, offset: 20, bytes: Data(count: 4))) }
        try rejects("Zero cursor shape revision accepted") { _ = try CursorShape.decode(replacing(encoded, offset: 24, bytes: Data(count: 8))) }
        try rejects("Unknown cursor image flag accepted") { _ = try CursorShape.decode(replacing(encoded, offset: 32, bytes: Data([2]))) }
        for offset in [37, 45, 53, 61] {
            try rejects("NaN cursor image metadata accepted") {
                _ = try CursorShape.decode(replacing(encoded, offset: offset, bytes: bits(Double.nan.bitPattern)))
            }
        }
        var tooLong = Data(); tooLong.put(UInt32(CursorImage.maximumBytes + 1))
        try rejects("Oversized advertised cursor PNG length accepted") { _ = try CursorShape.decode(replacing(encoded, offset: 69, bytes: tooLong)) }
        try rejects("Oversized cursor shape allocation accepted") { _ = try CursorShape.decode(Data(count: CursorImage.maximumBytes + 81)) }
        try rejects("Zero revision shape constructed") { _ = try CursorShape(cursorID: cursorID, epoch: 1, revision: 0, image: nil) }
    }

    run("Cursor positions preserve visibility bounds and reject binary truncations and invalid numbers") {
        for inside in [false, true] {
            let value = try CursorPosition(cursorID: cursorID, epoch: 9, sequence: 17, insideDisplay: inside, x: 0.25, y: 0.75)
            let encoded = value.encode(), decoded = try CursorPosition.decode(encoded)
            try check(decoded.cursorID == cursorID && decoded.epoch == 9 && decoded.sequence == 17
                      && decoded.insideDisplay == inside && decoded.x == 0.25 && decoded.y == 0.75, "Cursor position changed on the wire")
            let padded = Data([1, 2, 3]) + encoded
            try check(try CursorPosition.decode(padded.dropFirst(3)).x == value.x, "Sliced position assumed a zero data index")
            for length in 0..<encoded.count {
                try rejects("Truncated cursor position accepted") { _ = try CursorPosition.decode(encoded.prefix(length)) }
            }
            try rejects("Trailing cursor position accepted") { _ = try CursorPosition.decode(encoded + Data([0])) }
            try rejects("Non-boolean position flag accepted") { _ = try CursorPosition.decode(replacing(encoded, offset: 32, bytes: Data([2]))) }
            for offset in [33, 41] {
                for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
                    try rejects("Invalid encoded cursor coordinate accepted") {
                        _ = try CursorPosition.decode(replacing(encoded, offset: offset, bytes: bits(invalid.bitPattern)))
                    }
                }
            }
        }
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            try rejects("Invalid position constructed") {
                _ = try CursorPosition(cursorID: cursorID, epoch: 1, sequence: 1, insideDisplay: true, x: invalid, y: 0)
            }
        }
        try rejects("Zero position epoch accepted") { _ = try CursorPosition(cursorID: cursorID, epoch: 0, sequence: 1, insideDisplay: true, x: 0, y: 0) }
        try rejects("Zero position sequence accepted") { _ = try CursorPosition(cursorID: cursorID, epoch: 1, sequence: 0, insideDisplay: true, x: 0, y: 0) }
    }

    run("Cursor mode changes only when its matching media stream commits") {
        var state = CursorPresentationState()
        try check(state.status(status()) && !state.enabled, "Status activated cursor mode before a frame commit")
        try check(state.bind(binding(first)) && !state.enabled, "Binding activated cursor mode before commit")
        try check(!state.commit(second) && !state.enabled, "An unrelated candidate activated cursor mode")
        try check(state.commit(first) && state.enabled, "Matching stream did not activate cursor mode")
        try check(state.status(status(epoch: 2, enabled: false)) && state.enabled, "Disable status changed the existing display prematurely")
        try check(state.bind(binding(second, epoch: 2, enabled: false)) && state.enabled, "Disable binding changed mode before commit")
        try check(!state.commit(first) && state.enabled, "Old candidate commit activated the next mode")
        try check(state.commit(second) && !state.enabled, "Matching disable stream did not disable cursor mode")
    }

    run("Old cursor epochs, cursor identities, shape revisions and position sequences cannot regress presentation") {
        var state = CursorPresentationState()
        _ = state.status(status()); _ = state.bind(binding(first)); _ = state.commit(first)
        let current = try image()
        try check(state.update(CursorShape(cursorID: cursorID, epoch: 1, revision: 2, image: current)), "Current shape rejected")
        try check(!state.update(CursorShape(cursorID: cursorID, epoch: 1, revision: 1, image: nil)), "Old shape revision replaced the current image")
        try check(state.update(CursorPosition(cursorID: cursorID, epoch: 1, sequence: 3, insideDisplay: true, x: 0.6, y: 0.4)), "Current position rejected")
        try check(!state.update(CursorPosition(cursorID: cursorID, epoch: 1, sequence: 2, insideDisplay: false, x: 0, y: 0)), "Old position hid the current cursor")
        try check(!state.status(status()) && !state.status(status(epoch: 3, id: UUID())), "Repeated status or another cursor session was accepted")
        try check(state.status(status(epoch: 2)) && state.image == nil && state.position == nil, "New epoch kept stale shape or position")
        try check(!state.update(CursorShape(cursorID: cursorID, epoch: 1, revision: 100, image: current))
                  && !state.update(CursorPosition(cursorID: cursorID, epoch: 1, sequence: 100, insideDisplay: true, x: 1, y: 1)), "Old epoch updates changed a new epoch")
        try check(!state.bind(binding(second, epoch: 1)) && !state.bind(binding(second, epoch: 2, id: UUID())), "Wrong binding identity accepted")
        try check(state.update(CursorShape(cursorID: cursorID, epoch: 2, revision: 1, image: current))
                  && state.update(CursorPosition(cursorID: cursorID, epoch: 2, sequence: 1, insideDisplay: true, x: 0.2, y: 0.8)), "New epoch inherited old sequence watermarks")
    }

    run("An unknown cursor image does not mean the cursor is hidden or the mode disabled") {
        var state = CursorPresentationState()
        _ = state.status(status()); _ = state.bind(binding(first)); _ = state.commit(first)
        _ = state.update(try CursorShape(cursorID: cursorID, epoch: 1, revision: 1, image: image()))
        _ = state.update(try CursorPosition(cursorID: cursorID, epoch: 1, sequence: 1, insideDisplay: true, x: 0.5, y: 0.5))
        try check(state.update(CursorShape(cursorID: cursorID, epoch: 1, revision: 2, image: nil))
                  && state.image == nil && state.enabled && state.position?.insideDisplay == true,
                  "Unknown shape was turned into a hidden cursor")
    }

    run("Late old-stream bindings cannot change cursor mode after a newer stream committed") {
        var state = CursorPresentationState()
        _ = state.status(status())
        _ = state.bind(binding(first)); _ = state.bind(binding(second, enabled: false))
        try check(state.commit(second) && !state.enabled, "Newest fixture stream did not commit")
        try check(!state.bind(binding(first)) && !state.commit(first) && !state.enabled,
                  "A late binding and old commit rolled presentation back")
        let otherSession = MediaStreamID(sessionID: UUID(), transportEpoch: 10, codecEpoch: 10)
        try check(!state.bind(binding(otherSession)) && !state.commit(otherSession)
                  && !state.bind(binding(second)) && !state.commit(second) && !state.enabled,
                  "A cross-session or repeated committed binding changed cursor mode")
    }

    run("A newer codec binding in the same transport survives an earlier codec commit") {
        var state = CursorPresentationState()
        let codecOnly = MediaStreamID(sessionID: sessionID, transportEpoch: 1, codecEpoch: 2)
        _ = state.status(status())
        _ = state.bind(binding(first)); _ = state.bind(binding(codecOnly, enabled: false))
        try check(state.commit(first) && state.enabled, "First codec did not commit")
        try check(state.commit(codecOnly) && !state.enabled, "Earlier commit discarded the newer codec binding")
    }

    run("Cursor stream binding retention remains bounded under repeated uncommitted candidates") {
        var state = CursorPresentationState()
        _ = state.status(status())
        let streams = (1...300).map { MediaStreamID(sessionID: sessionID, transportEpoch: UInt32($0), codecEpoch: UInt32($0)) }
        for stream in streams { try check(state.bind(binding(stream)), "A current candidate binding was rejected") }
        var retained = 0
        for stream in streams { if state.commit(stream) { retained += 1 } }
        try check((1...3).contains(retained), "Uncommitted cursor bindings were retained without a fixed bound")
    }
}
