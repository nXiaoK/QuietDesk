import Foundation
import Security
import QuietDeskCore

enum KeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.quietdesk.pairing",
        kSecAttrAccount as String: "host"
    ]

    static func load(account: String = "host") throws -> PairingKey? {
        var request = query
        request[kSecAttrAccount as String] = account
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let code = String(data: data, encoding: .utf8) else {
            throw DeskError.system("无法读取钥匙串中的配对码", status)
        }
        return try PairingKey(code: code)
    }

    static func save(_ key: PairingKey, account: String = "host") throws {
        var query = Self.query
        query[kSecAttrAccount as String] = account
        let data = Data(key.code.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw DeskError.system("无法保存配对码到钥匙串", added) }
        } else if status != errSecSuccess {
            throw DeskError.system("无法更新钥匙串配对码", status)
        }
    }

    static func remove(account: String) throws {
        var query = Self.query
        query[kSecAttrAccount as String] = account
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw DeskError.system("无法删除配对记录", result) }
    }
}
