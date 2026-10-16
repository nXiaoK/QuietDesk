import Foundation

public struct CapsLockPress {
    public static let holdDuration: TimeInterval = 0.6
    private var pressedAt: TimeInterval?
    public init() {}

    public mutating func update(isDown: Bool, time: TimeInterval) -> RemoteInput.Kind? {
        guard time.isFinite else { reset(); return nil }
        if isDown {
            if pressedAt == nil { pressedAt = time }
            return nil
        }
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        guard time >= start else { return nil }
        return time - start >= Self.holdDuration ? .toggleCapsLock : .switchInputSource
    }

    public mutating func reset() { pressedAt = nil }
}

public struct KeyboardSource: Equatable {
    public let id: String
    public let name: String
    public let isChinese: Bool
    public let isASCII: Bool
    public init(id: String, name: String, isChinese: Bool, isASCII: Bool) {
        self.id = id
        self.name = name
        self.isChinese = isChinese
        self.isASCII = isASCII
    }
}

public struct InputSourceChoice {
    private var lastChineseID: String?
    private var lastASCIIID: String?
    public init() {}

    public mutating func target(current: KeyboardSource, enabled: [KeyboardSource]) -> KeyboardSource? {
        let chinese = enabled.filter(\.isChinese)
        let ascii = enabled.filter { $0.isASCII && !$0.isChinese }
        if current.isChinese {
            lastChineseID = current.id
            return ascii.first(where: { $0.id == lastASCIIID }) ?? ascii.first
        }
        if current.isASCII { lastASCIIID = current.id }
        return chinese.first(where: { $0.id == lastChineseID }) ?? chinese.first
    }
}

public struct InputFeedback: Codable, Sendable {
    public let message: String
    public let capsLocked: Bool
    public init(message: String, capsLocked: Bool) {
        self.message = message
        self.capsLocked = capsLocked
    }
}
