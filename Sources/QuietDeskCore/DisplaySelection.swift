import Foundation

public struct DisplaySnapshot: Equatable, Sendable {
    public let id: UInt32
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bounds: CGRect

    public init(id: UInt32, pixelWidth: Int, pixelHeight: Int, bounds: CGRect) {
        self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.bounds = bounds
    }

    public static func capturePixelDimensions(contentSize: CGSize, pointPixelScale: CGFloat,
                                               fallbackWidth: Int, fallbackHeight: Int) -> (width: Int, height: Int) {
        guard pointPixelScale.isFinite, pointPixelScale > 0,
              let width = Int(exactly: (contentSize.width * pointPixelScale).rounded()),
              let height = Int(exactly: (contentSize.height * pointPixelScale).rounded()),
              width > 0, height > 0 else { return (fallbackWidth, fallbackHeight) }
        return (width, height)
    }

    fileprivate var isAvailable: Bool {
        id != 0 && pixelWidth > 0 && pixelHeight > 0
            && bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }
}

public enum DisplaySelection {
    public static func select(preferred: UInt32, main: UInt32, available: [DisplaySnapshot]) -> DisplaySnapshot? {
        let usable = available.filter(\.isAvailable)
        return usable.first(where: { $0.id == preferred })
            ?? usable.first(where: { $0.id == main })
            ?? usable.first
    }

    public static func requiresRestart(captured: DisplaySnapshot, available: [DisplaySnapshot]) -> Bool {
        available.first(where: { $0.id == captured.id && $0.isAvailable }) != captured
    }
}

public struct RemoteDisplayInfo: Codable, Equatable, Identifiable, Sendable {
    public static let maximumNameLength = 96
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public let isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id
        self.name = String(name.prefix(Self.maximumNameLength))
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    public var summary: String {
        let primary = isMain ? "（主屏）" : ""
        return "\(name)\(primary) · \(width)×\(height)"
    }

    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != 0,
              !trimmed.isEmpty,
              name.count <= Self.maximumNameLength,
              (2...16_384).contains(width),
              (2...16_384).contains(height) else {
            throw DeskError.invalid("远端显示器信息无效")
        }
    }

    public static func validateList(_ displays: [RemoteDisplayInfo], selectedDisplayID: UInt32?) throws {
        guard (1...DisplayControl.maximumDisplays).contains(displays.count) else {
            throw DeskError.invalid("远端显示器列表数量无效")
        }
        var seen = Set<UInt32>()
        for display in displays {
            try display.validate()
            guard seen.insert(display.id).inserted else {
                throw DeskError.invalid("远端显示器列表包含重复标识")
            }
        }
        if let selectedDisplayID {
            guard seen.contains(selectedDisplayID) else {
                throw DeskError.invalid("当前共享显示器不在可用列表中")
            }
        }
    }
}

public struct DisplayControl: Codable, Equatable, Sendable {
    public static let maximumDisplays = 16
    public enum Operation: String, Codable, Equatable, Sendable {
        case subscribe
        case state
        case select
        case result
    }

    public let operation: Operation
    public let id: UUID?
    public let displayID: UInt32?
    public let selectedDisplayID: UInt32?
    public let displays: [RemoteDisplayInfo]?
    public let videoState: VideoStreamState?
    public let error: String?

    private init(operation: Operation, id: UUID? = nil, displayID: UInt32? = nil, selectedDisplayID: UInt32? = nil,
                 displays: [RemoteDisplayInfo]? = nil, videoState: VideoStreamState? = nil, error: String? = nil) {
        self.operation = operation
        self.id = id
        self.displayID = displayID
        self.selectedDisplayID = selectedDisplayID
        self.displays = displays
        self.videoState = videoState
        self.error = error
    }

    public static func subscribe() -> DisplayControl {
        DisplayControl(operation: .subscribe)
    }

    public static func state(displays: [RemoteDisplayInfo], selectedDisplayID: UInt32,
                             videoState: VideoStreamState? = nil) -> DisplayControl {
        DisplayControl(operation: .state, selectedDisplayID: selectedDisplayID, displays: displays, videoState: videoState)
    }

    public static func select(id: UUID = UUID(), displayID: UInt32) -> DisplayControl {
        DisplayControl(operation: .select, id: id, displayID: displayID)
    }

    public static func result(id: UUID, selectedDisplayID: UInt32, displays: [RemoteDisplayInfo],
                              videoState: VideoStreamState, error: String? = nil) -> DisplayControl {
        DisplayControl(operation: .result, id: id, selectedDisplayID: selectedDisplayID,
                       displays: displays, videoState: videoState, error: error)
    }

    public func validate() throws {
        if let error, error.count > 512 {
            throw DeskError.invalid("显示器切换错误信息过长")
        }
        switch operation {
        case .subscribe:
            guard id == nil, displayID == nil, selectedDisplayID == nil,
                  displays == nil, videoState == nil, error == nil else {
                throw DeskError.invalid("显示器订阅消息字段无效")
            }
        case .state:
            guard id == nil, displayID == nil, error == nil,
                  let displays, let selectedDisplayID else {
                throw DeskError.invalid("显示器状态更新消息字段无效")
            }
            try RemoteDisplayInfo.validateList(displays, selectedDisplayID: selectedDisplayID)
            if let videoState { try videoState.validate() }
        case .select:
            guard id != nil, let displayID, displayID != 0,
                  selectedDisplayID == nil, displays == nil, videoState == nil, error == nil else {
                throw DeskError.invalid("显示器切换请求字段无效")
            }
        case .result:
            guard id != nil, displayID == nil,
                  let selectedDisplayID, let displays, let videoState else {
                throw DeskError.invalid("显示器切换结果字段无效")
            }
            try RemoteDisplayInfo.validateList(displays, selectedDisplayID: selectedDisplayID)
            try videoState.validate()
        }
    }

    public func message() throws -> Message {
        try validate()
        return try Wire.json(.displayControl, self)
    }

    public static func read(_ payload: Data) throws -> DisplayControl {
        let decoded = try Wire.readJSON(DisplayControl.self, payload)
        try decoded.validate()
        return decoded
    }
}
