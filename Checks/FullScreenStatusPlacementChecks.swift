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
    run("Status placement handles unavailable bounds and draws its text opaque by default") {
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: .zero,
            status: CGSize(width: 600, height: 24)) == .zero, "Oversized status generated negative coordinates")
        try check(FullScreenStatusPlacement.position(for: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            container: CGSize(width: 800, height: 600), status: .zero) == .zero, "Invalid coordinates were retained")
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: CGSize(width: CGFloat.infinity, height: 0),
            status: .zero) == .zero, "Invalid geometry generated non-finite coordinates")
        try check(FullScreenStatusPlacement.defaultOpacity == 1, "Text-only status is translucent by default")
    }
    run("Status text turns dark over bright content and light over dark content without flickering") {
        var contrast = FullScreenStatusContrast()
        try check(!contrast.darkText && !contrast.observe(nil), "No picture changed the initial light text")
        try check(contrast.observe(0.9) && contrast.darkText, "The first bright sample did not choose dark text at once")
        try check(!contrast.observe(0.1) && contrast.darkText, "One dark video frame flipped the colour")
        try check(!contrast.observe(0.8) && !contrast.observe(0.1) && contrast.darkText,
                  "A bright sample between dark ones did not restart the confirmation")
        try check(contrast.observe(0.1) && !contrast.darkText, "Two dark samples in a row kept dark text")
        for value in [0.45, 0.5, 0.55, 0.57, 0.5, 0.43] {
            try check(!contrast.observe(value) && !contrast.darkText, "Mid-grey content \(value) flipped light text")
        }
        try check(!contrast.observe(0.58) && contrast.observe(0.6) && contrast.darkText, "The bright threshold did not switch")
        for value in [0.55, 0.5, 0.45, 0.43, 0.5] {
            try check(!contrast.observe(value) && contrast.darkText, "Mid-grey content \(value) flipped dark text")
        }
        try check(!contrast.observe(.nan) && !contrast.observe(-1) && contrast.observe(-2) && !contrast.darkText,
                  "Out-of-range samples were not clamped or a non-finite sample counted")
        var dark = FullScreenStatusContrast()
        try check(!dark.observe(0.2) && !dark.darkText, "The first dark sample changed light text")
    }
    run("Status sampling maps the screen rectangle onto the fitted picture and counts the black bands") {
        // A 3456 × 2234 picture fills a 1728 × 1117 screen at half scale.
        let full = FullScreenStatusContrast.samplePoints(status: CGRect(x: 1568, y: 967, width: 150, height: 140),
            container: CGSize(width: 1728, height: 1117), picture: (3456, 2234), columns: 2, rows: 2)
        try check(full.outside == 0 && full.pixels.map(\.x) == [3211, 3361, 3211, 3361]
            && full.pixels.map(\.y) == [2004, 2004, 2144, 2144], "Picture pixels under the status are wrong: \(full.pixels)")
        // A 16:9 picture on the same screen leaves 72-point bands above and below.
        let banded = FullScreenStatusContrast.samplePoints(status: CGRect(x: 1600, y: 1000, width: 100, height: 100),
            container: CGSize(width: 1728, height: 1117), picture: (1920, 1080), columns: 4, rows: 4)
        try check(banded.pixels.count == 8 && banded.outside == 8 && banded.pixels.allSatisfy { $0.y < 1080 && $0.x < 1920 },
                  "The bottom band was not counted as black: \(banded)")
        let defaults = FullScreenStatusContrast.samplePoints(status: CGRect(x: 10, y: 10, width: 50, height: 50),
            container: CGSize(width: 800, height: 600), picture: (800, 600))
        try check(defaults.pixels.count == 48 && defaults.outside == 0, "The default grid did not sample 8 × 6 points")
        for (status, container, picture) in [(CGRect(x: 0, y: 0, width: 0, height: 10), CGSize(width: 800, height: 600), (800, 600)),
                                              (CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGSize(width: 800, height: 600), (800, 600)),
                                              (CGRect(x: 0, y: 0, width: 10, height: 10), CGSize.zero, (800, 600)),
                                              (CGRect(x: 0, y: 0, width: 10, height: 10), CGSize(width: 800, height: 600), (0, 600))] {
            let empty = FullScreenStatusContrast.samplePoints(status: status, container: container, picture: picture)
            try check(empty.pixels.isEmpty && empty.outside == 0, "Invalid geometry produced samples")
        }
    }
}
