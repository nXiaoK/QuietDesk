import Foundation
import QuietDeskCore

func runRemoteTextTypingChecks() {
    run("TypeTextRequest normalizes CRLF/CR, allows Unicode/Tab/LF, and round-trips through Wire.json") {
        let request = try TypeTextRequest(text: "Hello 中文\r\nLine2\tTab\rEnd", submitReturn: true)
        try check(!request.cancel && request.submitReturn, "Expected submitReturn non-cancel request")
        try check(request.text == "Hello 中文\nLine2\tTab\nEnd", "Expected CRLF/CR normalized to LF")

        let message = try Wire.json(.typeTextRequest, request)
        try check(message.kind == .typeTextRequest, "Wrong message kind")
        let decoded = try Wire.readJSON(TypeTextRequest.self, message.payload)
        try check(decoded == request, "TypeTextRequest round trip mismatch")
    }

    run("TypeTextRequest.cancel round-trips cleanly and rejects non-empty cancel payloads") {
        let targetID = UUID()
        let cancelReq = TypeTextRequest.cancel(id: targetID)
        try check(cancelReq.cancel && cancelReq.text.isEmpty && !cancelReq.submitReturn, "Cancel fields invalid")
        let message = try Wire.json(.typeTextRequest, cancelReq)
        let decoded = try Wire.readJSON(TypeTextRequest.self, message.payload)
        try check(decoded == cancelReq, "Cancel round trip mismatch")

        let malformedCancel = Data(#"{"id":"\#(targetID.uuidString)","cancel":true,"text":"sneak"}"#.utf8)
        try rejects("Accepted cancel request with text") {
            _ = try Wire.readJSON(TypeTextRequest.self, malformedCancel)
        }
    }

    run("TypeTextRequest enforces 512-char / 2048-byte limits, stays under 4KB Wire limit, and rejects control/format scalars") {
        try rejects("Accepted empty text") {
            _ = try TypeTextRequest(text: "")
        }
        let maxASCII = String(repeating: "A", count: TypeTextRequest.maximumCharacterCount)
        let validMax = try TypeTextRequest(text: maxASCII, submitReturn: true)
        let encodedMax = try Wire.json(.typeTextRequest, validMax)
        try check(encodedMax.payload.count <= 4_096, "Max TypeTextRequest exceeded 4KB Wire.readJSON cap")

        try rejects("Accepted 513 characters") {
            _ = try TypeTextRequest(text: String(repeating: "A", count: TypeTextRequest.maximumCharacterCount + 1))
        }
        // 512 4-byte emoji = 2048 bytes (exact limit), whereas 512 escaped quotes/4-byte + extra exceeds 2048 bytes if > 512.
        // Test 512 4-byte UTF-8 characters (2048 UTF-8 bytes) succeeds and fits within 4096 JSON bytes:
        let maxUTF8 = String(repeating: "🙂", count: 512)
        let encodedEmoji = try Wire.json(.typeTextRequest, try TypeTextRequest(text: maxUTF8))
        try check(encodedEmoji.payload.count <= 4_096, "Emoji TypeTextRequest exceeded 4KB Wire cap")

        // Test > 2048 UTF-8 bytes with <= 512 Swift Characters (combining grapheme clusters) is rejected:
        let heavyGrapheme = "e\u{0301}\u{0302}\u{0303}" // 1 Character, 7 UTF-8 bytes
        let overBytesUnderChars = String(repeating: heavyGrapheme, count: 300) // 300 chars, 2100 UTF-8 bytes
        try check(overBytesUnderChars.count <= TypeTextRequest.maximumCharacterCount, "Expected <= 512 chars")
        try rejects("Accepted > 2048 UTF-8 bytes") {
            _ = try TypeTextRequest(text: overBytesUnderChars)
        }

        // Control and bidi format scalars must be rejected
        for forbidden in ["abc\u{0000}def", "abc\u{001B}[2J", "abc\u{0008}", "abc\u{202E}txt.exe", "abc\u{2028}line"] {
            try rejects("Accepted forbidden control/format scalar") {
                _ = try TypeTextRequest(text: forbidden)
            }
        }
    }

    run("TypeTextResult and Hello.typeTextV1 maintain backward compatibility") {
        let id = UUID()
        let ok = try TypeTextResult(id: id, typedCount: 42)
        let encoded = try Wire.json(.typeTextResult, ok)
        try check(try Wire.readJSON(TypeTextResult.self, encoded.payload) == ok, "TypeTextResult round trip mismatch")

        try rejects("Accepted negative typedCount") {
            _ = try TypeTextResult(id: id, typedCount: -1)
        }
        try rejects("Accepted oversized error string") {
            _ = try TypeTextResult(id: id, typedCount: 0, error: String(repeating: "x", count: 241))
        }

        let legacyHello = Hello(name: "OldMac", width: 1920, height: 1080, settings: .init(), canControl: true)
        let legacyMsg = try Wire.json(.hello, legacyHello)
        let decodedLegacy = try Wire.readJSON(Hello.self, legacyMsg.payload)
        try check(decodedLegacy.typeTextV1 == nil, "Legacy Hello should keep typeTextV1 == nil")

        let modernHello = Hello(name: "NewMac", width: 1920, height: 1080, settings: .init(), canControl: true, typeTextV1: true)
        let modernMsg = try Wire.json(.hello, modernHello)
        let decodedModern = try Wire.readJSON(Hello.self, modernMsg.payload)
        try check(decodedModern.typeTextV1 == true, "Modern Hello should decode typeTextV1 == true")
    }
}
