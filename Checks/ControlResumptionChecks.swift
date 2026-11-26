import Foundation
import QuietDeskCore

func runControlResumptionChecks() {
    run("Local session UI hands the keyboard back to a controlled picture, and a chosen release stays released") {
        var resumption = ControlResumption()
        // A picture that was not being controlled gets nothing back.
        resumption.localUIOpened(controlling: false)
        resumption.localUIClosed(now: 10)
        try check(!resumption.takeResume(now: 10, canControl: true, ready: true), "A released picture took the keyboard")
        // A controlled one does, once the UI is gone and the window can take it, and only once.
        resumption.localUIOpened(controlling: true)
        try check(!resumption.takeResume(now: 11, canControl: true, ready: true), "The keyboard returned while the UI was open")
        resumption.localUIClosed(now: 12)
        try check(!resumption.takeResume(now: 12.1, canControl: true, ready: false), "The keyboard returned before the window was key")
        try check(resumption.takeResume(now: 12.4, canControl: true, ready: true), "The keyboard did not return once the window was key")
        try check(!resumption.takeResume(now: 12.5, canControl: true, ready: true), "The keyboard returned twice")
        // Later than the window, without permission to control, or after a chosen release, it stays released.
        resumption.localUIOpened(controlling: true)
        resumption.localUIClosed(now: 20)
        try check(!resumption.takeResume(now: 20 + ControlResumption.window + 0.1, canControl: true, ready: true),
                  "The keyboard returned long after the UI closed")
        resumption.localUIOpened(controlling: true)
        resumption.localUIClosed(now: 30)
        try check(!resumption.takeResume(now: 30, canControl: false, ready: true)
                  && !resumption.takeResume(now: 30.1, canControl: true, ready: true), "A view-only picture took the keyboard")
        resumption.localUIOpened(controlling: true)
        resumption.cancel()
        resumption.localUIClosed(now: 40)
        try check(!resumption.takeResume(now: 40, canControl: true, ready: true), "A chosen release was undone")
    }
}
