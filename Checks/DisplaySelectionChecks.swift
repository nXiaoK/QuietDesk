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

    run("Remote display metadata and DisplayControl messages validate and round-trip cleanly") {
        let builtIn = RemoteDisplayInfo(id: 1, name: "Built-in Retina Display", width: 3024, height: 1964, isMain: true)
        let studio = RemoteDisplayInfo(id: 2, name: "Studio Display", width: 5120, height: 2880, isMain: false)
        try builtIn.validate()
        try studio.validate()
        try RemoteDisplayInfo.validateList([builtIn, studio], selectedDisplayID: 2)
        try check(builtIn.summary.contains("（主屏）") && !studio.summary.contains("（主屏）"),
                  "Primary display summary label did not distinguish main display")

        // Reject invalid IDs, empty names, duplicate IDs, and missing selectedDisplayID.
        for bad in [
            RemoteDisplayInfo(id: 0, name: "Bad", width: 1920, height: 1080, isMain: false),
            RemoteDisplayInfo(id: 3, name: "   ", width: 1920, height: 1080, isMain: false),
            RemoteDisplayInfo(id: 4, name: "Tiny", width: 1, height: 1080, isMain: false)
        ] {
            do { try bad.validate(); throw CheckFailure("Invalid RemoteDisplayInfo passed validation") }
            catch is DeskError { }
        }
        do {
            try RemoteDisplayInfo.validateList([builtIn, RemoteDisplayInfo(id: 1, name: "Dup", width: 1920, height: 1080, isMain: false)],
                                               selectedDisplayID: 1)
            throw CheckFailure("Duplicate display IDs passed list validation")
        } catch is DeskError { }
        do {
            try RemoteDisplayInfo.validateList([builtIn, studio], selectedDisplayID: 99)
            throw CheckFailure("Unmatched selectedDisplayID passed list validation")
        } catch is DeskError { }

        // Subscribe, state, select, and result round-trip over Wire.
        let subMsg = try DisplayControl.subscribe().message()
        try check(subMsg.kind == .displayControl, "DisplayControl used unexpected MessageKind")
        try check(try DisplayControl.read(subMsg.payload) == .subscribe(), "Subscribe message changed on decode")

        let videoState = VideoStreamState(settings: StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 12),
                                          width: 2560, height: 1440)
        let stateMsg = try DisplayControl.state(displays: [builtIn, studio], selectedDisplayID: 2, videoState: videoState).message()
        let decodedState = try DisplayControl.read(stateMsg.payload)
        try check(decodedState.operation == .state && decodedState.selectedDisplayID == 2
                  && decodedState.displays == [builtIn, studio] && decodedState.videoState == videoState,
                  "Display state update lost display list or videoState")

        let reqID = UUID()
        let selectMsg = try DisplayControl.select(id: reqID, displayID: 2).message()
        let decodedSelect = try DisplayControl.read(selectMsg.payload)
        try check(decodedSelect.operation == .select && decodedSelect.id == reqID && decodedSelect.displayID == 2,
                  "Display select request lost id or displayID")

        let resultMsg = try DisplayControl.result(id: reqID, selectedDisplayID: 2, displays: [builtIn, studio],
                                                  videoState: videoState).message()
        let decodedResult = try DisplayControl.read(resultMsg.payload)
        try check(decodedResult.operation == .result && decodedResult.id == reqID
                  && decodedResult.selectedDisplayID == 2 && decodedResult.videoState == videoState,
                  "Display switch result did not round-trip")
    }

    run("Hello multi-display fields remain backward-compatible and synchronize VideoTuningSession dimensions") {
        let legacyHello = Hello(name: "Mac", width: 1920, height: 1080, settings: StreamSettings(), canControl: true)
        try legacyHello.validate()
        try check(legacyHello.displaySwitchingV1 == nil && legacyHello.displays == nil && legacyHello.selectedDisplayID == nil,
                  "Legacy Hello synthesized multi-display fields")

        let displays = [
            RemoteDisplayInfo(id: 10, name: "Built-in", width: 3024, height: 1964, isMain: true),
            RemoteDisplayInfo(id: 20, name: "External 4K", width: 3840, height: 2160, isMain: false)
        ]
        let modernHello = Hello(name: "Mac", width: 1920, height: 1246, settings: StreamSettings(), canControl: true,
                                displaySwitchingV1: true, displays: displays, selectedDisplayID: 10)
        try modernHello.validate()
        let wire = try Wire.json(.hello, modernHello)
        let decoded = try Wire.readJSON(Hello.self, wire.payload)
        try decoded.validate()
        try check(decoded.displaySwitchingV1 == true && decoded.displays == displays && decoded.selectedDisplayID == 10,
                  "Hello multi-display capability or display list was lost")

        var tuning = try VideoTuningSession(
            applied: VideoStreamState(settings: StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 12),
                                      width: 2560, height: 1664),
            preferred: StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 12)
        )
        let switchedState = VideoStreamState(
            settings: StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 12),
            width: 2560, height: 1440
        )
        try tuning.synchronizeHostState(switchedState)
        try check(tuning.applied == switchedState && tuning.nextRequest() == nil,
                  "VideoTuningSession did not adopt switched display dimensions cleanly")
    }
}
