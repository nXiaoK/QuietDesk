import AppKit
import QuietDeskCore

private struct InputCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw InputCheckFailure(message) }
}

@MainActor
private final class EventRecorder {
    var events: [CGEvent] = []
    var pointer = CGPoint(x: 10000, y: 10000)
    var scrollTargets: [CGPoint] = []
    func post(_ event: CGEvent) {
        events.append(event)
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) { pointer = event.location }
        if event.type == .scrollWheel { scrollTargets.append(pointer) }
    }
}

@MainActor
private func scroll(x: Double = 0.5, y: Double = 0.5, dx: Double = 0, dy: Double = 0) -> RemoteInput {
    var value = RemoteInput(kind: .scroll)
    value.x = x; value.y = y; value.deltaX = dx; value.deltaY = dy
    return value
}

@MainActor
private func phased(_ phase: RemoteInput.ScrollPhase? = nil, momentum: RemoteInput.MomentumPhase? = nil,
                    dy: Double = 0) -> RemoteInput {
    var value = scroll(x: 0.2, y: 0.4, dy: dy)
    value.scrollPhase = phase; value.momentumPhase = momentum
    return value
}

@MainActor
private func phases(_ events: [CGEvent]) -> [String] {
    events.filter { $0.type == .scrollWheel }.map { event in
        let native = NSEvent(cgEvent: event)
        return "\(native?.phase.rawValue ?? 999)/\(native?.momentumPhase.rawValue ?? 999)/\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))"
    }
}

@main
private struct InputInjectorChecks {
    @MainActor
    static func main() async {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("A wire scroll moves the pointer to its Quartz target before delivering both axes") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            var input = scroll(x: 0.75, y: 0.25, dx: 24, dy: -36)
            input.flags = CGEventFlags.maskShift.union(.maskAlternate).union(.maskNonCoalesced).rawValue
            let packet = try Wire.json(.input, input)
            let decoded = try Wire.readJSON(RemoteInput.self, packet.payload)
            _ = try await injector.receive(decoded)
            let point = CGPoint(x: -480.75, y: 69.75)
            try require(recorder.events.count == 2 && recorder.events[0].type == .mouseMoved && recorder.events[1].type == .scrollWheel,
                        "Scroll was posted without its preceding pointer movement")
            try require(recorder.events.allSatisfy { $0.location == point } && recorder.scrollTargets == [point],
                        "Scroll target was based on an old pointer or incorrect display origin")
            let wheel = recorder.events[1]
            try require(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -36
                        && wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 24,
                        "Vertical and horizontal deltas were swapped or reversed")
            try require(wheel.getIntegerValueField(.scrollWheelEventIsContinuous) == 1, "Pixel scroll lost its continuous marker")
            guard let native = NSEvent(cgEvent: wheel) else { throw InputCheckFailure("No native scroll event") }
            try require(native.hasPreciseScrollingDeltas && native.scrollingDeltaX == 24 && native.scrollingDeltaY == -36,
                        "AppKit interpreted different scroll amounts")
            let flags: CGEventFlags = [.maskShift, .maskAlternate]
            try require(recorder.events.allSatisfy { $0.flags == flags }, "Pointer movement and scroll did not preserve allowed modifiers")
        }

        await run("Trackpad fractions accumulate independently and emit no empty wheel events") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 100, y: -1440, width: 900, height: 1440),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            for (index, count) in [0, 2, 2, 3].enumerated() {
                _ = try await injector.receive(scroll(x: 1, y: 1, dx: 0.25, dy: -0.5))
                try require(recorder.events.count == count, "Subpixel input generated an empty or repeated move, or was lost at \(index)")
            }
            let wheels = recorder.events.filter { $0.type == .scrollWheel }
            try require(wheels.count == 2 && wheels.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } == -2
                        && wheels.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == 1,
                        "Fine scrolling changed direction or lost an axis")
            try require(recorder.scrollTargets == [CGPoint(x: 999, y: -1), CGPoint(x: 999, y: -1)],
                        "Portrait display coordinates were not synchronized before each scroll")
        }

        await run("Wheel direction, single-axis motion, limits and display endpoints remain intact") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            let inputs = [scroll(x: 0, y: 0, dx: 120), scroll(x: 1, y: 1, dy: -240), scroll(dx: -3000, dy: 3000)]
            for input in inputs { _ = try await injector.receive(input) }
            try require(recorder.events.count == 6, "Wheel samples were dropped or produced extra events")
            try require(recorder.scrollTargets[0] == .zero && recorder.scrollTargets[1] == CGPoint(x: 1439, y: 899),
                        "Normalized endpoints left the selected display")
            for (index, input) in inputs.enumerated() {
                let wheel = recorder.events[index * 2 + 1]
                try require(wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == Int64(input.deltaY)
                            && wheel.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == Int64(input.deltaX),
                            "Wheel magnitude, direction or axis changed")
            }
        }

        await run("Scrolling while a button is held preserves drag and releases at the latest scroll target") {
            for (button, drag, up) in [(0, CGEventType.leftMouseDragged, CGEventType.leftMouseUp),
                                       (1, .rightMouseDragged, .rightMouseUp), (2, .otherMouseDragged, .otherMouseUp)] {
                let recorder = EventRecorder()
                let injector = InputInjector(bounds: CGRect(x: -100, y: 200, width: 101, height: 101),
                                             isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
                var down = RemoteInput(kind: .down)
                down.button = button; down.x = 0; down.y = 0
                _ = try await injector.receive(down)
                _ = try await injector.receive(scroll(x: 1, y: 1, dy: 12))
                injector.releaseAll()
                try require(recorder.events.count == 4 && recorder.events[1].type == drag && recorder.events[2].type == .scrollWheel
                            && recorder.events[3].type == up, "Scroll released a held button or changed its drag type")
                try require(recorder.events[3].location == CGPoint(x: 0, y: 300), "Release used a position older than the scroll")
            }
        }

        await run("A scroll where the pointer already is posts only the wheel, and a moved pointer is moved back first") {
            for held in [false, true] {
                let recorder = EventRecorder()
                let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                             isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
                if held {
                    var down = RemoteInput(kind: .down)
                    down.x = 0.5; down.y = 0.5
                    _ = try await injector.receive(down)
                    recorder.events.removeAll()
                }
                for _ in 0..<3 { _ = try await injector.receive(scroll(x: 0.2, y: 0.4, dy: -12)) }
                try require(recorder.events.map(\.type) == [held ? .leftMouseDragged : .mouseMoved, .scrollWheel, .scrollWheel, .scrollWheel],
                            "Scrolling at an unchanged pointer repeated its move or lost a wheel event")
                recorder.pointer = CGPoint(x: 20.3, y: 40.2)
                _ = try await injector.receive(scroll(x: 0.2, y: 0.4, dy: -12))
                try require(recorder.events.count == 5, "A sub-pixel pointer difference added a move")
                recorder.pointer = CGPoint(x: 90, y: 10)
                _ = try await injector.receive(scroll(x: 0.2, y: 0.4, dy: -12))
                try require(recorder.events.count == 7 && recorder.events[5].location == CGPoint(x: 20, y: 40)
                            && recorder.events[6].type == .scrollWheel && recorder.scrollTargets.last == CGPoint(x: 20, y: 40),
                            "A pointer moved on the host was not returned to the scroll target first")
                let unknown = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                            isTrusted: { true }, postEvent: recorder.post, pointerLocation: { nil })
                _ = try await unknown.receive(scroll(x: 0.2, y: 0.4, dy: -12))
                try require(recorder.events.count == 9 && recorder.events[7].type == .mouseMoved,
                            "An unknown pointer position skipped the move")
            }
        }

        await run("A line wheel replays as non-continuous lines with its exact fraction and pixel totals") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            var slow = scroll(x: 0.2, y: 0.4, dy: 3.6); slow.lineDeltaX = 0; slow.lineDeltaY = 0.3
            var fast = scroll(x: 0.2, y: 0.4, dx: -24, dy: 0.6); fast.lineDeltaX = -2; fast.lineDeltaY = 0.7
            var still = scroll(x: 0.2, y: 0.4); still.lineDeltaX = 0; still.lineDeltaY = 0
            for input in [slow, fast, still] { _ = try await injector.receive(input) }
            let wheels = recorder.events.filter { $0.type == .scrollWheel }
            try require(recorder.events.count == 3 && recorder.events[0].type == .mouseMoved && wheels.count == 2,
                        "A line wheel lost an event, moved the pointer twice or posted a zero wheel")
            guard let first = NSEvent(cgEvent: wheels[0]), let second = NSEvent(cgEvent: wheels[1]) else {
                throw InputCheckFailure("No native line wheel")
            }
            try require(wheels.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 }
                        && !first.hasPreciseScrollingDeltas && !second.hasPreciseScrollingDeltas,
                        "A line wheel became a precise pixel scroll")
            try require(abs(first.scrollingDeltaY - 0.3) < 0.001 && first.scrollingDeltaX == 0
                        && abs(second.scrollingDeltaY - 0.7) < 0.001 && second.scrollingDeltaX == -2,
                        "AppKit read different line amounts")
            try require(wheels[0].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0
                        && wheels[1].getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1
                        && wheels[1].getIntegerValueField(.scrollWheelEventDeltaAxis2) == -2,
                        "Whole-line deltas did not accumulate the fractions")
            try require(wheels[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 3
                        && wheels[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 1
                        && wheels[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -24,
                        "Pixel totals of a line wheel changed")
            try require(wheels.allSatisfy { $0.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
                                            && $0.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 },
                        "A line wheel acquired gesture phases")
        }

        await run("A trackpad gesture and its momentum keep their phases, including endings without a whole pixel") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            let sequence = [phased(.mayBegin), phased(.began), phased(.changed, dy: -0.4), phased(.changed, dy: -0.8),
                            phased(.ended), phased(momentum: .began, dy: -3), phased(momentum: .changed, dy: -2),
                            phased(momentum: .ended)]
            for input in sequence { _ = try await injector.receive(input) }
            try require(phases(recorder.events) == ["32/0/0", "1/0/0", "4/0/-1", "8/0/0", "0/1/-3", "0/4/-2", "0/8/0"],
                        "Gesture or momentum phases were lost, reordered or carried the wrong pixels: \(phases(recorder.events))")
            try require(recorder.events.filter { $0.type == .mouseMoved }.count == 1
                        && recorder.events.filter { $0.type == .scrollWheel }.allSatisfy {
                            $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 && NSEvent(cgEvent: $0)?.hasPreciseScrollingDeltas == true
                        }, "A phased scroll stopped being a precise pixel scroll or repeated its pointer move")
        }

        await run("A trackpad pause keeps one gesture open until its real ending") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            var began = phased(.began)
            began.flags = CGEventFlags.maskControl.union(.maskShift).rawValue
            var changed = began
            changed.scrollPhase = .changed; changed.deltaY = -5
            _ = try await injector.receive(began)
            _ = try await injector.receive(changed)
            try await Task.sleep(nanoseconds: 650_000_000)
            try require(phases(recorder.events) == ["1/0/0", "4/0/-5"],
                        "Pausing without lifting the fingers ended a valid gesture")
            _ = try await injector.receive(changed)
            var ended = began
            ended.scrollPhase = .ended
            _ = try await injector.receive(ended)
            let wheels = recorder.events.filter { $0.type == .scrollWheel }
            try require(phases(wheels) == ["1/0/0", "4/0/-5", "4/0/-5", "8/0/0"],
                        "A paused gesture restarted or ended twice")
            try require(wheels.allSatisfy { $0.flags == [.maskControl, .maskShift] },
                        "A paused gesture lost its modifiers")
        }

        await run("Lost gesture beginnings are supplied and unfinished ones end on a wheel or a release") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            _ = try await injector.receive(phased(.changed, dy: -5))
            try require(phases(recorder.events) == ["1/0/0", "4/0/-5"], "A gesture without its beginning was not opened first")
            injector.releaseAll()
            try require(phases(recorder.events) == ["1/0/0", "4/0/-5", "8/0/0"], "Release left a gesture open")
            _ = try await injector.receive(phased(.ended))
            _ = try await injector.receive(phased(momentum: .ended))
            try require(phases(recorder.events).count == 3, "An ending for an already ended gesture reached apps")
            _ = try await injector.receive(phased(.began))
            var wheel = scroll(x: 0.2, y: 0.4, dy: 12); wheel.lineDeltaX = 0; wheel.lineDeltaY = 1
            _ = try await injector.receive(wheel)
            try require(phases(recorder.events).suffix(3) == ["1/0/0", "8/0/0", "0/0/12"],
                        "A wheel did not end the open gesture before scrolling")
            _ = try await injector.receive(phased(momentum: .changed, dy: -4))
            try require(phases(recorder.events).suffix(2) == ["0/1/0", "0/4/-4"], "Momentum without its beginning was not opened first")
            injector.releaseAll()
            try require(phases(recorder.events).last == "0/8/0", "Release left momentum open")
            injector.releaseAll()
            try require(phases(recorder.events).count == 9, "A released gesture was ended twice")
            _ = try await injector.receive(phased(.began))
            _ = try await injector.receive(phased(momentum: .began, dy: -2))
            try require(phases(recorder.events).suffix(3) == ["1/0/0", "8/0/0", "0/1/-2"],
                        "Momentum did not end the gesture whose ending was lost")
            _ = try await injector.receive(phased(.mayBegin))
            try require(phases(recorder.events).suffix(2) == ["0/8/0", "32/0/0"], "A new touch did not end the running momentum")
            injector.releaseAll()
            try require(phases(recorder.events).last == "16/0/0", "An unfinished touch was not cancelled on release")
        }

        await run("Synthetic gesture and momentum endings retain the latest remote modifiers") {
            for momentum in [false, true] {
                let recorder = EventRecorder()
                let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                             isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
                var input = momentum ? phased(momentum: .began, dy: -3) : phased(.began, dy: -3)
                input.flags = CGEventFlags.maskControl.rawValue
                _ = try await injector.receive(input)
                var modifier = RemoteInput(kind: .flags)
                modifier.keyCode = 56
                modifier.flags = CGEventFlags.maskControl.union(.maskShift).rawValue
                _ = try await injector.receive(modifier)
                injector.releaseAll()
                guard let ending = recorder.events.last(where: { $0.type == .scrollWheel }) else {
                    throw InputCheckFailure("Release did not end the gesture")
                }
                try require(ending.flags == [.maskControl, .maskShift], "Release dropped the active gesture's current modifiers")
                try require(phases([ending]) == [momentum ? "0/8/0" : "8/0/0"], "Release used the wrong ending phase")
            }
        }

        await run("Release clears pending fractions and zero input does not move the pointer") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         isTrusted: { true }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            _ = try await injector.receive(scroll(dx: 0.75, dy: -0.75))
            injector.releaseAll()
            _ = try await injector.receive(scroll())
            _ = try await injector.receive(scroll(dx: 0.5, dy: -0.5))
            try require(recorder.events.isEmpty, "A release or zero scroll retained stale movement")
            _ = try await injector.receive(scroll(dx: 0.5, dy: -0.5))
            try require(recorder.events.count == 2, "Fresh fractions did not form a scroll after release")
        }

        await run("Invalid input is rejected before movement and lost permission clears pending state") {
            let recorder = EventRecorder()
            var trusted = true
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         isTrusted: { trusted }, postEvent: recorder.post, pointerLocation: { recorder.pointer })
            _ = try await injector.receive(scroll(dx: 0.5, dy: 0.5))
            for input in [scroll(x: .nan, dy: 12), scroll(dx: .infinity), scroll(dy: 3000.1)] {
                do { _ = try await injector.receive(input); throw InputCheckFailure("Invalid scroll was accepted") }
                catch is DeskError { }
            }
            try require(recorder.events.isEmpty, "Invalid input moved or scrolled the pointer")
            trusted = false
            _ = try await injector.receive(scroll(dy: 12))
            trusted = true
            _ = try await injector.receive(scroll(dx: 0.5, dy: 0.5))
            try require(recorder.events.isEmpty, "Permission loss retained an old fraction")
            _ = try await injector.receive(scroll(dx: 0.5, dy: 0.5))
            try require(recorder.events.count == 2, "Permission recovery did not resume fresh scrolling")
        }

        await run("The injected poster preserves ordinary keyboard, mouse and release behavior") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post)
            var move = RemoteInput(kind: .move)
            move.x = 0.25; move.y = 0.75
            _ = try await injector.receive(move)
            var key = RemoteInput(kind: .keyDown)
            key.keyCode = 0; key.flags = CGEventFlags.maskCommand.rawValue; key.isRepeat = true
            _ = try await injector.receive(key)
            injector.releaseAll()
            try require(recorder.events.count == 3 && recorder.events[0].type == .mouseMoved
                        && recorder.events[0].location == CGPoint(x: 25, y: 75), "Ordinary pointer movement changed")
            try require(recorder.events[1].type == .keyDown && recorder.events[1].getIntegerValueField(.keyboardEventAutorepeat) == 1
                        && recorder.events[1].flags == .maskCommand && recorder.events[2].type == .keyUp,
                        "Keyboard flags, repeats or release stopped using the injected poster")
        }

        await run("Left and right Shift releases use their independent device bits") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: recorder.post)
            for (key, bits): (UInt16, UInt64) in [(56, 0x02), (60, 0x06), (56, 0x04)] {
                var input = RemoteInput(kind: .flags)
                input.keyCode = key
                input.flags = CGEventFlags.maskShift.rawValue | bits
                _ = try await injector.receive(input)
            }
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.count == 1 && recorder.events[0].type == .flagsChanged
                        && recorder.events[0].flags.isEmpty
                        && recorder.events[0].getIntegerValueField(.keyboardEventKeycode) == 60,
                        "Left Shift stayed held after its independent release")
        }

        await run("Legacy modifier flags without device bits retain aggregate behavior") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: recorder.post)
            var input = RemoteInput(kind: .flags)
            input.keyCode = 56
            input.flags = CGEventFlags.maskShift.rawValue
            _ = try await injector.receive(input)
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.count == 1
                        && recorder.events[0].getIntegerValueField(.keyboardEventKeycode) == 56,
                        "Legacy Shift press was no longer held")
            _ = try await injector.receive(input)
            input.flags = 0
            _ = try await injector.receive(input)
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.isEmpty, "Legacy Shift release retained a held key")
        }

        await run("Immediate synchronous injection handles pointer, scroll, key and Caps Lock without async hop") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post,
                                         capsLockState: { false }, pointerLocation: { recorder.pointer })
            var move = RemoteInput(kind: .move)
            move.x = 0.5; move.y = 0.5
            try require(try injector.receiveImmediate(move) == nil, "Immediate pointer move returned unexpected feedback")
            let feedback = try injector.receiveImmediate(RemoteInput(kind: .toggleCapsLock))
            try require(feedback?.capsLocked == true && recorder.events.count == 2
                        && recorder.events[0].type == .mouseMoved && recorder.events[1].type == .flagsChanged,
                        "Immediate Caps Lock or pointer event did not post synchronously")
        }

        await run("Immediate input queue coalesces trailing move and drag events while preserving click barriers and backpressure") {
            let queue = HostImmediateInputQueue(capacity: 3)
            var resumed = 0
            func move(_ x: Double) -> RemoteInput {
                var input = RemoteInput(kind: .move); input.x = x; input.y = 0.5; return input
            }
            func drag(_ x: Double, button: Int = 0) -> RemoteInput {
                var input = RemoteInput(kind: .drag); input.x = x; input.y = 0.5; input.button = button; return input
            }
            let firstSchedule = queue.enqueue(move(0.1)) { resumed += 1 }
            let secondSchedule = queue.enqueue(move(0.2)) { resumed += 1 }
            try require(firstSchedule && !secondSchedule && resumed == 2,
                        "Coalesced moves did not resume immediately or scheduled duplicate flushes")
            var down = RemoteInput(kind: .down); down.x = 0.2; down.y = 0.5
            _ = queue.enqueue(down) { resumed += 1 }
            try require(resumed == 3, "Click below capacity did not resume immediately")
            _ = queue.enqueue(drag(0.3)) { resumed += 1 }
            _ = queue.enqueue(drag(0.4)) { resumed += 1 }
            try require(resumed == 3, "Events at capacity bypassed backpressure before drain")
            let batch = queue.drain()
            for resume in batch.resumes { resume() }
            try require(resumed == 5, "Drain did not release held backpressure continuations")
            try require(batch.inputs.map(\.kind) == [.move, .down, .drag]
                        && batch.inputs[0].x == 0.2 && batch.inputs[2].x == 0.4,
                        "Coalescing lost click ordering or kept stale intermediate pointer coordinates")
        }

        await run("Concurrent high-priority input queue injects pointer and keyboard events off the main actor") {
            final class ConcurrentEventBox: @unchecked Sendable {
                private let lock = NSLock()
                private var events: [(CGEventType, CGPoint, Bool)] = []
                func append(_ event: CGEvent, onMain: Bool) {
                    lock.withLock { events.append((event.type, event.location, onMain)) }
                }
                func snapshot() -> [(CGEventType, CGPoint, Bool)] { lock.withLock { events } }
            }
            let box = ConcurrentEventBox()
            let injector = InputInjector(concurrentBounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true },
                                         postEvent: { box.append($0, onMain: Thread.isMainThread) },
                                         capsLockState: { false },
                                         pointerLocation: { CGPoint(x: 50, y: 50) })
            let queue = DispatchQueue(label: "checks.host-input", qos: .userInteractive)
            let done = DispatchSemaphore(value: 0)
            queue.async {
                var move = RemoteInput(kind: .move); move.x = 0.5; move.y = 0.5
                var down = RemoteInput(kind: .down); down.x = 0.5; down.y = 0.5
                var key = RemoteInput(kind: .keyDown); key.keyCode = 0
                _ = try? injector.receiveImmediateOnInputQueue(move, validated: true)
                _ = try? injector.receiveImmediateOnInputQueue(down, validated: true)
                _ = try? injector.receiveImmediateOnInputQueue(key, validated: true)
                injector.releaseAllOnInputQueue()
                done.signal()
            }
            try require(done.wait(timeout: .now() + 3) == .success, "Off-main input queue did not finish")
            let recorded = box.snapshot()
            try require(recorded.map(\.0) == [.mouseMoved, .leftMouseDown, .keyDown, .keyUp, .leftMouseUp],
                        "Off-main injection lost event order or release cleanup")
            try require(recorded.allSatisfy { !$0.2 }, "Off-main input queue unexpectedly executed on the main thread")
        }

        await run("Sequenced UDP pointer moves and drags never regress cursor state after newer clicks or releases") {
            final class SequencedEventBox: @unchecked Sendable {
                private let lock = NSLock()
                private var items: [(CGEventType, CGPoint)] = []
                func append(_ event: CGEvent) { lock.withLock { items.append((event.type, event.location)) } }
                func snapshot() -> [(CGEventType, CGPoint)] { lock.withLock { items } }
            }
            let box = SequencedEventBox()
            let injector = InputInjector(concurrentBounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true },
                                         postEvent: { box.append($0) },
                                         capsLockState: { false },
                                         pointerLocation: { CGPoint(x: 0, y: 0) })
            var unheldDrag = RemoteInput(kind: .drag); unheldDrag.x = 0.2; unheldDrag.y = 0.2; unheldDrag.pointerSequence = 1
            _ = try injector.receiveImmediateOnInputQueue(unheldDrag, validated: true, fromDatagram: true)
            try require(box.snapshot().isEmpty, "UDP drag before button-down injected a phantom drag")

            var down = RemoteInput(kind: .down); down.x = 0.5; down.y = 0.5; down.pointerSequence = 10
            _ = try injector.receiveImmediateOnInputQueue(down, validated: true)
            var staleMove = RemoteInput(kind: .move); staleMove.x = 0.1; staleMove.y = 0.1; staleMove.pointerSequence = 9
            _ = try injector.receiveImmediateOnInputQueue(staleMove, validated: true, fromDatagram: true)
            var validDrag = RemoteInput(kind: .drag); validDrag.x = 0.6; validDrag.y = 0.6; validDrag.pointerSequence = 11
            _ = try injector.receiveImmediateOnInputQueue(validDrag, validated: true, fromDatagram: true)
            var up = RemoteInput(kind: .up); up.x = 0.6; up.y = 0.6; up.pointerSequence = 12
            _ = try injector.receiveImmediateOnInputQueue(up, validated: true)
            var lateDrag = RemoteInput(kind: .drag); lateDrag.x = 0.9; lateDrag.y = 0.9; lateDrag.pointerSequence = 11
            _ = try injector.receiveImmediateOnInputQueue(lateDrag, validated: true, fromDatagram: true)

            let events = box.snapshot()
            try require(events.map(\.0) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                        "Out-of-order UDP pointer packets crossed click/release boundaries: \(events.map(\.0))")
            try require(events[0].1 == CGPoint(x: 50, y: 50) && events[1].1 == CGPoint(x: 60, y: 60) && events[2].1 == CGPoint(x: 60, y: 60),
                        "Stale UDP move altered injected coordinates")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
