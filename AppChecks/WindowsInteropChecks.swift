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

private func writeRecording(_ packets: [VideoPacket], to path: String) throws -> [Data] {
    // Store the parameter sets and picture NALs that the Windows encoder hands to FrameSink.
    // Annex B discards trailing zero padding. VideoToolbox can also add non-picture SEI or filler.
    let frames = packets.map { packet in
        let units = [packet.sps, packet.pps].filter { !$0.isEmpty } + nalUnits(packet).filter {
            $0.first.map { (1...5).contains($0 & 0x1f) } == true
        }
        return units.reduce(into: Data()) { result, unit in
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(unit.prefix(through: unit.lastIndex(where: { $0 != 0 })!))
        }
    }
    var recording = Data()
    for stream in frames {
        recording.put(UInt32(stream.count))
        recording.append(stream)
    }
    try recording.write(to: URL(fileURLWithPath: path))
    return frames
}

/// The viewer steps of `DeskModel.handleViewer` that every released version performs, on Core types.
private final class MacViewer: @unchecked Sendable {
    struct State {
        var ready = false
        var closed: (reason: String, retryable: Bool)?
        var hello: Hello?
        var media: MediaSession?
        var commits: [MediaStreamID] = []
        var commitPaths: [String] = []
        var mediaFrames: [MediaFrame] = []
        var heldDecodes: [(frameID: UInt64, complete: () -> Void)] = []
        var cursor = CursorPresentationState()
        var cursorRequest: UUID?
        var cursorStatus: CursorControl?
        var cursorBinding: MediaStreamID?
        var readyWithCursor: [MediaStreamID] = []
        var tuning: VideoTuningSession?
        var decoded: [(sequence: UInt32, key: Bool, width: Int, height: Int)] = []
        var received: [UInt32] = []
        var legacyFrames = 0
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

    private let port: UInt16
    private let key: PairingKey
    private let useMedia: Bool

    init(port: UInt16, key: PairingKey, preferred: StreamSettings, useMedia: Bool) {
        self.port = port
        self.key = key
        self.useMedia = useMedia
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
        if let media = state.get().media {
            if message.kind == .mediaFrame {
                let frame = try MediaFrame.decode(message.payload)
                state.update { $0.mediaFrames.append(frame) }
            } else if message.kind == .mediaControl {
                let control = try MediaControl.read(message.payload)
                if control.operation == .commit, let path = control.path { state.update { $0.commitPaths.append(path) } }
                if control.operation == .ready {
                    state.update { state in
                        if let binding = state.cursorBinding, control.sessionID == binding.sessionID,
                           control.transportEpoch == binding.transportEpoch, control.codecEpoch == binding.codecEpoch {
                            state.readyWithCursor.append(binding)
                        }
                    }
                }
            }
            if media.receive(message) { return }
        }
        switch message.kind {
        case .hello:
            let hello = try Wire.readJSON(Hello.self, message.payload)
            try hello.validate()
            let applied = VideoStreamState(settings: hello.settings, width: hello.width, height: hello.height)
            var tuning = try VideoTuningSession(applied: applied, preferred: preferred)
            if hello.sessionTerminationV1 == true { peer.send(try SessionTermination(.subscribe).message()) }
            if hello.controlStatusUpdates == true { peer.send(Message(.controlStatus)) }
            if useMedia, hello.mediaTransportV1 == true {
                let media = try MediaSession.viewer(control: peer, key: key, host: "127.0.0.1", port: port, settings: hello.settings)
                media.onVideo = { [weak self] frame, complete in
                    self?.decode(frame.packet, frameID: frame.header.frameID, completion: complete)
                }
                media.onCommitStream = { [state] stream, _ in
                    state.update { state in
                        state.commits.append(stream)
                        state.cursor.commit(stream)
                    }
                }
                state.update { $0.media = media }
                media.start()
            }
            if hello.liveSettings == true {
                let request = hello.initialStreamNegotiationV1 == true ? tuning.initialConfirmationRequest() : tuning.nextRequest()
                if let request { peer.send(try Wire.json(.streamSettingsRequest, request)) }
            }
            state.update { $0.hello = hello; $0.tuning = tuning }
        case .video:
            let packet = try VideoPacket.decode(message.payload)
            state.update { $0.legacyFrames += 1 }
            decode(packet, frameID: nil) { [weak self] success in
                if success { self?.acknowledge(packet.sequence) }
            }
        case .cursorControl where state.get().hello?.independentCursorV1 == true:
            let control = try CursorControl.read(message.payload)
            try state.update { state in
                switch control.operation {
                case .status:
                    if control.requestID == state.cursorRequest, state.cursor.status(control) { state.cursorStatus = control }
                case .binding:
                    if state.cursor.bind(control) { state.cursorBinding = control.stream?.stream }
                case .request: throw Failure("The host sent a cursor request")
                }
            }
        case .cursorShape where state.get().hello?.independentCursorV1 == true:
            let shape = try CursorShape.decode(message.payload)
            state.update { _ = $0.cursor.update(shape) }
        case .cursorPosition where state.get().hello?.independentCursorV1 == true:
            let position = try CursorPosition.decode(message.payload)
            state.update { _ = $0.cursor.update(position) }
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
            state.get().media?.setPaused(result.paused)
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

    private func decode(_ packet: VideoPacket, frameID: UInt64?, completion: @escaping (Bool) -> Void) {
        state.update { $0.received.append(packet.sequence) }
        decoder.decode(packet) { [state] result in
            switch result {
            case .success(let image):
                let hold = state.update { state -> Bool in
                    state.decoded.append((packet.sequence, !packet.sps.isEmpty, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)))
                    if state.holdAcknowledgements, let frameID {
                        state.heldDecodes.append((frameID, { completion(true) }))
                    }
                    return state.holdAcknowledgements
                }
                if !hold { completion(true) }
            case .failure(let error):
                state.update { $0.failures.append("decode \(packet.sequence): \(error)") }
                completion(false)
            }
        }
    }

    func stop() {
        let media = state.update { state -> MediaSession? in
            defer { state.media = nil; state.heldDecodes.removeAll() }
            return state.media
        }
        media?.stop()
        decoder.stop()
        peer.close("check finished")
    }

    func acknowledge(_ sequence: UInt32) {
        var data = Data()
        data.put(sequence)
        peer.send(Message(.acknowledgement, data))
    }

    func requestCursor(enabled: Bool) throws -> UUID {
        let id = UUID()
        state.update { $0.cursorRequest = id }
        peer.send(try CursorControl(.request, requestID: id, enabled: enabled).message())
        return id
    }

    func releaseHeldDecodes() {
        let held = state.update { state -> [() -> Void] in
            state.holdAcknowledgements = false
            defer { state.heldDecodes.removeAll() }
            return state.heldDecodes.map(\.complete)
        }
        held.forEach { $0() }
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

private enum SyntheticCursor {
    static let rgba: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0,
        0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 255
    ]
    static func image() throws -> CursorImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 12, bitsPerPixel: 32), let data = bitmap.bitmapData else {
            throw Failure("The synthetic cursor bitmap could not be allocated")
        }
        rgba.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: $0.count) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("Encoding the cursor PNG failed") }
        return try CursorImage(png: png, pixelWidth: 3, pixelHeight: 2, logicalWidth: 1.5, logicalHeight: 1, hotSpotX: 0.5, hotSpotY: 0.25)
    }

    static func verify(_ image: CursorImage?) throws {
        guard let image, let bitmap = NSBitmapImageRep(data: image.png) else { throw Failure("The Windows cursor PNG could not be decoded") }
        try require(bitmap.pixelsWide == 3 && bitmap.pixelsHigh == 2 && bitmap.samplesPerPixel == 4
                    && image.logicalWidth == 1.5 && image.logicalHeight == 1 && image.hotSpotX == 0.5 && image.hotSpotY == 0.25,
                    "The Windows cursor lost its size, alpha or scaled hotspot")
        var pixel = [Int](repeating: 0, count: 4)
        for index in 0..<6 {
            bitmap.getPixel(&pixel, atX: index % 3, y: index / 3)
            try require(pixel == rgba[index * 4 ..< index * 4 + 4].map(Int.init), "Cursor pixel \(index) arrived with different channels")
        }
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
        var prepared = false
        var commits: [MediaControl] = []
        var cursorRequest: CursorControl?
        var heldCursorPreparation: (stream: MediaStreamID, complete: (Bool) -> Void)?
        var decodedFeedback = Set<MediaFrameHeader>()
        var recoverySequences: [UInt32] = []
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
    private let advertiseMedia: Bool
    private let cursorImage: CursorImage?
    private let cursorID = UUID()
    private let listener: NWListener
    private let packets: [VideoPacket]
    private let key: PairingKey
    private let size: (width: Int, height: Int)
    private let injector: InputInjector
    private var pump: DispatchSourceTimer?

    init(key: PairingKey, packets: [VideoPacket], size: (width: Int, height: Int), advertiseMedia: Bool, cursorImage: CursorImage?) throws {
        self.advertiseMedia = advertiseMedia
        self.cursorImage = cursorImage
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
                media.onPrepareStream = { [state = self.state, cursorID = self.cursorID, weak peer] stream, completion in
                    let request = state.update { state in
                        state.prepared = true; state.waiting.removeAll()
                        return state.cursorRequest
                    }
                    guard let request else { completion(true); return }
                    guard let peer else { completion(false); return }
                    do {
                        peer.send(try CursorControl(.binding, cursorID: cursorID, epoch: 1, enabled: request.enabled, stream: stream).message())
                        state.update { $0.heldCursorPreparation = (stream, completion) }
                    } catch {
                        state.update { $0.failures.append("binding: \(error)") }
                        completion(false)
                    }
                }
                media.onProduceRecoveryFrame = { [weak self] in self?.produceFrame(recovery: true) }
                media.onResumeFrames = { [state = self.state] in state.update { $0.prepared = false } }
                media.onAcknowledged = { [state = self.state] sequence in state.update { _ = $0.waiting.remove(sequence) } }
                media.start()
                self.state.update { $0.peer = peer; $0.media = media }
                // The capability set the application announces, with the fields of this Mac filled in.
                let preferred = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20)
                peer.send(try Wire.json(.hello, Hello(name: "检查用 Mac", width: applied.width, height: applied.height, settings: applied.settings,
                    canControl: true, preferredSettings: preferred.extendedCompatible, deviceID: UUID(), deviceIdentityExchange: true,
                    highRefreshVideoSettings: true, preferredHighRefreshSettings: preferred.highRefreshCompatible,
                    sessionEffects: true, sessionPause: true, mediaTransportV1: self.advertiseMedia ? true : nil,
                    independentCursorV1: self.cursorImage == nil ? nil : true,
                    relayTransportV1: true, relayDeviceID: nil, sessionLockV1: true, adaptiveVideoV1: true, sessionUnlockV1: true,
                    screenLocked: false, higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: preferred,
                    displayDimmingV1: true, builtInDisplayDimmable: false, sessionTerminationV1: true, desktopActionsV1: true,
                    hevcVideoV1: true, initialStreamNegotiationV1: true, hevc444VideoV1: true, displaySwitchingV1: true,
                    displays: [RemoteDisplayInfo(id: 1, name: "内建显示器", width: self.size.width, height: self.size.height, isMain: true)],
                    selectedDisplayID: 1, remoteAudioV1: true, relativeMouseV1: true, trackpadGesturesV1: true,
                    initialCursorNegotiationV1: self.cursorImage == nil ? nil : true, qualityProbeV1: true, typeTextV1: true)))
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

    private func produceFrame(recovery: Bool = false) {
        state.update { state in
            guard state.streaming, !state.paused, state.prepared == recovery, let media = state.media,
                  state.waiting.count < MediaBufferLimits.legacyFrameWindow else { return }
            if recovery { state.next = 0 }
            let source = packets[state.next]
            state.next = (state.next + 1) % packets.count
            state.sequence &+= 1
            if recovery { state.recoverySequences.append(state.sequence) }
            state.waiting.insert(state.sequence)
            media.sendVideo(VideoPacket(sequence: state.sequence, codec: .h264, vps: Data(), sps: source.sps, pps: source.pps, avcc: source.avcc))
        }
    }

    private func handle(_ message: Message, peer: Peer) throws {
        state.update { $0.received.append(message.kind) }
        if advertiseMedia {
            if message.kind == .mediaControl {
                let control = try MediaControl.read(message.payload)
                if control.operation == .committed { state.update { $0.commits.append(control) } }
            } else if message.kind == .mediaFeedback {
                let feedback = try MediaFeedback.decode(message.payload)
                if feedback.kind == .decoded { state.update { _ = $0.decodedFeedback.insert(feedback.header) } }
            }
            if state.get().media?.receive(message) == true { return }
        }
        switch message.kind {
        case .cursorControl:
            let request = try CursorControl.read(message.payload)
            let current = state.get()
            guard let cursorImage, let media = current.media, current.commits.count == 1, current.cursorRequest == nil,
                  request.operation == .request, request.enabled else { throw Failure("Unexpected cursor request or request before the first commit") }
            media.suspendForConfiguration { [state, cursorID] in
                do {
                    state.update { $0.cursorRequest = request; $0.prepared = true }
                    peer.send(try CursorControl(.status, requestID: request.requestID, cursorID: cursorID, epoch: 1, enabled: true).message())
                    peer.send(Message(.cursorShape, try CursorShape(cursorID: cursorID, epoch: 1, revision: 1, image: cursorImage).encode()))
                    let position = try CursorPosition(cursorID: cursorID, epoch: 1, sequence: 1, insideDisplay: true, x: 0.25, y: 0.75)
                    peer.send(Message(.cursorPosition, position.encode()))
                    media.resumeAfterConfiguration()
                } catch {
                    state.update { $0.failures.append("cursor: \(error)") }
                    peer.close("\(error)")
                }
            }
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
                if restart {
                    state.next = 0
                    state.waiting.removeAll()
                    // The reconfigured encoder waits for a new media commit before emitting P-frames.
                    if !state.commits.isEmpty { state.prepared = true }
                }
                state.streaming = true
                return restart
            }
            state.get().media?.updateSettings(applied.settings, restartsStream: restart)
            peer.send(try Wire.json(.streamSettingsResult, StreamSettingsResult(id: request.id, state: applied, error: nil,
                codec: request.codec == nil ? nil : .h264, chromaSubsampling: request.chromaSubsampling == nil ? nil : .yuv420,
                restartsStream: restart)))
        case .sessionPauseRequest:
            let request = try Wire.readJSON(SessionPauseRequest.self, message.payload)
            injector.releaseAllOnInputQueue()
            state.update { state in
                state.pauseRequests.append(request.paused)
                state.paused = request.paused
                if !request.paused {
                    state.next = 0
                    state.waiting.removeAll()
                    if !state.commits.isEmpty { state.prepared = true }
                }
            }
            peer.send(try Wire.json(.sessionPauseResult, SessionPauseResult(id: request.id, paused: request.paused)))
            state.get().media?.setPaused(request.paused)
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
        listener.cancel()
        let current = state.update { state -> State in
            defer { state.peer = nil; state.media = nil; state.accepted.removeAll() }
            return state
        }
        current.media?.stop()
        current.accepted.forEach { $0.close("check finished") }
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
        let replayFrames: [Data]
        do {
            packets = try encodeFrames(width: size.width, height: size.height, count: 24)
            replayFrames = try writeRecording(packets, to: recording)
        } catch {
            print("FAIL Encoding the synthetic stream: \(error)")
            exit(1)
        }
        let key = try! PairingKey.generate()
        let command = Int(CGEventFlags.maskCommand.rawValue) | 0x08, shift = Int(CGEventFlags.maskShift.rawValue) | 0x02

        func withWindowsHost(_ extra: [String] = [], useMedia: Bool = true, viewerKey: PairingKey? = nil, preferred: StreamSettings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8),
                             _ body: (Probe, MacViewer) throws -> Void) throws {
            let probe = try Probe(probePath, ["host", "--code", key.code, "--recording", recording, "--size", "\(size.width)x\(size.height)",
                                              "--name", "检查用 Windows 电脑"] + extra)
            defer { probe.stop() }
            guard let port = try probe.next("listening")["port"] as? Int else { throw Failure("The probe did not report its port") }
            let viewer = MacViewer(port: UInt16(port), key: viewerKey ?? key, preferred: preferred, useMedia: useMedia)
            defer { viewer.stop() }
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
                try require(hello.mediaTransportV1 == true, "The Windows host omitted the media capability")
                try require(hello.independentCursorV1 == nil && hello.clipboardSync == nil && hello.inputActions == nil
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

        run("A legacy Mac viewer decodes Windows video, and three unacknowledged frames stop it") {
            try withWindowsHost(useMedia: false) { _, viewer in
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

        run("A Mac viewer commits shared Windows streams, decodes exact media frames and returns frame credits") {
            try withWindowsHost { _, viewer in
                func verifyStream(_ count: Int) throws {
                    try until("shared stream \(count) delivers dependent frames") {
                        let state = viewer.state.get()
                        guard state.commits.count >= count else { return false }
                        return state.mediaFrames.filter { $0.header.stream == state.commits[count - 1] }.count >= 8
                    }
                    let state = viewer.state.get(), stream = state.commits[count - 1]
                    try require(state.commits.count == count && Set(state.commits).count == count
                                && state.commitPaths == Array(repeating: "shared", count: count),
                                "Expected \(count) distinct shared commits, got \(state.commitPaths)")
                    if count > 1 {
                        let old = state.commits[count - 2]
                        try require(stream.sessionID == old.sessionID && stream.transportEpoch > old.transportEpoch
                                    && stream.codecEpoch > old.codecEpoch, "The new stream reused an old epoch")
                    }
                    let frames = state.mediaFrames.filter { $0.header.stream == stream }.prefix(8)
                    for (index, frame) in frames.enumerated() {
                        try require(frame.header.frameID == UInt64(index + 1) && frame.header.isIDR == (index == 0)
                                    && annexB(frame.packet) == replayFrames[index], "Media frame \(index + 1) differed from the recording")
                    }
                    let eighth = frames.last!.packet.sequence
                    try until("VideoToolbox decodes the new stream") { viewer.state.get().decoded.contains { $0.sequence == eighth } }
                }

                try verifyStream(1)
                try require(viewer.state.get().legacyFrames > 0, "No legacy frames decoded before the shared path opened")
                viewer.state.update { $0.holdAcknowledgements = true }
                try until("three media frames remain unpaid") {
                    let state = viewer.state.get()
                    guard let held = state.heldDecodes.first, let last = state.mediaFrames.last else { return false }
                    return last.header.frameID >= held.frameID + 2
                }
                usleep(100_000)
                let state = viewer.state.get()
                try require(state.mediaFrames.last!.header.frameID == state.heldDecodes.first!.frameID + 2,
                            "A Windows host sent more than three frames without decode feedback")
                viewer.releaseHeldDecodes()
                try until("decode feedback reopens the window") { viewer.state.get().mediaFrames.count > state.mediaFrames.count + 6 }

                try viewer.choose(StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20))
                try verifyStream(2)
                viewer.peer.send(try Wire.json(.sessionPauseRequest, SessionPauseRequest(paused: true)))
                try until("the host is paused") { viewer.state.get().pauses.last?.paused == true }
                viewer.peer.send(try Wire.json(.sessionPauseRequest, SessionPauseRequest(paused: false)))
                try verifyStream(3)
            }
        }

        run("A Mac viewer switches its synthetic Windows cursor exactly when the bound screen becomes visible") {
            try withWindowsHost(["--synthetic-cursor"]) { _, viewer in
                try until("the first shared stream and initial quality are confirmed") {
                    let state = viewer.state.get()
                    return state.commits.count == 1 && !state.results.isEmpty && state.mediaFrames.last?.header.frameID ?? 0 > 1
                }
                let hello = viewer.state.get().hello
                try require(hello?.independentCursorV1 == true && hello?.initialCursorNegotiationV1 != true,
                            "The Windows host advertised a different cursor negotiation")
                viewer.state.update { $0.holdAcknowledgements = true }
                let request = try viewer.requestCursor(enabled: true)
                try until("the cursor-bound keyframe and the synthetic cursor have arrived") {
                    let s = viewer.state.get()
                    return s.cursor.position != nil && s.cursor.image != nil && s.cursorBinding != nil && s.heldDecodes.contains { $0.frameID == 1 }
                }
                let pending = viewer.state.get()
                guard let binding = pending.cursorBinding, let status = pending.cursorStatus, let position = pending.cursor.position else {
                    throw Failure("Missing cursor status, binding or position")
                }
                try require(status.requestID == request && status.enabled && status.reason == nil && pending.commits.count == 1
                            && pending.readyWithCursor == [binding] && !pending.cursor.enabled, "The cursor switched before the bound picture committed")
                try SyntheticCursor.verify(pending.cursor.image)
                try require(position.insideDisplay && position.x == 0.25 && position.y == 0.75, "Windows sent another cursor location")
                viewer.releaseHeldDecodes()
                try until("both ends have committed the bound stream") {
                    let state = viewer.state.get()
                    return state.cursor.enabled && state.commits.last == binding && state.mediaFrames.last?.header.stream == binding
                        && state.mediaFrames.last?.header.frameID ?? 0 > 1
                }

                let disable = try viewer.requestCursor(enabled: false)
                try until("the following stream restores the video cursor") {
                    let state = viewer.state.get()
                    return state.cursorStatus?.requestID == disable && state.commits.count == 3 && !state.cursor.enabled
                }
                let final = viewer.state.get()
                try require(final.cursorStatus?.cursorID == status.cursorID && final.cursorStatus?.enabled == false
                            && final.cursor.epoch > pending.cursor.epoch && final.readyWithCursor == Array(final.commits.dropFirst()),
                            "Disabling the cursor did not bind the new mode to its own stream")
            }
        }

        run("A Windows host lowers a request to its limit, restarts from a keyframe and survives a setting its encoder refuses") {
            try withWindowsHost(["--limit", "2560,60,30", "--refuse-edge", "1280"], useMedia: false) { probe, viewer in
                try until("frames flow") { viewer.state.get().decoded.count >= 5 }
                let before = viewer.state.get().decoded.count
                try viewer.choose(.highest)
                try until("the lowered settings are confirmed") { viewer.state.get().results.count == 2 }
                var current = viewer.state.get()
                let lowered = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 30)
                try require(current.results[1].state.settings == lowered && current.results[1].error == nil, "The limit was not applied: \(current.results[1])")
                try require(current.tuning?.applied.settings == lowered && current.tuning?.desired == lowered && current.tuning?.pending == nil,
                            "The viewer's tuning session did not settle on what the host applied")
                try until("the restarted stream decodes") {
                    viewer.state.get().decoded.dropFirst(before).contains { $0.key }
                }
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
            try withWindowsHost(useMedia: false) { probe, viewer in
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

        func withMacHost(advertiseMedia: Bool = true, cursorImage: CursorImage? = nil, viewerKey: PairingKey? = nil, quality: String = "1920,60,20", _ extra: [String] = [], _ body: (MacHost, Probe) throws -> Void) throws {
            let host = try MacHost(key: key, packets: packets, size: size, advertiseMedia: advertiseMedia, cursorImage: cursorImage)
            defer { host.stop() }
            let probe = try Probe(probePath, ["viewer", "--code", (viewerKey ?? key).code, "--port", "\(host.port)", "--quality", quality] + extra)
            defer { probe.stop() }
            try body(host, probe)
            let failures = host.state.get().failures
            try require(failures.isEmpty, "The macOS host rejected what the Windows viewer sent: \(failures)")
        }

        func verifyWindowsViewerWindow(_ host: MacHost, _ probe: Probe) throws {
            try probe.send(["command": "holdAcknowledgements", "hold": true])
            let sequences = try (0..<MediaBufferLimits.legacyFrameWindow).map { _ -> UInt32 in
                let frame = try probe.next("frame") { $0["held"] as? Bool == true }
                guard let sequence = frame["sequence"] as? UInt32 else { throw Failure("Held frame omitted its sequence") }
                return sequence
            }
            // Even though the pump has had time to produce more frames, only the held pictures
            // may be outstanding until the platform returns their actual receipts.
            usleep(100_000)
            let frames = probe.all("frame")
            try require(frames.filter { $0["held"] as? Bool == true }.count == sequences.count
                        && host.state.get().waiting == Set(sequences), "The host exceeded or prematurely released its decode window")
            try probe.send(["command": "holdAcknowledgements", "hold": false])
            for sequence in sequences { try probe.send(["command": "acknowledge", "sequence": Int(sequence)]) }
            try until("decode receipts reopen the Mac capture window") { probe.all("frame").count > frames.count + 6 }
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
                try require(!current.received.contains(.cursorControl) && !current.received.contains(.deviceIdentity)
                            && !current.received.contains(.clipboardSettings) && !current.received.contains(.displayControl) && !current.received.contains(.audioControl),
                            "The viewer used an extension it does not implement: \(current.received)")
            }
        }

        run("A Mac host without mediaTransportV1 sends plain video to a Windows viewer, byte for byte what the encoder produced") {
            try withMacHost(advertiseMedia: false) { host, probe in
                var frames: [[String: Any]] = []
                for _ in 0..<30 { frames.append(try probe.next("frame")) }
                try require(frames.compactMap { $0["sequence"] as? Int } == Array(1...30), "Frames arrived out of order")
                for (index, frame) in frames.enumerated() {
                    let source = packets[index % packets.count]
                    try require(frame["firstInMediaStream"] is NSNull && frame["key"] as? Bool == !source.sps.isEmpty,
                                "Legacy frame \(index + 1) changed path or lost its keyframe marking")
                    try require(frame["annexB"] as? String == hex(annexB(source)), "Frame \(index + 1) reached the decoder with other bytes")
                }
                try verifyWindowsViewerWindow(host, probe)
            }
        }

        run("A Windows viewer commits shared Mac streams and returns decode receipts for the encoder's exact frames") {
            try withMacHost { host, probe in
                func verifyStream(_ count: Int) throws {
                    let event = try probe.next("mediaCommitted")
                    try until("the Mac host sees shared commit \(count)") { host.state.get().commits.count >= count }
                    let state = host.state.get(), commit = state.commits[count - 1]
                    try require(state.commits.count == count && state.recoverySequences.count == count && commit.path == "shared"
                                && event["sessionID"] as? String == commit.sessionID?.uuidString.lowercased()
                                && event["transportEpoch"] as? UInt32 == commit.transportEpoch
                                && event["codecEpoch"] as? UInt32 == commit.codecEpoch, "The endpoints committed different streams")
                    let first = Int(state.recoverySequences[count - 1])
                    for index in 0..<8 {
                        let frame = try probe.next("frame") { $0["sequence"] as? Int == first + index }
                        try require(frame["annexB"] as? String == hex(annexB(packets[index])) && frame["key"] as? Bool == (index == 0)
                                    && frame["firstInMediaStream"] as? Bool == (index == 0),
                                    "Windows received different bytes for shared frame \(index + 1)")
                    }
                    try until("the Windows viewer acknowledges the decoded media frame") {
                        host.state.get().decodedFeedback.contains {
                            $0.stream.sessionID == commit.sessionID && $0.stream.codecEpoch == commit.codecEpoch
                            && $0.stream.transportEpoch == commit.transportEpoch && $0.frameID == 8
                        }
                    }
                }

                try verifyStream(1)
                try verifyWindowsViewerWindow(host, probe)

                try probe.send(["command": "quality", "settings": "2560,30,8"])
                try verifyStream(2)
                try probe.send(["command": "pause", "paused": true])
                try require(try probe.next("paused")["paused"] as? Bool == true, "The Windows viewer did not observe the pause")
                try probe.send(["command": "pause", "paused": false])
                try verifyStream(3)
            }
        }

        run("A Windows viewer presents the Mac cursor image, hotspot and position only with its bound stream") {
            try withMacHost(cursorImage: SyntheticCursor.image()) { host, probe in
                _ = try probe.next("mediaCommitted")
                try until("the Mac has sent the cursor binding and is holding its ready") { host.state.get().heldCursorPreparation != nil }
                let initial = host.state.get().requests.first
                try require(initial != nil && initial?.cursorRequestID == nil && initial?.independentCursor == nil,
                            "The Windows viewer combined its cursor request with initial video tuning")
                // This text reply on the ordered control connection establishes that the probe processed the binding.
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                try require(!probe.all("cursor").contains { $0["enabled"] as? Bool == true }, "The Windows viewer enabled a cursor over the old picture")
                guard let pending = host.state.update({ state in
                    defer { state.heldCursorPreparation = nil }
                    return state.heldCursorPreparation
                }) else { throw Failure("The prepared cursor binding vanished") }
                pending.complete(true)
                let commit = try probe.next("mediaCommitted")
                try require(commit["sessionID"] as? String == pending.stream.sessionID.uuidString.lowercased()
                            && commit["transportEpoch"] as? UInt32 == pending.stream.transportEpoch
                            && commit["codecEpoch"] as? UInt32 == pending.stream.codecEpoch, "The viewer committed the wrong cursor stream")
                let active = try probe.next("cursor") { $0["enabled"] as? Bool == true && $0["position"] is [String: Any] && $0["image"] is [String: Any] }
                let image = active["image"] as! [String: Any], position = active["position"] as! [String: Any]
                try require(image["rgba"] as? String == hex(Data(SyntheticCursor.rgba)) && image["width"] as? Int == 3 && image["height"] as? Int == 2
                            && image["logicalWidth"] as? Double == 1.5 && image["logicalHeight"] as? Double == 1
                            && image["hotSpotX"] as? Double == 0.5 && image["hotSpotY"] as? Double == 0.25
                            && position["inside"] as? Bool == true && position["x"] as? Double == 0.25 && position["y"] as? Double == 0.75,
                            "The Windows presentation lost the Mac's RGBA pixels, hotspot or position")
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
            try withMacHost(advertiseMedia: false) { host, probe in
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
