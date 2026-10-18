import AppKit
import SwiftUI
import QuietDeskCore

private struct CanvasCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CanvasCheckFailure(message) }
}

@MainActor
private func nativeEvent(_ event: CGEvent, point: CGPoint) throws -> NSEvent {
    // Derive the Quartz-to-AppKit origin without requiring a screen or window.
    event.location = .zero
    guard let origin = NSEvent(cgEvent: event)?.locationInWindow else {
        throw CanvasCheckFailure("Could not bridge an event coordinate origin")
    }
    event.location = CGPoint(x: point.x, y: origin.y - point.y)
    guard let native = NSEvent(cgEvent: event) else { throw CanvasCheckFailure("Could not bridge a native event") }
    return native
}

@MainActor
private func wheel(units: CGScrollEventUnit, x: Int32, y: Int32,
                   point: CGPoint = CGPoint(x: 100, y: 150)) throws -> NSEvent {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                              wheel1: y, wheel2: x, wheel3: 0) else {
        throw CanvasCheckFailure("Could not construct a scroll event")
    }
    event.flags = .maskAlternate
    return try nativeEvent(event, point: point)
}

@MainActor
private func mouse(_ type: CGEventType, button: CGMouseButton = .left,
                   point: CGPoint = CGPoint(x: 100, y: 150), clicks: Int64 = 2) throws -> NSEvent {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                              mouseButton: button) else {
        throw CanvasCheckFailure("Could not construct a mouse event")
    }
    event.timestamp = 1_000_000_000
    event.flags = .maskAlternate
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    return try nativeEvent(event, point: point)
}

@main
private struct RemoteCanvasChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("A precise AppKit scroll reaches the wire input callback with both axes") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            canvas.remoteSize = CGSize(width: 400, height: 200)
            canvas.canControl = true
            var inputs: [RemoteInput] = []
            canvas.onInput = { inputs.append($0) }
            let event = try wheel(units: .pixel, x: 24, y: -36)
            try require(event.hasPreciseScrollingDeltas, "The precise fixture lost its pixel unit")
            canvas.scrollWheel(with: event)
            try require(inputs.count == 1, "The native scroll never reached onInput")
            let input = inputs[0]
            try require(input.kind == .scroll && input.deltaX == 24 && input.deltaY == -36,
                        "Precise scrolling changed magnitude, axis or direction")
            try require(input.x == 0.25 && input.y == 0.5, "Scroll coordinates ignored picture letterboxing")
            try require(input.button == 0 && input.clicks == 1 && input.flags == NSEvent.ModifierFlags.option.rawValue,
                        "Scroll acquired click metadata or lost its modifiers")
        }

        run("A line wheel scales its deltas without reading click-only NSEvent properties") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            canvas.remoteSize = CGSize(width: 400, height: 300)
            canvas.canControl = true
            var inputs: [RemoteInput] = []
            canvas.onInput = { inputs.append($0) }
            let event = try wheel(units: .line, x: -2, y: 3)
            try require(!event.hasPreciseScrollingDeltas, "The wheel fixture unexpectedly uses pixel units")
            canvas.scrollWheel(with: event)
            try require(inputs.count == 1 && inputs[0].deltaX == -24 && inputs[0].deltaY == 36,
                        "Line wheel movement was lost or scaled incorrectly")
            try require(inputs[0].button == 0 && inputs[0].clicks == 1, "A wheel inherited mouse click metadata")
        }

        run("Ordinary move, click, drag and release retain their pointer metadata") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            canvas.remoteSize = CGSize(width: 400, height: 300)
            canvas.canControl = true
            var inputs: [RemoteInput] = []
            canvas.onInput = { inputs.append($0) }
            canvas.mouseMoved(with: try mouse(.mouseMoved))
            canvas.mouseDown(with: try mouse(.leftMouseDown))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged))
            canvas.mouseUp(with: try mouse(.leftMouseUp))
            canvas.rightMouseDown(with: try mouse(.rightMouseDown, button: .right))
            canvas.rightMouseDragged(with: try mouse(.rightMouseDragged, button: .right))
            canvas.rightMouseUp(with: try mouse(.rightMouseUp, button: .right))
            try require(inputs.map(\.kind) == [.move, .down, .drag, .up, .down, .drag, .up],
                        "Mouse motion or a button sequence was dropped")
            try require(inputs[0].button == 0 && inputs[0].clicks == 1, "Move acquired click metadata")
            try require(inputs.dropFirst().allSatisfy { $0.clicks == 2 }, "Click count changed for button events")
            try require(inputs.map(\.button) == [0, 0, 0, 0, 1, 1, 1], "A right button became a left button")
            try require(inputs.allSatisfy { $0.x == 0.25 && $0.y == 0.5 && $0.flags == NSEvent.ModifierFlags.option.rawValue },
                        "Mouse coordinates or modifiers changed")
        }

        run("Control permission, letterbox bounds and scroll limits are enforced") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            canvas.remoteSize = CGSize(width: 400, height: 200)
            var inputs: [RemoteInput] = []
            canvas.onInput = { inputs.append($0) }
            canvas.scrollWheel(with: try wheel(units: .pixel, x: 12, y: 24))
            try require(inputs.isEmpty, "A view-only canvas sent input")
            canvas.canControl = true
            canvas.scrollWheel(with: try wheel(units: .pixel, x: 12, y: 24, point: CGPoint(x: 100, y: 25)))
            try require(inputs.isEmpty, "A letterbox scroll reached the remote desktop")
            canvas.scrollWheel(with: try wheel(units: .pixel, x: 4000, y: -4000))
            try require(inputs.count == 1 && inputs[0].deltaX == 3000 && inputs[0].deltaY == -3000,
                        "Scroll deltas exceeded the protocol bounds")
        }

        run("Releasing a focused canvas notifies release and lost focus exactly once") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let canvas = RemoteCanvas(frame: window.contentView!.bounds)
            canvas.canControl = true
            window.contentView = canvas
            try require(window.makeFirstResponder(canvas), "Canvas could not become first responder")
            var releases = 0
            var focuses: [Bool] = []
            canvas.onRelease = { releases += 1 }
            canvas.onFocus = { focuses.append($0) }
            canvas.releaseControl()
            try require(window.firstResponder !== canvas, "Canvas retained focus after release")
            try require(releases == 1 && focuses == [false], "Focused release notified more than once")
        }

        run("Releasing a canvas without focus still notifies exactly once") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            var releases = 0
            var focuses: [Bool] = []
            canvas.onRelease = { releases += 1 }
            canvas.onFocus = { focuses.append($0) }
            canvas.releaseControl()
            try require(releases == 1 && focuses == [false], "Unfocused release notification changed")
        }

        run("A SwiftUI reconnect button above the canvas is a local target while exposed video remains remote") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let hosting = NSHostingView(rootView: ZStack {
                CanvasView(canvas: canvas)
                Button("停止重连") {}.frame(width: 160, height: 60)
            }.frame(width: 400, height: 300))
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try require(canvas.window === window, "SwiftUI did not attach the canvas fixture")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let local = NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 150), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let remote = NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw CanvasCheckFailure("Could not create local pointer events")
                }
                try require(!canvas.isInputTarget(of: local), "Reconnect button click was classified as remote canvas input")
                try require(canvas.isInputTarget(of: remote), "An exposed canvas click lost remote input routing")
            }
        }

        run("Keyboard routing follows the actual first responder and rejects other windows") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = canvas
            canvas.canControl = true
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7),
                  let otherWindow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7) else { throw CanvasCheckFailure("Could not create keyboard events") }
            try require(!canvas.isInputTarget(of: key), "An unfocused canvas intercepted local keyboard input")
            try require(window.makeFirstResponder(canvas), "Canvas did not take fixture focus")
            try require(canvas.isInputTarget(of: key), "Focused canvas lost keyboard routing")
            try require(!canvas.isInputTarget(of: otherWindow), "Another window's input reached the canvas")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
