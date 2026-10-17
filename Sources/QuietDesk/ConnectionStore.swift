import Foundation
import QuietDeskCore

enum ConnectionStore {
    static func matching(_ records: [ConnectionRecord], address: String, port: UInt16,
                         preferredID: UUID? = nil) -> ConnectionRecord? {
        if let preferredID, let selected = records.first(where: { $0.id == preferredID && $0.matches(address: address, port: port) }) {
            return selected
        }
        return records.first { $0.matches(address: address, port: port) }
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
