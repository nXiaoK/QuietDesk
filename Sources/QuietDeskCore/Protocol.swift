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
    // Sent only after the host's hello advertised sessionUnlockV1.
    case sessionUnlockRequest = 32, sessionUnlockResult
    // Sent only after sessionTerminationV1 is advertised and the viewer subscribes.
    case sessionTermination = 34
    // Sent only after the host advertises desktopActionsV1.
    case desktopActionRequest = 35, desktopActionResult
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
    public static let highRefreshFrameRates = legacyFrameRates + [60]
    public static let frameRates = highRefreshFrameRates + [75, 90, 120, 144, 165, 240]
    public static let legacyBitRates = [1, 2, 3, 5, 8, 12]
    public static let extendedBitRates = legacyBitRates + [30]
    public static let bitRates = extendedBitRates + [60, 100]
    // Finer automatic steps for hosts that negotiated adaptiveVideoV1. Manual choices keep the coarse list.
    public static let adaptiveBitRates = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100]
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
              Self.adaptiveBitRates.contains(megabits) else { throw DeskError.invalid("不支持的画质参数") }
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

    public var highRefreshCompatible: StreamSettings {
        StreamSettings(longestEdge: longestEdge, framesPerSecond: min(framesPerSecond, 60), megabits: megabits)
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
    public let sessionLockV1: Bool?
    // The host accepts adaptiveBitRates, applies bitrate-only changes to the running encoder without a new
    // keyframe, and reports frame delivery delay in media stats.
    public let adaptiveVideoV1: Bool?
    // The host types a lock screen password the viewer sends, and reports whether it was locked when this hello was sent.
    public let sessionUnlockV1: Bool?
    public let screenLocked: Bool?
    // Rates above 60 fps use separate optional fields so existing high-refresh viewers still receive a valid default.
    public let higherFrameRateVideoV1: Bool?
    public let preferredHigherFrameRateSettings: StreamSettings?
    // The host understands SessionEffectsState.dimBuiltInDisplay, and reports whether it was a laptop whose
    // built-in display brightness could be changed when this hello was sent.
    public let displayDimmingV1: Bool?
    public let builtInDisplayDimmable: Bool?
    public let sessionTerminationV1: Bool?
    public let desktopActionsV1: Bool?
    public init(name: String, width: Int, height: Int, settings: StreamSettings, canControl: Bool, inputActions: Bool? = true, clipboardSync: Bool? = true, liveSettings: Bool? = true, controlStatusUpdates: Bool? = true, extendedVideoSettings: Bool? = true, preferredSettings: StreamSettings? = nil, deviceID: UUID? = nil, deviceIdentityExchange: Bool? = nil, highRefreshVideoSettings: Bool? = nil, preferredHighRefreshSettings: StreamSettings? = nil, sessionEffects: Bool? = nil, sessionPause: Bool? = nil, mediaTransportV1: Bool? = nil, independentCursorV1: Bool? = nil, relayTransportV1: Bool? = nil, relayDeviceID: UUID? = nil, sessionLockV1: Bool? = nil, adaptiveVideoV1: Bool? = nil, sessionUnlockV1: Bool? = nil, screenLocked: Bool? = nil, higherFrameRateVideoV1: Bool? = nil, preferredHigherFrameRateSettings: StreamSettings? = nil, displayDimmingV1: Bool? = nil, builtInDisplayDimmable: Bool? = nil, sessionTerminationV1: Bool? = nil, desktopActionsV1: Bool? = nil) {
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
        self.sessionLockV1 = sessionLockV1
        self.adaptiveVideoV1 = adaptiveVideoV1
        self.sessionUnlockV1 = sessionUnlockV1
        self.screenLocked = screenLocked
        self.higherFrameRateVideoV1 = higherFrameRateVideoV1
        self.preferredHigherFrameRateSettings = preferredHigherFrameRateSettings
        self.displayDimmingV1 = displayDimmingV1
        self.builtInDisplayDimmable = builtInDisplayDimmable
        self.sessionTerminationV1 = sessionTerminationV1
        self.desktopActionsV1 = desktopActionsV1
    }

    public func validate() throws {
        guard version == Wire.version, (2...8192).contains(width), (2...8192).contains(height),
              width * height <= 36_000_000,
              (1...60).contains(settings.framesPerSecond), (1...30).contains(settings.megabits) else {
            throw DeskError.invalid("远端版本或画面参数不兼容")
        }
        if extendedVideoSettings == true, let preferredSettings { try preferredSettings.validateControlValues() }
        if highRefreshVideoSettings == true, let preferredHighRefreshSettings { try preferredHighRefreshSettings.validateControlValues() }
        guard extendedVideoSettings != true || (preferredSettings?.framesPerSecond ?? 0) <= 60,
              highRefreshVideoSettings != true || (preferredHighRefreshSettings?.framesPerSecond ?? 0) <= 60 else {
            throw DeskError.invalid("兼容画质字段的帧率不能超过 60 fps")
        }
        if higherFrameRateVideoV1 == true, let preferredHigherFrameRateSettings { try preferredHigherFrameRateSettings.validateControlValues() }
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
