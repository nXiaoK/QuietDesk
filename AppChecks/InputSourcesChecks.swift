import AppKit
import QuietDeskCore

private struct SourceCheckFailure: Error { let message: String }

@MainActor
private final class SourceProbe: InputSourceAccess {
    let english = KeyboardSource(id: "abc", name: "ABC", isChinese: false, isASCII: true)
    let chinese = KeyboardSource(id: "pinyin", name: "拼音", isChinese: true, isASCII: true)
    var current: KeyboardSource?
    var requested: KeyboardSource?
    var rejectSelection = false
    var selections = 0
    var contextRefresh: InputSourceContextRefresh?
    init() { current = english }
    func prepareContextRefresh() -> InputSourceContextRefresh? { contextRefresh }
    func enabledSources() throws -> [KeyboardSource] { [english, chinese] }
    func currentSource() -> KeyboardSource? { current }
    func select(_ source: KeyboardSource) throws {
        selections += 1
        if rejectSelection { throw SourceCheckFailure(message: "Synthetic system rejection") }
        requested = source
    }
}

@MainActor
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw SourceCheckFailure(message: message) }
}

@main
private struct InputSourcesChecks {
    @MainActor
    static func main() async {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await run("Source selection waits for delayed Pinyin activation before a subsequent injected key") {
            let probe = SourceProbe()
            var turns = 0, keySources: [String] = []
            let sources = InputSources(access: probe) {
                turns += 1
                if turns == 3 { probe.current = probe.requested }
                await Task.yield()
            }
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { _ in
                keySources.append(probe.current?.id ?? "missing")
            }, inputSources: sources, capsLockState: { false })
            var setup = RemoteInput(kind: .keyDown)
            setup.keyCode = 0; setup.independentCapsLock = true
            let result = try await injector.receive(RemoteInput(kind: .switchInputSource))
            _ = try await injector.receive(setup)
            try require(turns == 4 && keySources == [probe.chinese.id], "Following key overtook delayed input-source activation")
            try require(result?.message.contains("已确认") == true && probe.selections == 1, "Switch was not confirmed exactly once")
        }
        await run("A successful select call that never changes the source cannot claim success") {
            let probe = SourceProbe()
            var turns = 0
            let sources = InputSources(access: probe) { turns += 1; await Task.yield() }
            do { _ = try await sources.toggle(); throw SourceCheckFailure(message: "Unchanged input source was accepted") }
            catch is DeskError { }
            try require(turns == 25 && probe.selections == 1, "Confirmation was unbounded or repeated selection")
        }
        await run("A source that briefly changes then reverts must stabilize before confirmation") {
            let probe = SourceProbe()
            var turns = 0
            let sources = InputSources(access: probe) {
                turns += 1
                probe.current = turns == 1 || turns >= 4 ? probe.chinese : probe.english
                await Task.yield()
            }
            _ = try await sources.toggle()
            try require(turns == 5, "A transient source observation falsely confirmed activation")
        }
        await run("Releasing control cancels the pending confirmation without a late success") {
            let probe = SourceProbe()
            weak var pending: InputSources?
            let sources = InputSources(access: probe) { pending?.cancel(); probe.current = probe.requested; await Task.yield() }
            pending = sources
            do { _ = try await sources.toggle(); throw SourceCheckFailure(message: "Cancelled switch returned success") }
            catch is CancellationError { }
            try require(probe.selections == 1, "Cancellation selected an additional input source")
        }
        await run("Confirmed Chinese and ASCII selections preserve the remembered input-source choice") {
            let probe = SourceProbe()
            let sources = InputSources(access: probe) { probe.current = probe.requested; await Task.yield() }
            _ = try await sources.toggle()
            try require(probe.current == probe.chinese, "First switch did not select Chinese")
            _ = try await sources.toggle()
            try require(probe.current == probe.english, "Second switch did not return to ASCII")
        }
        await run("System selection errors propagate without pretending a target was activated") {
            let probe = SourceProbe(); probe.rejectSelection = true
            var turns = 0
            let sources = InputSources(access: probe) { turns += 1 }
            do { _ = try await sources.toggle(); throw DeskError.invalid("Selection rejection was hidden") }
            catch is SourceCheckFailure { }
            try require(turns == 0 && probe.current == probe.english, "Failed selection started a success wait")
        }
        await run("Short Caps Lock first releases remote uppercase and the next press confirms Pinyin") {
            let probe = SourceProbe()
            let sources = InputSources(access: probe) { probe.current = probe.requested; await Task.yield() }
            var posted: [CGEvent] = []
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { posted.append($0) },
                                         inputSources: sources, capsLockState: { true })
            let released = try await injector.receive(RemoteInput(kind: .switchInputSource))
            try require(released?.capsLocked == false && probe.selections == 0 && posted.count == 1,
                        "Short press changed the existing uppercase-release behavior")
            let selected = try await injector.receive(RemoteInput(kind: .switchInputSource))
            try require(selected?.message.contains("已确认") == true && probe.current == probe.chinese && probe.selections == 1,
                        "A subsequent short press did not confirm Pinyin")
            let upper = try await injector.receive(RemoteInput(kind: .toggleCapsLock))
            try require(upper?.capsLocked == true && probe.selections == 1, "Long press unexpectedly selected another source")
        }
        await run("Permission loss or release during activation does not return a stale success") {
            for release in [false, true] {
                let probe = SourceProbe()
                var trusted = true
                weak var active: InputInjector?
                let sources = InputSources(access: probe) {
                    probe.current = probe.requested
                    if release { active?.releaseAll() }
                    else { trusted = false }
                    await Task.yield()
                }
                let injector = InputInjector(bounds: .zero, isTrusted: { trusted }, postEvent: { _ in },
                                             inputSources: sources, capsLockState: { false })
                active = injector
                let result = try await injector.receive(RemoteInput(kind: .switchInputSource))
                try require(result == nil, "A cancelled or unauthorized activation reported success")
            }
        }
        print("Input source checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
