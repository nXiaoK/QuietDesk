import Foundation
import Network

/// A saved address with an explicit route through the application's Tailscale node.
public enum TailnetAddress {
    public static let prefix = "tailscale:"

    public static func host(in address: String) throws -> String? {
        guard address.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(address.dropFirst(prefix.count))
        guard let ip = IPv4Address(value), ip.debugDescription == value,
              ip.rawValue[0] == 100, (64...127).contains(ip.rawValue[1]) else {
            throw DeskError.invalid("Tailscale 地址需填写为 tailscale:100.x.y.z，请使用对端 QuietDesk 显示的 IPv4 地址")
        }
        return value
    }
}
