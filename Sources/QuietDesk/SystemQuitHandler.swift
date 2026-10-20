import AppKit

// AppKit ignores a quit Apple event while any window has a sheet attached. System Settings'
// "Quit & Reopen" then reopens the still-running app, and logout is interrupted. Close
// sheets as cancelled first, then follow the normal termination path.
@MainActor
final class SystemQuitHandler: NSObject {
    // SwiftUI re-presents a sheet ended behind its back while its binding stays true, so
    // views that own sheets reset their presentation state on this notification.
    static let dismissSheets = Notification.Name("QuietDeskDismissSheetsBeforeQuit")
    private var quitting = false

    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        // An app-modal alert still blocks termination; keep sheets in sync with their owners then.
        guard NSApp.modalWindow == nil else { NSApp.terminate(nil); return }
        guard !quitting else { return }
        quitting = true
        NotificationCenter.default.post(name: Self.dismissSheets, object: nil)
        for window in NSApp.windows where window.sheetParent == nil { endSheets(of: window) }
        Task { @MainActor in
            // System Settings reopens the app about three seconds after asking it to quit.
            let deadline = ContinuousClock.now + .seconds(1)
            while NSApp.windows.contains(where: { !$0.sheets.isEmpty }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            quitting = false
            NSApp.terminate(nil)
        }
    }

    private func endSheets(of window: NSWindow) {
        for sheet in window.sheets.reversed() {
            endSheets(of: sheet)
            window.endSheet(sheet, returnCode: .cancel)
        }
    }
}
