import Foundation
import QuietDeskCore

enum ConnectionStore {
    static func matching(_ records: [ConnectionRecord], address: String, port: UInt16,
                         preferredID: UUID? = nil, relay: RelayConnectionInfo? = nil) -> ConnectionRecord? {
        if let relay {
            // A relayed Mac is the same device through any node; a record on the same node wins a tie.
            let device = records.filter { $0.relay?.deviceID == relay.deviceID }
            if let preferredID, let selected = device.first(where: { $0.id == preferredID }) { return selected }
            return device.first(where: { $0.relay?.endpoint == relay.endpoint }) ?? device.first
        }
        func matches(_ record: ConnectionRecord) -> Bool {
            record.relay == nil && record.matches(address: address, port: port)
        }
        if let preferredID, let selected = records.first(where: { $0.id == preferredID && matches($0) }) {
            return selected
        }
        return records.first(where: matches)
    }

    static func load() -> [ConnectionRecord] {
        guard let data = UserDefaults.standard.data(forKey: "connections"),
              let records = try? JSONDecoder().decode([ConnectionRecord].self, from: data) else { return [] }
        return records.sorted { $0.lastConnected > $1.lastConnected }
    }
    static func save(_ records: [ConnectionRecord]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: "connections")
    }
}
