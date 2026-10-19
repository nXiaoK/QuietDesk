import Foundation
import Security

public enum DeskError: LocalizedError {
    case invalid(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .system(let message, let code): return "\(message)（\(code)）"
        }
    }
}

public enum MessageKind: UInt8, Sendable {
    case hello = 1, video, acknowledgement, input, ping, pong, clipboard, requestClipboard, releaseInput, inputStatus
    case clipboardSettings, clipboardBegin, clipboardEntry, clipboardChunk, clipboardEnd, clipboardReceipt, clipboardCancel
    case streamSettingsRequest, streamSettingsResult
    case controlStatus
    case deviceIdentity
    case sessionEffectsRequest, sessionEffectsResult
    case sessionPauseRequest, sessionPauseResult
    case mediaControl = 26, mediaFrame, mediaFeedback
    case cursorControl = 29, cursorShape, cursorPosition
}

public struct Message: Sendable {
    public let kind: MessageKind
    public let payload: Data
    public init(_ kind: MessageKind, _ payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }

    public func framed() throws -> Data {
        guard payload.count + 1 <= Wire.maximumMessageBytes else {
            throw DeskError.invalid("消息过大")
        }
        var result = Data()
        result.put(UInt32(payload.count + 1))
        result.append(kind.rawValue)
        result.append(payload)
        return result
    }
}

public enum Wire {
    public static let version = 1
    public static let maximumMessageBytes = 16 * 1024 * 1024
    public static let maximumClipboardBytes = 1 * 1024 * 1024

    public static func decodeBody(_ body: Data) throws -> Message {
        guard body.count <= maximumMessageBytes else { throw DeskError.invalid("消息过大") }
        guard let byte = body.first, let kind = MessageKind(rawValue: byte) else {
            throw DeskError.invalid("无法识别的消息类型")
        }
        return Message(kind, body.dropFirst())
    }

    public static func json<T: Encodable>(_ kind: MessageKind, _ value: T) throws -> Message {
        Message(kind, try JSONEncoder().encode(value))
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= 4096 else { throw DeskError.invalid("控制消息过大") }
        return try JSONDecoder().decode(type, from: data)
    }
}

public struct PairingKey: Sendable {
    public let data: Data
    public var code: String {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 8)])
        }.joined(separator: "-")
    }

    public init(code: String) throws {
        let clean = code.filter { !$0.isWhitespace && $0 != "-" }
        guard clean.count == 64, clean.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw DeskError.invalid("配对码应为完整的 64 位十六进制字符，可保留横线") }
        var bytes = Data()
        var cursor = clean.startIndex
        while cursor < clean.endIndex {
            let end = clean.index(cursor, offsetBy: 2)
            guard let value = UInt8(clean[cursor..<end], radix: 16) else {
                throw DeskError.invalid("配对码格式错误")
            }
            bytes.append(value)
            cursor = end
        }
        self.data = bytes
    }

    public static func generate() throws -> PairingKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw DeskError.system("无法生成配对码", result) }
        return PairingKey(data: Data(bytes))
    }

    private init(data: Data) { self.data = data }
}

public struct StreamSettings: Codable, Equatable, Sendable {
    public static let legacyLongestEdges = [1280, 1920, 2560, 3840]
    public static let nativeLongestEdge = 8192
    public static let longestEdges = legacyLongestEdges + [nativeLongestEdge]
    public static let legacyFrameRates = [10, 15, 30]
    public static let frameRates = legacyFrameRates + [60]
    public static let legacyBitRates = [1, 2, 3, 5, 8, 12]
    public static let extendedBitRates = legacyBitRates + [30]
    public static let bitRates = extendedBitRates + [60, 100]
    public static let highest = StreamSettings(longestEdge: nativeLongestEdge, framesPerSecond: 60, megabits: 100)
    public var longestEdge: Int
    public var framesPerSecond: Int
    public var megabits: Int
    public init(longestEdge: Int = 1920, framesPerSecond: Int = 15, megabits: Int = 3) {
        self.longestEdge = longestEdge
        self.framesPerSecond = framesPerSecond
        self.megabits = megabits
    }

    public func validateControlValues() throws {
        guard Self.longestEdges.contains(longestEdge), Self.frameRates.contains(framesPerSecond),
              Self.bitRates.contains(megabits) else { throw DeskError.invalid("不支持的画质参数") }
    }

    public static func resolutionLabel(_ longestEdge: Int) -> String {
        longestEdge == nativeLongestEdge ? "原分辨率（上限 8K）" : "\(longestEdge)"
    }

    public var summary: String { "\(Self.resolutionLabel(longestEdge)) / \(framesPerSecond) fps / \(megabits) Mbps" }

    public var legacyCompatible: StreamSettings {
        StreamSettings(longestEdge: min(longestEdge, Self.legacyLongestEdges.last!),
                       framesPerSecond: min(framesPerSecond, 30), megabits: min(megabits, Self.legacyBitRates.last!))
    }

    public var extendedCompatible: StreamSettings {
        StreamSettings(longestEdge: longestEdge, framesPerSecond: min(framesPerSecond, 30), megabits: min(megabits, 30))
    }

    public func dimensions(width: Int, height: Int) -> (Int, Int) {
        let sourceWidth = Double(max(1, width)), sourceHeight = Double(max(1, height))
        let scale = min(1, Double(min(longestEdge, Self.nativeLongestEdge)) / max(sourceWidth, sourceHeight),
                        sqrt(36_000_000 / (sourceWidth * sourceHeight)))
        return (max(2, Int(Double(width) * scale) / 2 * 2),
                max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

public struct Hello: Codable, Sendable {
    public var version: Int = Wire.version
    public let name: String
    public let width: Int
    public let height: Int
    public let settings: StreamSettings
    public let canControl: Bool
    public let inputActions: Bool?
    public let clipboardSync: Bool?
    public let liveSettings: Bool?
    public let controlStatusUpdates: Bool?
    public let extendedVideoSettings: Bool?
    public let preferredSettings: StreamSettings?
    public let deviceID: UUID?
    public let deviceIdentityExchange: Bool?
    public let highRefreshVideoSettings: Bool?
    public let preferredHighRefreshSettings: StreamSettings?
    public let sessionEffects: Bool?
    public let sessionPause: Bool?
    public let mediaTransportV1: Bool?
    public let independentCursorV1: Bool?
    public let relayTransportV1: Bool?
    public let relayDeviceID: UUID?
    public init(name: String, width: Int, height: Int, settings: StreamSettings, canControl: Bool, inputActions: Bool? = true, clipboardSync: Bool? = true, liveSettings: Bool? = true, controlStatusUpdates: Bool? = true, extendedVideoSettings: Bool? = true, preferredSettings: StreamSettings? = nil, deviceID: UUID? = nil, deviceIdentityExchange: Bool? = nil, highRefreshVideoSettings: Bool? = nil, preferredHighRefreshSettings: StreamSettings? = nil, sessionEffects: Bool? = nil, sessionPause: Bool? = nil, mediaTransportV1: Bool? = nil, independentCursorV1: Bool? = nil, relayTransportV1: Bool? = nil, relayDeviceID: UUID? = nil) {
        self.name = name
        self.width = width
        self.height = height
        self.settings = settings
        self.canControl = canControl
        self.inputActions = inputActions
        self.clipboardSync = clipboardSync
        self.liveSettings = liveSettings
        self.controlStatusUpdates = controlStatusUpdates
        self.extendedVideoSettings = extendedVideoSettings
        self.preferredSettings = preferredSettings
        self.deviceID = deviceID
        self.deviceIdentityExchange = deviceIdentityExchange
        self.highRefreshVideoSettings = highRefreshVideoSettings
        self.preferredHighRefreshSettings = preferredHighRefreshSettings
        self.sessionEffects = sessionEffects
        self.sessionPause = sessionPause
        self.mediaTransportV1 = mediaTransportV1
        self.independentCursorV1 = independentCursorV1
        self.relayTransportV1 = relayTransportV1
        self.relayDeviceID = relayDeviceID
    }

    public func validate() throws {
        guard version == Wire.version, (2...8192).contains(width), (2...8192).contains(height),
              width * height <= 36_000_000,
              (1...60).contains(settings.framesPerSecond), (1...30).contains(settings.megabits) else {
            throw DeskError.invalid("远端版本或画面参数不兼容")
        }
        if extendedVideoSettings == true, let preferredSettings { try preferredSettings.validateControlValues() }
        if highRefreshVideoSettings == true, let preferredHighRefreshSettings { try preferredHighRefreshSettings.validateControlValues() }
    }
}

public struct ControlStatus: Codable, Sendable {
    public let canControl: Bool
    public init(canControl: Bool) { self.canControl = canControl }
}

public struct RemoteInput: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move, drag, down, up, scroll, keyDown, keyUp, flags, switchInputSource, toggleCapsLock
    }
    public var kind: Kind
    public var x: Double = 0
    public var y: Double = 0
    public var button: Int = 0
    public var keyCode: UInt16 = 0
    public var flags: UInt64 = 0
    public var deltaX: Double = 0
    public var deltaY: Double = 0
    public var clicks: Int = 1
    public var isRepeat: Bool = false
    public var independentCapsLock: Bool?

    public init(kind: Kind) { self.kind = kind }

    public func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              (0...2).contains(button), keyCode <= 127, (0...3).contains(clicks),
              deltaX.isFinite, deltaY.isFinite, abs(deltaX) <= 3000, abs(deltaY) <= 3000 else {
            throw DeskError.invalid("远端输入参数无效")
        }
    }
}

public struct VideoPacket: Sendable {
    public let sequence: UInt32
    public let sps: Data
    public let pps: Data
    public let avcc: Data

    public init(sequence: UInt32, sps: Data, pps: Data, avcc: Data) {
        self.sequence = sequence
        self.sps = sps
        self.pps = pps
        self.avcc = avcc
    }

    public func encode() throws -> Data {
        guard sps.count <= 4096, pps.count <= 4096, !avcc.isEmpty,
              avcc.count < Wire.maximumMessageBytes - 8201 else {
            throw DeskError.invalid("编码帧大小无效")
        }
        var data = Data()
        data.put(sequence)
        data.put(UInt16(sps.count))
        data.put(UInt16(pps.count))
        data.append(sps)
        data.append(pps)
        data.append(avcc)
        return data
    }

    public static func decode(_ data: Data) throws -> VideoPacket {
        guard data.count < Wire.maximumMessageBytes else { throw DeskError.invalid("视频帧过大") }
        var reader = ByteReader(data)
        let sequence: UInt32 = try reader.take()
        let spsLength: UInt16 = try reader.take()
        let ppsLength: UInt16 = try reader.take()
        guard spsLength <= 4096, ppsLength <= 4096,
              (spsLength == 0) == (ppsLength == 0) else {
            throw DeskError.invalid("视频参数无效")
        }
        let sps = try reader.bytes(Int(spsLength))
        let pps = try reader.bytes(Int(ppsLength))
        let avcc = try reader.bytes(reader.remaining)
        guard !avcc.isEmpty else { throw DeskError.invalid("空视频帧") }
        var nalReader = ByteReader(avcc)
        while nalReader.remaining > 0 {
            let length: UInt32 = try nalReader.take()
            guard length > 0, length <= nalReader.remaining else {
                throw DeskError.invalid("H.264 数据损坏")
            }
            try nalReader.skip(Int(length))
        }
        return VideoPacket(sequence: sequence, sps: sps, pps: pps, avcc: avcc)
    }
}

public struct ByteReader {
    private let data: Data
    private var offset = 0
    public var remaining: Int { data.count - offset }
    public init(_ data: Data) { self.data = data }

    public mutating func take<T: FixedWidthInteger>() throws -> T {
        let count = MemoryLayout<T>.size
        guard remaining >= count else { throw DeskError.invalid("消息被截断") }
        var value: T = 0
        let start = data.startIndex + offset
        for byte in data[start..<(start + count)] { value = (value << 8) | T(truncatingIfNeeded: byte) }
        offset += count
        return value
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw DeskError.invalid("消息被截断") }
        defer { offset += count }
        let start = data.startIndex + offset
        return data[start..<(start + count)]
    }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw DeskError.invalid("消息被截断") }
        offset += count
    }
}

public extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
