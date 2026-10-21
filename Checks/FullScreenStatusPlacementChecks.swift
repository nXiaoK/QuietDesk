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
}
