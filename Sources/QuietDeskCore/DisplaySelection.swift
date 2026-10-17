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
