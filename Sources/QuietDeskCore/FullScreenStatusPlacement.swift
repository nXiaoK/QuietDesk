import CoreGraphics

/// Where the full-screen connection status goes: a vertical list in the bottom-right corner,
/// or wherever the viewer dragged it, kept inside the current screen.
public enum FullScreenStatusPlacement {
    /// Distance of the automatic position from the trailing and bottom edges.
    public static let margin: CGFloat = 10
    /// The status is text only, drawn opaque until the viewer picks another opacity.
    public static let defaultOpacity = 1.0

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

/// Text colour of the full-screen status, from the brightness of the remote picture behind it:
/// light text over dark content, dark text over light content.
public struct FullScreenStatusContrast: Equatable, Sendable {
    /// After the first decision, dark text needs a background at least this bright, and light text
    /// returns at or below `lightTextAtMost`; the gap keeps mid-grey content from flipping the colour.
    public static let darkTextAtLeast = 0.58
    public static let lightTextAtMost = 0.42
    /// Samples in a row needed to switch, so one bright or dark video frame does not flip the colour.
    public static let confirmations = 2

    public private(set) var darkText = false
    private var decided = false
    private var pending = 0

    public init() {}

    /// `luminance` runs from 0 (black) to 1 (white); nil, with no picture to read, keeps the colour.
    /// Returns whether the colour changed.
    @discardableResult
    public mutating func observe(_ luminance: Double?) -> Bool {
        guard let luminance, luminance.isFinite else { pending = 0; return false }
        let value = min(1, max(0, luminance))
        guard decided else {
            decided = true
            darkText = value >= 0.5
            return darkText
        }
        guard darkText ? value <= Self.lightTextAtMost : value >= Self.darkTextAtLeast else { pending = 0; return false }
        pending += 1
        guard pending >= Self.confirmations else { return false }
        pending = 0
        darkText.toggle()
        return true
    }

    /// Picture pixels under `status` (container coordinates, origin top-left) on a `columns` × `rows` grid.
    /// The picture is aspect-fitted and centred in `container`; grid points outside it lie on the black bands.
    public static func samplePoints(status: CGRect, container: CGSize, picture: (width: Int, height: Int),
                                    columns: Int = 8, rows: Int = 6) -> (pixels: [(x: Int, y: Int)], outside: Int) {
        guard columns > 0, rows > 0, picture.width > 0, picture.height > 0,
              container.width > 0, container.height > 0, container.width.isFinite, container.height.isFinite,
              status.width > 0, status.height > 0,
              [status.minX, status.minY, status.width, status.height].allSatisfy(\.isFinite) else { return ([], 0) }
        let width = CGFloat(picture.width), height = CGFloat(picture.height)
        let scale = min(container.width / width, container.height / height)
        let left = (container.width - width * scale) / 2, top = (container.height - height * scale) / 2
        var pixels: [(x: Int, y: Int)] = [], outside = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let x = (status.minX + (CGFloat(column) + 0.5) * status.width / CGFloat(columns) - left) / scale
                let y = (status.minY + (CGFloat(row) + 0.5) * status.height / CGFloat(rows) - top) / scale
                if x >= 0, y >= 0, x < width, y < height { pixels.append((Int(x), Int(y))) } else { outside += 1 }
            }
        }
        return (pixels, outside)
    }
}
