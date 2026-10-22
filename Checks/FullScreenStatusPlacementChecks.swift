import CoreGraphics
import QuietDeskCore

func runFullScreenStatusPlacementChecks() {
    run("Full-screen status goes to a letterbox or pillarbox band and stays over the picture otherwise") {
        // A 16:9 picture on a 16:10 screen leaves bands above and below.
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 1728, height: 1117),
            picture: CGSize(width: 1920, height: 1080)) == .topBand(height: 72), "Letterbox band not used")
        // A portrait display on a 16:10 screen leaves wide bands at the sides.
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 1728, height: 1117),
            picture: CGSize(width: 1080, height: 1920)) == .leadingBand(width: 549), "Pillarbox band not used")
        // A 4:3 picture leaves side bands too narrow for the stacked items.
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 1728, height: 1117),
            picture: CGSize(width: 1600, height: 1200)) == .overlay, "Status squeezed into a narrow side band")
        // Matching aspect ratios leave no room outside the picture.
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 1728, height: 1117),
            picture: CGSize(width: 3456, height: 2234)) == .overlay, "Status placed outside a full picture")
        // A band thinner than one row is not used.
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 1512, height: 982),
            picture: CGSize(width: 1920, height: 1200)) == .overlay, "Status squeezed into a thin band")
        try check(FullScreenStatusPlacement.choose(container: .zero, picture: CGSize(width: 16, height: 9)) == .overlay,
                  "Empty container placed the status in a band")
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 800, height: 600), picture: .zero) == .overlay,
                  "Unknown picture size placed the status in a band")
        try check(FullScreenStatusPlacement.choose(container: CGSize(width: 800, height: CGFloat.infinity),
            picture: CGSize(width: 16, height: 9)) == .overlay, "Non-finite size placed the status in a band")
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
    run("Status placement handles unavailable bounds and keeps the original default opacity") {
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: .zero,
            status: CGSize(width: 600, height: 24)) == .zero, "Oversized status generated negative coordinates")
        try check(FullScreenStatusPlacement.position(for: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            container: CGSize(width: 800, height: 600), status: .zero) == .zero, "Invalid coordinates were retained")
        try check(FullScreenStatusPlacement.origin(for: CGPoint(x: 1, y: 1), container: CGSize(width: CGFloat.infinity, height: 0),
            status: .zero) == .zero, "Invalid geometry generated non-finite coordinates")
        try check(FullScreenStatusPlacement.overlay.defaultOpacity == 0.6
            && FullScreenStatusPlacement.topBand(height: 30).defaultOpacity == 1
            && FullScreenStatusPlacement.leadingBand(width: 200).defaultOpacity == 1, "Default opacity changed")
    }
}
