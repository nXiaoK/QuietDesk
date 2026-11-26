import CoreGraphics
import QuietDeskCore

func runFullScreenToolbarRevealChecks() {
    typealias Reveal = FullScreenToolbarReveal

    run("The full-screen toolbar answers to the top-centre edge only, including the menu bar strip above it") {
        let width: CGFloat = 1728
        let centre = width / 2
        try check(Reveal.zone(x: centre, fromTop: 0, containerWidth: width) == .edge
                  && Reveal.zone(x: centre - 170, fromTop: 2, containerWidth: width) == .edge
                  // A notch display keeps the window below the camera housing, and a menu bar that is always
                  // shown stops the pointer above the picture.
                  && Reveal.zone(x: centre, fromTop: -30, containerWidth: width) == .edge,
                  "The top-centre edge was not recognised")
        try check(Reveal.zone(x: centre, fromTop: 8, containerWidth: width) == .toolbar
                  && Reveal.zone(x: centre + 250, fromTop: 0, containerWidth: width) == .toolbar
                  && Reveal.zone(x: centre, fromTop: Reveal.toolbarTop + Reveal.toolbarHeight, containerWidth: width) == .toolbar,
                  "The space around the toolbar does not keep it")
        try check(Reveal.zone(x: 60, fromTop: 0, containerWidth: width) == .elsewhere
                  && Reveal.zone(x: width - 60, fromTop: 0, containerWidth: width) == .elsewhere
                  && Reveal.zone(x: centre, fromTop: 160, containerWidth: width) == .elsewhere
                  // A display arranged above this one.
                  && Reveal.zone(x: centre, fromTop: -400, containerWidth: width) == .elsewhere,
                  "The corners of the picture, its middle or another display answered")
        try check(Reveal.zone(x: .nan, fromTop: 0, containerWidth: width) == .elsewhere
                  && Reveal.zone(x: centre, fromTop: .infinity, containerWidth: width) == .elsewhere
                  && Reveal.zone(x: 0, fromTop: 0, containerWidth: 0) == .elsewhere, "Unusable geometry answered")
    }

    run("The full-screen toolbar comes once the pointer rests at the edge and leaves a moment after the pointer does") {
        var reveal = Reveal()
        // Passing over the edge, and coming back to it, each start the wait again.
        try check(!reveal.sample(.edge, buttonPressed: false, now: 0) && !reveal.sample(.edge, buttonPressed: false, now: 0.2)
                  && !reveal.sample(.elsewhere, buttonPressed: false, now: 0.25) && !reveal.sample(.edge, buttonPressed: false, now: 0.3)
                  && !reveal.sample(.edge, buttonPressed: false, now: 0.55) && !reveal.revealed, "A pointer passing by brought the toolbar")
        try check(reveal.sample(.edge, buttonPressed: false, now: 0.3 + Reveal.dwell + 0.01) && reveal.revealed,
                  "A pointer resting at the edge did not bring the toolbar")
        // On the toolbar, on the way to it or back at the edge it stays, however long.
        for (index, zone) in [Reveal.Zone.toolbar, .edge, .toolbar, .toolbar].enumerated() {
            try check(!reveal.sample(zone, buttonPressed: index == 2, now: 10 + Double(index) * 30) && reveal.revealed,
                      "The toolbar left while the pointer was on it")
        }
        // A short trip away is forgiven; staying away is not.
        try check(!reveal.sample(.elsewhere, buttonPressed: false, now: 200) && !reveal.sample(.elsewhere, buttonPressed: false, now: 200.5)
                  && !reveal.sample(.toolbar, buttonPressed: false, now: 200.6)
                  && !reveal.sample(.elsewhere, buttonPressed: false, now: 201) && !reveal.sample(.elsewhere, buttonPressed: false, now: 201.7)
                  && reveal.revealed, "The toolbar left before the pointer had been away long enough")
        try check(reveal.sample(.elsewhere, buttonPressed: false, now: 201 + Reveal.linger + 0.01) && !reveal.revealed,
                  "The toolbar stayed after the pointer left")
        // Dragging something to the edge never brings it, and the wait starts once the button is up.
        for step in 0..<20 {
            try check(!reveal.sample(.edge, buttonPressed: true, now: 300 + Double(step) * 0.1), "A drag to the edge brought the toolbar")
        }
        try check(!reveal.sample(.edge, buttonPressed: false, now: 302) && !reveal.sample(.edge, buttonPressed: false, now: 302.2)
                  && reveal.sample(.edge, buttonPressed: false, now: 302.31), "The wait did not start when the button was released")
        // Leaving full screen takes it away at once, and an unusable clock changes nothing.
        try check(reveal.hide() && !reveal.revealed && !reveal.hide(), "Hiding did not report its change once")
        try check(!reveal.sample(.edge, buttonPressed: false, now: .nan) && !reveal.sample(.edge, buttonPressed: false, now: 400)
                  && !reveal.sample(.edge, buttonPressed: false, now: .infinity) && !reveal.revealed, "An unusable clock brought the toolbar")
    }
}
