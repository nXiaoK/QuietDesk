import AppKit
import CoreVideo
import SwiftUI
import QuietDeskCore

private struct CanvasCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class CanvasLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class CanvasDecoderProbe: MediaCanvasDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(UInt32, (Result<CVPixelBuffer, Error>) -> Void)] = []
    private(set) var stopped = false
    var pendingCount: Int { lock.withLock { pending.count } }
    func decode(_ packet: VideoPacket, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        lock.withLock { pending.append((packet.sequence, completion)) }
    }
    func stop() { lock.withLock { stopped = true } }
    func finish(_ sequence: UInt32, _ result: Result<CVPixelBuffer, Error>) {
        let callback = lock.withLock { () -> ((Result<CVPixelBuffer, Error>) -> Void)? in
            guard let index = pending.firstIndex(where: { $0.0 == sequence }) else { return nil }
            return pending.remove(at: index).1
        }
        callback?(result)
    }
}

private func mediaFrame(stream: MediaStreamID, id: UInt64, keyFrame: Bool) throws -> MediaFrame {
    let packet = VideoPacket(sequence: UInt32(truncatingIfNeeded: id),
        sps: keyFrame ? Data([0x67, 0x64]) : Data(), pps: keyFrame ? Data([0x68]) : Data(),
        avcc: Data([0, 0, 0, 2, keyFrame ? 0x65 : 0x41, 0x88]))
    return try MediaFrame(header: .init(stream: stream, frameID: id, isIDR: keyFrame), packet: packet)
}

private func canvasPixel() throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &pixel) == kCVReturnSuccess,
          let pixel else { throw CanvasCheckFailure("Could not create a synthetic pixel buffer") }
    return pixel
}

@MainActor
private func drainCanvasDisplay() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
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

        run("Preparing media keeps temporary legacy video live until the new stream commits") {
            let canvas = RemoteCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let legacyDecoder = CanvasDecoderProbe(), mediaDecoder = CanvasDecoderProbe()
            let legacy = canvas.makeVideoReceiver(makeDecoder: { _ in legacyDecoder })
            let receiver = canvas.makeMediaReceiver(makeDecoder: { _ in mediaDecoder })
            defer { receiver.stop(); canvas.reset() }
            let old = try mediaFrame(stream: .init(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1), id: 1, keyFrame: true)
            let pixel = try canvasPixel()
            var acknowledged = false
            legacy(old.packet) { acknowledged = true }
            try require(!legacyDecoder.stopped && legacyDecoder.pendingCount == 1,
                        "UDP preparation stopped the temporary TCP decoder")
            legacyDecoder.finish(old.packet.sequence, .success(pixel))
            try require(acknowledged, "Temporary TCP video lost its decode acknowledgement")
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
            receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { _ in }
            mediaDecoder.finish(1, .success(pixel))
            try require(receiver.commit(stream: stream), "Decoded media candidate did not commit")
            drainCanvasDisplay()
            try require(legacyDecoder.stopped, "Committed media left the temporary TCP decoder running")
        }

        run("Candidate media acknowledges off the main queue and draws only after a decoded IDR commit") {
            let decoder = CanvasDecoderProbe(), results = CanvasLocked<[Bool]>([])
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
            let pixel = try canvasPixel()
            var displayed: [CVPixelBuffer] = []
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in decoder }) { inbox in
                if let image = inbox.take() { displayed.append(image) }
            }
            defer { receiver.stop() }
            receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { value in results.update { $0.append(value) } }
            try require(!receiver.commit(stream: stream), "A candidate committed before its keyframe decoded")
            let finished = DispatchSemaphore(value: 0), background = CanvasLocked(false), decodedPixel = CanvasLocked(pixel)
            DispatchQueue.global().async {
                background.update { $0 = !Thread.isMainThread }
                decoder.finish(1, .success(decodedPixel.read()))
                finished.signal()
            }
            try require(finished.wait(timeout: .now() + 1) == .success && background.read() && results.read() == [true],
                        "Decode acknowledgement waited for the blocked main thread")
            drainCanvasDisplay()
            try require(displayed.isEmpty, "A candidate drew before commit")
            try require(receiver.commit(stream: stream), "A decoded candidate could not commit")
            drainCanvasDisplay()
            try require(displayed.count == 1 && displayed[0] === pixel, "Commit did not publish the candidate frame")
            try require(receiver.commit(stream: stream), "A duplicate active commit was rejected")
            drainCanvasDisplay()
            try require(displayed.count == 1, "A duplicate commit enqueued the same frame again")
        }

        run("Media display coalesces pending frames and uses the envelope frame ID for ordering") {
            let decoder = CanvasDecoderProbe()
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
            let first = try canvasPixel(), newest = try canvasPixel()
            var displayed: [CVPixelBuffer] = []
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in decoder }) { inbox in
                if let image = inbox.take() { displayed.append(image) }
            }
            defer { receiver.stop() }
            receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { _ in }
            decoder.finish(1, .success(first))
            try require(receiver.commit(stream: stream), "Initial frame failed to commit")
            for id in UInt64(2)...40 {
                receiver.receive(try mediaFrame(stream: stream, id: id, keyFrame: false)) { _ in }
                decoder.finish(UInt32(id), .success(id == 40 ? newest : first))
            }
            drainCanvasDisplay()
            try require(displayed.count == 1 && displayed[0] === newest,
                        "Pending display callbacks queued pixel buffers instead of replacing the latest frame")
        }

        run("Out-of-order decoder callbacks cannot regress the candidate's newest image") {
            let decoder = CanvasDecoderProbe()
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
            let first = try canvasPixel(), newer = try canvasPixel()
            var displayed: CVPixelBuffer?
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in decoder }) { displayed = $0.take() }
            defer { receiver.stop() }
            receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { _ in }
            receiver.receive(try mediaFrame(stream: stream, id: 2, keyFrame: false)) { _ in }
            decoder.finish(2, .success(newer))
            try require(!receiver.commit(stream: stream), "A P frame confirmed the candidate before its IDR")
            decoder.finish(1, .success(first))
            try require(receiver.commit(stream: stream), "Late IDR completion did not confirm the candidate")
            drainCanvasDisplay()
            try require(displayed === newer, "Late keyframe callback overwrote a newer decoded image")
        }

        run("Replacing a candidate or active stream settles pending decodes and fences late callbacks") {
            let probes = CanvasLocked<[CanvasDecoderProbe]>([]), outcomes = CanvasLocked<[Int: [Bool]]>([:])
            let session = UUID(), pixel = try canvasPixel()
            let streams = (1...3).map { MediaStreamID(sessionID: session, transportEpoch: UInt32($0), codecEpoch: 1) }
            var displays = 0
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in
                let probe = CanvasDecoderProbe(); probes.update { $0.append(probe) }; return probe
            }) { inbox in _ = inbox.take(); displays += 1 }
            defer { receiver.stop() }
            receiver.receive(try mediaFrame(stream: streams[0], id: 1, keyFrame: true)) { value in outcomes.update { $0[1, default: []].append(value) } }
            probes.read()[0].finish(1, .success(pixel))
            try require(receiver.commit(stream: streams[0]), "First stream could not commit")
            drainCanvasDisplay()
            receiver.receive(try mediaFrame(stream: streams[0], id: 2, keyFrame: false)) { value in outcomes.update { $0[2, default: []].append(value) } }
            receiver.receive(try mediaFrame(stream: streams[1], id: 3, keyFrame: true)) { value in outcomes.update { $0[3, default: []].append(value) } }
            receiver.receive(try mediaFrame(stream: streams[2], id: 4, keyFrame: true)) { value in outcomes.update { $0[4, default: []].append(value) } }
            try require(probes.read().count == 3 && probes.read()[1].stopped && outcomes.read()[3] == [false],
                        "Superseding a candidate retained its decoder or pending callback")
            probes.read()[1].finish(3, .success(pixel))
            try require(!receiver.commit(stream: streams[1]), "A retired candidate committed")
            probes.read()[2].finish(4, .success(pixel))
            try require(receiver.commit(stream: streams[2]), "Newest candidate did not commit")
            try require(probes.read()[0].stopped && outcomes.read()[2] == [false], "Old active decoder was not drained")
            probes.read()[0].finish(2, .success(pixel))
            drainCanvasDisplay()
            try require(displays == 2 && outcomes.read()[2] == [false] && outcomes.read()[3] == [false],
                        "A late retired callback displayed or acknowledged a second time")
            var rejected: [Bool] = []
            receiver.receive(try mediaFrame(stream: streams[0], id: 5, keyFrame: true)) { rejected.append($0) }
            receiver.receive(try mediaFrame(stream: .init(sessionID: UUID(), transportEpoch: 4, codecEpoch: 1), id: 6, keyFrame: true)) { rejected.append($0) }
            try require(rejected == [false, false] && probes.read().count == 3, "A stale epoch or different session allocated a decoder")
        }

        run("Media decode credit is bounded and stop completes every pending frame exactly once") {
            let decoder = CanvasDecoderProbe(), outcomes = CanvasLocked<[Bool]>([])
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1), pixel = try canvasPixel()
            var displays = 0
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in decoder }) { _ in displays += 1 }
            for id in UInt64(1)...4 {
                receiver.receive(try mediaFrame(stream: stream, id: id, keyFrame: id == 1)) { value in outcomes.update { $0.append(value) } }
            }
            try require(decoder.pendingCount == 3 && outcomes.read() == [false], "Receiver exceeded three pending decodes")
            receiver.stop(); receiver.stop()
            try require(outcomes.read() == [false, false, false, false] && decoder.stopped,
                        "Stop lost or duplicated a pending completion")
            for id in UInt32(1)...3 { decoder.finish(id, .success(pixel)) }
            drainCanvasDisplay()
            try require(outcomes.read().count == 4 && displays == 0 && !receiver.commit(stream: stream),
                        "A stopped receiver displayed or completed a late decode")
        }

        run("A queued display from an older commit cannot draw after the next commit or stop") {
            let probes = CanvasLocked<[CanvasDecoderProbe]>([]), session = UUID(), pixel = try canvasPixel()
            var displays = 0
            let receiver = MediaCanvasReceiver(makeDecoder: { _ in
                let probe = CanvasDecoderProbe(); probes.update { $0.append(probe) }; return probe
            }) { inbox in _ = inbox.take(); displays += 1 }
            for epoch in UInt32(1)...2 {
                let stream = MediaStreamID(sessionID: session, transportEpoch: epoch, codecEpoch: 1)
                receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { _ in }
                probes.read()[Int(epoch - 1)].finish(1, .success(pixel))
                try require(receiver.commit(stream: stream), "Fixture stream did not commit")
            }
            drainCanvasDisplay()
            try require(displays == 1, "An already queued old callback drew after a newer commit")
            let stream = MediaStreamID(sessionID: session, transportEpoch: 2, codecEpoch: 1)
            receiver.receive(try mediaFrame(stream: stream, id: 2, keyFrame: false)) { _ in }
            probes.read()[1].finish(2, .success(pixel))
            receiver.stop()
            drainCanvasDisplay()
            try require(displays == 1, "An already queued display callback drew after stop")
        }

        run("Media decode failures stay local and commits preserve canvas focus and input ownership") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let canvas = RemoteCanvas(frame: window.contentView!.bounds), decoder = CanvasDecoderProbe()
            canvas.canControl = true
            window.contentView = canvas
            try require(window.makeFirstResponder(canvas), "Canvas fixture did not acquire focus")
            var releases = 0, fatalFailures = 0, outcomes: [Bool] = []
            canvas.onRelease = { releases += 1 }
            canvas.onFailure = { _ in fatalFailures += 1 }
            let receiver = canvas.makeMediaReceiver(makeDecoder: { _ in decoder })
            defer { receiver.stop() }
            let stream = MediaStreamID(sessionID: UUID(), transportEpoch: 1, codecEpoch: 1)
            receiver.receive(try mediaFrame(stream: stream, id: 1, keyFrame: true)) { outcomes.append($0) }
            decoder.finish(1, .success(try canvasPixel()))
            try require(receiver.commit(stream: stream), "Canvas media stream could not commit")
            drainCanvasDisplay()
            try require(canvas.canControl && window.firstResponder === canvas && releases == 0,
                        "A video commit reset keyboard focus or released input")
            receiver.receive(try mediaFrame(stream: stream, id: 2, keyFrame: false)) { outcomes.append($0) }
            decoder.finish(2, .failure(CanvasCheckFailure("Synthetic decode failure")))
            drainCanvasDisplay()
            try require(outcomes == [true, false] && fatalFailures == 0 && releases == 0,
                        "Media decode failure closed the whole session or released input")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
