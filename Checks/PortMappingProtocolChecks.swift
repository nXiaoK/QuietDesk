import Foundation
import QuietDeskCore

func runPortMappingProtocolChecks() {
    run("Port mapping authorize carries optional device identity while preserving legacy wire compatibility") {
        enum LegacyControl: Codable, Equatable {
            case authorize(PortMappingTarget)
        }
        let target = try PortMappingTarget(host: "127.0.0.1", port: 3000)
        let deviceID = UUID()

        let legacyPayload = try JSONEncoder().encode(LegacyControl.authorize(target))
        let decodedFromLegacy = try PortMappingControl.read(Message(.mappingControl, legacyPayload))
        try check(decodedFromLegacy == .authorize(target, deviceID: nil),
                  "Legacy authorize message failed to decode with nil deviceID")

        let modernNil = try Wire.json(.mappingControl, PortMappingControl.authorize(target))
        try check(try JSONDecoder().decode(LegacyControl.self, from: modernNil.payload) == .authorize(target),
                  "Modern nil-deviceID authorize broke legacy decoder")
        let nilObject = try JSONSerialization.jsonObject(with: modernNil.payload) as? [String: Any]
        let nilAuthorize = nilObject?["authorize"] as? [String: Any]
        try check(nilAuthorize?["deviceID"] == nil, "Nil deviceID should be omitted on the wire")

        let modernWithDevice = try Wire.json(.mappingControl, PortMappingControl.authorize(target, deviceID: deviceID))
        let decodedModern = try PortMappingControl.read(modernWithDevice)
        try check(decodedModern == .authorize(target, deviceID: deviceID),
                  "Modern authorize lost deviceID")
        try check(try JSONDecoder().decode(LegacyControl.self, from: modernWithDevice.payload) == .authorize(target),
                  "Older host failed to ignore optional deviceID in authorize")

        let badDeviceID = Data(#"{"authorize":{"_0":{"host":"127.0.0.1","port":3000},"deviceID":"not-a-uuid"}}"#.utf8)
        try rejects("Accepted malformed deviceID in mapping authorize") {
            _ = try PortMappingControl.read(Message(.mappingControl, badDeviceID))
        }
        let publicTarget = Data(#"{"authorize":{"_0":{"host":"8.8.8.8","port":443},"deviceID":"\#(deviceID.uuidString)"}}"#.utf8)
        try rejects("Accepted public IP mapping target when deviceID is present") {
            _ = try PortMappingControl.read(Message(.mappingControl, publicTarget))
        }
    }
}
