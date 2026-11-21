import Darwin
import Foundation
import QuietDeskCore

func runLANWakeDiscoveryChecks() {
    run("MACAddress parses standard notations, normalizes uppercase colons and rejects multicast or broadcast") {
        let expected = [UInt8(0xA4), 0x83, 0xE7, 0x12, 0x9B, 0x0C]
        let forms = [
            "a4:83:e7:12:9b:0c",
            "  A4-83-E7-12-9B-0C \n",
            "a483.e712.9b0c",
            "A483E7129B0C"
        ]
        for input in forms {
            let parsed = try MACAddress(parsing: input)
            try check(parsed.bytes == expected && parsed.formatted == "A4:83:E7:12:9B:0C", "Unexpected normalization for \(input)")
        }
        for invalid in [
            "",
            "00:00:00:00:00:00",
            "FF:FF:FF:FF:FF:FF",
            "01:00:5E:00:00:01", // IPv4 multicast MAC (LSB of octet 0 == 1)
            "33:33:00:00:00:01", // IPv6 multicast MAC
            "A4:83-E7:12:9B:0C", // mixed separators
            "A4:83:E7:12:9B",
            "A4:83:E7:12:9B:0C:11",
            "A4:8:E7:12:9B:0C",
            "G4:83:E7:12:9B:0C"
        ] {
            try rejects("Invalid MAC accepted: \(invalid)") {
                _ = try MACAddress(parsing: invalid)
            }
        }
    }

    run("Wake-on-LAN magic packet builds exact 102-byte IEEE 802.3 frame") {
        let mac = try MACAddress(parsing: "18:65:90:AB:CD:EF")
        let packet = mac.magicPacket()
        try check(packet.count == 102, "Magic packet must be 102 bytes")
        try check(Array(packet.prefix(6)) == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], "Sync stream prefix mismatch")
        for index in 0..<16 {
            let start = 6 + index * 6
            let slice = Array(packet[start..<(start + 6)])
            try check(slice == mac.bytes, "MAC repetition \(index) mismatch")
        }
    }

    run("WakeOnLANSender prioritizes matching subnet directed broadcast and tolerates partial interface failure") {
        let mac = try MACAddress(parsing: "A4:83:E7:12:9B:0C")
        let config = try WakeOnLANConfiguration(macAddress: mac)
        let officeIf = WakeOnLANSender.InterfaceIPv4(
            address: WakeOnLANSender.parseIPv4HostOrder("10.10.4.20")!,
            netmask: WakeOnLANSender.parseIPv4HostOrder("255.255.255.0")!
        )
        let deskIf = WakeOnLANSender.InterfaceIPv4(
            address: WakeOnLANSender.parseIPv4HostOrder("192.168.50.5")!,
            netmask: WakeOnLANSender.parseIPv4HostOrder("255.255.255.0")!
        )
        let planned = WakeOnLANSender.plannedEndpoints(
            configuration: config,
            directHost: "192.168.50.88",
            interfaces: [officeIf, deskIf]
        )
        try check(
            planned.map(\.label) == ["192.168.50.255:9", "10.10.4.255:9", "255.255.255.255:9"],
            "Unexpected broadcast target order: \(planned.map(\.label))"
        )
        // Non-contiguous netmask is rejected cleanly.
        try check(WakeOnLANSender.subnetBroadcastIPv4(hostAddress: 0xC0A8_0105, netmask: 0xFF00_FF00) == nil,
                  "Accepted non-contiguous subnet mask")

        var attempted: [String] = []
        let delivered = try WakeOnLANSender.send(config, directHost: "192.168.50.88", interfaces: [officeIf, deskIf]) { data, ep in
            try check(data == mac.magicPacket(), "Corrupted magic packet bytes")
            attempted.append(ep.ipv4)
            if ep.ipv4 == "255.255.255.255" {
                throw DeskError.invalid("Simulated global broadcast block")
            }
        }
        try check(attempted.count == 3 && delivered.map(\.ipv4) == ["192.168.50.255", "10.10.4.255"],
                  "Partial broadcast delivery did not return delivered targets")

        let explicit = try WakeOnLANConfiguration(macAddress: mac, broadcastAddress: " 192.168.88.255 ", port: 7)
        try check(explicit.broadcastAddress == "192.168.88.255" && explicit.port == 7, "Explicit config normalization failed")
        try rejects("Zero port accepted") {
            _ = try WakeOnLANConfiguration(macAddress: mac, port: 0)
        }
        try rejects("Hostname broadcast accepted") {
            _ = try WakeOnLANConfiguration(macAddress: mac, broadcastAddress: "studio.local")
        }
    }

    if !CommandLine.arguments.contains("--skip-network") {
        run("WakeOnLANSender delivers a real 102-byte UDP magic packet over loopback socket") {
            let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            try check(receiver >= 0, "Could not create loopback UDP receiver")
            defer { close(receiver) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var bindAddr = sockaddr_in()
            bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_port = 0
            _ = inet_pton(AF_INET, "127.0.0.1", &bindAddr.sin_addr)
            let bound = withUnsafePointer(to: &bindAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(receiver, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try check(bound == 0, "Could not bind loopback UDP socket")

            var assigned = sockaddr_in()
            var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(receiver, sa, &assignedLen)
                }
            }
            try check(named == 0, "Could not query bound UDP port")
            let port = UInt16(bigEndian: assigned.sin_port)

            let mac = try MACAddress(parsing: "3C:22:FB:11:22:33")
            let config = try WakeOnLANConfiguration(macAddress: mac, broadcastAddress: "127.0.0.1", port: port)
            let endpoints = try WakeOnLANSender.send(config)
            try check(endpoints == [WakeOnLANSender.Endpoint(ipv4: "127.0.0.1", port: port)], "Unexpected loopback endpoint")

            var buffer = [UInt8](repeating: 0, count: 256)
            let receivedBytes = recv(receiver, &buffer, buffer.count, 0)
            try check(receivedBytes == 102 && Data(buffer.prefix(102)) == mac.magicPacket(),
                      "Loopback UDP socket did not receive intact 102-byte magic packet")
        }
    }

    run("BonjourDiscovery bounds UTF-8 service names without splitting characters and parses RFC 6763 TXT safely") {
        let longChinese = "书桌上的主力工作站-" + String(repeating: "苹果电脑", count: 10)
        let sanitized = BonjourDiscovery.sanitizedServiceName(" \n\t" + longChinese + "\r ")
        try check(sanitized.utf8.count <= BonjourDiscovery.maximumServiceNameUTF8Bytes && !sanitized.isEmpty,
                  "Service name exceeded 63 UTF-8 bytes")
        try check(!sanitized.contains("\n") && !sanitized.contains("\r"), "Control characters remained in service name")
        try check(BonjourDiscovery.sanitizedServiceName("  \n\t  ") == "QuietDesk Mac", "Empty service name fallback failed")

        let id = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
        let metadata = try BonjourDiscovery.TXTMetadata(version: 1, deviceID: id)
        var raw = metadata.rawTXTRecord()
        // Append an unknown forward-compatible TXT key.
        let extra = Array("extra=future".utf8)
        raw.append(UInt8(extra.count))
        raw.append(contentsOf: extra)
        let decoded = try BonjourDiscovery.TXTMetadata.parse(rawTXTRecord: raw)
        try check(decoded == metadata, "TXT round-trip lost version or deviceID")

        // Truncated length prefix and invalid version/UUID are rejected.
        try rejects("Truncated TXT accepted") {
            _ = try BonjourDiscovery.TXTMetadata.parse(rawTXTRecord: Data([5, 0x76, 0x3D]))
        }
        try rejects("Invalid version accepted") {
            _ = try BonjourDiscovery.TXTMetadata.parse(["v": "0"])
        }
        try rejects("Malformed UUID accepted") {
            _ = try BonjourDiscovery.TXTMetadata.parse(["v": "1", "id": "not-a-uuid"])
        }
        try rejects("Oversized TXT accepted") {
            _ = try BonjourDiscovery.TXTMetadata.parse(rawTXTRecord: Data(repeating: 0, count: 1_025))
        }
    }

    run("BonjourDiscovery ranks LAN IPv4 above Thunderbolt link-local, global IPv6 and mDNS hostnames") {
        try check(
            BonjourDiscovery.preferredEndpointHost(
                literals: ["127.0.0.1", "::1", "fe80::1", "fd12:3456::8", "169.254.12.34", "192.168.31.88"],
                hostname: "Studio.local."
            ) == "192.168.31.88",
            "Did not prefer RFC1918 LAN IPv4"
        )
        try check(
            BonjourDiscovery.preferredEndpointHost(
                literals: ["fe80::abcd", "169.254.99.4"],
                hostname: "Desk.local."
            ) == "169.254.99.4",
            "Did not accept Thunderbolt Bridge 169.254/16 over link-local IPv6"
        )
        try check(
            BonjourDiscovery.preferredEndpointHost(
                literals: ["127.0.0.1", "224.0.0.251", "ff02::fb", "0.0.0.0"],
                hostname: "Mac-Mini.local."
            ) == "mac-mini.local",
            "Did not fall back to normalized mDNS hostname when all literals were invalid"
        )
    }

    run("BonjourDiscovery matches saved records across DHCP IP changes by deviceID and preserves legacy JSON keys") {
        let deviceID = UUID(uuidString: "BBBB1111-2222-3333-4444-555566667777")!
        let mac = try MACAddress(parsing: "F0:18:98:AA:BB:CC")
        let wol = try WakeOnLANConfiguration(macAddress: mac, port: 9)
        let saved = ConnectionRecord(address: "192.168.1.10", port: 5908, name: "书桌 Mini", deviceID: deviceID, wakeOnLAN: wol)
        let other = ConnectionRecord(address: "192.168.1.50", port: 5908, name: "其他 Mac")

        let dhcpChangedHost = DiscoveredLANHost(serviceName: "书桌 Mini", host: "192.168.1.99", port: 5908, deviceID: deviceID)
        try check(BonjourDiscovery.matchingRecord(for: dhcpChangedHost, in: [other, saved])?.id == saved.id,
                  "Failed to match saved record by deviceID after DHCP IP change")

        let noIDHost = DiscoveredLANHost(serviceName: "其他 Mac", host: "192.168.1.50", port: 5908, deviceID: nil)
        try check(BonjourDiscovery.matchingRecord(for: noIDHost, in: [other, saved])?.id == other.id,
                  "Failed to fall back to address + port matching")

        let encodedSaved = try JSONEncoder().encode([saved, other])
        let roundTripped = try JSONDecoder().decode([ConnectionRecord].self, from: encodedSaved)
        try check(roundTripped == [saved, other], "ConnectionRecord with deviceID and wakeOnLAN did not round-trip")

        // Corrupt optional wakeOnLAN degrades gracefully without losing the saved record.
        let corruptJSON = """
        [{"id":"\(other.id.uuidString)","address":"10.0.0.5","port":5908,"name":"Mini","lastConnected":0,"wakeOnLAN":{"macAddress":"FF:FF:FF:FF:FF:FF"}}]
        """.data(using: .utf8)!
        let recovered = try JSONDecoder().decode([ConnectionRecord].self, from: corruptJSON)
        try check(recovered.count == 1 && recovered[0].id == other.id && recovered[0].wakeOnLAN == nil,
                  "Corrupt optional wakeOnLAN failed ConnectionRecord decoding")
    }
}
