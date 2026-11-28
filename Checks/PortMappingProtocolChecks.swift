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

    run("Port mapping groups LAN, Tailscale and two relay nodes by authenticated machine ID") {
        let hostID = UUID(), relayID = UUID()
        let lan = ConnectionRecord(address: "192.168.1.50", port: 5908, name: "Studio",
                                   lastConnected: Date(timeIntervalSince1970: 1), deviceID: hostID)
        var tailnet = ConnectionRecord(address: "tailscale:100.88.0.2", port: 5908, name: "100.88.0.2",
                                       lastConnected: Date(timeIntervalSince1970: 2), deviceID: hostID)
        tailnet.customName = "Studio 原名称"
        var firstRelay = ConnectionRecord(address: "", port: 5908, name: "relay-1.example",
                                           lastConnected: Date(timeIntervalSince1970: 3),
                                           relay: try mappingRelay("relay-1.example:7443", deviceID: relayID), deviceID: hostID)
        firstRelay.customName = "工作室 Mac"
        let secondRelay = ConnectionRecord(address: "", port: 5908, name: "tls://relay-2.example:443",
                                            lastConnected: Date(timeIntervalSince1970: 4),
                                            relay: try mappingRelay("relay-2.example", deviceID: relayID), deviceID: hostID)
        let groups = PortMappingMachineResolver.group(records: [firstRelay, lan, secondRelay, tailnet])
        try check(groups.count == 1, "Known host was split across different transports")
        guard let group = groups.first else { throw CheckFailure("Missing authenticated machine group") }
        try check(group.id == "device:" + hostID.uuidString.lowercased() &&
                  group.hostDeviceID == hostID && group.relayDeviceID == relayID, "Machine identity did not prefer authenticated UUID")
        try check(group.title == "工作室 Mac", "Most recent custom name did not win")
        try check(group.routes.map(\.id) == [secondRelay.id, firstRelay.id, tailnet.id, lan.id] &&
                  group.primaryRecord == secondRelay && group.contains(recordID: lan.id) &&
                  group.recordIDs == [lan.id, tailnet.id, firstRelay.id, secondRelay.id], "Route membership or ordering changed")
        try check(RemoteMachineGroup.routeShortLabel(for: tailnet) == "Tailscale · 100.88.0.2:5908" &&
                  RemoteMachineGroup.routeKindBadge(for: firstRelay) == "自托管中继" &&
                  RemoteMachineGroup.routeShortLabel(for: firstRelay) == "中继 · relay-1.example:7443",
                  "Route labels did not identify their actual endpoints")
    }

    run("Port mapping groups unconnected routes with an identical pairing digest") {
        let digest = Data(repeating: 0xab, count: 32)
        let first = ConnectionRecord(address: "fd12::1", port: 5908, name: "fd12::1", lastConnected: Date(timeIntervalSince1970: 1))
        let second = ConnectionRecord(address: "tailscale:100.88.0.2", port: 5908, name: "My Draft", lastConnected: Date(timeIntervalSince1970: 2))
        let groups = PortMappingMachineResolver.group(records: [first, second], pairingIdentities: [first.id: digest, second.id: digest])
        try check(groups.count == 1, "Equal draft digest failed to group the route aliases")
        guard let group = groups.first else { throw CheckFailure("Missing draft machine group") }
        try check(group.hostDeviceID == nil && group.id.hasPrefix("key:") && group.title == "My Draft" &&
                  group.routes.map(\.id) == [second.id, first.id], "Draft group identity, name or ordering changed")
        try check(RemoteMachineGroup.routeShortLabel(for: first) == "直连 · [fd12::1]:5908", "IPv6 endpoint lost brackets")
        let empty = PortMappingMachineResolver.group(records: [first, second], pairingIdentities: [first.id: Data(), second.id: Data()])
        try check(empty.count == 2, "Empty digest became shared identity evidence")
    }

    run("Port mapping keeps distinct authenticated UUIDs separate even with relay and pairing draft bridges") {
        let relayID = UUID(), digest = Data(repeating: 0xbc, count: 32)
        let relay = try mappingRelay("relay.example:7443", deviceID: relayID)
        let firstID = UUID(), secondID = UUID()
        let first = ConnectionRecord(address: "", port: 5908, name: "First", relay: relay, deviceID: firstID)
        let second = ConnectionRecord(address: "", port: 5908, name: "Second", relay: relay, deviceID: secondID)
        let draft = ConnectionRecord(address: "tailscale:100.88.0.2", port: 5908, name: "Draft")
        let relayDraft = ConnectionRecord(address: "", port: 5908, name: "Unknown relay key", relay: relay)
        let digests = [first.id: digest, second.id: digest, draft.id: digest]
        let groups = PortMappingMachineResolver.group(records: [first, draft, relayDraft, second], pairingIdentities: digests)
        try check(groups.count == 4 && Set(groups.map(\.id)).count == 4, "A draft joined or arbitrarily inherited a conflicting known host")
        try check(groups.allSatisfy { $0.routes.count == 1 } &&
                  Set(groups.compactMap(\.hostDeviceID)) == [firstID, secondID],
                  "Authenticated records were incorrectly attached by weaker evidence")
        let reordered = PortMappingMachineResolver.group(records: [relayDraft, second, draft, first], pairingIdentities: digests)
        try check(Set(reordered.map(\.id)) == Set(groups.map(\.id)), "Ambiguous record group IDs depend on input order")
    }

    run("Port mapping uses relay identity only when explicit pairing digests do not conflict") {
        let relay = try mappingRelay("relay.example:7443", deviceID: UUID())
        let first = ConnectionRecord(address: "", port: 5908, name: "First", relay: relay)
        let second = ConnectionRecord(address: "", port: 5908, name: "Second", relay: relay)
        let unknown = ConnectionRecord(address: "", port: 5908, name: "Unknown", relay: relay)
        let firstDigest = Data(repeating: 0xda, count: 32), secondDigest = Data(repeating: 0xdb, count: 32)
        let shared = PortMappingMachineResolver.group(records: [first, second, unknown], pairingIdentities: [first.id: firstDigest])
        try check(shared.count == 1 && shared.first?.recordIDs == [first.id, second.id, unknown.id] &&
                  shared.first?.id == "relay:" + relay.deviceID.uuidString.lowercased(), "Compatible relay aliases failed to group")
        let conflicting = PortMappingMachineResolver.group(records: [first, second, unknown],
            pairingIdentities: [first.id: firstDigest, second.id: secondDigest])
        try check(conflicting.count == 3 && Set(conflicting.map(\.id)).count == 3 &&
                  conflicting.allSatisfy { $0.routes.count == 1 }, "Missing relay digest bridged incompatible keys")
    }

    run("Port mapping orders active, preferred and eligible direct, Tailscale and relay routes") {
        let hostID = UUID(), relayID = UUID()
        let direct = ConnectionRecord(address: "192.168.1.50", port: 5908, name: "Studio",
                                      lastConnected: Date(timeIntervalSince1970: 1), deviceID: hostID)
        let auto = ConnectionRecord(address: "192.168.1.51", port: 5908, name: "Studio",
                                    lastConnected: Date(timeIntervalSince1970: 2),
                                    relay: try mappingRelay("relay-1.example", deviceID: relayID, strategy: .automatic), deviceID: hostID)
        let tailnet = ConnectionRecord(address: "tailscale:100.88.0.2", port: 5908, name: "Studio",
                                       lastConnected: Date(timeIntervalSince1970: 3), deviceID: hostID)
        let relay = ConnectionRecord(address: "", port: 5908, name: "Studio",
                                     lastConnected: Date(timeIntervalSince1970: 4),
                                     relay: try mappingRelay("relay-2.example", deviceID: relayID), deviceID: hostID)
        guard let group = PortMappingMachineResolver.group(records: [relay, tailnet, auto, direct]).first else {
            throw CheckFailure("Missing candidates' machine group")
        }
        func ordered(preferred: UUID? = nil, active: Set<UUID> = [], tailnetRunning: Bool = true, relayEnabled: Bool = true) -> [UUID] {
            PortMappingMachineResolver.orderedCandidateRecords(for: group, preferredRecordID: preferred,
                activeConnectedRecordIDs: active, tailnetRunning: tailnetRunning, relayEnabled: relayEnabled).map(\.id)
        }
        try check(ordered() == [auto.id, direct.id, tailnet.id, relay.id], "Connection choices ignored transport ordering")
        try check(ordered(preferred: tailnet.id, active: [relay.id]) == [relay.id, tailnet.id, auto.id, direct.id],
                  "An active or preferred route lost priority")
        try check(ordered(tailnetRunning: false) == [auto.id, direct.id, relay.id, tailnet.id],
                  "An inactive Tailscale route shadowed an enabled relay")
        try check(ordered(preferred: relay.id, relayEnabled: false) == [auto.id, direct.id, tailnet.id],
                  "Disabled relays remained candidates or took down a usable hybrid direct route")
        try check(RemoteMachineGroup.routeShortLabel(for: auto) == "直连优先+中继 · 192.168.1.51:5908" &&
                  RemoteMachineGroup.routeKindBadge(for: auto) == "直连+中继", "Hybrid route label lost its direct endpoint")
    }
}

private func mappingRelay(_ address: String, deviceID: UUID,
                          strategy: RelayConnectionStrategy = .relay) throws -> RelayConnectionInfo {
    try RelayConnectionInfo(endpoint: RelayEndpoint(address: address), deviceID: deviceID, strategy: strategy)
}
