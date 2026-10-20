import AppKit
import Darwin
import Security

// AppKit ignores a quit Apple event while any window has a sheet attached. System Settings'
// "Quit & Reopen" then reopens the still-running app, and logout is interrupted. Close
// sheets as cancelled first, then follow the normal termination path.
@MainActor
final class SystemQuitHandler: NSObject {
    // SwiftUI re-presents a sheet ended behind its back while its binding stays true, so
    // views that own sheets reset their presentation state on this notification.
    static let dismissSheets = Notification.Name("QuietDeskDismissSheetsBeforeQuit")
    private static let reopenArgument = "--quietdesk-reopen-after-quit-v1"
    // Only the privacy pane's "Quit & Reopen" expects the app back; logout and Dock quits do not.
    private static let reopenRequesters = "anchor apple and (identifier \"com.apple.settings.PrivacySecurity.extension\" or identifier \"com.apple.systempreferences\")"
    private var quitting = false

    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard !quitting else { return }
        if Self.requestedByPrivacySettings(event) { Self.startReopenHelper() }
        // An app-modal alert still blocks termination; keep sheets in sync with their owners then.
        guard NSApp.modalWindow == nil else { NSApp.terminate(nil); return }
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

    private static func requestedByPrivacySettings(_ event: NSAppleEventDescriptor) -> Bool {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 1 else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(reopenRequesters as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func startReopenHelper() {
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [reopenArgument, String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // System Settings drops its pending reopen when it is closed within about three seconds of
    // "Quit & Reopen". This helper copy of the executable reopens the app once the request can no
    // longer be served: as soon as System Settings is gone, or after five seconds at the latest.
    static func runReopenHelperIfRequested(applicationURL: URL = Bundle.main.bundleURL,
                                           requesterBundleIdentifier: String = "com.apple.systempreferences") -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments[1] == reopenArgument else { return false }
        _ = setsid()
        signal(SIGHUP, SIG_IGN)
        guard arguments.count == 3, let parent = Int32(arguments[2]), parent > 1,
              let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else { return true }
        let start = Date()
        while kill(parent, 0) == 0 || errno == EPERM {
            // Termination was refused, so there is nothing to reopen.
            guard Date().timeIntervalSince(start) < 10 else { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        while Date().timeIntervalSince(start) < 5,
              !NSRunningApplication.runningApplications(withBundleIdentifier: requesterBundleIdentifier).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let reopened = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == applicationURL.resolvingSymlinksInPath() }
        guard !reopened else { return true }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [applicationURL.path]
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
        return true
    }
}
