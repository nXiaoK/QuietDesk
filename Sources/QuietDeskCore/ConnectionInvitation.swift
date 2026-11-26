import Foundation
import Network

/// What a host hands to another Mac so that it can connect: where it listens and its pairing code, as one
/// token of text that survives a chat or a note. Whoever holds it can view and control the host, exactly
/// like the pairing code it contains.
public struct ConnectionInvitation: Equatable, Sendable {
    public static let prefix = "quietdesk://"
    /// Longer text is not an invitation, whatever it starts with.
    public static let maximumLength = 512

    /// A host name or an IP address, without brackets.
    public let address: String
    public let port: UInt16
    /// The pairing code in the form the host displays it.
    public let code: String

    public init(address: String, port: UInt16, key: PairingKey) throws {
        guard let address = Self.canonical(address), port > 0 else { throw DeskError.invalid("连接信息需要有效的地址和端口") }
        self.address = address; self.port = port; code = key.code
    }

    public var text: String {
        Self.prefix + (address.contains(":") ? "[\(address)]" : address) + ":\(port)#" + code
    }

    /// Reads pasted text; nil when it is not a complete invitation. Surrounding white space is ignored,
    /// anything else that does not belong is not.
    public init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maximumLength, text.lowercased().hasPrefix(Self.prefix) else { return nil }
        let parts = text.dropFirst(Self.prefix.count).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, let key = try? PairingKey(code: String(parts[1])) else { return nil }
        let endpoint = parts[0]
        let host: Substring, portText: Substring
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]"), endpoint[endpoint.index(after: close)...].hasPrefix(":") else { return nil }
            host = endpoint[endpoint.index(after: endpoint.startIndex)..<close]
            portText = endpoint[endpoint.index(close, offsetBy: 2)...]
            guard host.contains(":") else { return nil }
        } else {
            guard let colon = endpoint.lastIndex(of: ":") else { return nil }
            host = endpoint[..<colon]; portText = endpoint[endpoint.index(after: colon)...]
            guard !host.contains(":") else { return nil }
        }
        guard portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(portText), port > 0,
              let address = Self.canonical(String(host)) else { return nil }
        self.address = address; self.port = port; code = key.code
    }

    // An IP address in its usual form, or a host name of letters, digits, dots and hyphens.
    private static func canonical(_ address: String) -> String? {
        guard !address.isEmpty, address.utf8.count <= 253 else { return nil }
        if address.contains(":") {
            guard let ip = IPv6Address(address), !address.contains("%") else { return nil }
            return ip.debugDescription.lowercased()
        }
        if let ip = IPv4Address(address) { return ip.debugDescription }
        let labels = address.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { return nil }
        return address.lowercased()
    }

    /// Addresses of this Mac that another device can try, the one on the default route first. Loopback,
    /// link-local and multicast addresses are left out.
    public static func localAddresses() -> [String] {
        var seen = Set<String>()
        return RelayPeerLocalCandidates.gather(port: 1).map(\.address).filter { seen.insert($0).inserted }
    }
}
