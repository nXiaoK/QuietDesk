import CoreGraphics
import Foundation
import QuietDeskCore

private struct PrivacyCursorCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw PrivacyCursorCheckFailure(message) }
}

private final class CursorBackendProbe {
    var calls: [String] = []
    var enableFailure = false, disableFailure = false
    var hideResult = CGError.success, showResult = CGError.success
    var backend: PrivacyCursorBackend {
        PrivacyCursorBackend(setBackground: { enabled in
            self.calls.append(enabled ? "background on" : "background off")
            if enabled ? self.enableFailure : self.disableFailure { throw DeskError.invalid("fake background failure") }
        }, hide: { self.calls.append("hide"); return self.hideResult },
           show: { self.calls.append("show"); return self.showResult })
    }
}

@main
enum PrivacyCursorChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("A hide is paired with one show before background support is removed") {
            let probe = CursorBackendProbe()
            let hider = PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend))
            try hider.begin()
            try require(hider.isActive && probe.calls == ["background on", "hide"], "Begin did not acquire a single hide")
            try require(hider.end() == nil && !hider.isActive, "End failed")
            try require(probe.calls == ["background on", "hide", "show", "background off"], "Restore order changed")
        }
        run("Repeated begin, end and restore do not add hide counts or over-show") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let owner = PrivacyCursorHider(controller: controller)
            try owner.begin(); try owner.begin()
            try require(owner.end() == nil && owner.end() == nil && controller.retryRestoration() == nil, "Repeated cleanup failed")
            try require(probe.calls == ["background on", "hide", "show", "background off"], "Duplicate request changed the hide count")
        }
        run("Overlapping owners keep the cursor hidden until the final owner ends") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let first = PrivacyCursorHider(controller: controller), second = PrivacyCursorHider(controller: controller)
            try first.begin(); try second.begin()
            try require(first.end() == nil && controller.retryRestoration() == nil, "First release failed")
            try require(probe.calls == ["background on", "hide"] && second.isActive, "A live owner lost its hide")
            try require(second.end() == nil, "Final release failed")
            try require(probe.calls == ["background on", "hide", "show", "background off"], "Owners did not share one hide")
        }
        run("Unavailable background support refuses hiding without a show") {
            let probe = CursorBackendProbe(); probe.enableFailure = true
            let hider = PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend))
            var refused = false
            do { try hider.begin() } catch { refused = error.localizedDescription.contains("fake background failure") }
            try require(refused && !hider.isActive && hider.end() == nil && probe.calls == ["background on"], "Unavailable support changed the cursor")
        }
        run("Failed hide rolls background support back without showing") {
            let probe = CursorBackendProbe(); probe.hideResult = .failure
            let hider = PrivacyCursorHider(controller: PrivacyCursorController(backend: probe.backend))
            var refused = false
            do { try hider.begin() } catch { refused = error.localizedDescription.contains("隐藏本机光标失败") }
            try require(refused && !hider.isActive && hider.end() == nil, "Failed hide acquired ownership")
            try require(probe.calls == ["background on", "hide", "background off"], "Failed hide showed a cursor it did not hide")
        }
        run("Failed hide and rollback report both failures and retry only the property") {
            let probe = CursorBackendProbe(); probe.hideResult = .failure; probe.disableFailure = true
            let controller = PrivacyCursorController(backend: probe.backend)
            let owner = PrivacyCursorHider(controller: controller)
            var reason = ""
            do { try owner.begin() } catch { reason = error.localizedDescription }
            try require(reason.contains("隐藏本机光标失败") && reason.contains("恢复后台光标状态失败"), "Rollback error was lost")
            probe.disableFailure = false
            try require(controller.retryRestoration() == nil, "Property retry failed")
            try require(probe.calls == ["background on", "hide", "background off", "background off"], "Rollback retry changed the cursor count")
        }
        run("Failed show preserves the hide for retry and does not disable background support") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let hider = PrivacyCursorHider(controller: controller)
            try hider.begin(); probe.showResult = .failure
            try require(hider.end()?.contains("恢复本机光标失败") == true && !hider.isActive, "Failed show was not reported")
            try require(probe.calls == ["background on", "hide", "show"], "Background support ended before show succeeded")
            probe.showResult = .success
            try require(controller.retryRestoration() == nil && hider.end() == nil, "Show retry failed")
            try require(probe.calls == ["background on", "hide", "show", "show", "background off"], "Show retry over-restored")
        }
        run("A new owner reuses a hide left by a failed restoration") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let first = PrivacyCursorHider(controller: controller), second = PrivacyCursorHider(controller: controller)
            try first.begin(); probe.showResult = .failure
            _ = first.end()
            try second.begin()
            try require(probe.calls == ["background on", "hide", "show"] && second.isActive, "New owner added another hide")
            probe.showResult = .success
            try require(first.end() == nil && controller.retryRestoration() == nil && second.isActive, "Stale cleanup disturbed the new owner")
            try require(second.end() == nil, "New owner could not restore")
            try require(probe.calls == ["background on", "hide", "show", "show", "background off"], "Reused hide was not paired")
        }
        run("Property restoration failure retries without another show") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let hider = PrivacyCursorHider(controller: controller)
            try hider.begin(); probe.disableFailure = true
            try require(hider.end()?.contains("恢复后台光标状态失败") == true, "Property failure was not reported")
            probe.disableFailure = false
            try require(controller.retryRestoration() == nil, "Property restoration retry failed")
            try require(probe.calls == ["background on", "hide", "show", "background off", "background off"], "Property retry showed twice")
        }
        run("Dropping an owner restores on a background thread without main-actor assumptions") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            try DispatchQueue.global().sync {
                let hider = PrivacyCursorHider(controller: controller)
                try hider.begin()
            }
            try require(probe.calls == ["background on", "hide", "show", "background off"], "Deinit did not restore")
        }
        run("Concurrent owners serialize around one live hide") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let keeper = PrivacyCursorHider(controller: controller)
            try keeper.begin()
            DispatchQueue.concurrentPerform(iterations: 100) { _ in
                let hider = PrivacyCursorHider(controller: controller)
                try? hider.begin(); try? hider.begin()
                _ = hider.end(); _ = hider.end()
            }
            try require(probe.calls == ["background on", "hide"] && keeper.isActive, "Concurrent releases disturbed the keeper")
            try require(keeper.end() == nil && probe.calls == ["background on", "hide", "show", "background off"], "Concurrent ownership left a hide count")
        }
        run("Stray cleanup preserves the live owner and removes all other claims") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let live = PrivacyCursorHider(controller: controller), stale = PrivacyCursorHider(controller: controller)
            try live.begin(); try stale.begin()
            try require(PrivacyCursorHider.removeStray(keeping: live, controller: controller) == nil,
                        "Stray cleanup failed")
            try require(live.isActive && !stale.isActive && probe.calls == ["background on", "hide"],
                        "Stray cleanup ended the live hide")
            try require(stale.end() == nil && PrivacyCursorHider.removeStray(keeping: nil, controller: controller) == nil,
                        "Final stray cleanup failed")
            try require(!live.isActive && live.end() == nil && probe.calls == ["background on", "hide", "show", "background off"],
                        "Stray cleanup did not balance one hide")
        }
        run("Unused owners do not call the cursor backend") {
            let probe = CursorBackendProbe()
            let controller = PrivacyCursorController(backend: probe.backend)
            let unused = PrivacyCursorHider(controller: controller)
            try require(!unused.isActive && unused.end() == nil && probe.calls.isEmpty, "Unused owner changed the cursor")
        }

        print("Privacy cursor checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
