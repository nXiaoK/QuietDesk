import Foundation
import QuietDeskCore

private struct EntryCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct ConnectionEntryChecks {
    static func main() throws {
        var passed = 0, failed = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw EntryCheckFailure(message) }
        }
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("Connection entry checks use synthetic records and pure presentation only; no app model, network, credentials, system clipboard or defaults access.")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let records = (0..<8).map { index in
            ConnectionRecord(address: "mac-\(index).example.invalid", port: UInt16(5908 + index), name: "书桌 \(index)",
                             lastConnected: date.addingTimeInterval(Double(-index)), videoSettings: index == 3 ? .highest : nil)
        }
        let route = try RelayConnectionInfo(endpoint: RelayEndpoint(address: "tls://relay.example.invalid:7443"),
                                             deviceID: UUID(uuidString: "AAAA1111-2222-3333-4444-555566667777")!, strategy: .automatic)
        let relayed = ConnectionRecord(address: "192.0.2.10", port: 5908, name: "工作 Mac", lastConnected: date, relay: route)
        let code = String(repeating: "A", count: 64)
        func field(relay: Bool = false, strategy: RelayConnectionStrategy = .direct, address: String = "mac.example.invalid",
                   port: String = "5908", deviceID: String = "", code: String = String(repeating: "A", count: 64)) -> ConnectionEntryPresentation.Field? {
            ConnectionEntryPresentation.firstIncompleteField(relayEnabled: relay, strategy: strategy, address: address,
                                                               port: port, deviceID: deviceID, code: code)
        }

        run("Collapsed recent records show three without changing saved order or identities") {
            try require(ConnectionEntryPresentation.visible(records, query: "", expanded: false) == Array(records.prefix(3)),
                        "Recent subset reordered or changed records")
        }
        run("Inline expansion exposes every record and collapse remains a pure projection") {
            try require(ConnectionEntryPresentation.visible(records, query: "", expanded: true) == records,
                        "Expansion omitted records")
            try require(ConnectionEntryPresentation.visible(records, query: "", expanded: false).count == 3 && records.count == 8,
                        "Collapse mutated the input")
        }
        run("Search finds a hidden record without requiring prior expansion") {
            try require(ConnectionEntryPresentation.visible(records, query: "mac-7", expanded: false).map(\.id) == [records[7].id],
                        "Search only inspected the collapsed subset")
        }
        run("Search is whitespace-tolerant, case-insensitive and supports names and ports") {
            try require(ConnectionEntryPresentation.matching(records, query: "  MAC-5  ").map(\.id) == [records[5].id], "Address search failed")
            try require(ConnectionEntryPresentation.matching(records, query: "书桌 4").map(\.id) == [records[4].id], "Name search failed")
            try require(ConnectionEntryPresentation.matching(records, query: "5915").map(\.id) == [records[7].id], "Port search failed")
        }
        run("Empty and unmatched searches neither remove nor invent saved records") {
            try require(ConnectionEntryPresentation.matching(records, query: " \n ") == records, "Whitespace filtered records")
            try require(ConnectionEntryPresentation.visible(records, query: "not-saved", expanded: true).isEmpty, "No-match fabricated a record")
        }
        run("Relay records are searchable by full device identity, node host and node port") {
            for query in [route.deviceID.uuidString.lowercased(), "relay.example.invalid", "7443", "192.0.2.10"] {
                try require(ConnectionEntryPresentation.matching([relayed], query: query) == [relayed], "Relay metadata search failed: \(query)")
            }
        }
        run("Filtering preserves duplicate endpoint records and their saved quality") {
            let duplicate = ConnectionRecord(address: records[3].address, port: records[3].port, name: "Other", lastConnected: date)
            let values = ConnectionEntryPresentation.matching([records[3], duplicate], query: records[3].address)
            try require(values.map(\.id) == [records[3].id, duplicate.id] && values[0].videoSettings == .highest,
                        "Filtering coalesced identities or changed quality")
        }
        run("Endpoint labels bracket IPv6 and retain relay nodes as saved rather than actual-path claims") {
            let ipv6 = ConnectionRecord(address: "2001:db8::5", port: 5908, name: "IPv6")
            try require(ConnectionEntryPresentation.endpoint(ipv6) == "[2001:db8::5]:5908", "Ambiguous IPv6 endpoint")
            try require(ConnectionEntryPresentation.endpoint(relayed) == route.endpoint.address
                        && ConnectionEntryPresentation.route(relayed) == "自动（直连优先）", "Saved relay route mislabeled")
        }
        run("Unnamed saved records have a useful title without modifying the stored name") {
            let direct = ConnectionRecord(address: "example.invalid", port: 5908, name: "  ")
            let relay = ConnectionRecord(address: "", port: 5908, name: "", relay: route)
            try require(ConnectionEntryPresentation.title(direct) == direct.address && direct.name == "  ", "Name was changed")
            try require(ConnectionEntryPresentation.title(relay) == "已保存的 Mac", "Empty relay name had no title")
        }
        run("An existing failure always keeps recovery visible even when its string repeats") {
            try require(ConnectionEntryPresentation.showsForm(hasRecords: true, expanded: false, failure: "same error"),
                        "A repeated failure could hide the recovery fields")
            try require(!ConnectionEntryPresentation.showsForm(hasRecords: true, expanded: false, failure: nil)
                        && ConnectionEntryPresentation.showsForm(hasRecords: false, expanded: false, failure: nil),
                        "Normal recent or first-use disclosure defaults changed")
        }
        run("Direct-entry focus identifies missing or invalid host before port and code") {
            for address in ["", "  ", "tls://example.invalid", "example.invalid/path"] {
                try require(field(address: address) == .address, "Invalid host did not focus address")
            }
            for port in ["0", "65536", "abc", " 5908"] {
                try require(field(port: port) == .port, "Invalid port did not focus port")
            }
        }
        run("Pairing-code focus reuses the actual decoder without loading or generating credentials") {
            try require(field(code: "") == .code && field(code: "bad") == .code, "Missing/malformed code not focused")
            try require(field(code: code) == nil && field(code: String(repeating: "a-", count: 64)) == nil, "Valid code was rejected")
        }
        run("Automatic mode requires a valid device ID but permits an absent direct hint and ignored port") {
            try require(field(relay: true, strategy: .automatic, deviceID: "bad") == .deviceID, "Device ID not focused")
            try require(field(relay: true, strategy: .automatic, address: "", port: "bad", deviceID: route.deviceID.uuidString) == nil,
                        "Automatic mode required an optional direct hint")
            try require(field(relay: true, strategy: .automatic, address: "example.invalid", port: "bad", deviceID: route.deviceID.uuidString) == .port,
                        "Present direct hint bypassed port guidance")
        }
        run("Relay-only focus ignores hidden direct fields while disabled relay preserves direct rules") {
            try require(field(relay: true, strategy: .relay, address: "bad/path", port: "bad", deviceID: route.deviceID.uuidString) == nil,
                        "Relay-only mode focused hidden direct fields")
            try require(field(relay: false, strategy: .relay, address: "") == .address, "Disabled relay bypassed direct requirements")
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
