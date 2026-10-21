import Foundation

/// A lock screen password for the host to type. It travels only inside the encrypted control session;
/// neither end logs it and the host keeps it only while typing.
public struct SessionUnlockRequest: Codable, Sendable {
    public static let maximumPasswordLength = 128
    public let id: UUID
    public let password: String

    public init(id: UUID = UUID(), password: String) throws {
        try Self.validate(password)
        self.id = id; self.password = password
    }

    private enum CodingKeys: String, CodingKey { case id, password }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let password = try values.decode(String.self, forKey: .password)
        try Self.validate(password)
        id = try values.decode(UUID.self, forKey: .id)
        self.password = password
    }

    /// Rejects empty or long passwords and any control or invisible formatting character, so typing
    /// it can never press Return, Tab or Escape partway through.
    public static func validate(_ password: String) throws {
        let scalars = password.unicodeScalars
        guard !scalars.isEmpty, password.count <= maximumPasswordLength,
              !scalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                  || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator }) else {
            throw DeskError.invalid("锁屏密码为空、超过 \(maximumPasswordLength) 个字符或含有控制字符")
        }
    }
}

public struct SessionUnlockResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The host was locked, the password was typed and the session is now unlocked.
        case unlocked
        /// The host was not locked, so nothing was typed.
        case notLocked
        /// Typing was refused or the screen stayed locked; `error` says why.
        case failed
    }
    public let id: UUID
    public let outcome: Outcome
    public let error: String?
    public init(id: UUID, outcome: Outcome, error: String? = nil) {
        self.id = id; self.outcome = outcome; self.error = error
    }
}
