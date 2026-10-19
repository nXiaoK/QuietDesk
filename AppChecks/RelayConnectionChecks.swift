import Foundation
import Darwin
import QuietDeskCore

private struct RouteFailure: Error { let message: String }
private func requireRoute(_ value: Bool, _ message: String) throws { if !value { throw RouteFailure(message: message) } }

@main private struct RelayConnectionChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        run("Direct and relay records cannot share credentials merely because their display address matches") {
            let endpoint = try RelayEndpoint(address: "relay.example.com:7443")
            let route = try RelayConnectionInfo(endpoint: endpoint, deviceID: UUID())
            let direct = ConnectionRecord(address: "same.local", port: 5908, name: "Synthetic direct")
            let relayed = ConnectionRecord(address: "same.local", port: 5908, name: "Synthetic relayed", relay: route)
            let records = [relayed, direct]
            try requireRoute(ConnectionStore.matching(records, address: "SAME.local", port: 5908, preferredID: relayed.id)?.id == direct.id,
                             "A direct target selected relay credentials")
            try requireRoute(ConnectionStore.matching(records, address: "same.local", port: 5908, preferredID: direct.id, relay: route)?.id == relayed.id,
                             "A relay target selected legacy direct credentials")
        }
        run("The same device on different relay nodes never aliases another node's credentials") {
            let id = UUID(), first = try RelayConnectionInfo(endpoint: RelayEndpoint(address: "first.example.com"), deviceID: id)
            let second = try RelayConnectionInfo(endpoint: RelayEndpoint(address: "second.example.com"), deviceID: id)
            let record = ConnectionRecord(address: "", port: 5908, name: "Synthetic relay", relay: first)
            try requireRoute(ConnectionStore.matching([record], address: "", port: 5908, preferredID: record.id, relay: second) == nil,
                             "A new node reused a prior node record")
            let other = try RelayConnectionInfo(endpoint: first.endpoint, deviceID: UUID())
            try requireRoute(ConnectionStore.matching([record], address: "", port: 5908, relay: other) == nil,
                             "Another device reused a prior device record")
        }
        run("Changing a known device's direct fallback or strategy preserves its saved relay identity and quality") {
            let id = UUID(), endpoint = try RelayEndpoint(address: "relay.example.com:7443")
            let relay = try RelayConnectionInfo(endpoint: endpoint, deviceID: id)
            let automatic = try RelayConnectionInfo(endpoint: endpoint, deviceID: id, strategy: .automatic)
            let quality = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 30)
            let record = ConnectionRecord(address: "old.local", port: 5908, name: "Synthetic relay", videoSettings: quality, relay: relay)
            let selected = ConnectionStore.matching([record], address: "new.local", port: 5909, preferredID: record.id, relay: automatic)
            try requireRoute(selected?.id == record.id && selected?.videoSettings == quality,
                             "A route change erased the authenticated device's record or quality")
        }
        run("A relay node access key and desktop pairing code remain separate private-file accounts") {
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw RouteFailure(message: "Cannot resolve private test directory") }
            let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
            let directory = base.appendingPathComponent("quietdesk-relay-credential-check-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LocalCredentialStore(directory: directory)
            let node = try RelayEndpoint(address: "relay.example.com"), desktop = try PairingKey.generate(), access = try PairingKey.generate()
            let id = UUID(), remoteAccount = "remote." + id.uuidString
            try store.save(desktop, account: remoteAccount)
            try store.save(access, account: node.credentialAccount)
            try requireRoute(try store.load(account: remoteAccount)?.data == desktop.data, "Node configuration replaced the desktop code")
            try requireRoute(try store.load(account: node.credentialAccount)?.data == access.data, "Desktop code replaced node access credentials")
            try store.remove(account: remoteAccount)
            try requireRoute(try store.load(account: node.credentialAccount)?.data == access.data, "Removing one connection deleted shared node access")
        }
        print("Relay connection checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
