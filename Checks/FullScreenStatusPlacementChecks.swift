import CoreGraphics
import QuietDeskCore

func runFullScreenStatusPlacementChecks() {
    run("Full-screen status starts in the bottom-right corner and keeps its margin on any screen") {
        let status = CGSize(width: 150, height: 140)
        try check(FullScreenStatusPlacement.automaticOrigin(container: CGSize(width: 1728, height: 1117), status: status)
            == CGPoint(x: 1568, y: 967), "Automatic position is not the inset bottom-right corner")
        try check(FullScreenStatusPlacement.automaticOrigin(container: CGSize(width: 1512, height: 982), status: status)
            == CGPoint(x: 1352, y: 832), "Automatic position did not follow a smaller screen")
        try check(FullScreenStatusPlacement.automaticOrigin(container: CGSize(width: 155, height: 60), status: status) == .zero,
                  "A screen smaller than the status produced negative coordinates")
        try check(FullScreenStatusPlacement.automaticOrigin(container: CGSize(width: CGFloat.infinity, height: 600), status: status)
            == CGPoint(x: 0, y: 450), "Non-finite bounds produced a non-finite position")
        let automatic = FullScreenStatusPlacement.automaticOrigin(container: CGSize(width: 1200, height: 800), status: status)
        let normalized = FullScreenStatusPlacement.position(for: automatic, container: CGSize(width: 1200, height: 800), status: status)
        let restored = FullScreenStatusPlacement.origin(for: normalized, container: CGSize(width: 1200, height: 800), status: status)
        try check(abs(restored.x - automatic.x) < 0.001 && abs(restored.y - automatic.y) < 0.001,
                  "The automatic position moved when the overlay normalized it")
    }
    run("Dragged status positions stay inside the screen and adapt to a different screen or status width") {
        let container = CGSize(width: 1200, height: 800), status = CGSize(width: 600, height: 24)
        let position = FullScreenStatusPlacement.position(for: CGPoint(x: 300, y: 388), container: container, status: status)
        try check(position == CGPoint(x: 0.5, y: 0.5), "Position did not use the available travel")
        try check(FullScreenStatusPlacement.origin(for: position, container: CGSize(width: 800, height: 600),
            status: CGSize(width: 700, height: 40)) == CGPoint(x: 50, y: 280), "Saved position did not adapt to new bounds")
        try check(FullScreenStatusPlacement.position(for: CGPoint(x: -20, y: 900), container: container, status: status)
            == CGPoint(x: 0, y: 1), "Dragging beyond the screen was not clamped")
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: container, status: status)
            == CGPoint(x: 600, y: 776), "Status could leave the bottom or trailing edge")
    }
    run("Status placement handles unavailable bounds and starts with a 60% transparent background") {
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: .zero,
            status: CGSize(width: 600, height: 24)) == .zero, "Oversized status generated negative coordinates")
        try check(FullScreenStatusPlacement.position(for: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            container: CGSize(width: 800, height: 600), status: .zero) == .zero, "Invalid coordinates were retained")
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: CGSize(width: CGFloat.infinity, height: 0),
            status: .zero) == .zero, "Invalid geometry generated non-finite coordinates")
        try check(FullScreenStatusPlacement.defaultBackgroundOpacity == 0.4, "Status background does not start 60% transparent")
    }
}
