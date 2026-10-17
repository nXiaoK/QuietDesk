import AppKit

private struct PermissionGuideCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PermissionGuideCheckFailure(message) }
}

@MainActor
private final class SyntheticPermissionState {
    var screenRecording = false
    var accessibility = false
    var inputMonitoring = false
    var checked: [PermissionGuide.Kind] = []

    func check(_ kind: PermissionGuide.Kind) -> Bool {
        checked.append(kind)
        switch kind {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        }
    }
}

@MainActor
private final class InvisiblePermissionCheckPanel: NSPanel {
    var presentationCount = 0
    var closeCount = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        alphaValue = 0
    }

    override func orderFrontRegardless() {
        presentationCount += 1
        super.orderFrontRegardless()
    }

    override func close() {
        closeCount += 1
        super.close()
    }
}

@main
private struct PermissionGuideChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        print("Permission guide checks use synthetic states in an isolated test bundle; no system permissions are queried or changed.")
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func fixture(_ state: SyntheticPermissionState) -> (PermissionGuide, InvisiblePermissionCheckPanel) {
            let guide = PermissionGuide(permissionCheck: state.check, onRefresh: {})
            let panel = InvisiblePermissionCheckPanel()
            guide.window = panel
            return (guide, panel)
        }

        run("The production guide retains a nonactivating floating panel") {
            let guide = PermissionGuide(permissionCheck: { _ in false }, onRefresh: {})
            defer { guide.close() }
            guard let panel = guide.window as? NSPanel else {
                throw PermissionGuideCheckFailure("The guide no longer uses an NSPanel")
            }
            try require(panel.styleMask.contains(.nonactivatingPanel) && panel.isFloatingPanel,
                        "The guide lost its nonactivating floating behavior")
            try require(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate,
                        "The guide can steal focus or hide while using System Settings")
            try require(panel.contentView != nil && !guide.isVisible, "The guide is empty or visible before presentation")
        }

        for kind in [PermissionGuide.Kind.screenRecording, .accessibility, .inputMonitoring] {
            run("\(kind.title): a pending permission stays visible until effective") {
                let state = SyntheticPermissionState()
                let (guide, panel) = fixture(state)
                defer { guide.close() }
                guide.present(for: kind)
                try require(guide.isVisible && panel.presentationCount == 1, "A pending permission did not show its guide")
                try require(panel.title.contains(kind.title), "The guide title names the wrong permission")
                guide.refreshStatus()
                try require(guide.isVisible && panel.closeCount == 0, "An ineffective permission closed the guide")
                try require(state.checked == [kind, kind], "Presentation or refresh checked the wrong permission")
                switch kind {
                case .screenRecording: state.screenRecording = true
                case .accessibility: state.accessibility = true
                case .inputMonitoring: state.inputMonitoring = true
                }
                guide.refreshStatus()
                try require(!guide.isVisible && panel.closeCount == 1, "An effective permission did not close the guide")
                guide.refreshStatus()
                try require(state.checked == [kind, kind, kind] && panel.closeCount == 1,
                            "A closed guide kept querying or closing")
            }

            run("\(kind.title): an effective permission never presents the guide") {
                let state = SyntheticPermissionState()
                state.screenRecording = true
                state.accessibility = true
                state.inputMonitoring = true
                let (guide, panel) = fixture(state)
                defer { guide.close() }
                guide.present(for: kind)
                try require(!guide.isVisible && panel.presentationCount == 0, "An effective permission briefly showed a guide")
                try require(state.checked == [kind], "The requested permission was not checked exactly once")
            }
        }

        run("Switching to another pending permission only follows its actual state") {
            let state = SyntheticPermissionState()
            let (guide, panel) = fixture(state)
            defer { guide.close() }
            guide.present(for: .screenRecording)
            guide.present(for: .inputMonitoring)
            state.screenRecording = true
            guide.refreshStatus()
            try require(guide.isVisible && panel.closeCount == 0, "The previous permission closed the current guide")
            try require(state.checked == [.screenRecording, .inputMonitoring, .inputMonitoring],
                        "Refresh did not follow the current permission")
            state.inputMonitoring = true
            guide.refreshStatus()
            try require(!guide.isVisible && panel.closeCount == 1, "The current permission did not close the guide")
        }

        run("Switching to an effective permission closes an older pending guide without presenting again") {
            let state = SyntheticPermissionState()
            let (guide, panel) = fixture(state)
            defer { guide.close() }
            guide.present(for: .accessibility)
            state.inputMonitoring = true
            guide.present(for: .inputMonitoring)
            try require(!guide.isVisible && panel.presentationCount == 1 && panel.closeCount == 1,
                        "Switching to an effective permission left or presented a guide")
        }

        run("A manually closed guide is not reopened by later permission refreshes") {
            let state = SyntheticPermissionState()
            let (guide, panel) = fixture(state)
            defer { guide.close() }
            guide.present(for: .accessibility)
            guide.close()
            guide.refreshStatus()
            state.accessibility = true
            guide.refreshStatus()
            state.accessibility = false
            guide.refreshStatus()
            try require(!guide.isVisible && panel.presentationCount == 1 && state.checked == [.accessibility],
                        "Refreshing a manually closed guide reopened it or continued querying")
            guide.present(for: .accessibility)
            try require(guide.isVisible && panel.presentationCount == 2, "An explicit request could not reopen a pending guide")
        }

        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
