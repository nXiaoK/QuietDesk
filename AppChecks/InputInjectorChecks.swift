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

@main
private struct InputInjectorChecks {
    @MainActor
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("A wire scroll moves the pointer to its Quartz target before delivering both axes") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
                                         isTrusted: { true }, postEvent: recorder.post)
            var input = scroll(x: 0.75, y: 0.25, dx: 24, dy: -36)
            input.flags = CGEventFlags.maskShift.union(.maskAlternate).union(.maskNonCoalesced).rawValue
            let packet = try Wire.json(.input, input)
            let decoded = try Wire.readJSON(RemoteInput.self, packet.payload)
            _ = try injector.receive(decoded)
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

        run("Trackpad fractions accumulate independently and emit no empty wheel events") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 100, y: -1440, width: 900, height: 1440),
                                         isTrusted: { true }, postEvent: recorder.post)
            for index in 0..<4 {
                _ = try injector.receive(scroll(x: 1, y: 1, dx: 0.25, dy: -0.5))
                try require(recorder.events.count == (index + 1) / 2 * 2, "Subpixel input generated an empty event or was lost")
            }
            let wheels = recorder.events.filter { $0.type == .scrollWheel }
            try require(wheels.count == 2 && wheels.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } == -2
                        && wheels.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == 1,
                        "Fine scrolling changed direction or lost an axis")
            try require(recorder.scrollTargets == [CGPoint(x: 999, y: -1), CGPoint(x: 999, y: -1)],
                        "Portrait display coordinates were not synchronized before each scroll")
        }

        run("Wheel direction, single-axis motion, limits and display endpoints remain intact") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         isTrusted: { true }, postEvent: recorder.post)
            let inputs = [scroll(x: 0, y: 0, dx: 120), scroll(x: 1, y: 1, dy: -240), scroll(dx: -3000, dy: 3000)]
            for input in inputs { _ = try injector.receive(input) }
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

        run("Scrolling while a button is held preserves drag and releases at the latest scroll target") {
            for (button, drag, up) in [(0, CGEventType.leftMouseDragged, CGEventType.leftMouseUp),
                                       (1, .rightMouseDragged, .rightMouseUp), (2, .otherMouseDragged, .otherMouseUp)] {
                let recorder = EventRecorder()
                let injector = InputInjector(bounds: CGRect(x: -100, y: 200, width: 101, height: 101),
                                             isTrusted: { true }, postEvent: recorder.post)
                var down = RemoteInput(kind: .down)
                down.button = button; down.x = 0; down.y = 0
                _ = try injector.receive(down)
                _ = try injector.receive(scroll(x: 1, y: 1, dy: 12))
                injector.releaseAll()
                try require(recorder.events.count == 4 && recorder.events[1].type == drag && recorder.events[2].type == .scrollWheel
                            && recorder.events[3].type == up, "Scroll released a held button or changed its drag type")
                try require(recorder.events[3].location == CGPoint(x: 0, y: 300), "Release used a position older than the scroll")
            }
        }

        run("Release clears pending fractions and zero input does not move the pointer") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         isTrusted: { true }, postEvent: recorder.post)
            _ = try injector.receive(scroll(dx: 0.75, dy: -0.75))
            injector.releaseAll()
            _ = try injector.receive(scroll())
            _ = try injector.receive(scroll(dx: 0.5, dy: -0.5))
            try require(recorder.events.isEmpty, "A release or zero scroll retained stale movement")
            _ = try injector.receive(scroll(dx: 0.5, dy: -0.5))
            try require(recorder.events.count == 2, "Fresh fractions did not form a scroll after release")
        }

        run("Invalid input is rejected before movement and lost permission clears pending state") {
            let recorder = EventRecorder()
            var trusted = true
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                                         isTrusted: { trusted }, postEvent: recorder.post)
            _ = try injector.receive(scroll(dx: 0.5, dy: 0.5))
            for input in [scroll(x: .nan, dy: 12), scroll(dx: .infinity), scroll(dy: 3000.1)] {
                do { _ = try injector.receive(input); throw InputCheckFailure("Invalid scroll was accepted") }
                catch is DeskError { }
            }
            try require(recorder.events.isEmpty, "Invalid input moved or scrolled the pointer")
            trusted = false
            _ = try injector.receive(scroll(dy: 12))
            trusted = true
            _ = try injector.receive(scroll(dx: 0.5, dy: 0.5))
            try require(recorder.events.isEmpty, "Permission loss retained an old fraction")
            _ = try injector.receive(scroll(dx: 0.5, dy: 0.5))
            try require(recorder.events.count == 2, "Permission recovery did not resume fresh scrolling")
        }

        run("The injected poster preserves ordinary keyboard, mouse and release behavior") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: CGRect(x: 0, y: 0, width: 101, height: 101),
                                         isTrusted: { true }, postEvent: recorder.post)
            var move = RemoteInput(kind: .move)
            move.x = 0.25; move.y = 0.75
            _ = try injector.receive(move)
            var key = RemoteInput(kind: .keyDown)
            key.keyCode = 0; key.flags = CGEventFlags.maskCommand.rawValue; key.isRepeat = true
            _ = try injector.receive(key)
            injector.releaseAll()
            try require(recorder.events.count == 3 && recorder.events[0].type == .mouseMoved
                        && recorder.events[0].location == CGPoint(x: 25, y: 75), "Ordinary pointer movement changed")
            try require(recorder.events[1].type == .keyDown && recorder.events[1].getIntegerValueField(.keyboardEventAutorepeat) == 1
                        && recorder.events[1].flags == .maskCommand && recorder.events[2].type == .keyUp,
                        "Keyboard flags, repeats or release stopped using the injected poster")
        }

        run("Left and right Shift releases use their independent device bits") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: recorder.post)
            for (key, bits): (UInt16, UInt64) in [(56, 0x02), (60, 0x06), (56, 0x04)] {
                var input = RemoteInput(kind: .flags)
                input.keyCode = key
                input.flags = CGEventFlags.maskShift.rawValue | bits
                _ = try injector.receive(input)
            }
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.count == 1 && recorder.events[0].type == .flagsChanged
                        && recorder.events[0].flags.isEmpty
                        && recorder.events[0].getIntegerValueField(.keyboardEventKeycode) == 60,
                        "Left Shift stayed held after its independent release")
        }

        run("Legacy modifier flags without device bits retain aggregate behavior") {
            let recorder = EventRecorder()
            let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: recorder.post)
            var input = RemoteInput(kind: .flags)
            input.keyCode = 56
            input.flags = CGEventFlags.maskShift.rawValue
            _ = try injector.receive(input)
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.count == 1
                        && recorder.events[0].getIntegerValueField(.keyboardEventKeycode) == 56,
                        "Legacy Shift press was no longer held")
            _ = try injector.receive(input)
            input.flags = 0
            _ = try injector.receive(input)
            recorder.events.removeAll()
            injector.releaseAll()
            try require(recorder.events.isEmpty, "Legacy Shift release retained a held key")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
