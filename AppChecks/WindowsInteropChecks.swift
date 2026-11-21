import AppKit
import Network
import VideoToolbox
import QuietDeskCore

// The Windows client is built from windows/core. These checks run that code, through the headless
// quietdesk-probe, against the macOS implementation over loopback TLS: this Mac's Peer, Hello, tuning,
// decoder, encoder, media session and input injector on one side, the probe on the other. The probe only
// stands in for what needs Windows: it replays a recorded stream instead of capturing and encoding, and
// reports frames instead of decoding and drawing them.

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) throws {
    guard try condition() else { throw Failure(message()) }
}

private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result { try lock.withLock { try body(&value) } }
}

private func until(_ what: String, seconds: Double = 10, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { throw Failure("Timed out waiting until \(what)") }
        usleep(2_000)
    }
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// The probe as a child process: commands go in and events come out as one JSON object per line.
private final class Probe {
    private let process = Process()
    private let input = Pipe()
    private let events = Shared<[[String: Any]]>([])
    private var consumed: [String: Int] = [:]

    init(_ path: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        let events = events
        let reader = Thread {
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<end]
                    pending = Data(pending[(end + 1)...])
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        events.update { $0.append(object) }
                    }
                }
            }
        }
        reader.stackSize = 1 << 20
        try process.run()
        reader.start()
    }

    func send(_ command: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    /// The next event of this name that has not been returned yet and satisfies `matching`.
    func next(_ name: String, seconds: Double = 10, matching: ([String: Any]) -> Bool = { _ in true }) throws -> [String: Any] {
        var found: [String: Any]?
        try until("the probe reports \(name)", seconds: seconds) {
            let all = events.get()
            var index = consumed[name] ?? 0
            while index < all.count {
                let event = all[index]
                index += 1
                if event["event"] as? String == name, matching(event) {
                    consumed[name] = index
                    found = event
                    return true
                }
            }
            return false
        }
        return found!
    }

    func all(_ name: String) -> [[String: Any]] { events.get().filter { $0["event"] as? String == name } }

    func stop() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
    }
}

/// Frames of a moving pattern encoded by this Mac's hardware or software H.264 encoder.
private func encodeFrames(width: Int, height: Int, count: Int) throws -> [VideoPacket] {
    let encoder = try VideoEncoder(width: width, height: height, settings: StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 3))
    defer { encoder.stop() }
    let ready = DispatchSemaphore(value: 0)
    let output = Shared<Result<VideoPacket, Error>?>(nil)
    encoder.onOutput = { result in output.update { $0 = result }; ready.signal() }
    encoder.onDropped = { _ in output.update { $0 = nil }; ready.signal() }
    var packets: [VideoPacket] = []
    var frame = 0
    while packets.count < count {
        frame += 1
        try require(frame < count * 4, "The encoder dropped most synthetic frames")
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw Failure("Creating synthetic pixels failed: \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                for column in 0..<stride {
                    base[row * stride + column] = plane == 0 ? UInt8(truncatingIfNeeded: (column + frame * 5) / 2 + row) : 128
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try encoder.encode(buffer, time: CMTime(value: Int64(frame), timescale: 30), sequence: UInt32(frame), forceKeyFrame: packets.isEmpty)
        try require(ready.wait(timeout: .now() + 10) == .success, "The synthetic encoder did not finish")
        if let result = output.get() { packets.append(try result.get()) }
    }
    try require(packets[0].hasParameterSets && packets.dropFirst().allSatisfy { $0.sps.isEmpty }, "Expected one keyframe followed by dependent frames")
    return packets
}

private func nalUnits(_ packet: VideoPacket) -> [Data] {
    var units: [Data] = []
    var reader = ByteReader(packet.avcc)
    while reader.remaining > 0, let length: UInt32 = try? reader.take(), let unit = try? reader.bytes(Int(length)) { units.append(Data(unit)) }
    return units
}

/// The byte stream a Windows encoder would hand over for this frame, and a Windows decoder would be given.
private func annexB(_ packet: VideoPacket) -> Data {
    ([packet.sps, packet.pps].filter { !$0.isEmpty } + nalUnits(packet)).reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
}

private func writeRecording(_ packets: [VideoPacket], to path: String) throws {
    var recording = Data()
    for packet in packets {
        let stream = annexB(packet)
        recording.put(UInt32(stream.count))
        recording.append(stream)
    }
    try recording.write(to: URL(fileURLWithPath: path))
}

/// The viewer steps of `DeskModel.handleViewer` that every released version performs, on Core types.
private final class MacViewer: @unchecked Sendable {
    struct State {
        var ready = false
        var closed: (reason: String, retryable: Bool)?
        var hello: Hello?
        var tuning: VideoTuningSession?
        var decoded: [(sequence: UInt32, key: Bool, width: Int, height: Int)] = []
        var received: [UInt32] = []
        var failures: [String] = []
        var results: [StreamSettingsResult] = []
        var control: [Bool] = []
        var pauses: [SessionPauseResult] = []
        var clipboard: [String] = []
        var terminated = false
        var holdAcknowledgements = false
    }
    let state = Shared(State())
    let peer: Peer
    private let decoder = VideoDecoder()
    private let preferred: StreamSettings

    init(port: UInt16, key: PairingKey, preferred: StreamSettings) {
        self.preferred = preferred
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: SecureTransport.parameters(key: key, responsiveAcknowledgements: true))
        peer = Peer(connection: connection)
        peer.onReady = { [state] in state.update { $0.ready = true } }
        peer.onClose = { [state, weak peer] reason in state.update { $0.closed = (reason, peer?.closeIsRetryable == true) } }
        peer.onMessage = { [weak self] message in
            guard let self else { return }
            do { try self.handle(message) }
            catch { self.state.update { $0.failures.append("\(message.kind): \(error)") } }
        }
        peer.start()
    }

    private func handle(_ message: Message) throws {
        switch message.kind {
        case .hello:
            let hello = try Wire.readJSON(Hello.self, message.payload)
            try hello.validate()
            let applied = VideoStreamState(settings: hello.settings, width: hello.width, height: hello.height)
            var tuning = try VideoTuningSession(applied: applied, preferred: preferred)
            if hello.sessionTerminationV1 == true { peer.send(try SessionTermination(.subscribe).message()) }
            if hello.controlStatusUpdates == true { peer.send(Message(.controlStatus)) }
            if hello.liveSettings == true {
                let request = hello.initialStreamNegotiationV1 == true ? tuning.initialConfirmationRequest() : tuning.nextRequest()
                if let request { peer.send(try Wire.json(.streamSettingsRequest, request)) }
            }
            state.update { $0.hello = hello; $0.tuning = tuning }
        case .video:
            let packet = try VideoPacket.decode(message.payload)
            state.update { $0.received.append(packet.sequence) }
            decoder.decode(packet) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let image):
                    let hold = self.state.update { state -> Bool in
                        state.decoded.append((packet.sequence, !packet.sps.isEmpty, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)))
                        return state.holdAcknowledgements
                    }
                    if !hold { self.acknowledge(packet.sequence) }
                case .failure(let error):
                    self.state.update { $0.failures.append("decode \(packet.sequence): \(error)") }
                }
            }
        case .streamSettingsResult:
            let result = try Wire.readJSON(StreamSettingsResult.self, message.payload)
            let next = try state.update { state -> StreamSettingsRequest? in
                guard var tuning = state.tuning, try tuning.receive(result, maximumFrameRate: 60) else { return nil }
                state.results.append(result)
                let next = tuning.nextRequest()
                state.tuning = tuning
                return next
            }
            if let next { peer.send(try Wire.json(.streamSettingsRequest, next)) }
        case .controlStatus:
            let status = try Wire.readJSON(ControlStatus.self, message.payload)
            state.update { $0.control.append(status.canControl) }
        case .sessionPauseResult:
            let result = try Wire.readJSON(SessionPauseResult.self, message.payload)
            state.update { $0.pauses.append(result) }
        case .sessionTermination:
            let notice = try SessionTermination.read(message.payload)
            try require(notice.operation == .ended, "The host sent a termination message of the wrong direction")
            state.update { $0.terminated = true }
        case .clipboard:
            guard let text = String(data: message.payload, encoding: .utf8) else { throw Failure("Clipboard text was not UTF-8") }
            state.update { $0.clipboard.append(text) }
        default:
            throw Failure("A released viewer would close the connection on this message")
        }
    }

    func acknowledge(_ sequence: UInt32) {
        var data = Data()
        data.put(sequence)
        peer.send(Message(.acknowledgement, data))
    }

    func choose(_ settings: StreamSettings) throws {
        let request = try state.update { state -> StreamSettingsRequest? in
            guard var tuning = state.tuning else { return nil }
            try tuning.choose(settings)
            let request = tuning.nextRequest()
            state.tuning = tuning
            return request
        }
        if let request { peer.send(try Wire.json(.streamSettingsRequest, request)) }
    }

    func send(_ input: RemoteInput) throws {
        try input.validate()
        peer.send(try Wire.json(.input, input))
    }
}

private struct PostedEvent {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let location: CGPoint
    let clicks: Int64
    let button: Int64
    let repeated: Bool
    let lines: (x: Double, y: Double)
    let pixels: (x: Int64, y: Int64)
}

/// The host steps of `DeskModel.accept` and `handleHost` that this protocol subset uses, on Core types and
/// the application's own input injector. Events the injector would post are recorded instead.
private final class MacHost: @unchecked Sendable {
    struct State {
        var accepted: [Peer] = []
        var peer: Peer?
        var media: MediaSession?
        var closed: String?
        var failures: [String] = []
        var waiting = Set<UInt32>()
        var sequence: UInt32 = 0
        var next = 0
        var paused = false
        var streaming = false
        var requests: [StreamSettingsRequest] = []
        var applied: VideoStreamState
        var subscribedTermination = false
        var subscribedControl = false
        var pauseRequests: [Bool] = []
        var clipboard = "Mac 主机剪贴板"
        var received: [MessageKind] = []
        var posted: [PostedEvent] = []
        var pointer = CGPoint(x: -1, y: -1)
        var released = 0
    }
    let state: Shared<State>
    let port: UInt16
    private let listener: NWListener
    private let packets: [VideoPacket]
    private let key: PairingKey
    private let size: (width: Int, height: Int)
    private let injector: InputInjector
    private var pump: DispatchSourceTimer?

    init(key: PairingKey, packets: [VideoPacket], size: (width: Int, height: Int)) throws {
        self.key = key
        self.packets = packets
        self.size = size
        let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
        let state = Shared(State(applied: VideoStreamState(settings: settings, width: size.width, height: size.height)))
        self.state = state
        injector = InputInjector(concurrentBounds: CGRect(x: 0, y: 0, width: 1600, height: 900), isTrusted: { true },
            postEvent: { event in
                let posted = PostedEvent(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                    location: event.location, clicks: event.getIntegerValueField(.mouseEventClickState),
                    button: event.getIntegerValueField(.mouseEventButtonNumber),
                    repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    lines: (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
                    pixels: (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
                state.update { state in
                    state.posted.append(posted)
                    if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) { state.pointer = event.location }
                }
            },
            capsLockState: { false }, pointerLocation: { state.get().pointer })
        let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        var accept: ((NWConnection) -> Void)?
        listener.newConnectionHandler = { accept?($0) }
        listener.start(queue: DispatchQueue(label: "interop.listener"))
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else { throw Failure("The loopback listener did not start") }
        self.port = port
        accept = { [weak self] connection in self?.accept(connection) }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        state.update { $0.accepted.append(peer) }
        peer.onClose = { [state] reason in state.update { $0.closed = reason } }
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            do {
                let role = MediaSecureTransport.negotiatedRole(on: connection)
                try require(role == nil || role == .control, "The viewer opened an auxiliary channel nobody offered")
                let applied = self.state.get().applied
                let media = try MediaSession.host(control: peer, key: self.key, port: self.port, settings: applied.settings, relayRouting: true)
                media.onAcknowledged = { [state = self.state] sequence in state.update { _ = $0.waiting.remove(sequence) } }
                media.start()
                self.state.update { $0.peer = peer; $0.media = media }
                // The capability set the application announces, with the fields of this Mac filled in.
                let preferred = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20)
                peer.send(try Wire.json(.hello, Hello(name: "检查用 Mac", width: applied.width, height: applied.height, settings: applied.settings,
                    canControl: true, preferredSettings: preferred.extendedCompatible, deviceID: UUID(), deviceIdentityExchange: true,
                    highRefreshVideoSettings: true, preferredHighRefreshSettings: preferred.highRefreshCompatible,
                    sessionEffects: true, sessionPause: true, mediaTransportV1: true, independentCursorV1: true,
                    relayTransportV1: true, relayDeviceID: nil, sessionLockV1: true, adaptiveVideoV1: true, sessionUnlockV1: true,
                    screenLocked: false, higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: preferred,
                    displayDimmingV1: true, builtInDisplayDimmable: false, sessionTerminationV1: true, desktopActionsV1: true,
                    hevcVideoV1: true, initialStreamNegotiationV1: true, hevc444VideoV1: true, displaySwitchingV1: true,
                    displays: [RemoteDisplayInfo(id: 1, name: "内建显示器", width: self.size.width, height: self.size.height, isMain: true)],
                    selectedDisplayID: 1, remoteAudioV1: true, relativeMouseV1: true, trackpadGesturesV1: true,
                    initialCursorNegotiationV1: true, qualityProbeV1: true, typeTextV1: true)))
                // The application waits this long for the viewer's first settings before it starts capture.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in self?.state.update { $0.streaming = true } }
            } catch {
                self.state.update { $0.failures.append("accept: \(error)") }
                peer.close("\(error)")
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            do { try self.handle(message, peer: peer) }
            catch {
                self.state.update { $0.failures.append("\(message.kind): \(error)") }
                peer.close("\(error)")
            }
        }
        peer.start()
        let pump = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "interop.frames"))
        pump.schedule(deadline: .now(), repeating: .milliseconds(4))
        pump.setEventHandler { [weak self] in self?.produceFrame() }
        self.pump = pump
        pump.resume()
    }

    private func produceFrame() {
        let frame = state.update { state -> (MediaSession, VideoPacket)? in
            guard state.streaming, !state.paused, let media = state.media, state.waiting.count < MediaBufferLimits.legacyFrameWindow else { return nil }
            let source = packets[state.next]
            state.next = (state.next + 1) % packets.count
            state.sequence &+= 1
            state.waiting.insert(state.sequence)
            return (media, VideoPacket(sequence: state.sequence, codec: .h264, vps: Data(), sps: source.sps, pps: source.pps, avcc: source.avcc))
        }
        if let (media, packet) = frame { media.sendVideo(packet) }
    }

    private func handle(_ message: Message, peer: Peer) throws {
        state.update { $0.received.append(message.kind) }
        if state.get().media?.receive(message) == true { return }
        switch message.kind {
        case .acknowledgement:
            try require(message.payload.count == 4, "A frame acknowledgement had the wrong size")
            var reader = ByteReader(message.payload)
            let sequence: UInt32 = try reader.take()
            state.update { _ = $0.waiting.remove(sequence) }
        case .sessionTermination:
            try require(SessionTermination.read(message.payload).operation == .subscribe, "The viewer sent a termination message of the wrong direction")
            state.update { $0.subscribedTermination = true }
        case .controlStatus:
            try require(message.payload.isEmpty, "The control subscription carried a payload")
            state.update { $0.subscribedControl = true }
            peer.send(try Wire.json(.controlStatus, ControlStatus(canControl: true)))
        case .streamSettingsRequest:
            let request = try Wire.readJSON(StreamSettingsRequest.self, message.payload)
            try request.validate()
            let dimensions = request.settings.dimensions(width: size.width, height: size.height)
            let applied = VideoStreamState(settings: request.settings, width: dimensions.0, height: dimensions.1)
            let restart = state.update { state -> Bool in
                state.requests.append(request)
                let restart = state.streaming && state.applied != applied
                state.applied = applied
                if restart { state.next = 0; state.waiting.removeAll() }
                state.streaming = true
                return restart
            }
            peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: applied, error: nil,
                codec: request.codec == nil ? nil : .h264, chromaSubsampling: request.chromaSubsampling == nil ? nil : .yuv420,
                restartsStream: restart)))
        case .sessionPauseRequest:
            let request = try Wire.readJSON(SessionPauseRequest.self, message.payload)
            injector.releaseAllOnInputQueue()
            state.update { state in
                state.pauseRequests.append(request.paused)
                state.paused = request.paused
                if !request.paused { state.next = 0; state.waiting.removeAll() }
            }
            peer.send(try Wire.json(.sessionPauseResult, SessionPauseResult(id: request.id, paused: request.paused)))
        case .input:
            let input = try Wire.readJSON(RemoteInput.self, message.payload)
            try input.validate()
            _ = try injector.receiveImmediateOnInputQueue(input, validated: true)
        case .releaseInput:
            injector.releaseAllOnInputQueue()
            state.update { $0.released += 1 }
        case .clipboard:
            guard message.payload.count <= Wire.maximumClipboardBytes, let text = String(data: message.payload, encoding: .utf8) else {
                throw Failure("Clipboard text was too large or not UTF-8")
            }
            state.update { $0.clipboard = text }
        case .requestClipboard:
            peer.send(Message(.clipboard, Data(state.get().clipboard.utf8)))
        default:
            throw DeskError.invalid("收到当前角色不支持的消息")
        }
    }

    func end() {
        pump?.cancel()
        let current = state.get()
        current.media?.stop()
        current.peer?.closeAfterSessionTermination(notify: current.subscribedTermination)
    }

    func stop() {
        pump?.cancel()
        let current = state.get()
        current.media?.stop()
        current.accepted.forEach { $0.close("check finished") }
        listener.cancel()
    }
}

private func settings(_ event: [String: Any]) -> [Int] {
    guard let stream = event["stream"] as? [String: Any], let settings = stream["settings"] as? [String: Any] else { return [] }
    return ["longestEdge", "framesPerSecond", "megabits"].compactMap { settings[$0] as? Int } + ["width", "height"].compactMap { stream[$0] as? Int }
}

@main
private struct WindowsInteropChecks {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            print("usage: WindowsInteropChecks <quietdesk-probe> <work directory>")
            exit(2)
        }
        let probePath = CommandLine.arguments[1], work = CommandLine.arguments[2]
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        let size = (width: 640, height: 360)
        let packets: [VideoPacket]
        let recording = work + "/recording.h264"
        do {
            packets = try encodeFrames(width: size.width, height: size.height, count: 24)
            try writeRecording(packets, to: recording)
        } catch {
            print("FAIL Encoding the synthetic stream: \(error)")
            exit(1)
        }
        let key = try! PairingKey.generate()
        let command = Int(CGEventFlags.maskCommand.rawValue) | 0x08, shift = Int(CGEventFlags.maskShift.rawValue) | 0x02

        func withWindowsHost(_ extra: [String] = [], viewerKey: PairingKey? = nil, preferred: StreamSettings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8),
                             _ body: (Probe, MacViewer) throws -> Void) throws {
            let probe = try Probe(probePath, ["host", "--code", key.code, "--recording", recording, "--size", "\(size.width)x\(size.height)",
                                              "--name", "检查用 Windows 电脑"] + extra)
            defer { probe.stop() }
            guard let port = try probe.next("listening")["port"] as? Int else { throw Failure("The probe did not report its port") }
            let viewer = MacViewer(port: UInt16(port), key: viewerKey ?? key, preferred: preferred)
            defer { viewer.peer.close("check finished") }
            try body(probe, viewer)
            let failures = viewer.state.get().failures
            try require(failures.isEmpty, "The macOS viewer rejected what the Windows host sent: \(failures)")
        }

        run("A Mac viewer pairs with a Windows host, reads its hello and starts the stream once with its own settings") {
            let preferred = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20)
            try withWindowsHost(preferred: preferred) { probe, viewer in
                try until("the Windows host's hello arrives") { viewer.state.get().hello != nil }
                let hello = viewer.state.get().hello!
                try require(hello.name == "检查用 Windows 电脑" && hello.width == 640 && hello.height == 360 && hello.canControl, "Hello carried other basics")
                try require(hello.settings == StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8), "Hello carried other settings")
                try require(hello.liveSettings == true && hello.extendedVideoSettings == true && hello.highRefreshVideoSettings == true
                            && hello.controlStatusUpdates == true && hello.sessionPause == true && hello.sessionTerminationV1 == true
                            && hello.initialStreamNegotiationV1 == true, "Hello did not announce what the Windows host implements")
                try require(hello.mediaTransportV1 == nil && hello.independentCursorV1 == nil && hello.clipboardSync == nil && hello.inputActions == nil
                            && hello.hevcVideoV1 == nil && hello.adaptiveVideoV1 == nil && hello.higherFrameRateVideoV1 == nil && hello.remoteAudioV1 == nil
                            && hello.displaySwitchingV1 == nil && hello.sessionEffects == nil && hello.deviceIdentityExchange == nil
                            && hello.relativeMouseV1 == nil && hello.trackpadGesturesV1 == nil && hello.typeTextV1 == nil && hello.desktopActionsV1 == nil,
                            "Hello announced something the Windows host does not implement")
                try until("the stream is confirmed") { viewer.state.get().results.count == 1 }
                let result = viewer.state.get().results[0]
                try require(result.state == VideoStreamState(settings: preferred, width: 640, height: 360) && result.error == nil
                            && result.codec == nil && result.chromaSubsampling == nil, "The first settings were not applied as asked: \(result)")
                try require(probe.all("configured").count == 1 && settings(try probe.next("configured")) == [2560, 60, 20, 640, 360],
                            "The Windows host started its stream more than once or with other settings")
                try until("control status arrives") { viewer.state.get().control == [true] }
            }
        }

        run("VideoToolbox decodes the stream a Windows host frames, and three unacknowledged frames stop it") {
            try withWindowsHost { _, viewer in
                try until("thirty frames decode") { viewer.state.get().decoded.count >= 30 }
                let decoded = viewer.state.get().decoded
                try require(decoded.map(\.sequence) == Array(1...UInt32(decoded.count)), "Frames arrived out of order: \(decoded.map(\.sequence))")
                try require(decoded.allSatisfy { $0.width == 640 && $0.height == 360 }, "Decoded pictures had another size")
                // The recording holds one keyframe per 24 frames; the replay starts over with it.
                try require(decoded.prefix(30).enumerated().allSatisfy { $0.element.key == ($0.offset % 24 == 0) }, "Keyframes were not where the encoder put them")
                viewer.state.update { $0.holdAcknowledgements = true }
                usleep(200_000)
                let stalled = viewer.state.get().received.count
                usleep(200_000)
                let held = viewer.state.get()
                try require(held.received.count == stalled, "The host kept sending without acknowledgements")
                let outstanding = held.received.suffix(3)
                try require(Set(outstanding).isSubset(of: Set(held.decoded.map(\.sequence))), "Unacknowledged frames were not decoded")
                viewer.state.update { $0.holdAcknowledgements = false }
                outstanding.forEach(viewer.acknowledge)
                try until("frames resume") { viewer.state.get().received.count > stalled + 6 }
            }
        }

        run("A Windows host lowers a request to its limit, restarts from a keyframe and survives a setting its encoder refuses") {
            try withWindowsHost(["--limit", "2560,60,30", "--refuse-edge", "1280"]) { probe, viewer in
                try until("frames flow") { viewer.state.get().decoded.count >= 5 }
                try viewer.choose(.highest)
                try until("the lowered settings are confirmed") { viewer.state.get().results.count == 2 }
                var current = viewer.state.get()
                let lowered = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 30)
                try require(current.results[1].state.settings == lowered && current.results[1].error == nil, "The limit was not applied: \(current.results[1])")
                try require(current.tuning?.applied.settings == lowered && current.tuning?.desired == lowered && current.tuning?.pending == nil,
                            "The viewer's tuning session did not settle on what the host applied")
                let before = current.decoded.count
                try until("the restarted stream decodes") { viewer.state.get().decoded.count > before + 5 }
                current = viewer.state.get()
                try require(current.decoded[before...].contains { $0.key }, "The restarted stream did not begin with a keyframe")

                try viewer.choose(StreamSettings(longestEdge: 1280, framesPerSecond: 60, megabits: 30))
                try until("the refusal is reported") { viewer.state.get().results.count == 3 }
                current = viewer.state.get()
                try require(current.results[2].state.settings == lowered && current.results[2].error?.contains("编码器不支持") == true,
                            "A refused setting did not report the stream that keeps running: \(current.results[2])")
                let afterRefusal = current.decoded.count
                try until("the previous stream continues") { viewer.state.get().decoded.count > afterRefusal + 5 }
                try require(probe.all("configured").count == 3, "The host did not return to its previous stream exactly once")
            }
        }

        run("Mac keys, modifiers, clicks and scrolling reach a Windows host as the keys at the same positions") {
            func operations(_ probe: Probe) throws -> [String] { (try probe.next("inject")["operations"] as? [String]) ?? [] }
            try withWindowsHost { probe, viewer in
                try until("frames flow") { viewer.state.get().decoded.count >= 1 }
                var flags = RemoteInput(kind: .flags); flags.keyCode = 55; flags.flags = UInt64(command)
                try viewer.send(flags)
                try require(try operations(probe) == ["Key { key: Scan { code: 29, extended: false }, down: true }"], "Command did not press Ctrl")
                var key = RemoteInput(kind: .keyDown); key.keyCode = 8; key.flags = UInt64(command)
                try viewer.send(key)
                try require(try operations(probe) == ["CapsLock(false)", "Key { key: Scan { code: 46, extended: false }, down: true }"], "C was not pressed at its position")
                key.kind = .keyUp
                try viewer.send(key)
                try require(try operations(probe) == ["Key { key: Scan { code: 46, extended: false }, down: false }"], "C was not released")
                flags.flags = 0
                try viewer.send(flags)
                try require(try operations(probe) == ["Key { key: Scan { code: 29, extended: false }, down: false }"], "Command did not release Ctrl")

                var arrow = RemoteInput(kind: .keyDown); arrow.keyCode = 126
                arrow.flags = UInt64(shift) | UInt64(CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
                try viewer.send(arrow)
                try require(try operations(probe) == ["Key { key: Scan { code: 42, extended: false }, down: true }", "CapsLock(false)",
                                                      "Key { key: Scan { code: 72, extended: true }, down: true }"], "A keystroke did not carry the Shift of its own flags")
                viewer.peer.send(Message(.releaseInput))
                try require(try operations(probe) == ["Key { key: Scan { code: 72, extended: true }, down: false }",
                                                      "Key { key: Scan { code: 42, extended: false }, down: false }"], "Losing focus did not release what was held")

                var press = RemoteInput(kind: .down); press.x = 0.25; press.y = 0.75; press.button = 1; press.clicks = 2
                try viewer.send(press)
                try require(try operations(probe) == ["Move { x: 0.25, y: 0.75 }", "Button { button: Right, down: true }"], "A right press arrived differently")
                var wheel = RemoteInput(kind: .scroll); wheel.x = 0.5; wheel.y = 0.5; wheel.deltaY = -36; wheel.lineDeltaX = 0; wheel.lineDeltaY = -3
                try viewer.send(wheel)
                try require(try operations(probe) == ["Move { x: 0.5, y: 0.5 }", "Wheel { vertical: -120, horizontal: 0 }"], "Three wheel lines were not one notch")
                var gesture = RemoteInput(kind: .scroll); gesture.x = 0.5; gesture.y = 0.5; gesture.deltaX = 40; gesture.deltaY = 80
                gesture.scrollPhase = .changed
                try viewer.send(gesture)
                try require(try operations(probe) == ["Move { x: 0.5, y: 0.5 }", "Wheel { vertical: 120, horizontal: -60 }"], "A trackpad gesture scrolled differently")
            }
            try withWindowsHost(["--standard-modifiers"]) { probe, viewer in
                try until("frames flow") { viewer.state.get().decoded.count >= 1 }
                var flags = RemoteInput(kind: .flags); flags.keyCode = 55; flags.flags = UInt64(command)
                try viewer.send(flags)
                try require(try operations(probe) == ["Key { key: Scan { code: 91, extended: true }, down: true }"], "Command did not press the Windows key")
            }
        }

        run("Pausing, withdrawn control, clipboard text and the host's ending reach a Mac viewer as its own host would send them") {
            try withWindowsHost { probe, viewer in
                try until("frames flow") { viewer.state.get().decoded.count >= 3 }
                let pause = SessionPauseRequest(paused: true)
                viewer.peer.send(try Wire.json(.sessionPauseRequest, pause))
                try until("the pause is confirmed") { viewer.state.get().pauses.count == 1 }
                try require(viewer.state.get().pauses[0].id == pause.id && viewer.state.get().pauses[0].paused && viewer.state.get().pauses[0].error == nil, "The pause was answered differently")
                usleep(150_000)
                let paused = viewer.state.get().received.count
                usleep(150_000)
                try require(viewer.state.get().received.count == paused, "Frames kept arriving while paused")
                viewer.peer.send(try Wire.json(.sessionPauseRequest, SessionPauseRequest(paused: false)))
                try until("frames resume") { viewer.state.get().decoded.count > paused }
                try require(viewer.state.get().decoded[paused].key, "A resumed stream did not start from a keyframe")

                try probe.send(["command": "allowControl", "value": false])
                try until("the viewer hears control was withdrawn") { viewer.state.get().control == [true, false] }
                let before = probe.all("inject").count
                var click = RemoteInput(kind: .down); click.x = 0.5; click.y = 0.5
                try viewer.send(click)

                viewer.peer.send(Message(.requestClipboard))
                try until("the host's clipboard text arrives") { viewer.state.get().clipboard == ["probe host clipboard 剪贴板"] }
                try require(probe.all("inject").count == before, "Input was injected after control was withdrawn")
                viewer.peer.send(Message(.clipboard, Data("来自 Mac 的文字".utf8)))
                try require(try probe.next("clipboard")["text"] as? String == "来自 Mac 的文字", "Clipboard text from the Mac arrived differently")

                try probe.send(["command": "end"])
                try until("the ending notice arrives") { viewer.state.get().terminated }
                try until("the connection closes") { viewer.state.get().closed != nil }
                try require(try probe.next("ended")["reason"] as? String == SessionTermination.hostEndedReason, "The host ended for another reason")
            }
        }

        run("A Mac viewer with another pairing code gets no further with a Windows host than with a Mac host") {
            try withWindowsHost(viewerKey: try PairingKey.generate()) { probe, viewer in
                try require(try probe.next("rejected")["reason"] as? String != nil, "The Windows host did not record the refusal")
                // Network.framework reports the host's bad-record-MAC alert while it keeps the connection
                // waiting, exactly as it does against a Mac host; Peer then ends the attempt at its
                // handshake timeout. The session never becomes ready and no hello is delivered.
                usleep(300_000)
                let current = viewer.state.get()
                try require(!current.ready && current.hello == nil && current.received.isEmpty, "A viewer without the key got through")
                try require(probe.all("accepted").isEmpty, "The Windows host accepted a viewer without the key")
            }
        }

        func withMacHost(viewerKey: PairingKey? = nil, quality: String = "1920,60,20", _ extra: [String] = [], _ body: (MacHost, Probe) throws -> Void) throws {
            let host = try MacHost(key: key, packets: packets, size: size)
            defer { host.stop() }
            let probe = try Probe(probePath, ["viewer", "--code", (viewerKey ?? key).code, "--port", "\(host.port)", "--quality", quality] + extra)
            defer { probe.stop() }
            try body(host, probe)
            let failures = host.state.get().failures
            try require(failures.isEmpty, "The macOS host rejected what the Windows viewer sent: \(failures)")
        }

        run("A Windows viewer pairs with a Mac host, reads the application's hello and confirms its settings before capture starts") {
            try withMacHost { host, probe in
                _ = try probe.next("secured")
                let connected = try probe.next("connected")
                try require(connected["name"] as? String == "检查用 Mac" && connected["canControl"] as? Bool == true && connected["liveSettings"] as? Bool == true
                            && settings(connected) == [1920, 30, 8, 640, 360], "The Windows viewer read the hello differently: \(connected)")
                let stream = try probe.next("stream")
                try require(settings(stream) == [1920, 60, 20, 640, 360] && stream["error"] is NSNull, "The confirmed stream differs: \(stream)")
                let current = host.state.get()
                try require(current.requests.count == 1 && current.requests[0].settings == StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 20)
                            && current.requests[0].codec == nil && current.requests[0].chromaSubsampling == nil
                            && current.requests[0].cursorRequestID == nil && current.requests[0].independentCursor == nil,
                            "The first settings request was not the plain H.264 request a released host expects: \(current.requests)")
                try require(current.subscribedTermination && current.subscribedControl, "The viewer did not subscribe to the ending notice and control changes")
                try require(try probe.next("control")["canControl"] as? Bool == true, "The control status did not arrive")
                try require(!current.received.contains(.mediaControl) && !current.received.contains(.cursorControl) && !current.received.contains(.deviceIdentity)
                            && !current.received.contains(.clipboardSettings) && !current.received.contains(.displayControl) && !current.received.contains(.audioControl),
                            "The viewer used an extension it does not implement: \(current.received)")
            }
        }

        run("A Mac host's media session sends a Windows viewer plain video messages, byte for byte what the encoder produced") {
            try withMacHost { host, probe in
                var frames: [[String: Any]] = []
                for _ in 0..<30 { frames.append(try probe.next("frame")) }
                try require(frames.compactMap { $0["sequence"] as? Int } == Array(1...30), "Frames arrived out of order")
                for (index, frame) in frames.enumerated() {
                    let source = packets[index % packets.count]
                    try require(frame["key"] as? Bool == !source.sps.isEmpty, "Frame \(index + 1) lost its keyframe marking")
                    try require(frame["annexB"] as? String == hex(annexB(source)), "Frame \(index + 1) reached the decoder with other bytes")
                }
                try probe.send(["command": "holdAcknowledgements", "hold": true])
                usleep(200_000)
                let stalled = probe.all("frame").count
                usleep(200_000)
                try require(probe.all("frame").count == stalled && host.state.get().waiting.count == 3, "The host's frame window was not three")
                try probe.send(["command": "holdAcknowledgements", "hold": false])
                for sequence in host.state.get().waiting { try probe.send(["command": "acknowledge", "sequence": Int(sequence)]) }
                try until("frames resume") { probe.all("frame").count > stalled + 6 }
            }
        }

        run("PC keys, modifiers, clicks and a wheel reach the Mac's own input injector as Mac events") {
            func key(_ scanCode: Int, _ down: Bool, extended: Bool = false, repeated: Bool = false, capsLock: Bool = false) -> [String: Any] {
                ["command": "key", "scanCode": scanCode, "extended": extended, "down": down, "repeat": repeated, "capsLock": capsLock]
            }
            func posted(_ host: MacHost, _ count: Int) throws -> [PostedEvent] {
                try until("the injector builds \(count) events") { host.state.get().posted.count >= count }
                usleep(50_000)
                let events = host.state.update { state -> [PostedEvent] in defer { state.posted.removeAll() }; return state.posted }
                try require(events.count == count, "Expected \(count) events, the injector built \(events.count): \(events.map { "\($0.type.rawValue)/\($0.keyCode)" })")
                return events
            }
            let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]
            try withMacHost { host, probe in
                _ = try probe.next("frame")
                // Left Ctrl, C, release both: Control-C on the Mac, as Apple maps a PC keyboard.
                for command in [key(0x1D, true), key(0x2E, true), key(0x2E, true, repeated: true), key(0x2E, false), key(0x1D, false)] { try probe.send(command) }
                var events = try posted(host, 5)
                try require(events.map(\.type) == [.flagsChanged, .keyDown, .keyDown, .keyUp, .flagsChanged], "Key events arrived as other kinds")
                try require(events.map(\.keyCode) == [59, 8, 8, 8, 59], "Keys arrived at other positions: \(events.map(\.keyCode))")
                try require(events[0...3].allSatisfy { $0.flags.intersection(modifiers) == .maskControl } && events[4].flags.intersection(modifiers) == [],
                            "Control was not held exactly around the key")
                try require(events.map(\.repeated) == [false, false, true, false, false], "Auto-repeat was not marked")

                // The Windows key is Command; an arrow carries the flags AppKit gives it.
                for command in [key(0x5B, true, extended: true), key(0x4B, true, extended: true), key(0x4B, false, extended: true), key(0x5B, false, extended: true)] { try probe.send(command) }
                events = try posted(host, 4)
                try require(events.map(\.keyCode) == [55, 123, 123, 55], "Command-Left arrived as other keys: \(events.map(\.keyCode))")
                try require(events[1].flags.contains([.maskCommand, .maskNumericPad, .maskSecondaryFn]), "The arrow lost Command or its own flags")

                // Caps Lock reports the new lock state once; the Mac's lock follows it.
                for command in [key(0x3A, true, capsLock: true), key(0x3A, false, capsLock: true), key(0x1E, true, capsLock: true), key(0x1E, false, capsLock: true)] { try probe.send(command) }
                events = try posted(host, 3)
                try require(events.map(\.keyCode) == [57, 0, 0] && events[0].type == .flagsChanged && events[1].flags.contains(.maskAlphaShift),
                            "Caps Lock did not reach the Mac as a lock state: \(events.map(\.keyCode))")
                try probe.send(key(0x3A, true, capsLock: false))
                events = try posted(host, 1)
                try require(events[0].keyCode == 57 && !events[0].flags.contains(.maskAlphaShift), "Caps Lock was not switched off")

                // Two presses at one place are a double click; moving with the button down is a drag.
                try probe.send(["command": "move", "x": 0.5, "y": 0.5])
                try probe.send(["command": "button", "button": 0, "down": true, "x": 0.5, "y": 0.5, "atMilliseconds": 1000, "pixel": [400, 300]])
                try probe.send(["command": "button", "button": 0, "down": false, "x": 0.5, "y": 0.5, "atMilliseconds": 1060, "pixel": [400, 300]])
                try probe.send(["command": "button", "button": 0, "down": true, "x": 0.5, "y": 0.5, "atMilliseconds": 1200, "pixel": [401, 300]])
                try probe.send(["command": "move", "x": 0.75, "y": 0.5])
                try probe.send(["command": "button", "button": 0, "down": false, "x": 0.75, "y": 0.5, "atMilliseconds": 1400, "pixel": [600, 300]])
                events = try posted(host, 6)
                try require(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp], "Pointer events arrived as other kinds")
                try require(events.map(\.clicks) == [1, 1, 1, 2, 2, 2], "Click counts were \(events.map(\.clicks))")
                try require(events[1].location == CGPoint(x: 799.5, y: 449.5) && events[4].location == CGPoint(x: 1199.25, y: 449.5), "Positions were not fractions of the Mac's display")
                try probe.send(["command": "button", "button": 1, "down": true, "x": 0.1, "y": 0.9, "atMilliseconds": 3000, "pixel": [80, 540]])
                try probe.send(["command": "button", "button": 1, "down": false, "x": 0.1, "y": 0.9, "atMilliseconds": 3050, "pixel": [80, 540]])
                events = try posted(host, 2)
                try require(events.map(\.type) == [.rightMouseDown, .rightMouseUp], "The right button arrived as another button")

                // One notch away from the user scrolls three lines up; the pointer moves to the wheel's target first.
                try probe.send(["command": "wheel", "vertical": 1, "horizontal": 0, "x": 0.25, "y": 0.25])
                events = try posted(host, 2)
                try require(events.map(\.type) == [.mouseMoved, .scrollWheel] && events[1].lines.y == 3 && events[1].lines.x == 0 && events[1].pixels.y == 36,
                            "A wheel notch arrived as \(events.last.map { "\($0.lines) \($0.pixels)" } ?? "nothing")")

                // Losing the window releases what the Mac still holds.
                try probe.send(key(0x2A, true))
                _ = try posted(host, 1)
                try probe.send(["command": "release"])
                try until("the release arrives") { host.state.get().released == 1 }
                events = try posted(host, 1)
                try require(events[0].type == .flagsChanged && events[0].keyCode == 56 && !events[0].flags.contains(.maskShift), "Shift was not released")
            }
            try withMacHost(["--control-as-command"]) { host, probe in
                _ = try probe.next("frame")
                for command in [key(0x1D, true), key(0x2E, true)] { try probe.send(command) }
                let events = try posted(host, 2)
                try require(events.map(\.keyCode) == [55, 8] && events[1].flags.intersection(modifiers) == .maskCommand, "Left Ctrl did not act as Command")
            }
        }

        run("Quality changes, pausing, clipboard text and the Mac host's ending reach a Windows viewer") {
            try withMacHost { host, probe in
                _ = try probe.next("stream")
                _ = try probe.next("frame")
                try probe.send(["command": "quality", "settings": "8192,240,100"])
                let stream = try probe.next("stream")
                // This viewer decodes up to 60 frames per second, so it asks for no more.
                try require(settings(stream) == [8192, 60, 100, 640, 360] && host.state.get().requests.last?.settings == StreamSettings(longestEdge: 8192, framesPerSecond: 60, megabits: 100),
                            "The quality change arrived differently: \(stream)")

                try probe.send(["command": "pause", "paused": true])
                try require(try probe.next("paused")["paused"] as? Bool == true, "The pause was not confirmed")
                usleep(150_000)
                let paused = probe.all("frame").count
                usleep(150_000)
                try require(probe.all("frame").count == paused, "Frames kept arriving while paused")
                try probe.send(["command": "pause", "paused": false])
                try require(try probe.next("paused")["paused"] as? Bool == false, "The resume was not confirmed")
                try until("frames resume") { probe.all("frame").count > paused }
                try require(probe.all("frame")[paused]["key"] as? Bool == true, "The resumed stream did not start from a keyframe")
                try require(host.state.get().pauseRequests == [true, false], "The Mac host saw other pause requests")

                try probe.send(["command": "requestClipboard"])
                try require(try probe.next("clipboardText")["text"] as? String == "Mac 主机剪贴板", "The Mac's clipboard text arrived differently")
                try probe.send(["command": "sendClipboard", "text": "来自 Windows 的文字"])
                try until("the Mac stores the viewer's text") { host.state.get().clipboard == "来自 Windows 的文字" }

                host.end()
                let ended = try probe.next("ended")
                try require(ended["hostEnded"] as? Bool == true && ended["retryable"] as? Bool == false && ended["reason"] as? String == SessionTermination.hostEndedReason,
                            "The Windows viewer did not recognise that the Mac's user ended the session: \(ended)")
            }
        }

        run("A Windows viewer with another pairing code is refused by a Mac host as a pairing failure") {
            try withMacHost(viewerKey: try PairingKey.generate()) { host, probe in
                let failed = try probe.next("failed")
                print("    the probe reported: \(failed["reason"] as? String ?? "")")
                try require((failed["reason"] as? String)?.contains("配对码") == true, "A wrong pairing code was reported as another kind of failure: \(failed)")
                try until("the Mac host gives up on the connection") { host.state.get().closed != nil }
                try require(host.state.get().peer == nil && host.state.get().closed?.contains("TLS") == true,
                            "The Mac host did not refuse the handshake itself: \(host.state.get().closed ?? "")")
            }
        }

        print("Windows interop checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
