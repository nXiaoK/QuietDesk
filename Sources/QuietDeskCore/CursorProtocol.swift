import Foundation

public struct CursorStreamBinding: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let transportEpoch: UInt32
    public let codecEpoch: UInt32
    public init(_ stream: MediaStreamID) {
        sessionID = stream.sessionID; transportEpoch = stream.transportEpoch; codecEpoch = stream.codecEpoch
    }
    public var stream: MediaStreamID { .init(sessionID: sessionID, transportEpoch: transportEpoch, codecEpoch: codecEpoch) }
}

public struct CursorControl: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case request, status, binding }
    public enum Reason: String, Codable, Sendable { case unavailable, waitingForResume }
    public let operation: Operation
    public let requestID: UUID?
    public let cursorID: UUID?
    public let epoch: UInt32?
    public let enabled: Bool
    public let stream: CursorStreamBinding?
    public let reason: Reason?
    public init(_ operation: Operation, requestID: UUID? = nil, cursorID: UUID? = nil, epoch: UInt32? = nil,
                enabled: Bool, stream: MediaStreamID? = nil, reason: Reason? = nil) {
        self.operation = operation; self.requestID = requestID; self.cursorID = cursorID; self.epoch = epoch
        self.enabled = enabled; self.stream = stream.map(CursorStreamBinding.init); self.reason = reason
    }
    public func validate() throws {
        switch operation {
        case .request:
            guard requestID != nil, cursorID == nil, epoch == nil, stream == nil, reason == nil else {
                throw DeskError.invalid("光标请求无效")
            }
        case .status:
            guard requestID != nil, cursorID != nil, let epoch, epoch > 0, stream == nil else {
                throw DeskError.invalid("光标状态无效")
            }
        case .binding:
            guard requestID == nil, cursorID != nil, let epoch, epoch > 0, let stream,
                  stream.transportEpoch > 0, stream.codecEpoch > 0, reason == nil else {
                throw DeskError.invalid("光标画面绑定无效")
            }
        }
    }
    public func message() throws -> Message { try validate(); return try Wire.json(.cursorControl, self) }
    public static func read(_ payload: Data) throws -> Self {
        let value = try Wire.readJSON(Self.self, payload); try value.validate(); return value
    }
}

public struct CursorImage: Equatable, Sendable {
    public static let maximumBytes = 256 * 1024
    public let png: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let hotSpotX: Double
    public let hotSpotY: Double
    public init(png: Data, pixelWidth: Int, pixelHeight: Int, logicalWidth: Double, logicalHeight: Double,
                hotSpotX: Double, hotSpotY: Double) throws {
        guard (33...Self.maximumBytes).contains(png.count), (1...256).contains(pixelWidth), (1...256).contains(pixelHeight),
              logicalWidth.isFinite, logicalHeight.isFinite, (0.5...256).contains(logicalWidth), (0.5...256).contains(logicalHeight),
              hotSpotX.isFinite, hotSpotY.isFinite, (0...logicalWidth).contains(hotSpotX), (0...logicalHeight).contains(hotSpotY),
              png.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw DeskError.invalid("光标图片参数无效") }
        var reader = ByteReader(Data(png.dropFirst(8)))
        let length: UInt32 = try reader.take()
        guard length == 13, try reader.bytes(4) == Data("IHDR".utf8),
              try reader.take() as UInt32 == UInt32(pixelWidth), try reader.take() as UInt32 == UInt32(pixelHeight) else {
            throw DeskError.invalid("光标 PNG 尺寸不一致")
        }
        self.png = png; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth; self.logicalHeight = logicalHeight; self.hotSpotX = hotSpotX; self.hotSpotY = hotSpotY
    }
}

private enum CursorWire {
    static func begin(kind: UInt8, id: UUID, epoch: UInt32, sequence: UInt64) -> Data {
        var data = Data([0x43,0x55,1,kind])
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        data.put(epoch); data.put(sequence)
        return data
    }
    static func header(_ reader: inout ByteReader, kind: UInt8) throws -> (UUID, UInt32, UInt64) {
        guard try reader.bytes(4) == Data([0x43,0x55,1,kind]) else { throw DeskError.invalid("光标协议头无效") }
        let b = Array(try reader.bytes(16))
        let id = UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        let epoch: UInt32 = try reader.take(), sequence: UInt64 = try reader.take()
        guard epoch > 0, sequence > 0 else { throw DeskError.invalid("光标代次无效") }
        return (id, epoch, sequence)
    }
}

public struct CursorShape: Sendable {
    public let cursorID: UUID
    public let epoch: UInt32
    public let revision: UInt64
    public let image: CursorImage?
    public init(cursorID: UUID, epoch: UInt32, revision: UInt64, image: CursorImage?) throws {
        guard epoch > 0, revision > 0 else { throw DeskError.invalid("光标形状代次无效") }
        self.cursorID = cursorID; self.epoch = epoch; self.revision = revision; self.image = image
    }
    public func encode() -> Data {
        var data = CursorWire.begin(kind: 1, id: cursorID, epoch: epoch, sequence: revision)
        data.append(image == nil ? 0 : 1)
        if let image {
            data.put(UInt16(image.pixelWidth)); data.put(UInt16(image.pixelHeight))
            for value in [image.logicalWidth, image.logicalHeight, image.hotSpotX, image.hotSpotY] { data.put(value.bitPattern) }
            data.put(UInt32(image.png.count)); data.append(image.png)
        }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= CursorImage.maximumBytes + 80 else { throw DeskError.invalid("光标形状消息过大") }
        var reader = ByteReader(data)
        let (id, epoch, revision) = try CursorWire.header(&reader, kind: 1)
        let known: UInt8 = try reader.take()
        guard known <= 1 else { throw DeskError.invalid("光标形状标记无效") }
        var image: CursorImage?
        if known == 1 {
            let width: UInt16 = try reader.take(), height: UInt16 = try reader.take()
            let w = Double(bitPattern: try reader.take()), h = Double(bitPattern: try reader.take())
            let x = Double(bitPattern: try reader.take()), y = Double(bitPattern: try reader.take())
            let length: UInt32 = try reader.take()
            guard length <= CursorImage.maximumBytes, reader.remaining == Int(length) else { throw DeskError.invalid("光标图片长度无效") }
            image = try CursorImage(png: reader.bytes(Int(length)), pixelWidth: Int(width), pixelHeight: Int(height),
                                    logicalWidth: w, logicalHeight: h, hotSpotX: x, hotSpotY: y)
        }
        guard reader.remaining == 0 else { throw DeskError.invalid("光标形状有多余数据") }
        return try Self(cursorID: id, epoch: epoch, revision: revision, image: image)
    }
}

public struct CursorPosition: Sendable {
    public let cursorID: UUID
    public let epoch: UInt32
    public let sequence: UInt64
    public let insideDisplay: Bool
    public let x: Double
    public let y: Double
    public init(cursorID: UUID, epoch: UInt32, sequence: UInt64, insideDisplay: Bool, x: Double, y: Double) throws {
        guard epoch > 0, sequence > 0, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DeskError.invalid("光标位置无效")
        }
        self.cursorID = cursorID; self.epoch = epoch; self.sequence = sequence
        self.insideDisplay = insideDisplay; self.x = x; self.y = y
    }
    public func encode() -> Data {
        var data = CursorWire.begin(kind: 2, id: cursorID, epoch: epoch, sequence: sequence)
        data.append(insideDisplay ? 1 : 0); data.put(x.bitPattern); data.put(y.bitPattern)
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count == 49 else { throw DeskError.invalid("光标位置长度无效") }
        var reader = ByteReader(data)
        let (id, epoch, sequence) = try CursorWire.header(&reader, kind: 2)
        let inside: UInt8 = try reader.take()
        guard inside <= 1 else { throw DeskError.invalid("光标位置标记无效") }
        return try Self(cursorID: id, epoch: epoch, sequence: sequence, insideDisplay: inside == 1,
                        x: Double(bitPattern: reader.take()), y: Double(bitPattern: reader.take()))
    }
}

public struct CursorPresentationState {
    public private(set) var cursorID: UUID?
    public private(set) var epoch: UInt32 = 0
    public private(set) var enabled = false
    public private(set) var image: CursorImage?
    public private(set) var position: CursorPosition?
    private var revision: UInt64 = 0
    private var committedStream: MediaStreamID?
    private var bindings: [MediaStreamID: (epoch: UInt32, enabled: Bool)] = [:]
    public init() {}
    public mutating func status(_ control: CursorControl) -> Bool {
        guard control.operation == .status, let id = control.cursorID, let incoming = control.epoch,
              cursorID == nil || cursorID == id, incoming > epoch else { return false }
        cursorID = id; epoch = incoming; revision = 0; image = nil; position = nil
        return true
    }
    public mutating func bind(_ control: CursorControl) -> Bool {
        guard control.operation == .binding, control.cursorID == cursorID, control.epoch == epoch,
              let stream = control.stream?.stream else { return false }
        if let committedStream, !Self.isNewer(stream, than: committedStream) { return false }
        if bindings.count >= 3, bindings[stream] == nil { bindings.removeAll() }
        bindings[stream] = (epoch, control.enabled)
        return true
    }
    @discardableResult
    public mutating func commit(_ stream: MediaStreamID) -> Bool {
        if let committedStream, !Self.isNewer(stream, than: committedStream) { return false }
        guard let binding = bindings.removeValue(forKey: stream), binding.epoch == epoch else { return false }
        committedStream = stream
        enabled = binding.enabled
        bindings = bindings.filter { Self.isNewer($0.key, than: stream) }
        return true
    }
    @discardableResult
    public mutating func update(_ shape: CursorShape) -> Bool {
        guard shape.cursorID == cursorID, shape.epoch == epoch, shape.revision > revision else { return false }
        revision = shape.revision; image = shape.image
        return true
    }
    @discardableResult
    public mutating func update(_ value: CursorPosition) -> Bool {
        guard value.cursorID == cursorID, value.epoch == epoch,
              position.map({ value.sequence > $0.sequence }) ?? true else { return false }
        position = value
        return true
    }
    private static func isNewer(_ candidate: MediaStreamID, than current: MediaStreamID) -> Bool {
        candidate.sessionID == current.sessionID && (candidate.transportEpoch > current.transportEpoch
            || candidate.transportEpoch == current.transportEpoch && candidate.codecEpoch > current.codecEpoch)
    }
}
