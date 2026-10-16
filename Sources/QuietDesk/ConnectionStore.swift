import Foundation
import QuietDeskCore

enum ConnectionStore {
    static func load() -> [ConnectionRecord] {
        guard let data = UserDefaults.standard.data(forKey: "connections"),
              let records = try? JSONDecoder().decode([ConnectionRecord].self, from: data) else { return [] }
        return records.sorted { $0.lastConnected > $1.lastConnected }
    }
    static func save(_ records: [ConnectionRecord]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: "connections")
    }
}
