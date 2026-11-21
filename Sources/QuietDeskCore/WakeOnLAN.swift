import Darwin
import Foundation

public struct MACAddress: Codable, Equatable, Hashable, Sendable {
    public static let octetCount = 6
    public static let magicPacketRepetitions = 16
    public static let magicPacketByteCount = 6 + octetCount * magicPacketRepetitions

    public let bytes: [UInt8]

    public var formatted: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.octetCount else {
            throw DeskError.invalid("MAC 地址必须包含 6 字节（12 位十六进制字符）")
        }
        if bytes.allSatisfy({ $0 == 0 }) {
            throw DeskError.invalid("MAC 地址不能全为 0")
        }
        if bytes.allSatisfy({ $0 == 0xFF }) {
            throw DeskError.invalid("MAC 地址不能为全 FF 广播地址")
        }
        if bytes[0] & 0x01 != 0 {
            throw DeskError.invalid("MAC 地址不能为组播地址（首字节最低位需为 0）")
        }
        self.bytes = bytes
    }

    public init(parsing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DeskError.invalid("请填写目标网卡的物理 MAC 地址（例如 AA:BB:CC:DD:EE:FF）")
        }
        let hexPairs: [Substring]
        if trimmed.contains(":") {
            guard !trimmed.contains("-"), !trimmed.contains(".") else {
                throw DeskError.invalid("MAC 地址分隔符格式不统一，请使用冒号或横线分隔")
            }
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }) else {
                throw DeskError.invalid("MAC 地址应为 6 组两位十六进制字符（如 AA:BB:CC:DD:EE:FF）")
            }
            hexPairs = parts
        } else if trimmed.contains("-") {
            guard !trimmed.contains(".") else {
                throw DeskError.invalid("MAC 地址分隔符格式不统一，请使用冒号或横线分隔")
            }
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }) else {
                throw DeskError.invalid("MAC 地址应为 6 组两位十六进制字符（如 AA-BB-CC-DD-EE-FF）")
            }
            hexPairs = parts
        } else if trimmed.contains(".") {
            let groups = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 3, groups.allSatisfy({ $0.count == 4 }) else {
                throw DeskError.invalid("点分 MAC 地址应为 3 组四位十六进制字符（如 AABB.CCDD.EEFF）")
            }
            var pairs: [Substring] = []
            for group in groups {
                let mid = group.index(group.startIndex, offsetBy: 2)
                pairs.append(group[group.startIndex..<mid])
                pairs.append(group[mid..<group.endIndex])
            }
            hexPairs = pairs
        } else {
            guard trimmed.count == 12 else {
                throw DeskError.invalid("MAC 地址应为 12 位十六进制字符（如 AA:BB:CC:DD:EE:FF）")
            }
            var pairs: [Substring] = []
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex {
                let next = trimmed.index(cursor, offsetBy: 2)
                pairs.append(trimmed[cursor..<next])
                cursor = next
            }
            hexPairs = pairs
        }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(Self.octetCount)
        for pair in hexPairs {
            guard pair.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let octet = UInt8(pair, radix: 16) else {
                throw DeskError.invalid("MAC 地址包含无效的十六进制字符")
            }
            parsed.append(octet)
        }
        try self.init(bytes: parsed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(parsing: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }

    /// IEEE 802.3 Wake-on-LAN Magic Packet: 6 bytes of 0xFF followed by 16 repetitions of the 6-byte MAC address.
    public func magicPacket() -> Data {
        var data = Data(capacity: Self.magicPacketByteCount)
        data.append(contentsOf: repeatElement(UInt8(0xFF), count: 6))
        for _ in 0..<Self.magicPacketRepetitions {
            data.append(contentsOf: bytes)
        }
        return data
    }
}

public struct WakeOnLANConfiguration: Codable, Equatable, Sendable {
    public static let defaultPort: UInt16 = 9
    public static let globalBroadcastAddress = "255.255.255.255"

    public var macAddress: MACAddress
    /// Optional explicit IPv4 broadcast or relay target address; nil uses automatic LAN interface broadcasts + 255.255.255.255.
    public var broadcastAddress: String?
    public var port: UInt16

    public init(macAddress: MACAddress, broadcastAddress: String? = nil, port: UInt16 = Self.defaultPort) throws {
        guard port > 0 else {
            throw DeskError.invalid("网络唤醒 UDP 端口需为 1 到 65535 的整数")
        }
        let normalizedBroadcast: String?
        if let rawBroadcast = broadcastAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBroadcast.isEmpty {
            guard let ipv4 = WakeOnLANSender.parseIPv4HostOrder(rawBroadcast), ipv4 != 0 else {
                throw DeskError.invalid("唤醒广播地址需为有效的 IPv4 字面量（如 192.168.1.255 或留空自动选择）")
            }
            normalizedBroadcast = WakeOnLANSender.formatIPv4HostOrder(ipv4)
        } else {
            normalizedBroadcast = nil
        }
        self.macAddress = macAddress
        self.broadcastAddress = normalizedBroadcast
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mac = try values.decode(MACAddress.self, forKey: .macAddress)
        let broadcast = try values.decodeIfPresent(String.self, forKey: .broadcastAddress)
        let port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
        try self.init(macAddress: mac, broadcastAddress: broadcast, port: port)
    }
}

public enum WakeOnLANSender {
    public struct Endpoint: Equatable, Hashable, Sendable {
        public let ipv4: String
        public let port: UInt16

        public init(ipv4: String, port: UInt16) {
            self.ipv4 = ipv4
            self.port = port
        }

        public var label: String { "\(ipv4):\(port)" }
    }

    public struct InterfaceIPv4: Equatable, Sendable {
        public let address: UInt32
        public let netmask: UInt32
        public let broadcast: UInt32?

        public init(address: UInt32, netmask: UInt32, broadcast: UInt32? = nil) {
            self.address = address
            self.netmask = netmask
            self.broadcast = broadcast
        }
    }

    public static func parseIPv4HostOrder(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/") else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, trimmed, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    public static func formatIPv4HostOrder(_ hostOrder: UInt32) -> String {
        var addr = in_addr(s_addr: hostOrder.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else {
            return WakeOnLANConfiguration.globalBroadcastAddress
        }
        return String(cString: buffer)
    }

    public static func subnetBroadcastIPv4(hostAddress: UInt32, netmask: UInt32) -> UInt32? {
        guard hostAddress != 0, netmask != 0, netmask != 0xFFFF_FFFF else { return nil }
        // Ensure contiguous IPv4 subnet mask.
        let inverted = ~netmask
        guard inverted & (inverted &+ 1) == 0 else { return nil }
        let broadcast = (hostAddress & netmask) | inverted
        guard broadcast != 0 else { return nil }
        return broadcast
    }

    public static func activeBroadcastInterfaces() -> [InterfaceIPv4] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let head = pointer else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceIPv4] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) != 0,
                  let addrPtr = current.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = current.pointee.ifa_netmask,
                  maskPtr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let address = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let explicitBroadcast: UInt32? = current.pointee.ifa_dstaddr.flatMap { dstPtr in
                guard dstPtr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                let raw = dstPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                return raw == 0 ? nil : raw
            }
            guard address != 0, (address >> 24) != 127 else { continue }
            result.append(InterfaceIPv4(address: address, netmask: netmask, broadcast: explicitBroadcast))
        }
        return result
    }

    public static func plannedEndpoints(
        configuration: WakeOnLANConfiguration,
        directHost: String? = nil,
        interfaces: [InterfaceIPv4]
    ) -> [Endpoint] {
        if let explicit = configuration.broadcastAddress {
            return [Endpoint(ipv4: explicit, port: configuration.port)]
        }

        var orderedAddresses: [String] = []
        var seen = Set<String>()
        func appendAddress(_ ipv4: String) {
            if seen.insert(ipv4).inserted {
                orderedAddresses.append(ipv4)
            }
        }

        let targetHostOrder = directHost.flatMap { parseIPv4HostOrder($0) }
        if let targetIP = targetHostOrder, (targetIP >> 24) != 127 {
            for iface in interfaces where iface.netmask != 0 && (iface.address & iface.netmask) == (targetIP & iface.netmask) {
                if let directed = iface.broadcast ?? subnetBroadcastIPv4(hostAddress: iface.address, netmask: iface.netmask) {
                    appendAddress(formatIPv4HostOrder(directed))
                }
            }
        }

        for iface in interfaces {
            if let directed = iface.broadcast ?? subnetBroadcastIPv4(hostAddress: iface.address, netmask: iface.netmask) {
                appendAddress(formatIPv4HostOrder(directed))
            }
        }

        appendAddress(WakeOnLANConfiguration.globalBroadcastAddress)
        return orderedAddresses.map { Endpoint(ipv4: $0, port: configuration.port) }
    }

    @discardableResult
    public static func send(
        _ configuration: WakeOnLANConfiguration,
        directHost: String? = nil,
        interfaces: [InterfaceIPv4]? = nil,
        transport: ((Data, Endpoint) throws -> Void)? = nil
    ) throws -> [Endpoint] {
        let packet = configuration.macAddress.magicPacket()
        let activeInterfaces = interfaces ?? activeBroadcastInterfaces()
        let targets = plannedEndpoints(configuration: configuration, directHost: directHost, interfaces: activeInterfaces)
        guard !targets.isEmpty else {
            throw DeskError.invalid("没有可用的局域网唤醒广播目标地址")
        }

        if let transport {
            var delivered: [Endpoint] = []
            var firstError: Error?
            for endpoint in targets {
                do {
                    try transport(packet, endpoint)
                    delivered.append(endpoint)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if delivered.isEmpty {
                throw firstError ?? DeskError.invalid("无法发送网络唤醒数据包")
            }
            return delivered
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw DeskError.system("无法创建网络唤醒 UDP 套接字", errno)
        }
        defer { close(fd) }

        var broadcastEnabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DeskError.system("无法启用 UDP 广播选项", errno)
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var delivered: [Endpoint] = []
        var firstErrno: Int32 = 0
        for endpoint in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = endpoint.port.bigEndian
            guard inet_pton(AF_INET, endpoint.ipv4, &addr.sin_addr) == 1 else { continue }

            let sent = packet.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(fd, base, rawBuffer.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent == packet.count {
                delivered.append(endpoint)
            } else if firstErrno == 0 {
                firstErrno = errno
            }
        }

        guard !delivered.isEmpty else {
            throw DeskError.system("无法向局域网发送唤醒魔术包", firstErrno == 0 ? EHOSTUNREACH : firstErrno)
        }
        return delivered
    }
}
