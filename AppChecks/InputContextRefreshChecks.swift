import AppKit
import QuietDeskCore

private struct ContextCheckFailure: Error { let message: String }

@MainActor
private final class FocusProbe: InputSourceFocusAccess {
    var originalProcessID: pid_t? = 20
    let currentProcessID: pid_t = 10
    var frontmostProcessID: pid_t? = 20
    var isRefreshWindowKey = false
    var acceptsActivation = true
    var acceptsRestore = true
    var activatesImmediately = true
    var restoresImmediately = true
    var activations = 0, restores = 0, closes = 0
    func activateRefreshWindow() -> Bool {
        activations += 1
        if acceptsActivation && activatesImmediately { frontmostProcessID = currentProcessID; isRefreshWindowKey = true }
        return acceptsActivation
    }
    func restoreOriginalApplication() -> Bool {
        restores += 1
        if acceptsRestore && restoresImmediately { frontmostProcessID = originalProcessID; isRefreshWindowKey = false }
        return acceptsRestore
    }
    func closeRefreshWindow() { closes += 1; isRefreshWindowKey = false }
}

@MainActor
private final class ContextSourceProbe: InputSourceAccess {
    let english = KeyboardSource(id: "abc", name: "ABC", isChinese: false, isASCII: true)
    let chinese = KeyboardSource(id: "pinyin", name: "拼音", isChinese: true, isASCII: true)
    var current: KeyboardSource?
    let refresh: InputSourceContextRefresh
    var captures = 0
    init(refresh: InputSourceContextRefresh) { self.refresh = refresh; current = english }
    func enabledSources() throws -> [KeyboardSource] { [english, chinese] }
    func currentSource() -> KeyboardSource? { current }
    func select(_ source: KeyboardSource) throws { current = source }
    func prepareContextRefresh() -> InputSourceContextRefresh? { captures += 1; return refresh }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ContextCheckFailure(message: message) }
}

@main
private struct InputContextRefreshChecks {
    @MainActor
    static func main() async {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await run("A stable Pinyin ID still refreshes the original application before the next key") {
            let focus = FocusProbe()
            var turns = 0, safeKeys = 0
            let refresh = InputSourceContextRefresh(access: focus) { turns += 1; await Task.yield() }
            let probe = ContextSourceProbe(refresh: refresh)
            let sources = InputSources(access: probe) { await Task.yield() }
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { _ in
                if focus.frontmostProcessID == focus.originalProcessID && focus.closes == 1 && turns == 10 { safeKeys += 1 }
            }, inputSources: sources, capsLockState: { false })
            let result = try await injector.receive(RemoteInput(kind: .switchInputSource))
            _ = try await injector.receive(RemoteInput(kind: .keyDown))
            try require(result?.message.contains("已确认") == true && safeKeys == 1 && focus.restores == 1,
                        "The matching source ID bypassed context activation or restoration")
            _ = try await sources.toggle()
            try require(probe.current == probe.english && probe.captures == 1 && focus.activations == 1,
                        "Switching back to ASCII unexpectedly refreshed focus")
        }
        await run("Delayed activation and restoration are observed before completing the switch") {
            let focus = FocusProbe(); focus.activatesImmediately = false; focus.restoresImmediately = false
            var turns = 0
            let refresh = InputSourceContextRefresh(access: focus) {
                turns += 1
                if turns == 3 { focus.frontmostProcessID = focus.currentProcessID; focus.isRefreshWindowKey = true }
                if turns == 14 { focus.frontmostProcessID = focus.originalProcessID }
                await Task.yield()
            }
            try await refresh.refresh { false }
            try require(turns == 14 && focus.closes == 1 && focus.restores == 1, "Focus transitions were assumed synchronous")
        }
        await run("User focus changes before or during refresh never reactivate the old application") {
            for changedAt in [0, 1, 5, 10] {
                let focus = FocusProbe()
                if changedAt == 0 { focus.frontmostProcessID = 30 }
                var turns = 0
                let refresh = InputSourceContextRefresh(access: focus) {
                    turns += 1
                    if turns == changedAt { focus.frontmostProcessID = 30 }
                    await Task.yield()
                }
                do { try await refresh.refresh { false }; throw ContextCheckFailure(message: "User focus change was ignored") }
                catch is DeskError { }
                try require(focus.frontmostProcessID == 30 && focus.restores == (changedAt == 10 ? 1 : 0),
                            "Cleanup stole focus from the user's selected application")
                try require(focus.closes == (changedAt == 0 ? 0 : 1), "Temporary window survived a focus change")
            }
        }
        await run("Cancellation and task cancellation restore owned focus and close the temporary window") {
            for cancelledAt in [1, 5, 10] {
                let focus = FocusProbe()
                var turns = 0
                let refresh = InputSourceContextRefresh(access: focus) { turns += 1; await Task.yield() }
                do { try await refresh.refresh { turns == cancelledAt }; throw ContextCheckFailure(message: "Cancelled refresh succeeded") }
                catch is CancellationError { }
                try require(focus.frontmostProcessID == focus.originalProcessID && focus.closes == 1 && focus.restores == 1,
                            "Cancellation left focus on the temporary window")
            }
            let focus = FocusProbe()
            let refresh = InputSourceContextRefresh(access: focus) { throw CancellationError() }
            do { try await refresh.refresh { false }; throw ContextCheckFailure(message: "Task cancellation was ignored") }
            catch is CancellationError { }
            try require(focus.closes == 1 && focus.frontmostProcessID == focus.originalProcessID, "Thrown cancellation leaked focus")
        }
        await run("Rejected activation, rejected restore and transition timeouts cannot claim success") {
            for mode in 0..<4 {
                let focus = FocusProbe()
                if mode == 0 { focus.acceptsActivation = false }
                if mode == 1 { focus.acceptsRestore = false }
                if mode == 2 { focus.activatesImmediately = false }
                if mode == 3 { focus.restoresImmediately = false }
                var turns = 0
                let refresh = InputSourceContextRefresh(access: focus) { turns += 1; await Task.yield() }
                do { try await refresh.refresh { false }; throw ContextCheckFailure(message: "Failed focus transition succeeded") }
                catch is DeskError { }
                try require(focus.closes == 1 && turns <= 34, "Failure leaked a temporary window or waited without a bound")
            }
        }
        await run("Own-process input skips the focus excursion and a missing application is rejected") {
            let focus = FocusProbe(); focus.originalProcessID = focus.currentProcessID
            focus.frontmostProcessID = focus.currentProcessID
            let refresh = InputSourceContextRefresh(access: focus) { throw ContextCheckFailure(message: "Unexpected wait") }
            try await refresh.refresh { false }
            try require(focus.activations == 0, "The application's own input context lost focus")
            focus.originalProcessID = nil
            do { try await refresh.refresh { false }; throw ContextCheckFailure(message: "Unknown input application was accepted") }
            catch is DeskError { }
        }
        await run("Failed restoration blocks queued keys until an explicit pointer-down establishes focus") {
            let focus = FocusProbe(); focus.acceptsRestore = false
            let refresh = InputSourceContextRefresh(access: focus) { await Task.yield() }
            let probe = ContextSourceProbe(refresh: refresh)
            let sources = InputSources(access: probe) { await Task.yield() }
            var posted: [CGEvent] = []
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { posted.append($0) },
                                         inputSources: sources, capsLockState: { false })
            let result = try await injector.receive(RemoteInput(kind: .switchInputSource))
            try require(result?.message.contains("请点击") == true && sources.requiresKeyboardRefocus, "Failed restore was hidden")
            for kind: RemoteInput.Kind in [.keyDown, .keyUp, .flags] { _ = try await injector.receive(RemoteInput(kind: kind)) }
            for kind: RemoteInput.Kind in [.switchInputSource, .toggleCapsLock] {
                let blocked = try await injector.receive(RemoteInput(kind: kind))
                try require(blocked?.message.contains("请点击") == true && sources.requiresKeyboardRefocus,
                            "Another Caps Lock action bypassed the required focus recovery")
            }
            try require(posted.isEmpty, "Queued keys were sent to an application that was not restored")
            _ = try await injector.receive(RemoteInput(kind: .move))
            try require(sources.requiresKeyboardRefocus, "Pointer movement falsely established input focus")
            _ = try await injector.receive(RemoteInput(kind: .down))
            _ = try await injector.receive(RemoteInput(kind: .keyDown))
            try require(!sources.requiresKeyboardRefocus && posted.last?.type == .keyDown, "An explicit click did not resume input")
        }
        await run("An input source reverted during application restoration cannot report success") {
            let focus = FocusProbe()
            var turns = 0
            weak var selected: ContextSourceProbe?
            let refresh = InputSourceContextRefresh(access: focus) {
                turns += 1
                if turns == 10 { selected?.current = selected?.english }
                await Task.yield()
            }
            let probe = ContextSourceProbe(refresh: refresh)
            selected = probe
            let sources = InputSources(access: probe) { await Task.yield() }
            do { _ = try await sources.toggle(); throw ContextCheckFailure(message: "Restoration reverted the source without an error") }
            catch is DeskError { }
            try require(sources.requiresKeyboardRefocus && focus.frontmostProcessID == focus.originalProcessID && focus.closes == 1,
                        "A reverted source released queued keyboard input")
        }
        await run("Control release during context activation suppresses late feedback and subsequent keys") {
            let focus = FocusProbe()
            weak var active: InputInjector?
            let refresh = InputSourceContextRefresh(access: focus) { active?.releaseAll(); await Task.yield() }
            let probe = ContextSourceProbe(refresh: refresh)
            let sources = InputSources(access: probe) { await Task.yield() }
            var keyCount = 0
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { _ in keyCount += 1 },
                                         inputSources: sources, capsLockState: { false })
            active = injector
            let result = try await injector.receive(RemoteInput(kind: .switchInputSource))
            _ = try await injector.receive(RemoteInput(kind: .keyDown))
            try require(result == nil && keyCount == 0 && focus.closes == 1 && focus.frontmostProcessID == focus.originalProcessID,
                        "Released control returned a stale success or injected a key before refocus")
        }
        print("Input context checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
