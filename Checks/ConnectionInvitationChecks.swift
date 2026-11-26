import Foundation
import QuietDeskCore

func runConnectionInvitationChecks() {
    run("A connection invitation carries address, port and pairing code in one token and reads back only when complete") {
        let key = try PairingKey.generate()
        let invitation = try ConnectionInvitation(address: "192.168.1.10", port: 5908, key: key)
        try check(invitation.text == "quietdesk://192.168.1.10:5908#" + key.code && !invitation.text.contains(" "),
                  "The invitation is not one token: \(invitation.text.prefix(40))")
        try check(ConnectionInvitation(text: invitation.text) == invitation, "The invitation did not read back")
        // Pasted from a chat: line breaks around it, another letter case, the code without its hyphens.
        let pasted = "\n  QuietDesk://192.168.1.10:5908#" + key.code.replacingOccurrences(of: "-", with: "").lowercased() + " \n"
        try check(ConnectionInvitation(text: pasted) == invitation, "A pasted invitation with white space or another case was not read")
        // Host names and IPv6 addresses.
        let named = try ConnectionInvitation(address: "Studio.local", port: 6000, key: key)
        try check(named.address == "studio.local" && ConnectionInvitation(text: named.text) == named, "A host name did not round-trip")
        let v6 = try ConnectionInvitation(address: "2001:DB8::5", port: 5908, key: key)
        try check(v6.text.hasPrefix("quietdesk://[2001:db8::5]:5908#") && ConnectionInvitation(text: v6.text) == v6,
                  "An IPv6 address did not round-trip: \(v6.text.prefix(40))")
        // Anything incomplete or extra is not an invitation, so ordinary input in the same field stays as typed.
        let code = key.code
        for text in ["192.168.1.10", "192.168.1.10:5908", code, "quietdesk://192.168.1.10:5908", "quietdesk://192.168.1.10#" + code,
                     "quietdesk://192.168.1.10:0#" + code, "quietdesk://192.168.1.10:70000#" + code, "quietdesk://192.168.1.10:59a8#" + code,
                     "quietdesk://:5908#" + code, "quietdesk://exa mple:5908#" + code, "quietdesk://example.com/path:5908#" + code,
                     "quietdesk://-bad.example:5908#" + code, "quietdesk://2001:db8::5:5908#" + code, "quietdesk://[fe80::1%en0]:5908#" + code,
                     "quietdesk://[192.168.1.10]:5908#" + code, "quietdesk://192.168.1.10:5908#" + String(code.dropLast()),
                     "quietdesk://192.168.1.10:5908#" + code + "#" + code, "see quietdesk://192.168.1.10:5908#" + code,
                     "quietdesk://192.168.1.10:5908#" + code + String(repeating: " x", count: 300)] {
            try check(ConnectionInvitation(text: text) == nil, "Text that is not a complete invitation was read as one: \(text.prefix(48))")
        }
        for address in ["", "a b", "example.com/x", "fe80::1%en0", String(repeating: "a", count: 254)] {
            try rejects("An unusable address made an invitation: \(address.prefix(20))") {
                _ = try ConnectionInvitation(address: address, port: 5908, key: key)
            }
        }
        try rejects("Port 0 made an invitation") { _ = try ConnectionInvitation(address: "192.168.1.10", port: 0, key: key) }
        // This Mac's own addresses never include loopback or link-local ones, and each can be put in an invitation.
        for address in ConnectionInvitation.localAddresses() {
            try check(!address.hasPrefix("127.") && address != "::1" && !address.lowercased().hasPrefix("fe80") && !address.hasPrefix("169.254."),
                      "A loopback or link-local address was offered: \(address)")
            try check((try? ConnectionInvitation(address: address, port: 5908, key: key)) != nil, "A local address cannot be shared: \(address)")
        }
    }
}
