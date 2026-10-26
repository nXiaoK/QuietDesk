import CoreGraphics

/// Where the full-screen connection status goes: a vertical list in the bottom-right corner,
/// or wherever the viewer dragged it, kept inside the current screen.
public enum FullScreenStatusPlacement {
    /// Distance of the automatic position from the trailing and bottom edges.
    public static let margin: CGFloat = 10
    /// The black background behind the white text starts 60% transparent, like the style the status follows,
    /// until the viewer picks another transparency.
    public static let defaultBackgroundOpacity = 0.4

    /// The automatic position: the bottom-right corner, inset by `margin`.
    public static func automaticOrigin(container: CGSize, status: CGSize) -> CGPoint {
        let travel = travel(container: container, status: status)
        return CGPoint(x: max(0, travel.width - margin), y: max(0, travel.height - margin))
    }

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
}
