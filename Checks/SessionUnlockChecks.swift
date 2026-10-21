import Foundation
import QuietDeskCore

func runSessionUnlockChecks() {
    run("Unlock requests carry only printable passwords and keep the old message numbers") {
        try check(MessageKind.sessionUnlockRequest.rawValue == 32 && MessageKind.sessionUnlockResult.rawValue == 33
                  && MessageKind.cursorPosition.rawValue == 31, "Unlock messages renumbered the protocol")
        let request = try SessionUnlockRequest(password: "Pass word £1密码")
        let decoded = try Wire.readJSON(SessionUnlockRequest.self, Wire.json(.sessionUnlockRequest, request).payload)
        try check(decoded.id == request.id && decoded.password == request.password, "Unlock request changed on the wire")
        for password in ["", "line\nbreak", "tab\tkey", "return\r", "esc\u{1B}", "zero\u{200B}width",
                         String(repeating: "x", count: SessionUnlockRequest.maximumPasswordLength + 1)] {
            try rejects("Accepted unsafe password \(password.debugDescription)") { _ = try SessionUnlockRequest(password: password) }
        }
        let forged = Data(#"{"id":"\#(UUID().uuidString)","password":"a\nb"}"#.utf8)
        try rejects("Decoded a password with a line break") { _ = try Wire.readJSON(SessionUnlockRequest.self, forged) }
        let result = SessionUnlockResult(id: request.id, outcome: .failed, error: "x")
        try check(try Wire.readJSON(SessionUnlockResult.self, Wire.json(.sessionUnlockResult, result).payload) == result,
                  "Unlock result changed on the wire")
    }
    run("Hellos without unlock fields still decode and mean no unlock support") {
        let hello = Hello(name: "Host", width: 1920, height: 1080, settings: StreamSettings(), canControl: true)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as! [String: Any]
        try check(object["sessionUnlockV1"] == nil && object["screenLocked"] == nil, "Default hello advertised unlock")
        object["sessionUnlockV1"] = true; object["screenLocked"] = true
        let upgraded = try JSONDecoder().decode(Hello.self, from: JSONSerialization.data(withJSONObject: object))
        try check(upgraded.sessionUnlockV1 == true && upgraded.screenLocked == true, "Unlock fields lost")
        object.removeValue(forKey: "sessionUnlockV1"); object.removeValue(forKey: "screenLocked")
        let old = try JSONDecoder().decode(Hello.self, from: JSONSerialization.data(withJSONObject: object))
        try check(old.sessionUnlockV1 == nil && old.screenLocked == nil, "Old hello invented unlock support")
    }
}
