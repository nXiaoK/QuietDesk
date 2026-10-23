import Foundation
import Network

/// Confirms a directly attached physical subnet from the connected path, never from latency or private address ranges.
public enum LocalNetworkPath {
    public struct InterfaceAddress {
        public let address: NWEndpoint.Host
        public let netmask: Data
        public let type: NWInterface.InterfaceType
        public let isActive: Bool
        public let isPointToPoint: Bool

        public init(address: NWEndpoint.Host, netmask: Data, type: NWInterface.InterfaceType,
                    isActive: Bool = true, isPointToPoint: Bool = false) {
            self.address = address; self.netmask = netmask; self.type = type
            self.isActive = isActive; self.isPointToPoint = isPointToPoint
        }
    }

    public static func isLocal(remote: NWEndpoint.Host, local: NWEndpoint.Host, interfaces: [InterfaceAddress]) -> Bool {
        guard let remote = unicastBytes(remote), let local = unicastBytes(local), remote.count == local.count else { return false }
        return interfaces.contains { entry in
            guard entry.isActive, !entry.isPointToPoint, entry.type == .wifi || entry.type == .wiredEthernet,
                  let address = unicastBytes(entry.address), address == local, entry.netmask.count == remote.count else { return false }
            // A missing/default or non-contiguous mask cannot establish a directly attached subnet.
            var sawZero = false, sawOne = false
            for byte in entry.netmask {
                for bit in (0..<8).reversed() {
                    if byte & (1 << bit) == 0 { sawZero = true }
                    else { if sawZero { return false }; sawOne = true }
                }
            }
            guard sawOne else { return false }
            return zip(zip(remote, local), entry.netmask).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
        }
    }

    static func classification(_ path: NWPath?) -> Bool? {
        guard let path, path.status == .satisfied else { return nil }
        guard path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
              !path.usesInterfaceType(.loopback), !path.usesInterfaceType(.other), !path.usesInterfaceType(.cellular) else { return false }
        guard case .hostPort(let remote, _) = path.remoteEndpoint,
              case .hostPort(let local, _) = path.localEndpoint else { return nil }
        if case .name = remote { return nil }
        if case .name = local { return nil }
        let physical = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
        guard !physical.isEmpty else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var addresses: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee, flags = Int32(entry.ifa_flags)
            guard let name = entry.ifa_name, let interface = physical.first(where: { $0.name == String(cString: name) }),
                  flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  address.pointee.sa_family == mask.pointee.sa_family else { continue }
            let host: NWEndpoint.Host
            let netmask: Data
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
                    withUnsafeBytes(of: value.pointee.sin_addr) { Data($0) }
                }
                guard let ip = IPv4Address(bytes) else { continue }
                host = .ipv4(ip)
                netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
                    withUnsafeBytes(of: value.pointee.sin_addr) { Data($0) }
                }
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                    withUnsafeBytes(of: value.pointee.sin6_addr) { Data($0) }
                }
                guard let ip = IPv6Address(bytes) else { continue }
                host = .ipv6(ip)
                netmask = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                    withUnsafeBytes(of: value.pointee.sin6_addr) { Data($0) }
                }
            default: continue
            }
            addresses.append(InterfaceAddress(address: host, netmask: netmask, type: interface.type,
                isActive: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0, isPointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        guard let localBytes = unicastBytes(local),
              addresses.contains(where: { unicastBytes($0.address) == localBytes }) else { return nil }
        return isLocal(remote: remote, local: local, interfaces: addresses)
    }

    private static func unicastBytes(_ host: NWEndpoint.Host) -> Data? {
        switch host {
        case .ipv4(let address):
            guard address != .any, address != .broadcast, !address.isLoopback, !address.isMulticast else { return nil }
            return address.rawValue
        case .ipv6(let address):
            if address.isIPv4Mapped, let mapped = address.asIPv4 { return unicastBytes(.ipv4(mapped)) }
            guard !address.isAny, !address.isLoopback, !address.isMulticast else { return nil }
            return address.rawValue
        case .name: return nil
        @unknown default: return nil
        }
    }
}

// One instance per NWConnection: temporary loss of path evidence cannot turn a known LAN failure
// into an ordinary congestion reduction. A new connection never inherits another one's classification.
final class LocalNetworkStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var known: Bool?

    func read(_ path: NWPath?) -> Bool? {
        lock.withLock {
            if let measured = LocalNetworkPath.classification(path) { known = measured }
            return known
        }
    }
}
