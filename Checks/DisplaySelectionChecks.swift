import Foundation
import QuietDeskCore

func runDisplaySelectionChecks() {
    let main = DisplaySnapshot(id: 1, pixelWidth: 2560, pixelHeight: 1600,
                               bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
    let external = DisplaySnapshot(id: 2, pixelWidth: 3840, pixelHeight: 2160,
                                   bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

    run("Retina native capture retains backing pixels instead of the logical desktop size") {
        let source = DisplaySnapshot.capturePixelDimensions(contentSize: CGSize(width: 1512, height: 982),
            pointPixelScale: 2, fallbackWidth: 1512, fallbackHeight: 982)
        try check(source.width == 3024 && source.height == 1964, "Retina capture discarded three quarters of the source pixels")
        let native = StreamSettings.highest.dimensions(width: source.width, height: source.height)
        try check(native.0 == 3024 && native.1 == 1964, "Native quality still used the logical resolution")
        let capped = StreamSettings().dimensions(width: source.width, height: source.height)
        try check(capped.0 == 1920 && capped.1 == 1246, "Retina capture bypassed a capped quality selection")
        let largerCap = StreamSettings(longestEdge: 3840).dimensions(width: source.width, height: source.height)
        try check(largerCap.0 == source.width && largerCap.1 == source.height, "A larger quality preset upscaled Retina content")
    }

    run("Capture scaling supports standard, scaled, fractional and portrait displays") {
        for (points, scale, width, height) in [
            (CGSize(width: 1512, height: 982), CGFloat(1), 1512, 982),
            (CGSize(width: 1800, height: 1169), CGFloat(2), 3600, 2338),
            (CGSize(width: 1280, height: 800), CGFloat(1.5), 1920, 1200),
            (CGSize(width: 982, height: 1512), CGFloat(2), 1964, 3024)
        ] {
            let source = DisplaySnapshot.capturePixelDimensions(contentSize: points,
                pointPixelScale: scale, fallbackWidth: 1, fallbackHeight: 1)
            try check(source.width == width && source.height == height, "Capture scale or orientation changed")
        }
    }

    run("Unavailable capture geometry uses backing pixel fallback without trapping") {
        for (points, scale) in [
            (CGSize(width: 1512, height: 982), CGFloat(0)),
            (CGSize(width: 1512, height: 982), CGFloat(-1)),
            (CGSize(width: 1512, height: 982), CGFloat.nan),
            (CGSize(width: 1512, height: 982), CGFloat.infinity),
            (CGSize(width: 0, height: 982), CGFloat(2)),
            (CGSize(width: -1512, height: 982), CGFloat(2)),
            (CGSize(width: CGFloat.infinity, height: 982), CGFloat(2)),
            (CGSize(width: CGFloat.greatestFiniteMagnitude, height: 982), CGFloat(2))
        ] {
            let source = DisplaySnapshot.capturePixelDimensions(contentSize: points,
                pointPixelScale: scale, fallbackWidth: 3024, fallbackHeight: 1964)
            try check(source.width == 3024 && source.height == 1964, "Invalid geometry bypassed the native fallback")
        }
    }

    run("Display recovery preserves the chosen display and falls back to the current main display") {
        try check(DisplaySelection.select(preferred: 2, main: 1, available: [main, external]) == external,
                  "An available user selection was overwritten")
        let fallback = DisplaySelection.select(preferred: 99, main: 1, available: [external, main])
        try check(fallback == main, "An obsolete saved display did not select the current main display")
        try check(DisplaySelection.select(preferred: fallback!.id, main: 2, available: [external, main]) == main,
                  "A restored display or changed primary display forced an unwanted switch")
        try check(DisplaySelection.select(preferred: 99, main: 3, available: [external, main]) == external,
                  "A main display outside the capture list did not use the first valid display")
    }

    run("No available display returns no selection and invalid display geometry is ignored") {
        try check(DisplaySelection.select(preferred: 99, main: 1, available: []) == nil,
                  "An empty display list fabricated a selection")
        let zeroPixels = DisplaySnapshot(id: 3, pixelWidth: 0, pixelHeight: 2160, bounds: external.bounds)
        let invalidBounds = DisplaySnapshot(id: 4, pixelWidth: 3840, pixelHeight: 2160,
                                            bounds: CGRect(x: CGFloat.infinity, y: 0, width: 1920, height: 1080))
        try check(DisplaySelection.select(preferred: 3, main: 4, available: [zeroPixels, invalidBounds]) == nil,
                  "A disconnected or invalid display was selected")
        try check(DisplaySelection.select(preferred: 3, main: 4, available: [zeroPixels, invalidBounds, main]) == main,
                  "Invalid entries prevented fallback to a usable display")
    }

    run("Capture restarts for removal, physical pixel changes and Quartz layout changes") {
        try check(DisplaySelection.requiresRestart(captured: external, available: [main]), "Removed display was not detected")
        try check(DisplaySelection.requiresRestart(captured: external, available: []), "All displays disappearing was ignored")
        let resized = DisplaySnapshot(id: 2, pixelWidth: 2560, pixelHeight: 1440, bounds: external.bounds)
        try check(DisplaySelection.requiresRestart(captured: external, available: [main, resized]),
                  "Physical capture size changed without restarting")
        let moved = DisplaySnapshot(id: 2, pixelWidth: 3840, pixelHeight: 2160,
                                    bounds: CGRect(x: 1280, y: 200, width: 1920, height: 1080))
        try check(DisplaySelection.requiresRestart(captured: external, available: [main, moved]),
                  "Remote input bounds changed without restarting")
        let scaled = DisplaySnapshot(id: 2, pixelWidth: 3840, pixelHeight: 2160,
                                     bounds: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        try check(DisplaySelection.requiresRestart(captured: external, available: [main, scaled]),
                  "Logical input size changed without restarting")
    }

    run("Repeated notifications and unrelated display changes do not interrupt capture") {
        try check(!DisplaySelection.requiresRestart(captured: external, available: [main, external]),
                  "An unchanged snapshot caused a reconnect")
        let changedMain = DisplaySnapshot(id: 1, pixelWidth: 1920, pixelHeight: 1080,
                                          bounds: CGRect(x: 0, y: 0, width: 960, height: 540))
        try check(!DisplaySelection.requiresRestart(captured: external, available: [external, changedMain]),
                  "An unrelated display change or list reordering interrupted capture")
        try check(!DisplaySelection.requiresRestart(captured: external, available: [external]),
                  "Removing an unrelated display interrupted capture")
        try check(!DisplaySelection.requiresRestart(captured: changedMain, available: [changedMain, external]),
                  "The recovered snapshot caused another reconnect")
    }
}
