import Foundation
import CryptoKit

public struct RelayEndpoint: Codable, Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(address: String) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = text.contains("://") ? text : "tls://" + text
        guard let parts = URLComponents(string: url), parts.scheme == "tls", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty, let host = parts.host,
              !host.isEmpty, (1...65_535).contains(parts.port ?? 443) else {
            throw DeskError.invalid("中继地址应为 tls://域名:端口，不包含路径、账户或密码")
        }
        let endpoint = try TrafficEndpoint(address: host, port: UInt16(parts.port ?? 443))
        guard !endpoint.address.contains(where: { "/@?#\\%".contains($0) }) else { throw RelayServiceError.invalid }
        self.host = endpoint.address; port = endpoint.port
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let host = try values.decode(String.self, forKey: .host)
        let port = try values.decode(UInt16.self, forKey: .port)
        try self.init(address: "tls://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }

    public var address: String { "tls://\(host.contains(":") ? "[\(host)]" : host):\(port)" }
    public var credentialAccount: String { "relay." + SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public enum RelayConnectionStrategy: String, Codable, CaseIterable, Sendable {
    case direct, automatic, relay
    public var title: String {
        switch self { case .direct: return "仅直连"; case .automatic: return "自动（直连优先）"; case .relay: return "仅中继" }
    }
}

public enum RelayServiceError: String, Codable, Error, LocalizedError, Sendable {
    case unauthorized, offline, busy, capacity, timeout, expired, storage, unsupported
    case ownerMismatch = "owner_mismatch"
    case invalid = "protocol"

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "中继接入凭据不正确；它与 Mac 配对码是两组不同凭据"
        case .offline: return "目标设备未连接此中继，或共享尚未开启"
        case .busy: return "设备标识已由另一个共享实例使用，请先停止原实例"
        case .ownerMismatch: return "中继上的设备标识不属于本机登记凭据，拒绝接管"
        case .capacity: return "中继资源暂时不足"
        case .timeout: return "中继未在期限内接通目标设备"
        case .expired: return "中继会话绑定已失效，请重新连接"
        case .storage: return "中继无法保存设备登记，请检查服务端存储"
        case .unsupported: return "中继协议版本或操作不受支持"
        case .invalid: return "中继返回了无效的协议数据"
        }
    }

    public var retryable: Bool {
        switch self { case .offline, .busy, .capacity, .timeout, .expired: return true; default: return false }
    }
}

public struct RelayMessage: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case register, registered, connect, accept, ready, datagram, datagramReady
        case incoming, incomingDatagram, datagramClosed, ping, pong, error
    }
    public static let maximumBytes = 8_192
    public var version = 1
    public let op: Operation
    public var accessKey: Data?
    public var deviceID: String?
    public var ownerKey: Data?
    public var registration: String?
    public var circuitID: String?
    public var datagramID: Data?
    public var datagramKey: Data?
    public var udpPort: Int?
    public var error: RelayServiceError?

    public init(_ op: Operation, accessKey: Data? = nil, deviceID: UUID? = nil, ownerKey: Data? = nil,
                registration: String? = nil, circuitID: String? = nil, datagramID: Data? = nil,
                datagramKey: Data? = nil, udpPort: Int? = nil) {
        self.op = op; self.accessKey = accessKey; self.deviceID = deviceID?.uuidString.lowercased()
        self.ownerKey = ownerKey; self.registration = registration; self.circuitID = circuitID
        self.datagramID = datagramID; self.datagramKey = datagramKey; self.udpPort = udpPort
    }

    public func validate() throws {
        func token(_ value: String?) -> Bool {
            value.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? false
        }
        guard version == 1, accessKey.map({ $0.count == 32 }) ?? true, ownerKey.map({ $0.count == 32 }) ?? true,
              deviceID.map({ UUID(uuidString: $0) != nil }) ?? true,
              registration == nil || token(registration), circuitID == nil || token(circuitID),
              datagramID.map({ $0.count == 16 }) ?? true, datagramKey.map({ $0.count == 32 }) ?? true,
              udpPort.map({ (1...65_535).contains($0) }) ?? true else { throw RelayServiceError.invalid }
        switch op {
        case .register: guard accessKey != nil, deviceID != nil, ownerKey != nil else { throw RelayServiceError.invalid }
        case .connect, .datagram: guard accessKey != nil, deviceID != nil else { throw RelayServiceError.invalid }
        case .accept: guard accessKey != nil, deviceID != nil, registration != nil, circuitID != nil else { throw RelayServiceError.invalid }
        case .registered: guard registration != nil else { throw RelayServiceError.invalid }
        case .incoming: guard circuitID != nil else { throw RelayServiceError.invalid }
        case .incomingDatagram, .datagramReady:
            guard datagramID != nil, datagramKey != nil, udpPort != nil else { throw RelayServiceError.invalid }
        case .datagramClosed: guard datagramID != nil else { throw RelayServiceError.invalid }
        case .error: guard error != nil else { throw RelayServiceError.invalid }
        case .ready, .ping, .pong: break
        }
    }

    public func framed() throws -> Data {
        try validate()
        let body = try JSONEncoder().encode(self)
        guard !body.isEmpty, body.count <= Self.maximumBytes else { throw RelayServiceError.invalid }
        var data = Data(); data.put(UInt32(body.count)); data.append(body); return data
    }

    public static func decode(_ body: Data) throws -> RelayMessage {
        guard !body.isEmpty, body.count <= maximumBytes else { throw RelayServiceError.invalid }
        let message = try JSONDecoder().decode(Self.self, from: body)
        try message.validate(); return message
    }
}

public struct RelayReplayWindow: Sendable {
    private var highest: UInt64 = 0
    private var bits: UInt64 = 0
    public init() {}
    public mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > 0 else { return false }
        if sequence > highest {
            let distance = sequence - highest
            bits = distance >= 64 ? 1 : (bits << distance) | 1
            highest = sequence; return true
        }
        let distance = highest - sequence
        guard distance < 64, bits & (UInt64(1) << distance) == 0 else { return false }
        bits |= UInt64(1) << distance; return true
    }
}

public struct RelayDatagram: Sendable {
    public static let maximumPayloadBytes = 1_152
    public static let overhead = 64
    public let side: UInt8
    public let downstream: Bool
    public let sequence: UInt64
    public let id: Data
    public let payload: Data

    public init(side: UInt8, downstream: Bool = false, sequence: UInt64, id: Data, payload: Data) throws {
        guard side <= 1, sequence > 0, id.count == 16, payload.count <= Self.maximumPayloadBytes else { throw RelayServiceError.invalid }
        self.side = side; self.downstream = downstream; self.sequence = sequence; self.id = id; self.payload = payload
    }

    public func encode(key: Data) throws -> Data {
        guard key.count == 32 else { throw RelayServiceError.invalid }
        var data = Data("QDR1".utf8)
        data.append(side); data.append(downstream ? 1 : 0); data.put(sequence); data.append(id)
        data.put(UInt16(payload.count)); data.append(payload)
        data.append(contentsOf: HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        return data
    }

    public static func decode(_ data: Data, key: Data) throws -> RelayDatagram {
        guard key.count == 32, data.count >= overhead, data.count <= overhead + maximumPayloadBytes else { throw RelayServiceError.invalid }
        let authenticated = Data(data.dropLast(32))
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(data.suffix(32)), authenticating: authenticated, using: SymmetricKey(data: key)) else {
            throw RelayServiceError.invalid
        }
        var reader = ByteReader(authenticated)
        guard try reader.bytes(4) == Data("QDR1".utf8) else { throw RelayServiceError.invalid }
        let side: UInt8 = try reader.take(), direction: UInt8 = try reader.take(), sequence: UInt64 = try reader.take()
        let id = try reader.bytes(16), length: UInt16 = try reader.take()
        guard direction <= 1, Int(length) == reader.remaining else { throw RelayServiceError.invalid }
        return try Self(side: side, downstream: direction == 1, sequence: sequence, id: id, payload: reader.bytes(Int(length)))
    }
}
