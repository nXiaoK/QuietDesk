import Foundation

public struct MediaStreamID: Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let transportEpoch: UInt32
    public let codecEpoch: UInt32

    public init(sessionID: UUID, transportEpoch: UInt32, codecEpoch: UInt32) {
        self.sessionID = sessionID
        self.transportEpoch = transportEpoch
        self.codecEpoch = codecEpoch
    }
}

public struct MediaFrameHeader: Equatable, Hashable, Sendable {
    public let stream: MediaStreamID
    public let frameID: UInt64
    public let isIDR: Bool

    public init(stream: MediaStreamID, frameID: UInt64, isIDR: Bool) {
        self.stream = stream
        self.frameID = frameID
        self.isIDR = isIDR
    }
}

// The prefix and frame identity are shared by TCP frames and authenticated UDP records.
private enum MediaWire {
    static let magic: UInt16 = 0x514D
    static let version: UInt8 = 1
    static let headerBytes = 37

    static func begin(_ kind: UInt8, header: MediaFrameHeader) -> Data {
        var data = Data()
        data.put(magic)
        data.append(version)
        data.append(kind)
        var uuid = header.stream.sessionID.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        data.put(header.stream.transportEpoch)
        data.put(header.stream.codecEpoch)
        data.put(header.frameID)
        data.append(header.isIDR ? 1 : 0)
        return data
    }

    static func header(_ reader: inout ByteReader, kind: UInt8) throws -> MediaFrameHeader {
        let magic: UInt16 = try reader.take()
        let version: UInt8 = try reader.take()
        let receivedKind: UInt8 = try reader.take()
        guard magic == Self.magic, version == Self.version, receivedKind == kind else {
            throw DeskError.invalid("媒体协议或消息类型无效")
        }
        let bytes = [UInt8](try reader.bytes(16))
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let transport: UInt32 = try reader.take()
        let codec: UInt32 = try reader.take()
        let frame: UInt64 = try reader.take()
        let flags: UInt8 = try reader.take()
        guard flags <= 1 else { throw DeskError.invalid("媒体帧标志无效") }
        return MediaFrameHeader(stream: MediaStreamID(sessionID: uuid, transportEpoch: transport, codecEpoch: codec),
                                frameID: frame, isIDR: flags == 1)
    }
}

public struct MediaFrame: Sendable {
    // Leave room for the envelope and MessageKind in the existing TCP message limit.
    public static let maximumPacketBytes = Wire.maximumMessageBytes - MediaWire.headerBytes - 5
    public let header: MediaFrameHeader
    public let packet: VideoPacket
    let packetBytes: Data

    public init(header: MediaFrameHeader, packet: VideoPacket) throws {
        try self.init(header: header, packet: packet, packetBytes: packet.encode())
    }

    init(header: MediaFrameHeader, packetBytes: Data) throws {
        try self.init(header: header, packet: VideoPacket.decode(packetBytes), packetBytes: packetBytes)
    }

    private init(header: MediaFrameHeader, packet: VideoPacket, packetBytes: Data) throws {
        guard packetBytes.count <= Self.maximumPacketBytes else { throw DeskError.invalid("媒体帧超过协议上限") }
        let idr = try Self.containsIDR(packet.avcc, codec: packet.codec)
        guard header.isIDR == idr else { throw DeskError.invalid("媒体关键帧标志与视频内容不符") }
        if idr {
            switch packet.codec {
            case .h264:
                guard packet.sps.first.map({ $0 & 0x9F == 7 }) == true,
                      packet.pps.first.map({ $0 & 0x9F == 8 }) == true else {
                    throw DeskError.invalid("独立恢复帧缺少有效 SPS/PPS")
                }
            case .hevc:
                guard Self.hevcType(packet.vps) == 32, Self.hevcType(packet.sps) == 33, Self.hevcType(packet.pps) == 34 else {
                    throw DeskError.invalid("独立恢复帧缺少有效 VPS/SPS/PPS")
                }
            }
        } else if !packet.vps.isEmpty || !packet.sps.isEmpty || !packet.pps.isEmpty {
            throw DeskError.invalid("媒体格式变化必须以 IDR 开始")
        }
        self.header = header
        self.packet = packet
        self.packetBytes = packetBytes
    }

    // The NAL unit type of an HEVC parameter set, or nil without a valid two-byte header.
    private static func hevcType(_ unit: Data) -> UInt8? {
        guard unit.count >= 2, let first = unit.first, first & 0x80 == 0 else { return nil }
        return (first >> 1) & 0x3F
    }

    public func encode() throws -> Data {
        var data = MediaWire.begin(1, header: header)
        data.put(UInt32(packetBytes.count))
        data.append(packetBytes)
        return data
    }

    public static func decode(_ data: Data) throws -> MediaFrame {
        guard data.count < Wire.maximumMessageBytes else { throw DeskError.invalid("媒体帧过大") }
        var reader = ByteReader(data)
        let header = try MediaWire.header(&reader, kind: 1)
        let length: UInt32 = try reader.take()
        guard length > 0, length <= maximumPacketBytes, Int(length) == reader.remaining else {
            throw DeskError.invalid("媒体帧长度无效")
        }
        return try MediaFrame(header: header, packetBytes: reader.bytes(Int(length)))
    }

    public static func containsIDR(_ avcc: Data, codec: VideoCodec = .h264) throws -> Bool {
        var reader = ByteReader(avcc)
        var idr = false
        guard reader.remaining > 0 else { throw DeskError.invalid(codec == .hevc ? "空 HEVC 数据" : "空 H.264 数据") }
        while reader.remaining > 0 {
            let length: UInt32 = try reader.take()
            guard length > 0, length <= reader.remaining else {
                throw DeskError.invalid(codec == .hevc ? "HEVC NAL 长度无效" : "H.264 NAL 长度无效")
            }
            if codec == .hevc {
                guard length >= 2 else { throw DeskError.invalid("HEVC NAL 头无效") }
                let first: UInt8 = try reader.take(), second: UInt8 = try reader.take()
                guard first & 0x80 == 0, second & 0x07 != 0 else { throw DeskError.invalid("HEVC NAL 头无效") }
                // BLA, IDR and CRA pictures start decoding on their own; VideoToolbox's keyframes are IDR.
                if (16...21).contains((first >> 1) & 0x3F) { idr = true }
                try reader.skip(Int(length) - 2)
                continue
            }
            let nal: UInt8 = try reader.take()
            guard nal & 0x80 == 0, nal & 0x1F != 0 else { throw DeskError.invalid("H.264 NAL 头无效") }
            if nal & 0x1F == 5 {
                guard nal & 0x60 != 0 else { throw DeskError.invalid("IDR 参考标志无效") }
                idr = true
            }
            try reader.skip(Int(length) - 1)
        }
        return idr
    }
}

public struct MediaFragment: Equatable, Sendable {
    // This is the application record limit, before DTLS record overhead.
    public static let maximumDatagramBytes = 1_100
    public static let encodedHeaderBytes = MediaWire.headerBytes + 16
    public static let maximumPayloadBytes = maximumDatagramBytes - encodedHeaderBytes
    public let header: MediaFrameHeader
    public let packetSequence: UInt64
    public let frameBytes: Int
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let payload: Data

    public init(header: MediaFrameHeader, packetSequence: UInt64, frameBytes: Int,
                fragmentIndex: UInt16, fragmentCount: UInt16, payload: Data) throws {
        guard frameBytes > 0, frameBytes <= MediaFrame.maximumPacketBytes else {
            throw DeskError.invalid("媒体分片总长度无效")
        }
        let count = (frameBytes + Self.maximumPayloadBytes - 1) / Self.maximumPayloadBytes
        guard count <= Int(UInt16.max), Int(fragmentCount) == count, fragmentIndex < fragmentCount else {
            throw DeskError.invalid("媒体分片编号无效")
        }
        let expected = min(Self.maximumPayloadBytes, frameBytes - Int(fragmentIndex) * Self.maximumPayloadBytes)
        guard payload.count == expected else { throw DeskError.invalid("媒体分片长度无效") }
        self.header = header
        self.packetSequence = packetSequence
        self.frameBytes = frameBytes
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payload = payload
    }

    public func encode() -> Data {
        var data = MediaWire.begin(2, header: header)
        data.put(packetSequence)
        data.put(UInt32(frameBytes))
        data.put(fragmentIndex)
        data.put(fragmentCount)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> MediaFragment {
        guard data.count <= maximumDatagramBytes else { throw DeskError.invalid("媒体数据报过大") }
        var reader = ByteReader(data)
        let header = try MediaWire.header(&reader, kind: 2)
        let sequence: UInt64 = try reader.take()
        let frameBytes: UInt32 = try reader.take()
        let index: UInt16 = try reader.take()
        let count: UInt16 = try reader.take()
        return try MediaFragment(header: header, packetSequence: sequence, frameBytes: Int(frameBytes),
                                 fragmentIndex: index, fragmentCount: count, payload: reader.bytes(reader.remaining))
    }

    public static func fragment(frame: MediaFrame, startingPacketSequence: UInt64 = 1) throws -> [MediaFragment] {
        let data = frame.packetBytes
        let count = (data.count + maximumPayloadBytes - 1) / maximumPayloadBytes
        guard startingPacketSequence <= UInt64.max - UInt64(count - 1) else {
            throw DeskError.invalid("媒体包序号耗尽，需要新会话")
        }
        return try (0..<count).map { index in
            let start = index * maximumPayloadBytes
            let end = min(start + maximumPayloadBytes, data.count)
            return try MediaFragment(header: frame.header, packetSequence: startingPacketSequence + UInt64(index),
                                     frameBytes: data.count, fragmentIndex: UInt16(index), fragmentCount: UInt16(count),
                                     payload: data.subdata(in: start..<end))
        }
    }
}

public struct MediaFragmentRange: Equatable, Sendable {
    public let first: UInt16
    public let count: UInt16
    public init(first: UInt16, count: UInt16) { self.first = first; self.count = count }
}

public struct MediaFeedback: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case reassembled = 1, decoded, expired, nack }
    public static let maximumMissingRanges = 64
    public let kind: Kind
    public let header: MediaFrameHeader
    public let missingRanges: [MediaFragmentRange]

    public init(kind: Kind, header: MediaFrameHeader, missingRanges: [MediaFragmentRange] = []) throws {
        guard missingRanges.count <= Self.maximumMissingRanges,
              kind == .nack ? !missingRanges.isEmpty : missingRanges.isEmpty else {
            throw DeskError.invalid("媒体反馈范围无效")
        }
        var previousEnd = 0
        for range in missingRanges {
            let end = Int(range.first) + Int(range.count)
            guard range.count > 0, Int(range.first) >= previousEnd, end <= Int(UInt16.max) + 1 else {
                throw DeskError.invalid("媒体缺片范围重复或溢出")
            }
            previousEnd = end
        }
        self.kind = kind
        self.header = header
        self.missingRanges = missingRanges
    }

    public func encode() -> Data {
        var data = MediaWire.begin(3, header: header)
        data.append(kind.rawValue)
        data.append(UInt8(missingRanges.count))
        for range in missingRanges { data.put(range.first); data.put(range.count) }
        return data
    }

    public static func decode(_ data: Data) throws -> MediaFeedback {
        guard data.count <= MediaFragment.maximumDatagramBytes else { throw DeskError.invalid("媒体反馈过大") }
        var reader = ByteReader(data)
        let header = try MediaWire.header(&reader, kind: 3)
        let raw: UInt8 = try reader.take()
        let count: UInt8 = try reader.take()
        guard let kind = Kind(rawValue: raw), Int(count) <= maximumMissingRanges,
              reader.remaining == Int(count) * 4 else { throw DeskError.invalid("媒体反馈类型或长度无效") }
        var ranges: [MediaFragmentRange] = []
        for _ in 0..<count { ranges.append(try MediaFragmentRange(first: reader.take(), count: reader.take())) }
        return try MediaFeedback(kind: kind, header: header, missingRanges: ranges)
    }
}

public enum MediaDatagram: Sendable {
    case fragment(MediaFragment)
    case feedback(MediaFeedback)

    public func encode() -> Data {
        switch self {
        case .fragment(let fragment): return fragment.encode()
        case .feedback(let feedback): return feedback.encode()
        }
    }

    public static func decode(_ data: Data) throws -> MediaDatagram {
        guard data.count >= 4, data.count <= MediaFragment.maximumDatagramBytes else {
            throw DeskError.invalid("媒体数据报长度无效")
        }
        switch data[data.startIndex + 3] {
        case 2: return .fragment(try MediaFragment.decode(data))
        case 3: return .feedback(try MediaFeedback.decode(data))
        default: throw DeskError.invalid("未知媒体数据报类型")
        }
    }
}
