import Foundation

public struct DisplaySnapshot: Equatable, Sendable {
    public let id: UInt32
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bounds: CGRect

    public init(id: UInt32, pixelWidth: Int, pixelHeight: Int, bounds: CGRect) {
        self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.bounds = bounds
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
