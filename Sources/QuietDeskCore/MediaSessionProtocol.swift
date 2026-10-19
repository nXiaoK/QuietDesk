import Foundation

public struct MediaControl: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case request, offer, bind, bound, prepare, ready, decodedReady, commit, committed, abort, recover, stats
    }
    public let operation: Operation
    public let sessionID: UUID?
    public let token: Data?
    public let datagramKey: Data?
    public let role: MediaChannelRole?
    public let transactionID: UUID?
    public let transportEpoch: UInt32?
    public let codecEpoch: UInt32?
    public let path: String?
    public let mediaFailure: Bool?
    public let encodeMilliseconds: Double?
    public let relayRouting: Bool?

    public init(_ operation: Operation, sessionID: UUID? = nil, token: Data? = nil,
                datagramKey: Data? = nil, role: MediaChannelRole? = nil, transactionID: UUID? = nil,
                transportEpoch: UInt32? = nil, codecEpoch: UInt32? = nil, path: String? = nil,
                mediaFailure: Bool? = nil, encodeMilliseconds: Double? = nil, relayRouting: Bool? = nil) {
        self.operation = operation; self.sessionID = sessionID; self.token = token
        self.datagramKey = datagramKey; self.role = role; self.transactionID = transactionID
        self.transportEpoch = transportEpoch; self.codecEpoch = codecEpoch; self.path = path
        self.mediaFailure = mediaFailure; self.encodeMilliseconds = encodeMilliseconds
        self.relayRouting = relayRouting
    }

    public func validate() throws {
        guard token == nil || token?.count == 32, datagramKey == nil || datagramKey?.count == 32,
              path == nil || ["udp", "tcp", "shared"].contains(path!),
              mediaFailure == nil || operation == .abort || operation == .recover,
              relayRouting == nil || operation == .request || operation == .offer,
              encodeMilliseconds == nil || operation == .stats else {
            throw DeskError.invalid("媒体协商参数无效")
        }
        switch operation {
        case .request:
            guard sessionID == nil, token == nil, datagramKey == nil, role == nil,
                  transactionID == nil, transportEpoch == nil, codecEpoch == nil, path == nil else {
                throw DeskError.invalid("媒体能力请求无效")
            }
        case .offer:
            guard sessionID != nil, token != nil, datagramKey != nil else {
                throw DeskError.invalid("媒体会话凭据缺失")
            }
        case .bind, .bound:
            guard sessionID != nil, let role, role != .control, token != nil else {
                throw DeskError.invalid("媒体通道绑定无效")
            }
        case .prepare, .ready, .decodedReady, .commit, .committed, .abort:
            guard sessionID != nil, transactionID != nil, transportEpoch != nil, codecEpoch != nil, path != nil else {
                throw DeskError.invalid("媒体切换事务无效")
            }
        case .recover:
            guard sessionID != nil, transportEpoch != nil, codecEpoch != nil else {
                throw DeskError.invalid("媒体恢复请求无效")
            }
        case .stats:
            guard sessionID != nil, let encodeMilliseconds, encodeMilliseconds.isFinite,
                  (0...10_000).contains(encodeMilliseconds), token == nil, datagramKey == nil,
                  role == nil, transactionID == nil, transportEpoch == nil, codecEpoch == nil, path == nil else {
                throw DeskError.invalid("媒体计算观测无效")
            }
        }
    }

    public func message() throws -> Message { try validate(); return try Wire.json(.mediaControl, self) }
    public static func read(_ payload: Data) throws -> Self {
        let value = try Wire.readJSON(Self.self, payload)
        try value.validate()
        return value
    }
}

// This state is independent of diagnostics: disabling logging must not disable expiry or replay checks.
public struct MediaBindingGrant {
    public let sessionID: UUID
    public let token: Data
    public let expiresAt: TimeInterval
    private var bound: Set<MediaChannelRole> = []

    public init(sessionID: UUID, token: Data, now: TimeInterval, lifetime: TimeInterval = 15) throws {
        guard token.count == 32, now.isFinite, now >= 0, lifetime.isFinite, lifetime > 0, (now + lifetime).isFinite else {
            throw DeskError.invalid("媒体绑定凭据无效")
        }
        self.sessionID = sessionID; self.token = token; expiresAt = now + lifetime
    }

    public mutating func consume(_ request: MediaControl, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, now <= expiresAt, request.operation == .bind,
              request.sessionID == sessionID, let candidate = request.token, candidate.count == token.count,
              let role = request.role, role != .control, !bound.contains(role) else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, token) { difference |= left ^ right }
        guard difference == 0 else { return false }
        bound.insert(role)
        return true
    }
}
