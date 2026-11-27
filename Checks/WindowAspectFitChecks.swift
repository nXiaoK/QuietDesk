import CoreGraphics
import Foundation
import QuietDeskCore

func runWindowAspectFitChecks() {
    let minimum = CGSize(width: 720, height: 490), screen = CGSize(width: 1728, height: 990)
    func area(_ current: CGSize, _ aspect: CGFloat, _ change: WindowAspectFit.Change = .keepingWidth,
              minimum: CGSize = minimum, maximum: CGSize = screen) -> CGSize {
        WindowAspectFit.area(current, aspect: aspect, change: change, minimum: minimum, maximum: maximum)
    }

    run("A picture whose shape becomes known keeps the window's width and sets its height, so shapes shown in turn do not shrink it") {
        let window = CGSize(width: 1220, height: 710)
        // 16:9 is wider than the area: the height shrinks. A MacBook's 3024 x 1964 is narrower: it grows.
        let wide = area(window, 16.0 / 9)
        try check(wide == CGSize(width: 1220, height: 686), "A wider picture did not shrink the height: \(wide)")
        let tall = area(window, 3024.0 / 1964)
        try check(tall == CGSize(width: 1220, height: 792), "A narrower picture did not grow the height: \(tall)")
        // Two screens of the host shown in turn: the width never changes, so the window does not creep smaller.
        var current = window
        for aspect in [16.0 / 9, 3024.0 / 1964, 16.0 / 9, 3024.0 / 1964, 21.0 / 9, 16.0 / 9] {
            current = area(current, aspect)
            try check(current.width == 1220 && WindowAspectFit.fills(current, aspect: aspect), "A shape shown in turn changed the width: \(current)")
            // Setting what is already set changes nothing, so it cannot go on resizing.
            try check(area(current, aspect) == current, "Setting the same shape twice moved again for \(aspect)")
        }
        try check(WindowAspectFit.fills(CGSize(width: 1220, height: 686), aspect: 16.0 / 9)
                  && !WindowAspectFit.fills(window, aspect: 16.0 / 9), "A filled area was not told from one with bars")
        // One screen sent at two scales, 3024 x 1964 and 1920 x 1247, differs in shape by a fraction of a
        // point at this size: the area set for one counts as filled by the other.
        try check(WindowAspectFit.fills(tall, aspect: 1920.0 / 1247) && WindowAspectFit.fills(tall, aspect: 2560.0 / 1663),
                  "Another scale of the same screen would move the window")
        try check(!WindowAspectFit.fills(tall, aspect: 16.0 / 10), "A screen of another shape counted as the same")
    }

    run("Dragging one edge sets the other from the picture's shape, and a corner keeps the picture inside the drag") {
        let before = CGSize(width: 1220, height: 686), aspect: CGFloat = 16.0 / 9
        // The right edge out by 180 pt: the height follows and the window grows.
        let wider = area(CGSize(width: 1400, height: 686), aspect, .dragged(from: before))
        try check(wider == CGSize(width: 1400, height: 788), "A wider drag did not grow the height: \(wider)")
        // The bottom edge up by 86 pt: the width follows and the window shrinks.
        let shorter = area(CGSize(width: 1220, height: 600), aspect, .dragged(from: before))
        try check(shorter == CGSize(width: 1067, height: 600), "A shorter drag did not shrink the width: \(shorter)")
        // A corner: both moved, the picture stays inside what was dragged.
        let corner = area(CGSize(width: 1500, height: 700), aspect, .dragged(from: before))
        try check(corner == CGSize(width: 1244, height: 700), "A corner drag left the dragged area: \(corner)")
        // A drag that ends where it began leaves the size alone.
        try check(area(before, aspect, .dragged(from: before)) == before, "A drag back to the start resized")
    }

    run("The area stays on the screen and above the window's smallest size, with bars only when no size fits both") {
        let aspect: CGFloat = 16.0 / 9
        // Dragged wider than the screen is tall for it: the largest area of that shape the screen holds.
        let large = area(CGSize(width: 1728, height: 600), aspect, .dragged(from: CGSize(width: 1067, height: 600)))
        try check(large == CGSize(width: 1728, height: 972), "The grown area did not stop at the screen: \(large)")
        let shortScreen = area(CGSize(width: 1700, height: 600), aspect, .dragged(from: CGSize(width: 1067, height: 600)),
                               maximum: CGSize(width: 1728, height: 800))
        try check(shortScreen == CGSize(width: 1422, height: 800), "A short screen did not limit the height: \(shortScreen)")
        // A width that needs more height than the screen has gives way: the largest area of the shape.
        let zoomed = area(CGSize(width: 1728, height: 990), 3024.0 / 1964)
        try check(zoomed == CGSize(width: 1524, height: 990), "A window as wide as the screen did not give up width: \(zoomed)")
        // Dragged narrower than a very wide picture can be shown at the smallest height: the width stays where
        // it was dragged, the height stops at the smallest, and the picture keeps bars above and below.
        let small = area(CGSize(width: 720, height: 514), 21.0 / 9, .dragged(from: CGSize(width: 1200, height: 514)))
        try check(small == CGSize(width: 720, height: 490), "A drag to the smallest size grew the window: \(small)")
        let narrow = area(CGSize(width: 900, height: 514), 21.0 / 9, .dragged(from: CGSize(width: 1200, height: 514)))
        try check(narrow == CGSize(width: 900, height: 490), "A narrow drag did not stop at the smallest height: \(narrow)")
        // A portrait screen's picture cannot be as wide as the smallest window on this screen: the window
        // keeps its smallest width and the screen's height, and the picture keeps bars at its sides.
        let portrait = area(CGSize(width: 1220, height: 710), 1080.0 / 1920)
        try check(portrait == CGSize(width: 720, height: 990), "A portrait picture left the bounds: \(portrait)")
        // Nonsense in, nothing changed.
        for aspect in [CGFloat.nan, 0, -1, .infinity] {
            try check(area(CGSize(width: 900, height: 600), aspect) == CGSize(width: 900, height: 600), "An invalid shape resized the window")
        }
        try check(area(CGSize(width: 0, height: 600), 1.5) == CGSize(width: 0, height: 600), "An empty area was resized")
        // A screen smaller than the smallest window keeps the smallest window.
        let cramped = area(CGSize(width: 900, height: 600), aspect, maximum: CGSize(width: 600, height: 400))
        try check(cramped.width >= minimum.width && cramped.height >= minimum.height, "A small screen went below the smallest size: \(cramped)")
    }

    run("The window keeps its top-left corner, or the edges a drag did not move, and stays on the screen") {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1050)
        // 80 pt of title bar, toolbar and status bar surround an area of 1220 x 710.
        let frame = CGRect(x: 200, y: 150, width: 1220, height: 790)
        let trimmed = WindowAspectFit.frame(frame, area: CGSize(width: 1220, height: 710), target: CGSize(width: 1220, height: 686), screen: screen)
        try check(trimmed == CGRect(x: 200, y: 174, width: 1220, height: 766), "Trimming the height moved the top-left corner: \(trimmed)")
        // The left edge was dragged out by 100 pt; the height grows downwards and the right edge stays.
        let before = CGRect(x: 300, y: 150, width: 1120, height: 790)
        let leftDrag = WindowAspectFit.frame(frame, before: before, area: CGSize(width: 1220, height: 710),
                                             target: CGSize(width: 1220, height: 686), screen: screen)
        try check(leftDrag.maxX == frame.maxX && leftDrag.maxY == frame.maxY, "A drag of the left edge lost the right or top edge: \(leftDrag)")
        // The top edge was dragged up; the width follows and the bottom edge stays.
        let topBefore = CGRect(x: 200, y: 150, width: 1220, height: 700)
        let topDrag = WindowAspectFit.frame(frame, before: topBefore, area: CGSize(width: 1220, height: 710),
                                            target: CGSize(width: 1262, height: 710), screen: screen)
        try check(topDrag.minY == frame.minY && topDrag.minX == frame.minX && topDrag.width == 1262, "A drag of the top edge lost the bottom edge: \(topDrag)")
        // Growing past the screen's edge moves the window back inside.
        let nearEdge = CGRect(x: 600, y: 40, width: 1100, height: 790)
        let grown = WindowAspectFit.frame(nearEdge, before: CGRect(x: 600, y: 40, width: 900, height: 790), area: CGSize(width: 1100, height: 710),
                                          target: CGSize(width: 1100, height: 900), screen: screen)
        try check(grown.minY >= screen.minY && grown.maxY <= screen.maxY && grown.height == 980, "A grown window left the screen: \(grown)")
        // A window the viewer parked partly off the screen stays where it was put.
        let parked = CGRect(x: 1200, y: -300, width: 1220, height: 790)
        let parkedFit = WindowAspectFit.frame(parked, area: CGSize(width: 1220, height: 710), target: CGSize(width: 1220, height: 792), screen: screen)
        try check(parkedFit.minX == parked.minX && parkedFit.maxY == parked.maxY && parkedFit.height == 872, "A parked window was pulled back: \(parkedFit)")
        // Growing to the right past the screen's edge slides the window left instead.
        let right = CGRect(x: 700, y: 150, width: 1000, height: 790)
        let slid = WindowAspectFit.frame(right, before: CGRect(x: 700, y: 150, width: 1000, height: 700), area: CGSize(width: 1000, height: 710),
                                         target: CGSize(width: 1100, height: 710), screen: screen)
        try check(slid.maxX == screen.maxX && slid.width == 1100 && slid.minY == right.minY, "A window grown past the right edge was not slid back: \(slid)")
        // A window larger than the screen is left where it is rather than pushed off the other side.
        let huge = WindowAspectFit.frame(frame, area: CGSize(width: 1220, height: 710), target: CGSize(width: 2000, height: 710), screen: screen)
        try check(huge.minX == frame.minX && huge.width == 2000, "A window wider than the screen was moved: \(huge)")
        try check(WindowAspectFit.frame(frame, area: CGSize(width: 1220, height: 710), target: CGSize(width: 0, height: -100), screen: screen) == frame,
                  "An impossible size changed the frame")
    }
}
