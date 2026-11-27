import CoreGraphics

/// Sizes the area of a session window that shows the remote picture so that the picture fills it.
public enum WindowAspectFit {
    public enum Change: Equatable, Sendable {
        /// The picture's shape became known or changed: the width stays and the height follows, so that
        /// screens of different shapes shown in turn do not shrink the window step by step.
        case keepingWidth
        /// The viewer dragged the area from this size. A drag along one axis sets the other axis from it,
        /// growing or shrinking; a drag along both keeps the picture inside what was dragged.
        case dragged(from: CGSize)
    }

    /// The size the picture area should take, in whole points: of `aspect` (width over height), not below
    /// `minimum` and not above `maximum`. A size of that shape larger than `maximum` is scaled down to it;
    /// one smaller than `minimum` on an axis takes the minimum there, and the picture keeps bars.
    public static func area(_ current: CGSize, aspect: CGFloat, change: Change, minimum: CGSize, maximum: CGSize) -> CGSize {
        guard aspect.isFinite, aspect > 0, current.width > 0, current.height > 0,
              current.width.isFinite, current.height.isFinite else { return current }
        func inside(_ box: CGSize) -> CGSize {
            box.width / box.height > aspect ? CGSize(width: box.height * aspect, height: box.height)
                : CGSize(width: box.width, height: box.width / aspect)
        }
        var target: CGSize
        switch change {
        case .keepingWidth: target = CGSize(width: current.width, height: current.width / aspect)
        case .dragged(let old):
            let widthMoved = abs(current.width - old.width) >= 1, heightMoved = abs(current.height - old.height) >= 1
            if widthMoved && !heightMoved { target = CGSize(width: current.width, height: current.width / aspect) }
            else if heightMoved && !widthMoved { target = CGSize(width: current.height * aspect, height: current.height) }
            else { target = inside(current) }
        }
        let floor = CGSize(width: max(1, minimum.width), height: max(1, minimum.height))
        let ceiling = CGSize(width: max(floor.width, maximum.width), height: max(floor.height, maximum.height))
        if target.width > ceiling.width || target.height > ceiling.height { target = inside(ceiling) }
        // Below the smallest window the shape gives way on that axis: the picture keeps bars there, rather
        // than the window growing against the drag that made it small.
        target = CGSize(width: min(max(target.width, floor.width), ceiling.width), height: min(max(target.height, floor.height), ceiling.height))
        return CGSize(width: target.width.rounded(), height: target.height.rounded())
    }

    /// Whether an area shows a picture of `aspect` with bars thinner than `tolerance` points in all. Sizes
    /// of one screen at different scales differ by a fraction of a point; those must not move the window.
    public static func fills(_ area: CGSize, aspect: CGFloat, tolerance: CGFloat = 2) -> Bool {
        guard aspect.isFinite, aspect > 0, area.width > 0, area.height > 0 else { return true }
        return abs(area.width - area.height * aspect) < tolerance || abs(area.height - area.width / aspect) < tolerance
    }

    /// The window frame, in AppKit's coordinates with the origin at the bottom-left, whose picture area is
    /// `target` instead of `area`. The edges a drag left where they were in `before` stay; without a drag
    /// the top-left corner does. An edge that was on `screen` and would grow off it is held at the screen's
    /// edge instead; a window that already reached past the screen is not pulled back.
    public static func frame(_ frame: CGRect, before: CGRect? = nil, area: CGSize, target: CGSize, screen: CGRect) -> CGRect {
        let size = CGSize(width: frame.width + target.width - area.width, height: frame.height + target.height - area.height)
        guard size.width > 0, size.height > 0 else { return frame }
        var origin = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        if let before {
            // The left edge was dragged and the right one was not: the right edge is the one to keep.
            if abs(frame.minX - before.minX) >= 1, abs(frame.maxX - before.maxX) < 1 { origin.x = frame.maxX - size.width }
            // The top edge was dragged and the bottom one was not.
            if abs(frame.maxY - before.maxY) >= 1, abs(frame.minY - before.minY) < 1 { origin.y = frame.minY }
        }
        if size.width <= screen.width {
            if origin.x + size.width > screen.maxX, frame.maxX <= screen.maxX { origin.x = screen.maxX - size.width }
            if origin.x < screen.minX, frame.minX >= screen.minX { origin.x = screen.minX }
        }
        if size.height <= screen.height {
            if origin.y < screen.minY, frame.minY >= screen.minY { origin.y = screen.minY }
            if origin.y + size.height > screen.maxY, frame.maxY <= screen.maxY { origin.y = screen.maxY - size.height }
        }
        return CGRect(origin: origin, size: size)
    }
}
