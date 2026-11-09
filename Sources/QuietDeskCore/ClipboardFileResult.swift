import Foundation

/// Local completion evidence only; never sent over the clipboard protocol.
public struct ClipboardFileResult: Identifiable, Equatable, Sendable {
    public enum Direction: Sendable { case sending, receiving }
    public enum Outcome: Sendable { case completed, cancelled, failed }

    public let id: UUID
    public let direction: Direction
    public let outcome: Outcome
    public let message: String
    /// Complete local files moved into received storage; empty for sends and unfinished downloads.
    public let files: [URL]

    public init(id: UUID = UUID(), direction: Direction, outcome: Outcome, message: String, files: [URL] = []) {
        self.id = id; self.direction = direction; self.outcome = outcome; self.message = message; self.files = files
    }
}
