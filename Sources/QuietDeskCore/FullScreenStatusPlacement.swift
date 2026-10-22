import CoreGraphics

/// Where the full-screen connection status goes. The remote picture is fitted inside the screen,
/// so a different aspect ratio leaves black bands that belong to no remote content; the status sits
/// there when a band is large enough, and otherwise stays over the picture, drawn translucent.
public enum FullScreenStatusPlacement: Equatable, Sendable {
    /// In the band above the picture, which is `height` points tall.
    case topBand(height: CGFloat)
    /// In the band left of the picture, which is `width` points wide; the items stack vertically.
    case leadingBand(width: CGFloat)
    /// Over the picture.
    case overlay

    /// Smallest band height that holds one status row.
    public static let rowHeight: CGFloat = 26
    /// Smallest band width that holds the stacked items.
    public static let columnWidth: CGFloat = 140

    public var defaultOpacity: Double { self == .overlay ? 0.6 : 1 }

    /// Manual positions use the available travel, so a saved position stays visible on another screen.
    public static func origin(for position: CGPoint, container: CGSize, status: CGSize) -> CGPoint {
        let travel = travel(container: container, status: status)
        return CGPoint(x: unit(position.x) * travel.width, y: unit(position.y) * travel.height)
    }

    public static func position(for origin: CGPoint, container: CGSize, status: CGSize) -> CGPoint {
        let travel = travel(container: container, status: status)
        return CGPoint(x: travel.width > 0 ? unit(origin.x / travel.width) : 0,
                       y: travel.height > 0 ? unit(origin.y / travel.height) : 0)
    }

    private static func travel(container: CGSize, status: CGSize) -> CGSize {
        CGSize(width: container.width.isFinite && status.width.isFinite ? max(0, container.width - status.width) : 0,
               height: container.height.isFinite && status.height.isFinite ? max(0, container.height - status.height) : 0)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0 }

    /// `picture` is the remote frame size in any unit; only its aspect ratio matters.
    public static func choose(container: CGSize, picture: CGSize) -> FullScreenStatusPlacement {
        guard container.width > 0, container.height > 0, picture.width > 0, picture.height > 0,
              container.width.isFinite, container.height.isFinite, picture.width.isFinite, picture.height.isFinite else {
            return .overlay
        }
        let scale = min(container.width / picture.width, container.height / picture.height)
        let band = ((container.height - picture.height * scale) / 2).rounded(.down)
        if band >= rowHeight { return .topBand(height: band) }
        let side = ((container.width - picture.width * scale) / 2).rounded(.down)
        if side >= columnWidth { return .leadingBand(width: side) }
        return .overlay
    }
}
