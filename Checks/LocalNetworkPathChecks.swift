import Foundation
import Network
import QuietDeskCore

func runLocalNetworkPathChecks() {
    func interface(_ address: String, _ mask: String, type: NWInterface.InterfaceType = .wifi,
                   active: Bool = true, pointToPoint: Bool = false) -> LocalNetworkPath.InterfaceAddress {
        let netmask = IPv4Address(mask)?.rawValue ?? IPv6Address(mask)?.rawValue ?? Data()
        return .init(address: NWEndpoint.Host(address), netmask: netmask, type: type,
                     isActive: active, isPointToPoint: pointToPoint)
    }
    func matches(_ remote: String, _ local: String, _ interfaces: [LocalNetworkPath.InterfaceAddress]) -> Bool {
        LocalNetworkPath.isLocal(remote: NWEndpoint.Host(remote), local: NWEndpoint.Host(local), interfaces: interfaces)
    }

    run("LAN classification requires the resolved physical interface and its actual subnet") {
        let wifi = interface("192.168.8.2", "255.255.255.0")
        try check(matches("192.168.8.50", "192.168.8.2", [wifi]), "A directly attached IPv4 peer was not local")
        try check(!matches("192.168.9.50", "192.168.8.2", [wifi]), "A different private subnet was considered local")
        try check(!matches("8.8.8.8", "192.168.8.2", [wifi]), "An Internet address was considered local")
        try check(!matches("192.168.8.50", "192.168.8.3", [wifi]), "An unrelated local interface address was accepted")
        try check(!matches("peer.local", "192.168.8.2", [wifi]), "An unresolved hostname was considered local")
        try check(!matches("192.168.8.50", "192.168.8.2", []), "Missing interface evidence was considered local")
        try check(!matches("192.168.8.130", "192.168.8.2", [interface("192.168.8.2", "255.255.255.128")]),
                  "A non-byte-aligned subnet mask was ignored")
        let publicSubnet = interface("203.0.113.2", "255.255.255.0", type: .wiredEthernet)
        try check(matches("203.0.113.50", "203.0.113.2", [publicSubnet]), "A physical subnet was inferred only from private IP ranges")
    }

    run("LAN classification excludes inactive, tunnel, cellular and loopback interfaces") {
        for entry in [interface("10.1.0.2", "255.255.0.0", type: .other),
                      interface("10.1.0.2", "255.255.0.0", type: .cellular),
                      interface("10.1.0.2", "255.255.0.0", type: .loopback),
                      interface("10.1.0.2", "255.255.0.0", active: false),
                      interface("10.1.0.2", "255.255.0.0", pointToPoint: true)] {
            try check(!matches("10.1.0.30", "10.1.0.2", [entry]), "An inactive or non-physical interface was considered local")
        }
        try check(!matches("127.0.0.1", "127.0.0.1", [interface("127.0.0.1", "255.0.0.0")]),
                  "A relay's IPv4 loopback bridge was considered LAN")
        try check(!matches("::1", "::1", [interface("::1", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")]),
                  "A relay's IPv6 loopback bridge was considered LAN")
    }

    run("LAN classification normalizes mapped IPv4 and supports physical IPv6 subnets") {
        let wifi = interface("192.168.8.2", "255.255.255.0")
        try check(matches("::ffff:192.168.8.50", "::ffff:192.168.8.2", [wifi]), "Mapped IPv4 endpoints were not normalized")
        try check(!matches("::ffff:192.168.9.50", "192.168.8.2", [wifi]), "Mapped IPv4 escaped the subnet check")
        try check(!matches("::ffff:127.0.0.1", "192.168.8.2", [wifi]), "Mapped loopback was accepted")
        for prefix in ["fd12:3456:789a:1", "2001:db8:1234:1", "fe80:0:0:0"] {
            let local = prefix + "::2", remote = prefix + "::50"
            try check(matches(remote, local, [interface(local, "ffff:ffff:ffff:ffff::", type: .wiredEthernet)]),
                      "A directly attached IPv6 peer was not local")
        }
        let ipv6 = interface("fd12:3456:789a:1::2", "ffff:ffff:ffff:ffff::")
        try check(!matches("fd12:3456:789a:2::50", "fd12:3456:789a:1::2", [ipv6]), "A routed IPv6 subnet was considered local")
        try check(!matches("192.168.8.50", "fd12:3456:789a:1::2", [ipv6]), "Mismatched address families were accepted")
    }

    run("LAN classification rejects missing, invalid masks and non-unicast endpoints") {
        for mask in ["0.0.0.0", "255.0.255.0", "ffff:ffff:ffff:ffff::", "invalid"] {
            try check(!matches("192.168.8.50", "192.168.8.2", [interface("192.168.8.2", mask)]),
                      "An invalid interface mask was accepted")
        }
        for remote in ["0.0.0.0", "255.255.255.255", "224.0.0.1", "::", "ff02::1"] {
            let ipv6 = remote.contains(":")
            let local = ipv6 ? "fd12:3456:789a:1::2" : "192.168.8.2"
            try check(!matches(remote, local, [interface(local, ipv6 ? "ffff:ffff:ffff:ffff::" : "255.255.255.0")]),
                      "A non-unicast endpoint was considered local")
        }
    }
}
