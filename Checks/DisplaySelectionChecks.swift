import Foundation
import QuietDeskCore

func runDisplaySelectionChecks() {
    let main = DisplaySnapshot(id: 1, pixelWidth: 2560, pixelHeight: 1600,
                               bounds: CGRect(x: 0, y: 0, width: 1280, height: 800))
    let external = DisplaySnapshot(id: 2, pixelWidth: 3840, pixelHeight: 2160,
                                   bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080))

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
