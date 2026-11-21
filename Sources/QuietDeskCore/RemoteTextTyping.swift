import Foundation

/// A short text snippet for the host to type into the focused remote field as simulated keystrokes without
/// writing to the remote Mac's clipboard. Travels only inside the encrypted control session and is never logged.
public struct TypeTextRequest: Codable, Equatable, Sendable {
    public static let maximumCharacterCount = 512
    public static let maximumUTF8Bytes = 2_048

    public let id: UUID
    public let text: String
    public let submitReturn: Bool
    public let cancel: Bool

    public init(id: UUID = UUID(), text: String, submitReturn: Bool = false) throws {
        let normalized = Self.normalizeLineEndings(text)
        try Self.validate(normalized)
        self.id = id
        self.text = normalized
        self.submitReturn = submitReturn
        self.cancel = false
    }

    private init(cancelID: UUID) {
        self.id = cancelID
        self.text = ""
        self.submitReturn = false
        self.cancel = true
    }

    public static func cancel(id: UUID) -> TypeTextRequest {
        TypeTextRequest(cancelID: id)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, submitReturn, cancel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let cancel = try values.decodeIfPresent(Bool.self, forKey: .cancel) ?? false
        let rawText = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        let submitReturn = try values.decodeIfPresent(Bool.self, forKey: .submitReturn) ?? false
        if cancel {
            guard rawText.isEmpty, !submitReturn else {
                throw DeskError.invalid("取消模拟键入请求字段无效")
            }
            self.init(cancelID: id)
        } else {
            try self.init(id: id, text: rawText, submitReturn: submitReturn)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !cancel {
            try container.encode(text, forKey: .text)
        }
        if submitReturn {
            try container.encode(true, forKey: .submitReturn)
        }
        if cancel {
            try container.encode(true, forKey: .cancel)
        }
    }

    public static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Permits printable Unicode characters plus explicit Tab (`\t`) and LF (`\n`), rejecting Escape, Backspace,
    /// NUL, bidirectional overrides, and other control/format scalars.
    public static func validate(_ normalizedText: String) throws {
        guard !normalizedText.isEmpty else {
            throw DeskError.invalid("要模拟键入的文字不能为空")
        }
        guard normalizedText.count <= maximumCharacterCount,
              normalizedText.utf8.count <= maximumUTF8Bytes else {
            throw DeskError.invalid("模拟键入单次最多支持 \(maximumCharacterCount) 个字符（不超过 \(maximumUTF8Bytes) 字节），长文本请使用剪贴板粘贴")
        }
        for scalar in normalizedText.unicodeScalars {
            if scalar == "\n" || scalar == "\t" { continue }
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator {
                throw DeskError.invalid("模拟键入内容包含不允许的控制字符或不可见格式符")
            }
        }
    }
}

public struct TypeTextResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let typedCount: Int
    public let cancelled: Bool
    public let error: String?

    public init(id: UUID, typedCount: Int, cancelled: Bool = false, error: String? = nil) throws {
        guard (0...TypeTextRequest.maximumCharacterCount).contains(typedCount) else {
            throw DeskError.invalid("模拟键入结果计数超出范围")
        }
        if let error {
            guard !error.isEmpty, error.count <= 240 else {
                throw DeskError.invalid("模拟键入错误说明长度无效")
            }
        }
        self.id = id
        self.typedCount = typedCount
        self.cancelled = cancelled
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id, typedCount, cancelled, error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let typedCount = try values.decode(Int.self, forKey: .typedCount)
        let cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        let error = try values.decodeIfPresent(String.self, forKey: .error)
        try self.init(id: id, typedCount: typedCount, cancelled: cancelled, error: error)
    }
}
