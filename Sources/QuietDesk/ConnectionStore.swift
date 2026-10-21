import Foundation
import QuietDeskCore

enum ConnectionStore {
    static func matching(_ records: [ConnectionRecord], address: String, port: UInt16,
                         preferredID: UUID? = nil, relay: RelayConnectionInfo? = nil) -> ConnectionRecord? {
        func matches(_ record: ConnectionRecord) -> Bool {
            if let relay { return record.relay?.endpoint == relay.endpoint && record.relay?.deviceID == relay.deviceID }
            return record.relay == nil && record.matches(address: address, port: port)
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
