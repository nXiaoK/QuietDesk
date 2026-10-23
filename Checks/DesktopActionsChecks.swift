import Foundation
import QuietDeskCore

func runDesktopActionsChecks() {
    run("Desktop actions are optional and preserve existing wire kinds") {
        let legacy = Hello(name: "fixture", width: 1920, height: 1080, settings: .init(), canControl: true)
        let bytes = try JSONEncoder().encode(legacy)
        let fields = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try check(fields["desktopActionsV1"] == nil, "New capability was enabled by default")
        try check(Wire.readJSON(Hello.self, bytes).desktopActionsV1 == nil, "Legacy hello enabled desktop actions")
        let current = Hello(name: "fixture", width: 1920, height: 1080, settings: .init(), canControl: true, desktopActionsV1: true)
        try check(Wire.readJSON(Hello.self, JSONEncoder().encode(current)).desktopActionsV1 == true, "Capability was lost")
        try check(MessageKind.sessionUnlockRequest.rawValue == 32 && MessageKind.sessionTermination.rawValue == 34
                  && MessageKind.desktopActionRequest.rawValue == 35 && MessageKind.desktopActionResult.rawValue == 36,
                  "Existing wire numbers changed")
    }

    run("Desktop action requests contain a bounded named action and a correlation ID") {
        for action in RemoteDesktopAction.allCases {
            let request = DesktopActionRequest(action: action)
            let message = try Wire.json(.desktopActionRequest, request)
            let decoded = try Wire.decodeBody(Data(try message.framed().dropFirst(4)))
            try check(decoded.kind == .desktopActionRequest && Wire.readJSON(DesktopActionRequest.self, decoded.payload) == request,
                      "Request action or identifier changed")
        }
        let id = UUID().uuidString
        for payload in ["{}", "{\"id\":\"invalid\",\"action\":\"nextSpace\"}",
                        "{\"id\":\"\(id)\",\"action\":\"runCommand\"}",
                        "{\"id\":\"\(id)\",\"action\":1}"] {
            try rejects("Accepted an invalid desktop operation") { _ = try Wire.readJSON(DesktopActionRequest.self, Data(payload.utf8)) }
        }
        try rejects("Accepted oversized desktop command") { _ = try Wire.readJSON(DesktopActionRequest.self, Data(count: 4097)) }
    }

    run("Desktop action replies retain request identity and never assert a desktop number") {
        let id = UUID()
        for error in [nil, "远端已锁屏，暂不能选择桌面"] as [String?] {
            let result = DesktopActionResult(id: id, error: error)
            let bytes = try Wire.json(.desktopActionResult, result).payload
            try check(Wire.readJSON(DesktopActionResult.self, bytes) == result, "Result correlation or rejection was lost")
            let fields = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            try check(Set(fields.keys).isSubset(of: ["id", "error"]), "Result invented current Space state")
        }
    }
}
