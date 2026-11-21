import Darwin
import Foundation
import Network
import dnssd

public struct DiscoveredLANHost: Identifiable, Equatable, Sendable {
    public let serviceName: String
    public let host: String
    public let port: UInt16
    public let deviceID: UUID?

    public var id: String {
        if let deviceID {
            return "id:" + deviceID.uuidString.lowercased()
        }
        return "ep:\(serviceName.lowercased())|\(host.lowercased()):\(port)"
    }

    public var endpointLabel: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public init(serviceName: String, host: String, port: UInt16, deviceID: UUID?) {
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.deviceID = deviceID
    }
}

public enum BonjourDiscovery {
    public static let serviceType = "_quietdesk._tcp"
    public static let domain = "local."
    public static let protocolVersion = 1
    public static let maximumServiceNameUTF8Bytes = 63
    public static let maximumTXTRecordBytes = 1_024
    public static let maximumDiscoveredHosts = 64

    public struct TXTMetadata: Equatable, Sendable {
        public let version: Int
        public let deviceID: UUID?

        public init(version: Int = BonjourDiscovery.protocolVersion, deviceID: UUID?) throws {
            guard (1...99).contains(version) else {
                throw DeskError.invalid("局域网发现协议版本号无效")
            }
            self.version = version
            self.deviceID = deviceID
        }

        public func dictionary() -> [String: String] {
            var dict = ["v": String(version)]
            if let deviceID {
                dict["id"] = deviceID.uuidString.lowercased()
            }
            return dict
        }

        public func rawTXTRecord() -> Data {
            var data = Data()
            let entries: [(String, String)] = {
                var list = [("v", String(version))]
                if let deviceID {
                    list.append(("id", deviceID.uuidString.lowercased()))
                }
                return list
            }()
            for (key, value) in entries {
                let bytes = Array("\(key)=\(value)".utf8)
                guard bytes.count <= 255 else { continue }
                data.append(UInt8(bytes.count))
                data.append(contentsOf: bytes)
            }
            return data
        }

        public func nwTXTRecord() -> NWTXTRecord {
            NWTXTRecord(dictionary())
        }

        public static func parse(rawTXTRecord data: Data) throws -> TXTMetadata {
            guard data.count <= BonjourDiscovery.maximumTXTRecordBytes else {
                throw DeskError.invalid("局域网发现 TXT 记录超出长度上限")
            }
            var dict: [String: String] = [:]
            var reader = ByteReader(data)
            while reader.remaining > 0 {
                let entryLength: UInt8 = try reader.take()
                if entryLength == 0 { continue }
                let entryBytes = try reader.bytes(Int(entryLength))
                guard let entry = String(data: entryBytes, encoding: .utf8),
                      !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw DeskError.invalid("局域网发现 TXT 记录包含无效字符")
                }
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq]).lowercased()
                let value = String(entry[entry.index(after: eq)...])
                if !key.isEmpty, dict[key] == nil {
                    dict[key] = value
                }
            }
            return try parse(dict)
        }

        public static func parse(_ dictionary: [String: String]) throws -> TXTMetadata {
            let version: Int
            if let vText = dictionary["v"] {
                guard let parsed = Int(vText), (1...99).contains(parsed) else {
                    throw DeskError.invalid("局域网发现协议版本字段无效")
                }
                version = parsed
            } else {
                version = 1
            }

            let deviceID: UUID?
            if let idText = dictionary["id"], !idText.isEmpty {
                guard let parsedID = UUID(uuidString: idText) else {
                    throw DeskError.invalid("局域网发现设备标识格式无效")
                }
                deviceID = parsedID
            } else {
                deviceID = nil
            }
            return try TXTMetadata(version: version, deviceID: deviceID)
        }
    }

    /// Sanitizes and bounds a DNS-SD instance name within RFC 6763's 63-byte UTF-8 limit without splitting characters.
    public static func sanitizedServiceName(_ raw: String, fallback: String = "QuietDesk Mac") -> String {
        let singleLine = raw.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = singleLine
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let candidate = collapsed.isEmpty ? fallback : collapsed
        var result = ""
        var utf8Used = 0
        for character in candidate {
            let charBytes = String(character).utf8.count
            if utf8Used + charBytes > maximumServiceNameUTF8Bytes {
                break
            }
            result.append(character)
            utf8Used += charBytes
        }
        return result.isEmpty ? "QuietDesk" : result
    }

    public static func normalizedMDNSHostname(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty,
              host.utf8.count <= 253,
              !host.contains("/"),
              !host.contains(":"),
              !host.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return host.lowercased()
    }

    private static func literalAddressScore(_ candidate: String) -> (score: Int, normalized: String)? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("%"), !trimmed.contains("/") else { return nil }

        if !trimmed.contains(":") {
            var addr = in_addr()
            guard inet_pton(AF_INET, trimmed, &addr) == 1 else { return nil }
            let ip = UInt32(bigEndian: addr.s_addr)
            let b0 = UInt8((ip >> 24) & 0xFF)
            let b1 = UInt8((ip >> 16) & 0xFF)
            // Reject unspecified, loopback, multicast (224..239), and broadcast/reserved (240..255).
            guard ip != 0, b0 != 0, b0 != 127, b0 < 224 else { return nil }
            let normalized = WakeOnLANSender.formatIPv4HostOrder(ip)
            // RFC1918 LAN IPv4
            if b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168) {
                return (400, normalized)
            }
            // Carrier-grade / VPN overlay IPv4 (100.64.0.0/10) or routable unicast IPv4
            if b0 == 169 && b1 == 254 {
                // Thunderbolt Bridge / direct Ethernet cable link-local IPv4
                return (200, normalized)
            }
            return (300, normalized)
        } else {
            var addr6 = in6_addr()
            guard inet_pton(AF_INET6, trimmed, &addr6) == 1 else { return nil }
            let octets = withUnsafeBytes(of: &addr6) { Array($0) }
            guard octets.count == 16 else { return nil }
            let isAllZero = octets.allSatisfy { $0 == 0 }
            let isLoopback = octets.dropLast().allSatisfy({ $0 == 0 }) && octets.last == 1
            let isMulticast = octets[0] == 0xFF
            let isLinkLocal = octets[0] == 0xFE && (octets[1] & 0xC0) == 0x80
            guard !isAllZero, !isLoopback, !isMulticast, !isLinkLocal else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return (100, String(cString: buffer).lowercased())
        }
    }

    /// Selects the best connectible LAN host literal (preferring RFC1918 IPv4, then unicast IPv4, Thunderbolt 169.254/16,
    /// then non-link-local IPv6, and finally normalized `.local` hostname).
    public static func preferredEndpointHost(literals: [String], hostname: String? = nil) -> String? {
        var best: (score: Int, normalized: String)?
        for candidate in literals {
            guard let evaluated = literalAddressScore(candidate) else { continue }
            if best == nil || evaluated.score > best!.score {
                best = evaluated
            }
        }
        if let best {
            return best.normalized
        }
        return hostname.flatMap { normalizedMDNSHostname($0) }
    }

    /// Matches a discovered LAN host to a saved `ConnectionRecord`, prioritizing authenticated `deviceID`
    /// (which survives DHCP IP changes) before falling back to `address + port`.
    public static func matchingRecord(for host: DiscoveredLANHost, in records: [ConnectionRecord]) -> ConnectionRecord? {
        if let id = host.deviceID {
            if let directMatch = records.first(where: { $0.relay == nil && $0.deviceID == id }) {
                return directMatch
            }
            if let anyMatch = records.first(where: { $0.deviceID == id || $0.relay?.deviceID == id }) {
                return anyMatch
            }
        }
        return records.first { $0.relay == nil && $0.matches(address: host.host, port: host.port) }
    }

    public static func nwListenerService(name: String, deviceID: UUID?) -> NWListener.Service? {
        guard let txt = try? TXTMetadata(version: protocolVersion, deviceID: deviceID) else { return nil }
        return NWListener.Service(
            name: sanitizedServiceName(name),
            type: serviceType,
            domain: nil,
            txtRecord: txt.nwTXTRecord()
        )
    }
}

public final class BonjourLANScanner: @unchecked Sendable {
    private struct InstanceKey: Hashable {
        let name: String
        let regtype: String
        let domain: String
        let interfaceIndex: UInt32
    }

    private final class InstanceRecord {
        let key: InstanceKey
        var serviceName: String
        var port: UInt16?
        var deviceID: UUID?
        var hostname: String?
        var literals: [String] = []
        var resolveRef: DNSServiceRef?
        var resolveBoxPtr: UnsafeMutableRawPointer?
        var addrInfoRef: DNSServiceRef?
        var addrInfoBoxPtr: UnsafeMutableRawPointer?

        init(key: InstanceKey) {
            self.key = key
            self.serviceName = BonjourDiscovery.sanitizedServiceName(key.name)
        }
    }

    private final class BrowseBox {
        weak var session: ScanSession?
        init(session: ScanSession) { self.session = session }
    }

    private final class InstanceBox {
        weak var session: ScanSession?
        let key: InstanceKey
        init(session: ScanSession, key: InstanceKey) {
            self.session = session
            self.key = key
        }
    }

    private final class ScanSession {
        let excludedDeviceID: UUID?
        let onUpdate: @Sendable ([DiscoveredLANHost]) -> Void
        let onError: @Sendable (String) -> Void
        var mainRef: DNSServiceRef?
        var browseRef: DNSServiceRef?
        var browseBoxPtr: UnsafeMutableRawPointer?
        var instances: [InstanceKey: InstanceRecord] = [:]
        var stopped = false

        init(
            excludedDeviceID: UUID?,
            onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void,
            onError: @escaping @Sendable (String) -> Void
        ) {
            self.excludedDeviceID = excludedDeviceID
            self.onUpdate = onUpdate
            self.onError = onError
        }

        func cancelResolve(for record: InstanceRecord) {
            if let ref = record.resolveRef {
                DNSServiceRefDeallocate(ref)
                record.resolveRef = nil
            }
            if let ptr = record.resolveBoxPtr {
                Unmanaged<InstanceBox>.fromOpaque(ptr).release()
                record.resolveBoxPtr = nil
            }
        }

        func cancelAddrInfo(for record: InstanceRecord) {
            if let ref = record.addrInfoRef {
                DNSServiceRefDeallocate(ref)
                record.addrInfoRef = nil
            }
            if let ptr = record.addrInfoBoxPtr {
                Unmanaged<InstanceBox>.fromOpaque(ptr).release()
                record.addrInfoBoxPtr = nil
            }
        }

        func stopAll() {
            guard !stopped else { return }
            stopped = true
            for record in instances.values {
                cancelAddrInfo(for: record)
                cancelResolve(for: record)
            }
            instances.removeAll()
            if let ref = browseRef {
                DNSServiceRefDeallocate(ref)
                browseRef = nil
            }
            if let ptr = browseBoxPtr {
                Unmanaged<BrowseBox>.fromOpaque(ptr).release()
                browseBoxPtr = nil
            }
            if let ref = mainRef {
                DNSServiceRefDeallocate(ref)
                mainRef = nil
            }
        }

        func publishSnapshot() {
            guard !stopped else { return }
            var deduplicated: [String: DiscoveredLANHost] = [:]
            var orderedKeys: [String] = []
            for record in instances.values {
                guard let port = record.port, port > 0,
                      let host = BonjourDiscovery.preferredEndpointHost(literals: record.literals, hostname: record.hostname) else {
                    continue
                }
                if let excluded = excludedDeviceID, record.deviceID == excluded {
                    continue
                }
                let item = DiscoveredLANHost(
                    serviceName: record.serviceName,
                    host: host,
                    port: port,
                    deviceID: record.deviceID
                )
                let key = item.id
                if let existing = deduplicated[key] {
                    let existingHasIPv4 = !existing.host.contains(":") && WakeOnLANSender.parseIPv4HostOrder(existing.host) != nil
                    let newHasIPv4 = !item.host.contains(":") && WakeOnLANSender.parseIPv4HostOrder(item.host) != nil
                    if newHasIPv4 && !existingHasIPv4 {
                        deduplicated[key] = item
                    }
                } else {
                    deduplicated[key] = item
                    orderedKeys.append(key)
                }
            }
            let list = orderedKeys
                .compactMap { deduplicated[$0] }
                .sorted { lhs, rhs in
                    let cmp = lhs.serviceName.localizedStandardCompare(rhs.serviceName)
                    if cmp != .orderedSame { return cmp == .orderedAscending }
                    return lhs.endpointLabel < rhs.endpointLabel
                }
            onUpdate(Array(list.prefix(BonjourDiscovery.maximumDiscoveredHosts)))
        }
    }

    private let queue = DispatchQueue(label: "quietdesk.bonjour-scanner")
    private let excludedDeviceID: UUID?
    public var onUpdate: (@Sendable ([DiscoveredLANHost]) -> Void)?
    public var onError: (@Sendable (String) -> Void)?
    private var activeSession: ScanSession?

    public init(excludedDeviceID: UUID? = nil) {
        self.excludedDeviceID = excludedDeviceID
    }

    deinit {
        let session = activeSession
        activeSession = nil
        if let session {
            queue.async { session.stopAll() }
        }
    }

    public func start() {
        let updateHandler = onUpdate ?? { _ in }
        let errorHandler = onError ?? { _ in }
        let excluded = excludedDeviceID
        queue.async { [weak self] in
            guard let self else { return }
            self.activeSession?.stopAll()
            self.activeSession = nil

            let session = ScanSession(excludedDeviceID: excluded, onUpdate: updateHandler, onError: errorHandler)
            var mainRef: DNSServiceRef?
            let connErr = DNSServiceCreateConnection(&mainRef)
            guard connErr == kDNSServiceErr_NoError, let validMain = mainRef else {
                errorHandler("无法连接本机 Bonjour 发现服务（错误码 \(connErr)）")
                return
            }
            session.mainRef = validMain
            guard DNSServiceSetDispatchQueue(validMain, self.queue) == kDNSServiceErr_NoError else {
                DNSServiceRefDeallocate(validMain)
                session.mainRef = nil
                errorHandler("无法调度局域网发现队列")
                return
            }

            let box = BrowseBox(session: session)
            let boxPtr = Unmanaged.passRetained(box).toOpaque()
            var browseRef: DNSServiceRef? = validMain
            let browseErr = DNSServiceBrowse(
                &browseRef,
                DNSServiceFlags(kDNSServiceFlagsShareConnection),
                0,
                BonjourDiscovery.serviceType,
                BonjourDiscovery.domain,
                Self.browseCallback,
                boxPtr
            )
            guard browseErr == kDNSServiceErr_NoError, let validBrowse = browseRef else {
                Unmanaged<BrowseBox>.fromOpaque(boxPtr).release()
                DNSServiceRefDeallocate(validMain)
                session.mainRef = nil
                errorHandler("无法启动局域网设备扫描（错误码 \(browseErr)）")
                return
            }
            session.browseRef = validBrowse
            session.browseBoxPtr = boxPtr
            self.activeSession = session
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeSession?.stopAll()
            self.activeSession = nil
        }
    }

    private static let browseCallback: DNSServiceBrowseReply = { _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
        guard let context else { return }
        let box = Unmanaged<BrowseBox>.fromOpaque(context).takeUnretainedValue()
        guard let session = box.session, !session.stopped else { return }
        guard errorCode == kDNSServiceErr_NoError else {
            session.onError("局域网设备扫描中断（错误码 \(errorCode)）")
            return
        }
        guard let serviceName, let regtype, let replyDomain else { return }
        let key = InstanceKey(
            name: String(cString: serviceName),
            regtype: String(cString: regtype),
            domain: String(cString: replyDomain),
            interfaceIndex: interfaceIndex
        )
        let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
        if isAdd {
            guard session.instances[key] == nil,
                  session.instances.count < BonjourDiscovery.maximumDiscoveredHosts * 2,
                  let mainRef = session.mainRef else { return }
            let record = InstanceRecord(key: key)
            let resolveBox = InstanceBox(session: session, key: key)
            let resolvePtr = Unmanaged.passRetained(resolveBox).toOpaque()
            var resolveRef: DNSServiceRef? = mainRef
            let err = DNSServiceResolve(
                &resolveRef,
                DNSServiceFlags(kDNSServiceFlagsShareConnection),
                interfaceIndex,
                key.name,
                key.regtype,
                key.domain,
                BonjourLANScanner.resolveCallback,
                resolvePtr
            )
            if err == kDNSServiceErr_NoError, let validResolve = resolveRef {
                record.resolveRef = validResolve
                record.resolveBoxPtr = resolvePtr
                session.instances[key] = record
            } else {
                Unmanaged<InstanceBox>.fromOpaque(resolvePtr).release()
            }
        } else {
            if let removed = session.instances.removeValue(forKey: key) {
                session.cancelAddrInfo(for: removed)
                session.cancelResolve(for: removed)
                session.publishSnapshot()
            }
        }
    }

    private static let resolveCallback: DNSServiceResolveReply = { _, _, interfaceIndex, errorCode, _, hosttarget, port, txtLen, txtRecord, context in
        guard let context else { return }
        let box = Unmanaged<InstanceBox>.fromOpaque(context).takeUnretainedValue()
        guard let session = box.session, !session.stopped,
              let record = session.instances[box.key] else { return }
        defer { session.cancelResolve(for: record) }
        guard errorCode == kDNSServiceErr_NoError, let hosttarget else { return }

        let hostPort = UInt16(bigEndian: port)
        guard hostPort > 0 else { return }

        let txtData: Data
        if txtLen > 0, let txtRecord {
            txtData = Data(bytes: txtRecord, count: Int(txtLen))
        } else {
            txtData = Data()
        }
        guard let metadata = try? BonjourDiscovery.TXTMetadata.parse(rawTXTRecord: txtData) else { return }
        if let excluded = session.excludedDeviceID, metadata.deviceID == excluded {
            session.instances.removeValue(forKey: box.key)
            return
        }

        let targetHost = String(cString: hosttarget)
        record.port = hostPort
        record.deviceID = metadata.deviceID
        record.hostname = BonjourDiscovery.normalizedMDNSHostname(targetHost)
        session.publishSnapshot()

        session.cancelAddrInfo(for: record)
        guard let mainRef = session.mainRef else { return }
        let addrBox = InstanceBox(session: session, key: box.key)
        let addrPtr = Unmanaged.passRetained(addrBox).toOpaque()
        var addrRef: DNSServiceRef? = mainRef
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let err = DNSServiceGetAddrInfo(
            &addrRef,
            DNSServiceFlags(kDNSServiceFlagsShareConnection),
            interfaceIndex,
            protocols,
            targetHost,
            BonjourLANScanner.addrInfoCallback,
            addrPtr
        )
        if err == kDNSServiceErr_NoError, let validAddr = addrRef {
            record.addrInfoRef = validAddr
            record.addrInfoBoxPtr = addrPtr
        } else {
            Unmanaged<InstanceBox>.fromOpaque(addrPtr).release()
        }
    }

    private static let addrInfoCallback: DNSServiceGetAddrInfoReply = { _, flags, _, errorCode, _, address, _, context in
        guard let context else { return }
        let box = Unmanaged<InstanceBox>.fromOpaque(context).takeUnretainedValue()
        guard let session = box.session, !session.stopped,
              let record = session.instances[box.key] else { return }

        if errorCode == kDNSServiceErr_NoError, let address {
            let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
            if isAdd {
                if address.pointee.sa_family == sa_family_t(AF_INET) {
                    let literal = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr -> String? in
                        var sinAddr = ptr.pointee.sin_addr
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        guard inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(buf.count)) != nil else { return nil }
                        return String(cString: buf)
                    }
                    if let literal, !record.literals.contains(literal) {
                        record.literals.append(literal)
                    }
                } else if address.pointee.sa_family == sa_family_t(AF_INET6) {
                    let literal = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr -> String? in
                        var sin6Addr = ptr.pointee.sin6_addr
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        guard inet_ntop(AF_INET6, &sin6Addr, &buf, socklen_t(buf.count)) != nil else { return nil }
                        return String(cString: buf)
                    }
                    if let literal, !record.literals.contains(literal) {
                        record.literals.append(literal)
                    }
                }
                session.publishSnapshot()
            }
        }

        if (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) == 0 {
            // Keep IPv4/IPv6 if both arrive in separate batches until at least one IPv4 is resolved.
            let hasIPv4 = record.literals.contains { !$0.contains(":") }
            if hasIPv4 || errorCode != kDNSServiceErr_NoError {
                session.cancelAddrInfo(for: record)
            }
        }
    }
}
