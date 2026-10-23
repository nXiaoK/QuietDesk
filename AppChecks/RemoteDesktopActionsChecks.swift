import AppKit
import Carbon
import QuietDeskCore

private struct DesktopActionCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DesktopActionCheckFailure(message) }
}

@MainActor
private final class ShortcutRecorder {
    var locked = false
    var trusted = true
    var secureInput = false
    var flags: CGEventFlags = [.maskAlphaShift, .maskCommand, .maskAlternate, .maskShift]
    var events: [CGEvent] = []

    func executor(wait: @escaping () async throws -> Void = {}) -> RemoteDesktopActionExecutor {
        RemoteDesktopActionExecutor(isLocked: { self.locked }, isTrusted: { self.trusted },
            isSecureInput: { self.secureInput }, postEvent: { self.events.append($0) },
            currentFlags: { self.flags }, waitForKeyRelease: wait)
    }
}

@MainActor
private final class ShortcutPause {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func awaitEntry() async throws {
        for _ in 0..<100 {
            if entered { return }
            await Task.yield()
        }
        throw DesktopActionCheckFailure("Shortcut did not reach its bounded key hold")
    }
}

@main
private struct RemoteDesktopActionsChecks {
    @MainActor
    static func main() async {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("Each action sends one default shortcut with balanced presses and preserves Caps Lock") {
            for (action, key): (RemoteDesktopAction, Int64) in [(.previousSpace, 123), (.nextSpace, 124), (.missionControl, 126)] {
                let recorder = ShortcutRecorder()
                var waits = 0
                let executor = recorder.executor { waits += 1 }
                let error = await executor.perform(action)
                try require(error == nil && !executor.isExecuting && waits == 1, "Shortcut did not complete one bounded send")
                try require(recorder.events.count == 4, "Shortcut did not post exactly four keyboard events")
                let events = recorder.events
                try require(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                            "Shortcut modifiers or keys were not released in reverse order")
                try require(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [59, key, key, 59],
                            "Shortcut targeted a different system action")
                try require(events.prefix(3).allSatisfy { $0.flags == [.maskAlphaShift, .maskControl] }
                            && events[3].flags == .maskAlphaShift,
                            "Shortcut inherited unrelated modifiers or altered Caps Lock")
                try require(events.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 },
                            "Shortcut introduced repeated key presses")
                executor.cancel()
                try require(recorder.events.count == 4, "Cancellation released already released keys again")
            }
        }

        await run("Lock, missing accessibility and secure input reject shortcuts before any input") {
            for blocked in 0..<3 {
                let recorder = ShortcutRecorder()
                recorder.locked = blocked == 0
                recorder.trusted = blocked != 1
                recorder.secureInput = blocked == 2
                var waits = 0
                let executor = recorder.executor { waits += 1 }
                let error = await executor.perform(.missionControl)
                try require(error != nil && recorder.events.isEmpty && waits == 0 && !executor.isExecuting,
                            "Unavailable shortcut posted keyboard input or waited")
            }
        }

        await run("Every event allocation failure leaves the keyboard untouched") {
            for failure in 0..<4 {
                var allocations = 0
                var events: [CGEvent] = []
                let executor = RemoteDesktopActionExecutor(isLocked: { false }, isTrusted: { true },
                    isSecureInput: { false }, postEvent: { events.append($0) }, makeKeyEvent: { key, down in
                        defer { allocations += 1 }
                        if allocations == failure { return nil }
                        return CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                    }, currentFlags: { [] }, waitForKeyRelease: {})
                let error = await executor.perform(.previousSpace)
                try require(error != nil && events.isEmpty && !executor.isExecuting,
                            "A partial event allocation left a key pressed")
            }
        }

        await run("State loss before the arrow press releases only Control") {
            var trusted = true
            var events: [CGEvent] = []
            let executor = RemoteDesktopActionExecutor(isLocked: { false }, isTrusted: { trusted },
                isSecureInput: { false }, postEvent: { event in events.append(event); trusted = false },
                currentFlags: { [] }, waitForKeyRelease: {})
            let error = await executor.perform(.nextSpace)
            try require(error != nil && events.count == 2 && events.allSatisfy { $0.type == .flagsChanged }
                        && events.last?.flags.isEmpty == true, "Permission loss left Control pressed or sent an arrow")
        }

        await run("Lock, permission or secure input changes during a send release all shortcut keys") {
            for changed in 0..<3 {
                let recorder = ShortcutRecorder()
                let executor = recorder.executor {
                    recorder.locked = changed == 0
                    recorder.trusted = changed != 1
                    recorder.secureInput = changed == 2
                }
                let error = await executor.perform(.nextSpace)
                try require(error != nil && recorder.events.count == 4 && recorder.events[2].type == .keyUp
                            && recorder.events[3].type == .flagsChanged && !executor.isExecuting,
                            "State change was reported as success or left shortcut keys held")
            }
        }

        await run("Explicit cancellation releases immediately and never posts a second release") {
            let recorder = ShortcutRecorder()
            let pause = ShortcutPause()
            let executor = recorder.executor(wait: pause.wait)
            let task = Task { await executor.perform(.missionControl) }
            try await pause.awaitEntry()
            try require(recorder.events.count == 2 && executor.isExecuting, "Shortcut was not suspended with its keys pressed")
            executor.cancel()
            try require(recorder.events.count == 4 && recorder.events.last?.flags == .maskAlphaShift,
                        "Cancel did not immediately release the shortcut keys")
            pause.resume()
            let error = await task.value
            try require(error != nil && recorder.events.count == 4 && !executor.isExecuting,
                        "Cancelled shortcut succeeded or released twice")
        }

        await run("A cancelled task releases all shortcut keys even when its injected wait ignores cancellation") {
            let recorder = ShortcutRecorder()
            let pause = ShortcutPause()
            let executor = recorder.executor(wait: pause.wait)
            let task = Task { await executor.perform(.previousSpace) }
            try await pause.awaitEntry()
            task.cancel()
            pause.resume()
            let error = await task.value
            try require(error != nil && recorder.events.count == 4 && recorder.events[2].type == .keyUp
                        && !executor.isExecuting, "Task cancellation left shortcut keys held")
        }

        await run("A task already cancelled sends no events") {
            let recorder = ShortcutRecorder()
            let executor = recorder.executor()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await executor.perform(.nextSpace)
            }
            let error = await task.value
            try require(error != nil && recorder.events.isEmpty, "Already cancelled task sent a shortcut")
        }

        await run("Repeated requests are rejected while busy and do not form a delayed queue") {
            let recorder = ShortcutRecorder()
            let pause = ShortcutPause()
            var waits = 0
            let executor = recorder.executor {
                waits += 1
                if waits == 1 { try await pause.wait() }
            }
            let task = Task { await executor.perform(.previousSpace) }
            try await pause.awaitEntry()
            for _ in 0..<20 {
                let error = await executor.perform(.nextSpace)
                try require(error != nil && recorder.events.count == 2, "Concurrent request posted extra shortcut input")
            }
            executor.cancel()
            let busy = await executor.perform(.missionControl)
            try require(busy != nil && recorder.events.count == 4, "Cancellation admitted a new operation before the old one finished")
            pause.resume()
            _ = await task.value
            let error = await executor.perform(.nextSpace)
            try require(error == nil && recorder.events.count == 8 && waits == 2 && !executor.isExecuting,
                        "A cancelled request was replayed or blocked subsequent fresh input")
        }

        await run("A thrown wait error always releases keys") {
            let recorder = ShortcutRecorder()
            let executor = recorder.executor { throw CancellationError() }
            let error = await executor.perform(.missionControl)
            try require(error != nil && recorder.events.count == 4 && recorder.events[2].type == .keyUp
                        && recorder.events.last?.flags == .maskAlphaShift && !executor.isExecuting,
                        "A failed wait left the shortcut pressed")
        }

        await run("Cancellation during a modifier press never sends the arrow") {
            var executor: RemoteDesktopActionExecutor!
            var events: [CGEvent] = []
            executor = RemoteDesktopActionExecutor(isLocked: { false }, isTrusted: { true },
                isSecureInput: { false }, postEvent: { event in
                    events.append(event)
                    if events.count == 1 { executor.cancel() }
                }, currentFlags: { [] }, waitForKeyRelease: {})
            let error = await executor.perform(.missionControl)
            try require(error != nil && events.count == 2 && events.allSatisfy { $0.type == .flagsChanged }
                        && events.last?.flags.isEmpty == true && !executor.isExecuting,
                        "Cancellation during Control press sent an arrow or left Control held")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
