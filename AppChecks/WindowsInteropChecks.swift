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

    func exitStatus() throws -> Int32 {
        try until("the probe exits on its own") { !process.isRunning }
        return process.terminationStatus
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
    }
}

private enum CheckFEC: String, CaseIterable {
    case legacy, xor, block
}

/// Forwards loopback ciphertext. Halting only its UDP half leaves the bound TCP roles available.
private final class InteropMediaRoute: @unchecked Sendable {
    enum FragmentLoss {
        case firstFullFragmentAndParity
        case everyFullFragment
    }

    let port: UInt16
    let dropped = Shared(0)
    private let tcp: RelayOpaqueProxy
    private let udp: NWListener
    private let queue = DispatchQueue(label: "interop.datagram-route")
    private var sizes: [Int: Int] = [:]
    private var loss: FragmentLoss?
    private let pongDelay: Double
    private let delayed = DispatchQueue(label: "interop.delayed-probes", attributes: .concurrent)
    private var forwarding: Bool
    private var holdingProbes = false
    private var heldProbes: [(NWConnection, Data)] = []
    private var peers: [NWConnection] = []

    init(target: UInt16, forwardUDP: Bool, pongDelay: Double = 0) throws {
        self.pongDelay = pongDelay
        forwarding = forwardUDP
        tcp = try RelayOpaqueProxy(target: target)
        let ready = DispatchSemaphore(value: 0)
        tcp.onReady = { ready.signal() }
        tcp.start()
        guard ready.wait(timeout: .now() + 5) == .success, let port = tcp.port, let listen = NWEndpoint.Port(rawValue: port),
              let upstream = NWEndpoint.Port(rawValue: target) else { throw Failure("The loopback TCP route did not start") }
        self.port = port
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: listen)
        udp = try NWListener(using: parameters)
        udp.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        udp.newConnectionHandler = { [weak self] incoming in
            guard let self else { incoming.cancel(); return }
            let outgoing = NWConnection(host: "127.0.0.1", port: upstream, using: .udp)
            self.peers += [incoming, outgoing]
            incoming.start(queue: self.queue)
            outgoing.start(queue: self.queue)
            self.receive(from: incoming, to: outgoing, video: false)
            self.receive(from: outgoing, to: incoming, video: true)
        }
        udp.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { stop(); throw Failure("The loopback UDP route did not start") }
    }

    // The negotiated AES-GCM record adds its explicit nonce and tag after the 13-byte DTLS header.
    static let overhead = 13 + 8 + 16
    static let full = overhead + 1 + MediaFragment.maximumDatagramBytes
    static let xor = overhead + 1 + MediaFrameParity.encodedHeaderBytes + MediaFragment.maximumPayloadBytes
    static let block = overhead + 1 + MediaFrameFECShard.encodedHeaderBytes + MediaFragment.maximumPayloadBytes

    func loseVideoFragments(_ loss: FragmentLoss) {
        queue.sync { sizes.removeAll(); self.loss = loss }
    }

    func sizesAfterLoss() -> [Int: Int] { queue.sync { sizes } }

    private func receive(from source: NWConnection, to target: NWConnection, video: Bool) {
        source.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            var forward = self.forwarding
            if video, data.first == 23, let loss = self.loss {
                self.sizes[data.count, default: 0] += 1
                if data.count == Self.full {
                    if loss == .everyFullFragment || self.sizes[data.count] == 1 { forward = false }
                } else if loss == .firstFullFragmentAndParity && (data.count == Self.xor || data.count == Self.block) {
                    forward = false
                }
            }
            let isProbe = data.first == 23 && data.count == Self.overhead + 1024
            if forward, video, self.pongDelay > 0, isProbe {
                self.delayed.async { [weak self] in
                    guard let self else { return }
                    Thread.sleep(forTimeInterval: self.pongDelay)
                    self.queue.async {
                        guard self.forwarding else { return }
                        if self.holdingProbes { self.heldProbes.append((target, data)) }
                        else { target.send(content: data, completion: .idempotent) }
                    }
                }
            } else if forward, isProbe, self.holdingProbes {
                self.heldProbes.append((target, data))
            } else if forward { target.send(content: data, completion: .idempotent) }
            else { self.dropped.update { $0 += 1 } }
            self.receive(from: source, to: target, video: video)
        }
    }

    func holdProbes(_ enabled: Bool) {
        queue.sync {
            holdingProbes = enabled
            if !enabled {
                let pending = heldProbes
                heldProbes.removeAll()
                for (target, data) in pending { target.send(content: data, completion: .idempotent) }
            }
        }
    }

    func forwardUDP(_ enabled: Bool) { queue.sync { forwarding = enabled } }

    func stop() {
        tcp.stop()
        queue.sync { udp.cancel(); peers.forEach { $0.cancel() }; peers.removeAll() }
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
private final class InteropClipboard: @unchecked Sendable {
    let directory: URL
    let physical: Bool
    let receivesFileRootNames: Bool
    let transfer = Shared<ClipboardTransfer?>(nil)
    let copied = Shared<ClipboardPayload?>(nil)
    let manifest = Shared<ClipboardManifest?>(nil)
    let offers = Shared<[ClipboardFileOffer]>([])
    let applied = Shared<[ClipboardPayload]>([])
    let sent = Shared<[MessageKind]>([])
    let received = Shared<[MessageKind]>([])
    let completedSends = Shared<[Bool]>([])
    let bulkReceived = Shared<[MessageKind]>([])
    private let media = Shared<MediaSession?>(nil)
    private let session = Shared<UUID?>(nil)

    init(_ directory: URL, physical: Bool = true, receivesFileRootNames: Bool = true) {
        self.directory = directory
        self.physical = physical
        self.receivesFileRootNames = physical && receivesFileRootNames
    }

    func attach(_ session: MediaSession, to peer: Peer, failed: @escaping (String) -> Void) {
        media.update { $0 = session }
        session.onReliableData = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            do {
                try require(message.kind != .clipboardSettings && message.kind != .clipboardManifest,
                            "Windows sent clipboard negotiation or a manifest on the bulk connection")
                try require(self.receive(message, from: peer), "Unexpected message on bound bulk connection")
                self.bulkReceived.update { $0.append(message.kind) }
            } catch { failed("bulk: \(error)") }
        }
    }

    func greet(_ peer: Peer, id: UUID) throws {
        session.update { $0 = id }
        peer.send(try Wire.json(.clipboardSettings, ClipboardPreference(enabled: true, session: id,
                    receivesAutomaticUpdates: true, physicalFilePasteV1: physical ? true : nil,
                    fileRootNamesV1: receivesFileRootNames ? true : nil)))
    }

    func receive(_ message: Message, from peer: Peer) throws -> Bool {
        switch message.kind {
        case .clipboardSettings:
            let preference = try Wire.readJSON(ClipboardPreference.self, message.payload)
            guard let id = preference.session, preference.enabled, preference.fileApproval == true,
                  preference.onDemandClipboard == true, !physical || preference.physicalFilePasteV1 == true else {
                throw Failure("The Windows peer did not negotiate compatible clipboard settings")
            }
            if receivesFileRootNames {
                try require(preference.providesFileRootNamesV1 == true, "Windows omitted its file-root name provider capability")
            }
            if let existing = session.get() { try require(existing == id, "Clipboard session changed") }
            else { try greet(peer, id: id) }
            if transfer.get() != nil { return true }
            let copy = ClipboardTransfer(storage: directory.appendingPathComponent("received-by-mac"), requireFileApproval: true,
                allowsChunkWindow: preference.chunkWindow == true, allowsDecoupledFileTransfer: preference.decoupledFileTransfer == true,
                allowsOnDemandClipboard: true, allowsPhysicalFilePaste: physical, allowsFileRootNames: receivesFileRootNames)
            copy.onSend = { [weak peer, sent, media] message in
                sent.update { $0.append(message.kind) }
                if let session = media.get() { session.sendReliableData(message) } else { peer?.send(message) }
            }
            copy.onManifest = { [manifest] next in manifest.update { $0 = next } }
            copy.onFileOffer = { [offers] in if let offer = $0 { offers.update { $0.append(offer) } } }
            copy.onReceive = { [applied] payload in applied.update { $0.append(payload) } }
            copy.validatePulledPNG = { NSBitmapImageRep(data: $0) != nil }
            copy.onPullRequested = { [weak copy, copied, completedSends] request in
                guard let payload = copied.get() else { copy?.rejectPull(request, reason: "synthetic copy expired"); return }
                copy?.sendPulled(payload, requestID: request.requestID) { success in completedSends.update { $0.append(success) } }
            }
            transfer.update { $0 = copy }
        case .clipboardManifest, .clipboardPull, .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            guard let copy = transfer.get() else { throw Failure("Clipboard data preceded negotiation") }
            received.update { $0.append(message.kind) }
            copy.receive(message)
        default: return false
        }
        return true
    }
}

private enum StereoTone {
    static func encode() throws -> (cookie: Data?, packets: [Data]) {
        let encoder = try OpusAudioEncoder()
        let count = RemoteAudioControl.framesPerPacket
        var packets: [Data] = []
        for block in 0..<20 where packets.count < 12 {
            var samples: [Float] = []
            for frame in block * count..<(block + 1) * count {
                for frequency in [330.0, 660.0] {
                    let phase = 2 * Double.pi * frequency * Double(frame) / Double(RemoteAudioControl.sampleRate)
                    samples.append(Float(0.15 * sin(phase)))
                }
            }
            packets += try encoder.encode(interleavedStereoSamples: samples)
        }
        try require(packets.count >= 12, "Apple's Opus encoder produced too few packets")
        return (encoder.magicCookie, packets)
    }

    static func matches(_ levels: [[Double]]) -> Bool {
        guard levels.count == 2, levels.allSatisfy({ $0.count == 2 }) else { return false }
        return (0..<2).allSatisfy { channel in
            let primary = levels[channel][channel], secondary = levels[channel][1 - channel]
            return primary > 0.05 && primary > 3 * secondary
        }
    }

    static func checkWindowsPackets(_ packets: [RemoteAudioPacket], status: RemoteAudioControl) throws {
        let decoder = try OpusAudioDecoder(magicCookie: status.magicCookie)
        var channels = [[Float](), [Float]()]
        for (index, packet) in packets.enumerated() {
            try require(packet.epoch == status.epoch && packet.sequence == UInt64(index + 1) && packet.channels == 2,
                        "The audio packets did not start at sequence one in the confirmed stereo epoch")
            let expectedPrevious = index > 0 && status.redundantOpus == true ? packets[index - 1].opusPayload : nil
            try require(packet.previousOpusPayload == expectedPrevious, "The encoded predecessor differed from the negotiated packet history")
            let pcm = try decoder.decode(packet.opusPayload)
            if index >= 3 {
                try require(pcm.count == RemoteAudioControl.framesPerPacket * 2, "The decoded packet did not contain 20 ms of stereo")
                for frame in stride(from: 0, to: pcm.count, by: 2) {
                    channels[0].append(pcm[frame]); channels[1].append(pcm[frame + 1])
                }
            }
        }
        for (n, channel) in channels.enumerated() {
            let levels = [440.0, 880.0].map { frequency in
                var c = 0.0, s = 0.0
                for (index, sample) in channel.enumerated() {
                    let phase = 2 * Double.pi * frequency * Double(index) / Double(RemoteAudioControl.sampleRate)
                    c += Double(sample) * cos(phase); s += Double(sample) * sin(phase)
                }
                return 2 * hypot(c, s) / Double(channel.count)
            }
            try require(levels[n] > 0.05 && levels[n] > 3 * levels[1 - n], "The Mac decoded unexpected tones on channel \(n): \(levels)")
        }
    }
}

private final class MacViewer: @unchecked Sendable {
    struct State {
        var ready = false
        var closed: (reason: String, retryable: Bool)?
        var hello: Hello?
        var media: MediaSession?
        var commits: [MediaStreamID] = []
        var commitPaths: [String] = []
        var mediaFrames: [MediaFrame] = []
        var controlFrames = Set<MediaFrameHeader>()
        var inspectedControls: [MediaControl]?
        var controlRole: MediaChannelRole?
        var heldDecodes: [(frameID: UInt64, complete: () -> Void)] = []
        var cursor = CursorPresentationState()
        var cursorRequest: UUID?
        var cursorStatus: CursorControl?
        var cursorBinding: MediaStreamID?
        var readyWithCursor: [MediaStreamID] = []
        var displayRequest: UUID?
        var displayUpdates: [DisplayControl] = []
        var inputFeedback: [InputFeedback] = []
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
        var audioStatuses: [RemoteAudioControl] = []
        var datagramAudio: [RemoteAudioPacket] = []
        var datagramPositions: [CursorPosition] = []
        var audioPackets: [RemoteAudioPacket] = []
        var holdAcknowledgements = false
    }
    let state = Shared(State())
    let peer: Peer
    private let decoder = VideoDecoder()
    private let preferred: StreamSettings

    private let auxiliaryPort: UInt16
    private let key: PairingKey
    private let useMedia: Bool
    private let udp: Bool
    private let identity: DeviceIdentity?
    private let clipboard: InteropClipboard?

    init(port: UInt16, key: PairingKey, preferred: StreamSettings, useMedia: Bool, identity: DeviceIdentity? = nil,
         clipboard: InteropClipboard? = nil, auxiliaryPort: UInt16? = nil, udp: Bool = false) {
        self.udp = udp
        self.auxiliaryPort = auxiliaryPort ?? port
        self.key = key
        self.useMedia = useMedia
        self.identity = identity
        self.clipboard = clipboard
        self.preferred = preferred
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: SecureTransport.parameters(key: key, responsiveAcknowledgements: true))
        peer = Peer(connection: connection)
        peer.onReady = { [state] in state.update { $0.ready = true; $0.controlRole = MediaSecureTransport.negotiatedRole(on: connection) } }
        peer.onClose = { [state, weak peer] reason in state.update { $0.closed = (reason, peer?.closeIsRetryable == true) } }
        peer.onMessage = { [weak self] message in
            guard let self else { return }
            do { try self.handle(message) }
            catch { self.state.update { $0.failures.append("\(message.kind): \(error)") } }
        }
        peer.start()
    }

    private func handle(_ message: Message) throws {
        if try clipboard?.receive(message, from: peer) == true { return }
        if let media = state.get().media {
            if message.kind == .mediaFrame {
                let frame = try MediaFrame.decode(message.payload)
                state.update { _ = $0.controlFrames.insert(frame.header) }
            } else if message.kind == .mediaControl {
                let control = try MediaControl.read(message.payload)
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
            if let clipboard {
                try require(hello.clipboardSync == true && hello.physicalFilePasteV1 == true, "The Windows host omitted clipboard capabilities")
                try clipboard.greet(peer, id: UUID())
            }
            let applied = VideoStreamState(settings: hello.settings, width: hello.width, height: hello.height)
            var tuning = try VideoTuningSession(applied: applied, preferred: preferred)
            if hello.sessionTerminationV1 == true { peer.send(try SessionTermination(.subscribe).message()) }
            if hello.deviceIdentityExchange == true, let identity { peer.send(try Wire.json(.deviceIdentity, identity)) }
            if hello.controlStatusUpdates == true { peer.send(Message(.controlStatus)) }
            if hello.displaySwitchingV1 == true { peer.send(try DisplayControl.subscribe().message()) }
            if useMedia, hello.mediaTransportV1 == true {
                let media = try MediaSession.viewer(control: peer, key: key, host: "127.0.0.1", port: auxiliaryPort, settings: hello.settings, udpEnabled: udp)
                clipboard?.attach(media, to: peer) { [state] reason in state.update { $0.failures.append(reason) } }
                media.onAudioPacket = { [state] packet in state.update { $0.datagramAudio.append(packet) } }
                media.onCursorPosition = { [state] position in
                    state.update { value in
                        value.datagramPositions.append(position)
                        _ = value.cursor.update(position)
                    }
                }
                media.onVideo = { [weak self, state] frame, complete in
                    state.update { $0.mediaFrames.append(frame) }
                    self?.decode(frame.packet, frameID: frame.header.frameID, completion: complete)
                }
                media.onDiagnosticVideoPath = { [state] path in
                    if case .committed(let path, _) = path { state.update { $0.commitPaths.append(path.rawValue) } }
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
        case .mediaControl where state.get().inspectedControls != nil:
            let control = try MediaControl.read(message.payload)
            state.update { $0.inspectedControls?.append(control) }
        case .displayControl where state.get().hello?.displaySwitchingV1 == true:
            let update = try DisplayControl.read(message.payload)
            try state.update { state in
                switch update.operation {
                case .state: break
                case .result:
                    guard state.displayRequest == update.id else { return }
                    state.displayRequest = nil
                default: throw Failure("The Windows host sent a display request")
                }
                if update.error == nil, let video = update.videoState {
                    try state.tuning?.synchronizeHostState(video)
                    state.media?.updateSettings(video.settings)
                }
                state.displayUpdates.append(update)
            }
        case .audioControl where state.get().hello?.remoteAudioV1 == true:
            let status = try RemoteAudioControl.read(message.payload)
            try require(status.operation == .status, "The Windows host sent an audio request")
            state.update { $0.audioStatuses.append(status) }
        case .audioFrame where state.get().hello?.remoteAudioV1 == true:
            let packet = try RemoteAudioPacket.decode(message.payload)
            state.update { $0.audioPackets.append(packet) }
        case .inputStatus where state.get().hello?.inputActions == true:
            let feedback = try Wire.readJSON(InputFeedback.self, message.payload)
            state.update { $0.inputFeedback.append(feedback) }
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

    func requestMedia(markedRepairs: Bool? = nil, fec: CheckFEC = .legacy, dynamic: Bool? = nil, fast: Bool? = nil) throws -> MediaControl {
        state.update { $0.inspectedControls = [] }
        peer.send(try MediaControl(.request, receiveFrameWindow: dynamic == true ? 6 : nil, markedRepairs: markedRepairs, dynamicFrameWindow: dynamic, parityFEC: fec == .xor ? true : nil,
                                   blockFEC: fec == .block ? true : nil, fecFragmentLimit: fec == .block ? 256 : nil, fastRecovery: fast).message())
        try until("the Windows host offers media") { self.state.get().inspectedControls?.first != nil }
        guard let offer = state.get().inspectedControls?.first, offer.operation == .offer else { throw Failure("Missing media offer") }
        return offer
    }

    func checkAuxiliaryAdmission() throws {
        let offer = try requestMedia()
        guard let sessionID = offer.sessionID, let token = offer.token else { throw Failure("Incomplete media offer") }
        var otherToken = token
        otherToken[otherToken.startIndex] ^= 1
        for (claim, candidate, allowed) in [(MediaChannelRole.bulk, token, false), (.video, otherToken, false), (.video, token, true)] {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: auxiliaryPort)!,
                                          using: try MediaSecureTransport.tlsParameters(key: key, roles: [.video]))
            let auxiliary = Peer(connection: connection, handshakeTimeout: 4)
            let role = Shared<MediaChannelRole?>(nil), received = Shared<[Message]>([]), closed = Shared(false)
            let bind = try MediaControl(.bind, sessionID: sessionID, token: candidate, role: claim).message()
            auxiliary.onReady = { [weak auxiliary] in
                role.update { $0 = MediaSecureTransport.negotiatedRole(on: connection) }
                auxiliary?.send(bind)
            }
            auxiliary.onMessage = { message in received.update { $0.append(message) } }
            auxiliary.onClose = { _ in closed.update { $0 = true } }
            auxiliary.start()
            defer { auxiliary.close() }
            try until("Windows completes the binding decision") { closed.get() || !received.get().isEmpty }
            try require(role.get() == .video, "The test connection did not negotiate video ALPN")
            if allowed {
                guard let reply = received.get().first, reply.kind == .mediaControl else { throw Failure("Windows rejected the matching binding") }
                let bound = try MediaControl.read(reply.payload)
                try require(bound.operation == .bound && bound.sessionID == sessionID && bound.role == .video && bound.token == token,
                            "The binding response did not identify this socket's grant")
            } else {
                try require(closed.get() && received.get().isEmpty, "The host accepted a binding with a different role or grant")
            }
        }
    }

    private func datagramEndpoint(session: UUID, secret: Data) throws -> BoundedDatagramPeer {
        let parameters = try MediaSecureTransport.dtlsParameters(sessionKey: secret, identity: Data(session.uuidString.utf8))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: auxiliaryPort)!, using: parameters)
        return try BoundedDatagramPeer(connection: connection, maximumDatagramBytes: MediaFragment.maximumDatagramBytes + 1)
    }

    // A receiver delays genuine nonce echoes to vary the measured RTT. Holding only decoded receipts
    // lets the sender finish each UDP frame while measuring how many frames received capture credit.
    func checkDatagramWindow(_ window: Int, pongDelay: Double, recording: [Data], probe: Probe) throws {
        let modern = window != MediaBufferLimits.legacyFrameWindow
        let offer = try requestMedia(dynamic: modern ? true : nil, fast: modern ? true : nil)
        guard let session = offer.sessionID, let secret = offer.datagramKey, offer.path == "udp" else { throw Failure("Missing datagram endpoint") }
        try require((offer.dynamicFrameWindow == true) == modern && (offer.fastRecovery == true) == modern, "The offer changed the requested features")
        let udp = try datagramEndpoint(session: session, secret: secret)
        defer { udp.close() }
        var ping = Data([1])
        withUnsafeBytes(of: UUID().uuid) { ping.append(contentsOf: $0) }
        ping.append(Data(count: 1024 - ping.count))
        let nonce = ping
        let echoes = Shared(0), records = Shared<[Data]>([])
        let gate = Shared((closed: false, pongs: [Data]()))
        let response = DispatchQueue(label: "interop.delayed-nonce", attributes: .concurrent)
        udp.onDatagram = { [weak udp] data in
            if data.first == 1, data.count == 1024 {
                var bytes = data; bytes[bytes.startIndex] = 2
                let pong = bytes
                response.async { [weak udp] in
                    if pongDelay > 0 { Thread.sleep(forTimeInterval: pongDelay) }
                    let hold = gate.update { value -> Bool in
                        if value.closed { value.pongs.append(pong) }
                        return value.closed
                    }
                    if !hold { _ = udp?.send(pong) }
                    _ = udp?.send(nonce)
                }
            } else if data.first == 2, data.dropFirst() == nonce.dropFirst() { echoes.update { $0 += 1 } }
            else if data.first == 3 || data.first == 5 { records.update { $0.append(data) } }
        }
        func releasePongs() {
            let delayed = gate.update { value in defer { value = (false, []) }; return value.pongs }
            for pong in delayed { _ = udp.send(pong) }
        }
        udp.start()
        try until("fresh echoes measure the authenticated path") { echoes.get() >= 3 }

        for epoch in UInt32(1)...2 {
            let fast = modern && epoch == 2
            let stream = MediaStreamID(sessionID: session, transportEpoch: epoch, codecEpoch: epoch), transaction = UUID()
            let receiver = try MediaFrameReassembler(stream: stream, limits: MediaBufferLimits(maximumFrames: MediaBufferLimits.maximumDynamicFrameWindow))
            func message(_ op: MediaControl.Operation) throws -> Message {
                try MediaControl(op, sessionID: session, transactionID: transaction, transportEpoch: epoch, codecEpoch: epoch,
                                 path: "udp", fast: op == .prepare && fast ? true : nil).message()
            }
            func responses() -> [MediaControl.Operation] {
                (state.get().inspectedControls ?? []).filter { $0.transactionID == transaction && $0.transportEpoch == epoch
                    && $0.codecEpoch == epoch && $0.path == "udp" }.map(\.operation)
            }
            let prepare = try message(.prepare)
            if fast {
                gate.update { $0 = (true, []) }
                let request = Data([11]) + prepare.payload
                try require(udp.send(request) && udp.send(request), "The duplicate fast requests did not leave the viewer")
            } else { peer.send(prepare) }
            try until("Windows sends the correlated ready") { responses().contains(.ready) }
            if fast {
                try until("the fast transaction issues a fresh nonce") { !gate.get().pongs.isEmpty }
                usleep(45_000)
                try require(try !records.get().contains { try MediaFragment.decode(Data($0.dropFirst())).header.stream == stream },
                            "The host released the candidate IDR before the new nonce was returned")
                releasePongs()
                peer.send(prepare)
            } else { peer.send(try message(.ready)) }
            var frames: [MediaFrameHeader] = []
            func handle(_ events: [MediaReceiveEvent]) throws {
                for event in events {
                    switch event {
                    case .feedback(let ack):
                        if ack.kind != .decoded || ack.header.frameID == 1 { _ = udp.send(Data([4]) + ack.encode()) }
                    case .frameReady(let frame):
                        let index = frames.count
                        try require(frame.header.frameID == UInt64(index + 1) && annexB(frame.packet) == recording[index % recording.count],
                                    "A windowed frame arrived out of order or changed bytes")
                        let decoded = Shared(false), done = DispatchSemaphore(value: 0)
                        decode(frame.packet, frameID: frame.header.frameID) { ok in decoded.update { $0 = ok }; done.signal() }
                        try require(done.wait(timeout: .now() + 2) == .success && decoded.get(), "The windowed frame did not decode")
                        frames.append(frame.header)
                        try handle(receiver.decoded(frame.header, success: true))
                        if index == 0 {
                            if !fast {
                                peer.send(try message(.decodedReady))
                                try until("Windows sends the full protocol commit") { responses().contains(.commit) }
                            }
                            if epoch == 1 {
                                if pongDelay < 0.2 {
                                    gate.update { $0.closed = true }
                                    usleep(5_000)
                                }
                                try probe.send(["command": "observeCaptureWindow", "enabled": true])
                                _ = try probe.next("captureWindowArmed")
                            }
                            peer.send(try message(.committed))
                        }
                    case .recoveryRequired: throw Failure("An undamaged frame required another epoch")
                    }
                }
            }
            func poll() throws {
                let batch = records.update { value in defer { value.removeAll(keepingCapacity: true) }; return value }
                for data in batch {
                    let fragment = try MediaFragment.decode(Data(data.dropFirst()))
                    if fragment.header.stream == stream { try handle(receiver.receive(fragment)) }
                }
            }
            if epoch == 1 {
                var snapshot: [String: Any]?
                let by = SessionClock.uptime + 4
                while snapshot == nil && SessionClock.uptime < by {
                    try poll(); snapshot = probe.all("captureWindowFull").last; usleep(500)
                }
                guard let snapshot, let limit = snapshot["limit"] as? Int else { throw Failure("The capture window did not fill") }
                try require(snapshot["outstanding"] as? Int == limit && snapshot["excessDropped"] as? Bool == true,
                            "The sender admitted an access unit beyond its actual \(limit)-frame limit")
                let maximum = MediaBufferLimits.maximumDynamicFrameWindow
                let expected = !modern || window == maximum ? limit == window : (window...maximum).contains(limit)
                try require(expected, "Unexpected negotiated capture limit \(limit) for a minimum nonce delay of \(pongDelay)s")
                let filled = SessionClock.uptime + 3
                while frames.count < limit + 1 && SessionClock.uptime < filled { try poll(); usleep(500) }
                try require(frames.count == limit + 1, "The receiver got \(frames.count - 1) frames for a measured grant of \(limit)")
                gate.update { $0.closed = true }
                _ = udp.send(Data([4]) + (try MediaFeedback(kind: .decoded, header: frames[1]).encode()))
                let released = try probe.next("captureCreditReleased")
                releasePongs()
                guard let remaining = released["remaining"] as? Int, let nextLimit = released["limit"] as? Int, let queued = released["queued"] as? Bool
                else { throw Failure("Missing capture credit observation") }
                try require(remaining == limit - 1 && queued == (remaining < nextLimit), "One decoded receipt did not release exactly one capture credit")
                let count = limit + 1 + (queued ? 1 : 0), resumed = SessionClock.uptime + 2
                while frames.count < count && SessionClock.uptime < resumed { try poll(); usleep(500) }
                try require(frames.count == count, "The next access unit did not match the available capture credit")
                try probe.send(["command": "observeCaptureWindow", "enabled": false])
            } else {
                let by = SessionClock.uptime + 4
                while frames.count < 2 && SessionClock.uptime < by { try poll(); usleep(500) }
                try require(frames.count >= 2, "The new epoch did not resume video")
            }
            let replies = responses()
            try require(fast ? !replies.isEmpty && replies.allSatisfy { $0 == .ready } : replies == [.ready, .commit],
                        "Unexpected replies for the negotiated recovery: \(replies)")
        }
    }

    func checkDatagramRepair(recording: [Data], fec: CheckFEC = .legacy) throws {
        let offer = try requestMedia(markedRepairs: true, fec: fec)
        try require((offer.parityFEC == true) == (fec == .xor) && (offer.blockFEC == true) == (fec == .block),
                    "The host's FEC offer did not match this viewer's request")
        guard offer.path == "udp", let session = offer.sessionID, let secret = offer.datagramKey else {
            throw Failure("The Windows host did not offer its UDP endpoint")
        }

        if fec == .legacy {
            var wrong = secret
            wrong[wrong.startIndex] ^= 1
            let rejected = try datagramEndpoint(session: session, secret: wrong)
            let admitted = Shared(false), closed = DispatchSemaphore(value: 0)
            rejected.onReady = { admitted.update { $0 = true } }
            rejected.onClose = { _ in closed.signal() }
            rejected.start()
            defer { rejected.close() }
            try require(closed.wait(timeout: .now() + 4) == .success && !admitted.get(), "DTLS with a different session key became ready or failed to time out")
            let oldCount = state.get().clipboard.count
            peer.send(Message(.requestClipboard))
            try until("the original control channel answers after the incorrect UDP key") { self.state.get().clipboard.count > oldCount }
        }

        let udp = try datagramEndpoint(session: session, secret: secret)
        defer { udp.close() }
        var ping = Data([1])
        withUnsafeBytes(of: UUID().uuid) { ping.append(contentsOf: $0) }
        ping.append(Data(count: 1024 - ping.count))
        let challenge = ping
        let verified = Shared(false), records = Shared<[Data]>([])
        udp.onDatagram = { [weak udp] data in
            if data.first == 1, data.count == 1024 {
                var pong = data
                pong[pong.startIndex] = 2
                udp?.send(pong)
                udp?.send(challenge)
            } else if data.first == 2, data.dropFirst() == challenge.dropFirst() {
                verified.update { $0 = true }
            } else {
                records.update { $0.append(data) }
            }
        }
        udp.start()
        try until("both directions of the authenticated UDP challenge succeed") { verified.get() }
        let transaction = UUID(), stream = MediaStreamID(sessionID: session, transportEpoch: 1, codecEpoch: 1)
        func send(_ op: MediaControl.Operation) throws {
            peer.send(try MediaControl(op, sessionID: session, transactionID: transaction, transportEpoch: 1, codecEpoch: 1, path: "udp").message())
        }
        func wait(_ op: MediaControl.Operation) throws {
            try until("the Windows host sends \(op) for the UDP transaction") {
                self.state.get().inspectedControls?.contains {
                    $0.operation == op && $0.transactionID == transaction && $0.sessionID == session
                    && $0.transportEpoch == stream.transportEpoch && $0.codecEpoch == stream.codecEpoch && $0.path == "udp"
                } == true
            }
        }
        let receiver = try MediaFrameReassembler(stream: stream)
        try send(.prepare)
        try wait(.ready)
        try send(.ready)
        var omitted: MediaFragment?, requested = false, repaired = false, decoded = 0
        var parityHeaders: Set<MediaFrameHeader> = []
        let damaged: UInt64 = fec == .xor ? 2 : 1
        let hole: UInt16 = fec == .xor ? 0 : 1
        let deadline = Date().addingTimeInterval(6)
        while decoded < 2 {
            guard Date() < deadline else { throw Failure("Timed out during UDP repair (omitted \(omitted != nil), NACK \(requested), repair \(repaired), decoded \(decoded))") }
            var events: [MediaReceiveEvent] = []
            let batch = records.update { pending in
                defer { pending.removeAll(keepingCapacity: true) }
                return pending
            }
            for data in batch {
                guard let kind = data.first else { throw Failure("Empty application datagram") }
                let body = Data(data.dropFirst())
                if kind == 8 && fec == .xor {
                    let parity = try MediaFrameParity.decode(body)
                    parityHeaders.insert(parity.header)
                    events += try receiver.receive(parity)
                    continue
                }
                if kind == 10 && fec == .block {
                    let shard = try MediaFrameFECShard.decode(body)
                    parityHeaders.insert(shard.header)
                    events += try receiver.receive(shard)
                    continue
                }
                guard kind == 3 || kind == 5 else { throw Failure("Received a UDP record outside the negotiated FEC mode") }
                let fragment = try MediaFragment.decode(body)
                if fragment.header.frameID == damaged && fragment.fragmentIndex == hole {
                    if kind == 3, omitted == nil {
                        try require(Int(fragment.fragmentCount) >= Int(hole) + 2, "The fixture has too few fragments to expose the selected hole")
                        omitted = fragment
                        continue
                    }
                    if fec != .legacy { continue }
                    try require(kind == 5 && requested && fragment == omitted, "The omitted bytes arrived without a marked reply to the matching NACK")
                    repaired = true
                }
                events += try receiver.receive(fragment, isRepair: kind == 5)
            }
            events += receiver.poll()
            func handle(_ events: [MediaReceiveEvent]) throws {
                for event in events {
                    switch event {
                    case .feedback(let feedback):
                        if feedback.kind == .nack, let omitted, feedback.header == omitted.header {
                            requested = requested || feedback.missingRanges.contains {
                                (Int($0.first)..<(Int($0.first) + Int($0.count))).contains(Int(omitted.fragmentIndex))
                            }
                        }
                        try require(udp.send(Data([4]) + feedback.encode()), "Could not send UDP frame feedback")
                    case .frameReady(let frame):
                        let frameID = frame.header.frameID
                        try require(frameID == UInt64(decoded + 1) && annexB(frame.packet) == recording[decoded % recording.count],
                                    "The reassembled UDP frame differed from the source")
                        if frameID == damaged {
                            try require(omitted != nil && (fec == .legacy ? repaired : parityHeaders.contains(frame.header)),
                                        "The damaged frame arrived without the negotiated recovery record")
                        }
                        let ready = DispatchSemaphore(value: 0), success = Shared(false)
                        decode(frame.packet, frameID: frameID) { result in success.update { $0 = result }; ready.signal() }
                        try require(ready.wait(timeout: .now() + 2) == .success && success.get(), "VideoToolbox rejected the reassembled frame")
                        decoded += 1
                        try handle(receiver.decoded(frame.header, success: true))
                        if frameID == 1 { try send(.decodedReady); try wait(.commit); try send(.committed) }
                    case .recoveryRequired:
                        throw Failure("The UDP frame expired before the matching repair arrived")
                    }
                }
            }
            try handle(events)
            if decoded < 2 { usleep(500) }
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
        clipboard?.transfer.get()?.stop()
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

    func selectDisplay(_ display: UInt32) throws -> DisplayControl {
        let request = DisplayControl.select(displayID: display)
        state.update { $0.displayRequest = request.id }
        peer.send(try request.message())
        var result: DisplayControl?
        try until("the Windows host returns its actual display") {
            result = self.state.get().displayUpdates.first { $0.operation == .result && $0.id == request.id }
            return result != nil
        }
        return result!
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

private enum SyntheticDisplays {
    static let primary = RemoteDisplayInfo(id: 1, name: "Synthetic primary", width: 640, height: 360, isMain: true)
    static let external = RemoteDisplayInfo(id: 2, name: "Synthetic external", width: 320, height: 240, isMain: false)
}

private final class SyntheticInputSources: InputSourceAccess {
    private let english = KeyboardSource(id: "abc", name: "ABC", isChinese: false, isASCII: true)
    private let chinese = KeyboardSource(id: "pinyin", name: "合成拼音", isChinese: true, isASCII: true)
    nonisolated let active = Shared("abc")
    nonisolated let refuse = Shared(false)
    private var requested: KeyboardSource?

    nonisolated init() {}
    func enabledSources() -> [KeyboardSource] { [english, chinese] }
    func currentSource() -> KeyboardSource? { enabledSources().first { $0.id == active.get() } }
    func prepareContextRefresh() -> InputSourceContextRefresh? { nil }
    func select(_ source: KeyboardSource) throws {
        if refuse.get() { throw DeskError.invalid("Synthetic input source rejected") }
        requested = source
    }
    func applyRequestedSource() {
        if let requested {
            active.update { $0 = requested.id }
            self.requested = nil
        }
    }
}

private struct TrackpadEvent {
    let type: NSEvent.EventType
    let phase: NSEvent.Phase
    let momentum: NSEvent.Phase
    let value: Double
    let precise: Bool

    init?(_ event: CGEvent) {
        guard event.type == .scrollWheel || event.type.rawValue == 29, let native = NSEvent(cgEvent: event) else { return nil }
        type = native.type
        phase = native.phase
        momentum = type == .scrollWheel ? native.momentumPhase : []
        precise = type == .scrollWheel && native.hasPreciseScrollingDeltas
        switch type {
        case .magnify: value = native.magnification
        case .rotate: value = Double(native.rotation)
        default: value = 0
        }
    }
}

private struct PostedEvent {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let sourceID: String
    let location: CGPoint
    let motion: (x: Int64, y: Int64)
    let trackpad: TrackpadEvent?
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
        var stopped = false
        var accepted: [Peer] = []
        var auxiliary: [MediaChannelRole: Peer] = [:]
        var messagesByAuxiliary: [MediaChannelRole: [MessageKind]] = [:]
        var peer: Peer?
        var media: MediaSession?
        var closed: String?
        var failures: [String] = []
        var receiverLimit: Int?
        var waiting = Set<UInt32>()
        var sequence: UInt32 = 0
        var next = 0
        var paused = false
        var streaming = false
        var prepared = false
        var commits: [MediaControl] = []
        var transactions: [MediaControl] = []
        var deferredFastPrepare: Message?
        var holdFastPrepare = false
        var cursorRequest: CursorControl?
        var heldCursorPreparation: (stream: MediaStreamID, complete: (Bool) -> Void)?
        var decodedFeedback = Set<MediaFrameHeader>()
        var recoverySequences: [UInt32] = []
        var requests: [StreamSettingsRequest] = []
        var applied: VideoStreamState
        var subscribedTermination = false
        var subscribedControl = false
        var subscribedDisplays = false
        var displays: [RemoteDisplayInfo] = []
        var selectedDisplay = SyntheticDisplays.primary.id
        var rejectNextDisplay = false
        var displaySelections: [UInt32] = []
        var pauseRequests: [Bool] = []
        var clipboard = "Mac 主机剪贴板"
        var received: [MessageKind] = []
        var audioRequests: [RemoteAudioControl] = []
        var identities: [DeviceIdentity] = []
        var posted: [PostedEvent] = []
        var datagramInputs: [RemoteInput] = []
        var inputs: [RemoteInput] = []
        var pointer = CGPoint(x: -1, y: -1)
        var released = 0
    }
    let state: Shared<State>
    let port: UInt16
    private let advertiseMedia: Bool
    private let fec: CheckFEC?
    private let legacyMedia: Bool
    private let cursorImage: CursorImage?
    private let cursorID = UUID()
    private let listener: NWListener
    private let packets: [VideoPacket]
    private let externalPackets: [VideoPacket]
    private let key: PairingKey
    private let size: (width: Int, height: Int)
    private let injector: InputInjector
    let keyboard = SyntheticInputSources()
    private let advertiseAudio: Bool
    private let inputActions: Bool
    private let relativeMouse: Bool
    private let trackpadGestures: Bool
    private let deviceID: UUID?
    private let identityExchange: Bool?
    private let prepareHello: (Message) throws -> Message
    private let clipboard: InteropClipboard?
    private var pump: DispatchSourceTimer?

    init(key: PairingKey, packets: [VideoPacket], size: (width: Int, height: Int), advertiseMedia: Bool, cursorImage: CursorImage?,
         externalPackets: [VideoPacket] = [], inputActions: Bool = true, relativeMouse: Bool = true, trackpadGestures: Bool = true,
         deviceID: UUID? = UUID(), identityExchange: Bool? = true, prepareHello: @escaping (Message) throws -> Message = { $0 },
         on port: NWEndpoint.Port = .any, clipboard: InteropClipboard? = nil, advertiseAudio: Bool = true, fec: CheckFEC? = nil, legacyMedia: Bool = false) throws {
        self.legacyMedia = legacyMedia
        self.fec = fec
        self.advertiseAudio = advertiseAudio
        self.advertiseMedia = advertiseMedia
        self.cursorImage = cursorImage
        self.key = key
        self.packets = packets
        self.externalPackets = externalPackets
        self.inputActions = inputActions
        self.relativeMouse = relativeMouse
        self.trackpadGestures = trackpadGestures
        self.deviceID = deviceID
        self.identityExchange = identityExchange
        self.prepareHello = prepareHello
        self.clipboard = clipboard
        self.size = size
        let settings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8)
        let state = Shared(State(applied: VideoStreamState(settings: settings, width: size.width, height: size.height)))
        self.state = state
        if !externalPackets.isEmpty { state.update { $0.displays = [SyntheticDisplays.primary, SyntheticDisplays.external] } }
        let keyboard = self.keyboard
        let sources = InputSources(access: keyboard) {
            await Task.yield()
            await keyboard.applyRequestedSource()
        }
        injector = InputInjector(concurrentBounds: CGRect(x: 0, y: 0, width: 1600, height: 900), isTrusted: { true },
            postEvent: { event in
                let posted = PostedEvent(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, sourceID: keyboard.active.get(),
                    location: event.location, motion: (event.getIntegerValueField(.mouseEventDeltaX), event.getIntegerValueField(.mouseEventDeltaY)),
                    trackpad: TrackpadEvent(event),
                    clicks: event.getIntegerValueField(.mouseEventClickState),
                    button: event.getIntegerValueField(.mouseEventButtonNumber),
                    repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    lines: (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
                    pixels: (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)))
                state.update { state in
                    state.posted.append(posted)
                    if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) { state.pointer = event.location }
                }
            },
            inputSources: sources, capsLockState: { false }, pointerLocation: { state.get().pointer })
        let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
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
        peer.onClose = { [state, weak peer] reason in
            state.update { state in
                if state.peer === peer || (state.peer == nil && state.accepted.first === peer) { state.closed = reason }
            }
        }
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            do {
                let role = MediaSecureTransport.negotiatedRole(on: connection)
                if let role, role == .video || role == .bulk {
                    guard self.advertiseMedia, let media = self.state.get().media else { peer.close("No active media session"); return }
                    media.acceptAuxiliary(peer, role: role)
                    let handle = peer.onMessageHandled
                    peer.onMessageHandled = { [state = self.state] message, resume in
                        state.update { $0.messagesByAuxiliary[role, default: []].append(message.kind) }
                        handle?(message, resume)
                    }
                    self.state.update { $0.auxiliary[role] = peer }
                    return
                }
                guard role == nil || role == .control, self.state.get().peer == nil else { peer.close("Unexpected connection"); return }
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
                media.onReceiveFrameWindow = { [state = self.state] limit in state.update { $0.receiverLimit = limit } }
                media.onInteractiveInput = { [state = self.state] input in state.update { $0.datagramInputs.append(input) } }
                media.onProduceRecoveryFrame = { [weak self] in self?.produceFrame(recovery: true) }
                media.onResumeFrames = { [state = self.state] in state.update { $0.prepared = false } }
                media.onAcknowledged = { [state = self.state] sequence in state.update { _ = $0.waiting.remove(sequence) } }
                self.clipboard?.attach(media, to: peer) { [state = self.state] reason in state.update { $0.failures.append(reason) } }
                media.start()
                self.state.update { $0.peer = peer; $0.media = media }
                self.startPump()
                // The capability set the application announces, with the fields of this Mac filled in.
                let preferred = StreamSettings(longestEdge: 2560, framesPerSecond: 60, megabits: 20)
                let hello = try Wire.json(.hello, Hello(name: "检查用 Mac", width: applied.width, height: applied.height, settings: applied.settings,
                    canControl: true, inputActions: self.inputActions ? true : nil, preferredSettings: preferred.extendedCompatible, deviceID: self.deviceID, deviceIdentityExchange: self.identityExchange,
                    highRefreshVideoSettings: true, preferredHighRefreshSettings: preferred.highRefreshCompatible,
                    sessionEffects: true, sessionPause: true, mediaTransportV1: self.advertiseMedia ? true : nil,
                    independentCursorV1: self.cursorImage == nil ? nil : true,
                    relayTransportV1: true, relayDeviceID: nil, sessionLockV1: true, adaptiveVideoV1: true, sessionUnlockV1: true,
                    screenLocked: false, higherFrameRateVideoV1: true, preferredHigherFrameRateSettings: preferred,
                    displayDimmingV1: true, builtInDisplayDimmable: false, sessionTerminationV1: true, desktopActionsV1: true,
                    hevcVideoV1: true, initialStreamNegotiationV1: true, hevc444VideoV1: true,
                    displaySwitchingV1: self.externalPackets.isEmpty ? nil : true,
                    displays: self.externalPackets.isEmpty ? nil : self.state.get().displays,
                    selectedDisplayID: self.externalPackets.isEmpty ? nil : self.state.get().selectedDisplay,
                    remoteAudioV1: self.advertiseAudio ? true : nil, relativeMouseV1: self.relativeMouse ? true : nil, trackpadGesturesV1: self.trackpadGestures ? true : nil,
                    initialCursorNegotiationV1: self.cursorImage == nil ? nil : true, qualityProbeV1: true, typeTextV1: true,
                    physicalFilePasteV1: self.clipboard?.physical == true ? true : nil))
                peer.send(try self.prepareHello(hello))
                // The application waits this long for the viewer's first settings before it starts capture.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in self?.state.update { $0.streaming = true } }
            } catch {
                self.state.update { $0.failures.append("accept: \(error)") }
                peer.close("\(error)")
            }
        }
        peer.onMessageHandled = { [weak self, weak peer] message, resume in
            Task {
                defer { resume() }
                guard let self, let peer else { return }
                do { try await self.handle(message, peer: peer) }
                catch {
                    self.state.update { $0.failures.append("\(message.kind): \(error)") }
                    peer.close("\(error)")
                }
            }
        }
        peer.start()
    }

    private func startPump() {
        let pump = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "interop.frames"))
        pump.schedule(deadline: .now(), repeating: .milliseconds(4))
        pump.setEventHandler { [weak self] in self?.produceFrame() }
        self.pump = pump
        pump.resume()
    }

    private func produceFrame(recovery: Bool = false) {
        if fec != nil && !recovery { return }
        state.update { state in
            guard state.streaming, !state.paused, state.prepared == recovery, let media = state.media,
                  state.waiting.count < VideoFrameFlow.maximumOutstandingFrames(for: state.applied.settings, receiverLimit: state.receiverLimit) else { return }
            if recovery { state.next = 0 }
            let recording = state.selectedDisplay == SyntheticDisplays.external.id ? externalPackets : packets
            let source = recording[state.next]
            state.next = (state.next + 1) % recording.count
            state.sequence &+= 1
            if recovery { state.recoverySequences.append(state.sequence) }
            state.waiting.insert(state.sequence)
            media.sendVideo(VideoPacket(sequence: state.sequence, codec: .h264, vps: Data(), sps: source.sps, pps: source.pps, avcc: source.avcc))
        }
    }

    func moveCursor(sequence: UInt64, x: Double, y: Double) throws -> Bool {
        let position = try CursorPosition(cursorID: cursorID, epoch: 1, sequence: sequence, insideDisplay: true, x: x, y: y)
        let current = state.get()
        guard let media = current.media, let peer = current.peer else { throw Failure("Missing active cursor session") }
        if media.sendCursorPosition(position) { return true }
        peer.send(Message(.cursorPosition, position.encode()))
        return false
    }

    func sendFECFrame(source: VideoPacket, fullFragments: Int) throws -> VideoPacket {
        guard let media = state.get().media else { throw Failure("No active media session") }
        let seq = state.update { state in state.sequence += 1; return state.sequence }
        // The short tail has a different record length from a full fragment and from either parity format.
        let bytes = fullFragments * MediaFragment.maximumPayloadBytes + 930
        let pad = bytes - (try source.encode()).count - 4
        guard pad >= 2 else { throw Failure("The source frame is too large for the selected loss pattern") }
        var avcc = source.avcc
        avcc.put(UInt32(pad))
        avcc.append(12)
        avcc.append(Data(repeating: 0xff, count: pad - 2))
        avcc.append(0x80)
        let packet = VideoPacket(sequence: seq, codec: .h264, vps: source.vps, sps: source.sps, pps: source.pps, avcc: avcc)
        media.sendVideo(packet)
        return packet
    }

    private func handle(_ message: Message, peer: Peer) async throws {
        let (stopped, media) = state.update { state in
            if !state.stopped { state.received.append(message.kind) }
            return (state.stopped, state.media)
        }
        guard !stopped else { return }
        if try clipboard?.receive(message, from: peer) == true { return }
        if advertiseMedia {
            if message.kind == .mediaControl {
                let control = try MediaControl.read(message.payload)
                if [.prepare, .ready, .decodedReady, .committed].contains(control.operation) {
                    let deferred = state.update { state in
                        state.transactions.append(control)
                        if control.operation == .committed { state.commits.append(control) }
                        if state.holdFastPrepare, control.operation == .prepare, control.fast == true {
                            state.deferredFastPrepare = message
                            return true
                        }
                        return false
                    }
                    if deferred { return }
                }
                if control.operation == .request, legacyMedia {
                    _ = media?.receive(try MediaControl(.request).message())
                    return
                }
                if control.operation == .request, let fec {
                    let xor = fec == .xor && control.parityFEC == true, block = fec == .block && control.blockFEC == true
                    try require(fec == .legacy || xor || block, "The Windows viewer did not advertise the requested FEC mode")
                    let request = MediaControl(.request, receiveFrameWindow: control.receiveFrameWindow, markedRepairs: control.markedRepairs,
                                               parityFEC: xor ? true : nil, blockFEC: block ? true : nil, fecFragmentLimit: control.fecFragmentLimit)
                    _ = media?.receive(try request.message())
                    return
                }
            } else if message.kind == .mediaFeedback {
                let feedback = try MediaFeedback.decode(message.payload)
                if feedback.kind == .decoded { state.update { _ = $0.decodedFeedback.insert(feedback.header) } }
            }
            if media?.receive(message) == true { return }
        }
        switch message.kind {
        case .audioControl where advertiseAudio:
            let request = try RemoteAudioControl.read(message.payload)
            try require(request.operation == .request, "The Windows viewer sent an audio status")
            state.update { $0.audioRequests.append(request) }
        case .deviceIdentity:
            guard identityExchange == true else { throw Failure("The viewer sent an identity without negotiation") }
            let identity = try Wire.readJSON(DeviceIdentity.self, message.payload)
            state.update { $0.identities.append(identity) }
        case .displayControl where !externalPackets.isEmpty:
            let control = try DisplayControl.read(message.payload)
            switch control.operation {
            case .subscribe:
                let current = state.update { state in state.subscribedDisplays = true; return state }
                peer.send(try DisplayControl.state(displays: current.displays, selectedDisplayID: current.selectedDisplay).message())
            case .select:
                guard let id = control.id, let target = control.displayID else { throw Failure("Missing display selection") }
                state.update { state in
                    state.subscribedDisplays = true
                    state.displaySelections.append(target)
                }
                try changeDisplay(to: target, available: state.get().displays, request: id)
            default: throw Failure("The viewer sent a display update")
            }
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
            let current = state.get()
            let display = current.displays.first { $0.id == current.selectedDisplay }
            let dimensions = request.settings.dimensions(width: display?.width ?? size.width, height: display?.height ?? size.height)
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
            state.update { $0.inputs.append(input) }
            if let feedback = try await injector.receive(input) {
                peer.send(try Wire.json(.inputStatus, feedback))
            }
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

    func changeDisplay(to target: UInt32, available: [RemoteDisplayInfo], request: UUID? = nil) throws {
        let current = state.get()
        guard let peer = current.peer, let media = current.media, current.subscribedDisplays else { throw Failure("No display subscription") }
        let refused = state.update { current in defer { current.rejectNextDisplay = false }; return current.rejectNextDisplay }
        guard let next = available.first(where: { $0.id == target }), !refused, target != current.selectedDisplay else {
            if let request {
                let error = target == current.selectedDisplay ? nil : "Synthetic display is unavailable"
                peer.send(try DisplayControl.result(id: request, selectedDisplayID: current.selectedDisplay, displays: current.displays,
                                                    videoState: current.applied, error: error).message())
            }
            return
        }
        media.suspendForConfiguration { [state] in
            let video = state.update { state in
                state.prepared = true
                state.waiting.removeAll()
                state.next = 0
                state.selectedDisplay = target
                state.displays = available
                let size = state.applied.settings.dimensions(width: next.width, height: next.height)
                state.applied = VideoStreamState(settings: state.applied.settings, width: size.0, height: size.1)
                return state.applied
            }
            do {
                let update = request.map { DisplayControl.result(id: $0, selectedDisplayID: target, displays: available, videoState: video) }
                    ?? DisplayControl.state(displays: available, selectedDisplayID: target, videoState: video)
                peer.send(try update.message())
                media.resumeAfterConfiguration()
            } catch {
                state.update { $0.failures.append("display update: \(error)") }
                peer.close("\(error)")
            }
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
        clipboard?.transfer.get()?.stop()
        listener.cancel()
        let current = state.update { state -> State in
            defer { state.stopped = true; state.peer = nil; state.media = nil; state.accepted.removeAll() }
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

private func checkPhysicalClipboard(_ board: InteropClipboard, _ probe: Probe) throws {
    try until("the clipboard peers exchange enabled preferences") { board.transfer.get() != nil }
    guard let transfer = board.transfer.get() else { throw Failure("Clipboard did not start") }
    let text = "QuietDesk 内存粘贴 🖥️"
    board.copied.update { $0 = .text(Data(text.utf8)) }
    transfer.announceManifest(kind: .text)
    _ = try probe.next("clipboardManifest", matching: { $0["kind"] as? String == "text" })
    try require(board.sent.get() == [.clipboardManifest], "Mac transmitted text on copy")
    try probe.send(["command": "clipboardPaste"])
    let pasted = try probe.next("clipboardApplied")
    try require((pasted["content"] as? [String: Any])?["text"] as? String == text, "Windows did not receive the UTF-8 text")
    try until("Windows acknowledges the text") { board.completedSends.get() == [true] }

    let windowsText = "Windows → Mac 文本"
    try probe.send(["command": "copyText", "text": windowsText])
    try until("Mac receives the text manifest") { board.manifest.get()?.kind == .text }
    guard let textManifest = board.manifest.get() else { throw Failure("Missing text manifest") }
    guard case .text(let bytes)? = transfer.pullPayloadSynchronously(revision: textManifest.revision, kind: .text) else {
        throw Failure("Mac could not pull Windows text")
    }
    try require(bytes == Data(windowsText.utf8), "Windows text changed on the Mac")

    let png = try SyntheticCursor.image().png
    board.copied.update { $0 = .png(png) }
    transfer.announceManifest(kind: .png)
    _ = try probe.next("clipboardManifest", matching: { $0["kind"] as? String == "png" })
    try probe.send(["command": "clipboardPaste"])
    let pastedPNG = try probe.next("clipboardApplied")
    try require((pastedPNG["content"] as? [String: Any])?["bytes"] as? [UInt8] == Array(png), "Mac PNG changed on Windows")
    try until("Windows acknowledges the image") { board.completedSends.get() == [true, true] }

    let readsBeforeImage = probe.all("clipboardRead").count
    try probe.send(["command": "copyPng", "bytes": Array(png)])
    try until("Mac receives the image manifest") { board.manifest.get()?.kind == .png }
    try require(probe.all("clipboardRead").count == readsBeforeImage, "Windows rendered PNG before Mac requested it")
    guard let image = board.manifest.get() else { throw Failure("Missing image manifest") }
    let pulled = transfer.pullPayloadSynchronously(revision: image.revision, kind: .png)
    guard case .png(let pixels)? = pulled else { throw Failure("Mac did not validate the pulled PNG") }
    try require(pixels == png, "The pulled PNG bytes changed")

    let folder = board.directory.appendingPathComponent("收件目录", isDirectory: true)
    let empty = board.directory.appendingPathComponent("empty.txt")
    let contents = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0) })
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try contents.write(to: folder.appendingPathComponent("inside.bin"))
    try Data().write(to: empty)
    let names = [folder.lastPathComponent, empty.lastPathComponent]
    func verifyFiles(_ roots: [URL]) throws {
        try require(roots.map(\.lastPathComponent) == names, "The file roots were lost or reordered")
        try require(try Data(contentsOf: roots[0].appendingPathComponent("inside.bin")) == contents, "Nested file data changed")
        try require(try Data(contentsOf: roots[1]).isEmpty, "Zero-length file changed")
    }
    func fileMessages(_ messages: [MessageKind]) -> Int {
        messages.filter { $0 == .clipboardEntry || $0 == .clipboardChunk }.count
    }
    let previousSent = fileMessages(board.sent.get())
    board.copied.update { $0 = .files([folder, empty]) }
    transfer.announceManifest(kind: .files, fileRootCount: names.count)
    let announced = try probe.next("clipboardManifest", matching: { $0["kind"] as? String == "files" })
    try require(announced["fileRootCount"] as? Int == names.count && probe.all("clipboardOffer").isEmpty,
                "The on-copy manifest lost the root count or disclosed the offer before paste")
    try probe.send(["command": "clipboardPaste"])
    let offer = try probe.next("clipboardOffer")
    try require(offer["count"] as? Int == names.count && offer["bytes"] as? Int == contents.count &&
                fileMessages(board.sent.get()) == previousSent, "File content or an incorrect offer arrived before approval")
    try probe.send(["command": "clipboardDecision", "accept": true])
    let saved = try probe.next("clipboardApplied")
    guard let paths = (saved["content"] as? [String: Any])?["paths"] as? [String] else { throw Failure("Windows did not apply file paths") }
    try verifyFiles(paths.map { URL(fileURLWithPath: $0) })
    try until("Windows confirms local publication of both roots") { board.completedSends.get() == [true, true, true] }

    for accept in [false, true] {
        board.manifest.update { $0 = nil }
        try probe.send(["command": "copyFiles", "names": names])
        try until("Mac receives Windows file manifest") { board.manifest.get()?.kind == .files }
        guard let manifest = board.manifest.get(), manifest.fileRootCount == names.count else { throw Failure("Missing promised Windows file roots") }
        try require(manifest.fileRootNames == names, "Windows did not announce the negotiated root names in source order")
        let initial = fileMessages(board.received.get()), offerCount = board.offers.get().count
        transfer.requestFilePaste(revision: manifest.revision)
        transfer.requestFilePaste(revision: manifest.revision)
        try until("Windows replies to the file pull") { board.offers.get().count > offerCount }
        guard let approval = board.offers.get().last else { throw Failure("Missing Mac file approval") }
        try require(approval.count == 2 && approval.names == names && approval.bytes == UInt64(contents.count) &&
                    initial == fileMessages(board.received.get()), "Windows sent file data before Mac approval")
        let cancellations = board.sent.get().filter { $0 == .clipboardCancel }.count
        transfer.respondToFileOffer(id: approval.id, accept: accept)
        if accept {
            try until("Mac publishes the approved files") { !board.applied.get().isEmpty }
            guard case .files(let roots)? = board.applied.get().last else { throw Failure("Mac published the wrong content kind") }
            try verifyFiles(roots)
        } else {
            try until("Mac cancels the rejected offer") { board.sent.get().filter { $0 == .clipboardCancel }.count > cancellations }
            try require(initial == fileMessages(board.received.get()) && board.applied.get().isEmpty, "Declined files were transferred")
        }
    }

    let sentBeforeRefusal = fileMessages(board.sent.get())
    board.copied.update { $0 = .files([folder, empty]) }
    transfer.announceManifest(kind: .files)
    _ = try probe.next("clipboardManifest", matching: { $0["kind"] as? String == "files" })
    try probe.send(["command": "clipboardPaste"])
    _ = try probe.next("clipboardOffer")
    try probe.send(["command": "clipboardDecision", "accept": false])
    try until("the Mac receives the Windows file refusal") { board.completedSends.get() == [true, true, true, false] }
    try require(fileMessages(board.sent.get()) == sentBeforeRefusal, "File contents followed the Windows refusal")
}

@main
private struct WindowsInteropChecks {
    static func main() async {
        await Task.detached { runChecks() }.value
    }

    private nonisolated static func runChecks() {
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
        let externalPackets: [VideoPacket]
        let recording = work + "/recording.h264"
        let externalRecording = work + "/external.h264"
        let replayFrames: [Data]
        do {
            packets = try encodeFrames(width: size.width, height: size.height, count: 24)
            replayFrames = try writeRecording(packets, to: recording)
            externalPackets = try encodeFrames(width: SyntheticDisplays.external.width, height: SyntheticDisplays.external.height, count: 8)
            _ = try writeRecording(externalPackets, to: externalRecording)
        } catch {
            print("FAIL Encoding the synthetic stream: \(error)")
            exit(1)
        }
        let key = try! PairingKey.generate()
        let macIdentity = DeviceIdentity(id: UUID(), name: "  合成\tMac\n工作台  ")
        let windowsID = UUID()
        let windowsIdentityOptions = ["--device-id", windowsID.uuidString, "--name", "  合成\nWindows\t电脑  "]
        let command = Int(CGEventFlags.maskCommand.rawValue) | 0x08, shift = Int(CGEventFlags.maskShift.rawValue) | 0x02

        func withWindowsHost(_ extra: [String] = [], useMedia: Bool = true, udp: Bool = false, viewerKey: PairingKey? = nil, identity: DeviceIdentity? = nil, clipboard: InteropClipboard? = nil,
                             routeAuxiliary: ((UInt16) throws -> UInt16)? = nil,
                             preferred: StreamSettings = StreamSettings(longestEdge: 1920, framesPerSecond: 30, megabits: 8),
                             _ body: (Probe, MacViewer) throws -> Void) throws {
            let probe = try Probe(probePath, ["host", "--code", key.code, "--recording", recording, "--size", "\(size.width)x\(size.height)",
                                              "--name", "检查用 Windows 电脑"] + (udp ? [] : ["--no-udp"]) + extra)
            defer { probe.stop() }
            guard let port = try probe.next("listening")["port"] as? Int else { throw Failure("The probe did not report its port") }
            let viewer = try MacViewer(port: UInt16(port), key: viewerKey ?? key, preferred: preferred, useMedia: useMedia, identity: identity, clipboard: clipboard,
                                       auxiliaryPort: routeAuxiliary?(UInt16(port)), udp: udp)
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
                try require(hello.independentCursorV1 == nil && hello.clipboardSync == nil && hello.physicalFilePasteV1 == nil && hello.inputActions == nil
                            && hello.hevcVideoV1 == nil && hello.adaptiveVideoV1 == nil && hello.higherFrameRateVideoV1 == nil && hello.remoteAudioV1 == nil
                            && hello.displaySwitchingV1 == nil && hello.sessionEffects == nil && hello.deviceIdentityExchange == nil
                            && hello.relativeMouseV1 == nil && hello.trackpadGesturesV1 == nil && hello.typeTextV1 == nil && hello.desktopActionsV1 == nil,
                            "Hello announced something the Windows host does not implement")
                try until("the stream is confirmed") { viewer.state.get().results.count == 1 }
                let result = viewer.state.get().results[0]
                try require(result.state == VideoStreamState(settings: preferred, width: 640, height: 360) && result.error == nil
                            && result.codec == nil && result.chromaSubsampling == nil, "The first settings were not applied as asked: \(result)")
                _ = try probe.next("streaming")
                try until("the initial video route commits") { !viewer.state.get().commits.isEmpty }
                let starts = probe.all("configured").map(settings)
                try require(starts == [[2560, 60, 20, 640, 360]], "Unexpected capture configurations at first commit: \(starts)")
                try until("control status arrives") { viewer.state.get().control == [true] }
            }
        }

        run("A Mac decodes Windows stereo Opus across pause, disable and a new epoch") {
            try withWindowsHost(["--synthetic-audio"]) { _, viewer in
                try until("Windows offers remote sound and starts video") { viewer.state.get().hello?.remoteAudioV1 == true && !viewer.state.get().decoded.isEmpty }
                try require(viewer.state.get().audioPackets.isEmpty, "Sound started before a viewer requested it")
                func toggle(_ enabled: Bool, redundancy: Bool = false) throws -> RemoteAudioControl {
                    let request = RemoteAudioControl.request(enabled: enabled, redundantOpus: redundancy ? true : nil)
                    viewer.peer.send(try request.message())
                    try until("Windows confirms the matching sound request") { viewer.state.get().audioStatuses.contains { $0.requestID == request.requestID } }
                    let status = viewer.state.get().audioStatuses.first { $0.requestID == request.requestID }!
                    try require(status.enabled == enabled && status.error == nil && (status.redundantOpus == true) == redundancy,
                                "Windows confirmed a different sound configuration")
                    return status
                }
                let first = try toggle(true, redundancy: true)
                try until("eight redundant audio packets arrive") { viewer.state.get().audioPackets.count >= 8 }
                try StereoTone.checkWindowsPackets(Array(viewer.state.get().audioPackets.prefix(8)), status: first)
                viewer.peer.send(try Wire.json(.sessionPauseRequest, SessionPauseRequest(paused: true)))
                try until("the host confirms pause") { viewer.state.get().pauses.last?.paused == true }
                let pausedCount = viewer.state.get().audioPackets.count
                usleep(120_000)
                try require(viewer.state.get().audioPackets.count == pausedCount, "Audio continued after pause was confirmed")
                viewer.peer.send(try Wire.json(.sessionPauseRequest, SessionPauseRequest(paused: false)))
                try until("audio resumes in the same epoch") { viewer.state.get().audioPackets.count > pausedCount }
                let resumed = viewer.state.get().audioPackets[pausedCount]
                try require(resumed.epoch == first.epoch && resumed.previousOpusPayload == nil,
                            "The resumed stream carried a stale epoch or pre-pause audio redundancy")
                _ = try toggle(false)
                let stopped = viewer.state.get()
                try until("video advances after sound is disabled") { viewer.state.get().decoded.count > stopped.decoded.count + 4 }
                try require(viewer.state.get().audioPackets.count == stopped.audioPackets.count, "Windows continued sending after sound was disabled")
                let second = try toggle(true)
                try require(second.epoch! > first.epoch!, "Windows reused the previous audio epoch")
                try until("eight plain audio packets arrive") { viewer.state.get().audioPackets.filter { $0.epoch == second.epoch }.count >= 8 }
                try StereoTone.checkWindowsPackets(Array(viewer.state.get().audioPackets.filter { $0.epoch == second.epoch }.prefix(8)), status: second)
            }
        }

        run("Windows sends cursor and Opus datagrams and accepts a sequenced pointer before returning to reliable control") {
            var route: InteropMediaRoute?
            defer { route?.stop() }
            try withWindowsHost(["--synthetic-audio", "--synthetic-cursor"], udp: true, routeAuxiliary: { port in
                let proxy = try InteropMediaRoute(target: port, forwardUDP: true)
                route = proxy
                return proxy.port
            }) { probe, viewer in
                try until("UDP video commits before enabling the cursor") { viewer.state.get().commitPaths.last == "udp" }
                _ = try viewer.requestCursor(enabled: true)
                try until("the cursor is bound to a visible stream") { viewer.state.get().cursor.enabled }
                try probe.send(["command": "moveSyntheticCursor", "x": 0.375, "y": 0.625])
                try until("a cursor datagram updates the live Mac presentation") {
                    let s = viewer.state.get()
                    return s.datagramPositions.last?.x == 0.375 && s.cursor.position?.y == 0.625
                }
                guard let media = viewer.state.get().media else { throw Failure("Missing viewer media") }
                var move = RemoteInput(kind: .move)
                move.x = 0.375; move.y = 0.625; move.pointerSequence = 15
                try require(media.sendInteractiveInput(move), "The Mac could not submit a pointer datagram")
                _ = try probe.next("inject") { $0["operations"] as? [String] == ["Move { x: 0.375, y: 0.625 }"] }
                let toggle = RemoteAudioControl.request(enabled: true, redundantOpus: true)
                viewer.peer.send(try toggle.message())
                try until("eight Windows Opus datagrams arrive") { viewer.state.get().datagramAudio.count >= 8 }
                let before = viewer.state.get()
                guard let status = before.audioStatuses.first(where: { $0.requestID == toggle.requestID && $0.enabled }) else {
                    throw Failure("The audio epoch was not acknowledged")
                }
                try StereoTone.checkWindowsPackets(Array(before.datagramAudio.prefix(8)), status: status)
                try require(before.audioPackets.isEmpty, "UDP audio was duplicated on control")
                route?.forwardUDP(false)
                try until("the session falls back to reliable video and receives live audio on control", seconds: 15) {
                    let s = viewer.state.get()
                    return s.commitPaths.last == "tcp" && s.audioPackets.contains { $0.epoch == status.epoch }
                }
                try probe.send(["command": "moveSyntheticCursor", "x": 0.875, "y": 0.125])
                try until("VideoToolbox decodes Windows video after UDP loss") {
                    let state = viewer.state.get()
                    guard let stream = state.commits.last, let frame = state.mediaFrames.first(where: { $0.header.stream == stream && $0.header.frameID == 5 })
                    else { return false }
                    return state.decoded.contains { $0.sequence == frame.packet.sequence } && annexB(frame.packet) == replayFrames[4]
                }
                try until("the same cursor advances on control after UDP loss") {
                    let s = viewer.state.get()
                    return s.cursor.position?.x == 0.875 && s.datagramPositions.last?.x == 0.375
                }
                move.x = 0.875; move.y = 0.125; move.pointerSequence = 16
                try require(!media.sendInteractiveInput(move), "A blackholed path accepted a new pointer")
                try viewer.send(move)
                _ = try probe.next("inject") { $0["operations"] as? [String] == ["Move { x: 0.875, y: 0.125 }"] }
            }
        }

        run("A Windows capture failure reaches the Mac without interrupting video") {
            try withWindowsHost(["--synthetic-audio", "--fail-audio"]) { _, viewer in
                try until("the Mac sees audio support") { viewer.state.get().hello?.remoteAudioV1 == true }
                let request = RemoteAudioControl.request(enabled: true)
                viewer.peer.send(try request.message())
                try until("the Mac receives the capture error") { viewer.state.get().audioStatuses.contains { $0.requestID == request.requestID } }
                let state = viewer.state.get(), status = state.audioStatuses.last!
                try require(!status.enabled && status.epoch == nil && status.error?.contains("Synthetic audio capture") == true,
                            "Windows concealed its capture failure")
                try until("video continues with capture unavailable") { viewer.state.get().decoded.count > state.decoded.count + 3 }
                try require(viewer.state.get().audioPackets.isEmpty, "A failed capture emitted audio")
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

        run("A Mac decodes Windows video across UDP loss, reliable fallback and the first timed UDP reprobe") {
            var route: InteropMediaRoute?
            defer { route?.stop() }
            try withWindowsHost(udp: true, routeAuxiliary: { port in
                let relay = try InteropMediaRoute(target: port, forwardUDP: true)
                route = relay
                return relay.port
            }) { _, viewer in
                func check(_ path: String, seconds: Double = 15) throws -> MediaStreamID {
                    try until("VideoToolbox decodes eight frames on \(path)", seconds: seconds) {
                        let s = viewer.state.get()
                        guard s.commitPaths.last == path, let stream = s.commits.last,
                              let eighth = s.mediaFrames.first(where: { $0.header.stream == stream && $0.header.frameID == 8 }) else { return false }
                        return s.decoded.contains { $0.sequence == eighth.packet.sequence }
                    }
                    let s = viewer.state.get(), stream = s.commits.last!
                    let frames = s.mediaFrames.filter { $0.header.stream == stream }.prefix(8)
                    try require(s.controlFrames.isDisjoint(with: frames.map(\.header)), "\(path) video also appeared on control")
                    for (index, frame) in frames.enumerated() {
                        try require(frame.header.frameID == UInt64(index + 1) && frame.header.isIDR == (index == 0)
                                    && annexB(frame.packet) == replayFrames[index], "Windows \(path) video differed from the recording")
                    }
                    return stream
                }
                let original = try check("udp")
                let cut = SessionClock.uptime
                route?.forwardUDP(false)
                let reliable = try check("tcp")
                try require(route?.dropped.get() ?? 0 > 0 && reliable.sessionID == original.sessionID && reliable.transportEpoch > original.transportEpoch
                            && viewer.state.get().closed == nil, "UDP loss interrupted control or reused the old epoch")
                route?.forwardUDP(true)
                let restored = try check("udp", seconds: 43)
                try require(restored.sessionID == original.sessionID && restored.transportEpoch > reliable.transportEpoch
                            && restored.codecEpoch > reliable.codecEpoch && SessionClock.uptime - cut >= 30,
                            "The first scheduled UDP reprobe did not recover the original desktop with a fresh keyframe")
            }
        }

        for (window, delay) in [(3, 0.0), (8, 0.046), (24, 0.27)] {
            run("Windows enforces its measured decode window with a \(Int(delay * 1000)) ms nonce delay and uses the negotiated UDP recovery exchange") {
                try withWindowsHost(useMedia: false, udp: true, preferred: StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8)) { probe, viewer in
                    try until("Windows applies the requested frame rate") { !viewer.state.get().results.isEmpty && !viewer.state.get().decoded.isEmpty }
                    try viewer.checkDatagramWindow(window, pongDelay: delay, recording: replayFrames, probe: probe)
                }
            }
        }

        for fec in [CheckFEC.xor, .block] {
            run("A Mac reconstructs selected Windows UDP fragments using \(fec.rawValue) negotiation") {
                try withWindowsHost(useMedia: false, udp: true) { _, viewer in
                    try until("Windows offers its synthetic stream") { !viewer.state.get().decoded.isEmpty }
                    try viewer.checkDatagramRepair(recording: replayFrames, fec: fec)
                }
            }
        }

        run("A Windows host rejects an incorrect DTLS key and repairs the exact missing fragment for the original Mac session") {
            try withWindowsHost(useMedia: false, udp: true) { _, viewer in
                try until("the original control channel starts delivering video") { !viewer.state.get().decoded.isEmpty }
                try viewer.checkDatagramRepair(recording: replayFrames)
            }
        }

        run("A Mac switches Windows video from a bound TLS socket to control when the auxiliary links close") {
            var proxy: RelayOpaqueProxy?
            defer { proxy?.stop() }
            try withWindowsHost(["--synthetic-audio"], routeAuxiliary: { port in
                let relay = try RelayOpaqueProxy(target: port)
                let ready = DispatchSemaphore(value: 0)
                relay.onReady = { ready.signal() }
                proxy = relay; relay.start()
                guard ready.wait(timeout: .now() + 5) == .success, let port = relay.port else { throw Failure("The loopback auxiliary proxy did not start") }
                return port
            }) { _, viewer in
                try until("the Mac presents video on a dedicated TLS socket") { viewer.state.get().commitPaths == ["tcp"] && viewer.state.get().mediaFrames.count >= 8 }
                let initial = viewer.state.get()
                guard let first = initial.commits.first else { throw Failure("The first TCP commit did not present a stream") }
                let tcp = initial.mediaFrames.filter { $0.header.stream == first }
                try require(tcp.count >= 8 && initial.controlFrames.isDisjoint(with: tcp.map(\.header)), "Dedicated video also arrived on control")
                try require(tcp.enumerated().prefix(8).allSatisfy { annexB($0.element.packet) == replayFrames[$0.offset] }, "Dedicated video differed from the recording")
                let sound = RemoteAudioControl.request(enabled: true)
                viewer.peer.send(try sound.message())
                try until("audio control and Opus arrive on the control socket alongside dedicated video") {
                    let s = viewer.state.get()
                    return s.audioStatuses.contains { $0.requestID == sound.requestID && $0.enabled } && !s.audioPackets.isEmpty
                }
                proxy?.stop(); proxy = nil
                try until("video continues on the shared connection") {
                    let s = viewer.state.get()
                    guard s.commitPaths.last == "shared", let stream = s.commits.last, stream != first else { return false }
                    return s.mediaFrames.filter { $0.header.stream == stream && s.controlFrames.contains($0.header) }.count >= 4
                }
                let last = viewer.state.get(), second = last.commits.last!
                try require(last.commitPaths == ["tcp", "shared"] && first.sessionID == second.sessionID && second.transportEpoch > first.transportEpoch
                            && last.mediaFrames.first { $0.header.stream == second }?.header.isIDR == true && last.closed == nil,
                            "The auxiliary loss interrupted control or reused the old video stream")
            }
        }

        run("A Windows host rejects mismatched auxiliary bindings while its original Mac control remains active") {
            try withWindowsHost(useMedia: false) { _, viewer in
                try until("the no-ALPN control receives legacy video") { !viewer.state.get().decoded.isEmpty }
                try require(viewer.state.get().controlRole == nil, "This fixture did not exercise a control connection without ALPN")
                try viewer.checkAuxiliaryAdmission()
                let count = viewer.state.get().decoded.count
                try until("the original viewer decodes more screen updates") { viewer.state.get().decoded.count > count + 3 }
                try require(viewer.state.get().closed == nil, "Auxiliary binding failure closed control")
            }
        }

        run("A Mac viewer commits shared Windows streams, decodes exact media frames and returns frame credits") {
            try withWindowsHost(["--no-auxiliary"]) { _, viewer in
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
                try until("four negotiated 30 fps media frames remain unpaid") {
                    let state = viewer.state.get()
                    guard let held = state.heldDecodes.first, let stream = state.commits.last else { return false }
                    return state.controlFrames.contains { $0.stream == stream && $0.frameID == held.frameID + 3 }
                }
                usleep(100_000)
                let state = viewer.state.get()
                let held = state.heldDecodes.first!.frameID
                let outstanding = state.controlFrames.filter { $0.stream == state.commits.last && $0.frameID >= held }
                try require(outstanding.map(\.frameID).sorted() == Array(held ..< held + 4),
                            "The Windows host did not retain the negotiated four-frame 30 fps window")
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
                try until("the first media stream and initial quality are confirmed") {
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

        run("A Mac viewer selects Windows displays, decodes the chosen screen and follows its removal") {
            try withWindowsHost(["--second-recording", externalRecording]) { probe, viewer in
                let main = SyntheticDisplays.primary, external = SyntheticDisplays.external
                func picture(_ display: RemoteDisplayInfo, after old: MediaStreamID? = nil, newerThan sequence: UInt32 = 0) throws -> MediaStreamID {
                    try until("the selected display supplies committed, decodable pictures") {
                        let s = viewer.state.get()
                        guard let stream = s.commits.last, stream != old,
                              let frame = s.mediaFrames.first(where: { $0.header.stream == stream && $0.header.frameID > 1 && $0.packet.sequence > sequence }) else { return false }
                        return s.decoded.contains { $0.sequence == frame.packet.sequence && $0.width == display.width && $0.height == display.height }
                    }
                    return viewer.state.get().commits.last!
                }

                let first = try picture(main)
                try until("Windows sends the display subscription state") { viewer.state.get().displayUpdates.first?.operation == .state }
                let initial = viewer.state.get()
                try require(initial.hello?.displaySwitchingV1 == true && initial.hello?.displays == [main, external]
                            && initial.hello?.selectedDisplayID == main.id && initial.displayUpdates[0].displays == [main, external]
                            && initial.displayUpdates[0].selectedDisplayID == main.id, "The Windows display list or selected screen was incorrect")
                let captures = probe.all("switchCapture").count
                let same = try viewer.selectDisplay(main.id)
                let baseline = viewer.state.get().mediaFrames.count
                try until("the unchanged capture continues") { viewer.state.get().mediaFrames.count > baseline + 5 }
                try require(same.selectedDisplayID == main.id && same.error == nil && viewer.state.get().commits == [first]
                            && probe.all("switchCapture").count == captures,
                            "Selecting the current Windows display restarted capture")
                let missing = try viewer.selectDisplay(99)
                try require(missing.selectedDisplayID == main.id && missing.displays == [main, external] && missing.error != nil
                            && probe.all("switchCapture").count == captures, "An unknown display reached Windows capture")
                try probe.send(["command": "rejectNextDisplay"])
                _ = try probe.next("displayFailureArmed")
                let refused = try viewer.selectDisplay(external.id)
                try require(refused.selectedDisplayID == main.id && refused.error != nil && refused.videoState?.width == main.width,
                            "A failed selection replaced the actual Windows capture")
                let previous = try picture(main, newerThan: viewer.state.get().received.last ?? 0)
                let switched = try viewer.selectDisplay(external.id)
                try require(switched.error == nil && switched.selectedDisplayID == external.id && switched.videoState?.width == external.width
                            && switched.videoState?.height == external.height, "The Windows result did not describe the external display")
                let externalStream = try picture(external, after: previous)
                try probe.send(["command": "detachExternal"])
                try until("Windows reports the hotplug fallback") {
                    let update = viewer.state.get().displayUpdates.last
                    return update?.operation == .state && update?.displays == [main] && update?.selectedDisplayID == main.id
                }
                _ = try picture(main, after: externalStream)
                viewer.peer.send(try DisplayControl.state(displays: [main], selectedDisplayID: main.id).message())
                let rejected = try probe.next("ended")
                try require((rejected["reason"] as? String)?.contains("显示器") == true, "The Windows host accepted a viewer's display state")
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

        run("A Mac viewer receives the Windows host's Caps Lock and layout state after each independent action") {
            try withWindowsHost(["--synthetic-keyboard"]) { probe, viewer in
                try until("the Windows host is sharing a picture with keyboard actions") {
                    let state = viewer.state.get()
                    return state.hello?.inputActions == true && !state.decoded.isEmpty
                }
                var press = CapsLockPress()
                func action(start: TimeInterval, duration: TimeInterval) throws -> InputFeedback {
                    _ = press.update(isDown: true, time: start)
                    guard let kind = press.update(isDown: false, time: start + duration) else { throw Failure("Missing Mac Caps Lock action") }
                    var input = RemoteInput(kind: kind)
                    input.independentCapsLock = true
                    let count = viewer.state.get().inputFeedback.count
                    try viewer.send(input)
                    try until("the Windows keyboard status arrives") { viewer.state.get().inputFeedback.count > count }
                    return viewer.state.get().inputFeedback[count]
                }
                let enabled = try action(start: 1, duration: 0.7)
                try require(enabled.capsLocked && enabled.message == "Synthetic Caps Lock on", "Windows reported the wrong Caps Lock state")
                var key = RemoteInput(kind: .keyDown)
                key.keyCode = 8
                key.independentCapsLock = true
                try viewer.send(key)
                try require(try probe.next("inject")["operations"] as? [String] == ["Key { key: Scan { code: 46, extended: false }, down: true }"],
                            "An ordinary key overwrote the Windows host's Caps Lock with the Mac's flag")
                key.kind = .keyUp
                try viewer.send(key)
                let disabled = try action(start: 2, duration: 0.1)
                let switched = try action(start: 3, duration: 0.1)
                try require(!disabled.capsLocked && disabled.message == "Synthetic Caps Lock off"
                            && !switched.capsLocked && switched.message == "Synthetic layout B", "The Windows host changed layout before releasing Caps Lock")
                try probe.send(["command": "refuseLayout"])
                _ = try probe.next("layoutRefusalArmed")
                let refused = try action(start: 4, duration: 0.1)
                try require(!refused.capsLocked && refused.message == "Synthetic layout change unconfirmed", "An unconfirmed Windows layout change was reported as successful")
            }
        }

        run("A Mac viewer sends ordered relative motion and releases the Windows pointer at its current position") {
            try withWindowsHost(["--synthetic-relative-mouse"]) { probe, viewer in
                try until("Windows offers relative mouse on the active picture") {
                    let s = viewer.state.get()
                    return s.hello?.relativeMouseV1 == true && !s.decoded.isEmpty
                }
                func next() throws -> [String] { try probe.next("inject")["operations"] as? [String] ?? [] }
                var down = RemoteInput(kind: .down)
                down.x = 0.2; down.y = 0.3; down.pointerSequence = 10
                try viewer.send(down)
                try require(try next() == ["Move { x: 0.2, y: 0.3 }", "Button { button: Left, down: true }"], "The click that acquires the pointer changed position")
                var drag = RemoteInput(kind: .drag)
                drag.x = 0.5; drag.y = 0.5; drag.relativeMouse = true; drag.pointerSequence = 11
                drag.pointerDeltaX = 32.5; drag.pointerDeltaY = -15.5
                try viewer.send(drag)
                try require(try next() == ["RelativeMove { dx: 32, dy: -15 }"], "Windows used the picture center for locked drag")
                try viewer.send(drag)
                drag.pointerSequence = 12; drag.pointerDeltaX = 0.5; drag.pointerDeltaY = -0.5
                try viewer.send(drag)
                try require(try next() == ["RelativeMove { dx: 1, dy: -1 }"], "A duplicate or fractional Mac delta changed the accumulated Windows movement")

                var wheel = RemoteInput(kind: .scroll)
                wheel.x = 0.5; wheel.y = 0.5; wheel.relativeMouse = true; wheel.pointerSequence = 13
                wheel.deltaY = -36; wheel.lineDeltaX = 0; wheel.lineDeltaY = -3
                try viewer.send(wheel)
                try require(try next() == ["CurrentPointer", "Wheel { vertical: -120, horizontal: 0 }"], "Locked scrolling jumped to the center")
                var up = RemoteInput(kind: .up)
                up.x = 0.5; up.y = 0.5; up.relativeMouse = true; up.pointerSequence = 12
                try viewer.send(up)
                try require(try next() == ["CurrentPointer", "Button { button: Left, down: false }"], "An older button release was lost or moved the pointer")
                down.relativeMouse = true; down.pointerSequence = 14
                try viewer.send(down)
                try require(try next() == ["CurrentPointer", "Button { button: Left, down: true }"], "Locked clicking did not use the current pointer")
                viewer.peer.send(Message(.releaseInput))
                try require(try next() == ["Button { button: Left, down: false }"], "Releasing control left the Windows button down")
                var move = RemoteInput(kind: .move)
                move.x = 0.75; move.y = 0.25; move.pointerSequence = 15
                try viewer.send(move)
                try require(try next() == ["Move { x: 0.75, y: 0.25 }"], "The Windows pointer remained locked after release")
                drag.pointerDeltaY = nil
                viewer.peer.send(try Wire.json(.input, drag))
                try require((try probe.next("ended")["reason"] as? String)?.contains("指针") == true, "Windows accepted a relative movement with a missing delta")
            }
            try withWindowsHost { probe, viewer in
                try until("the absolute-only Windows host is sharing") { !viewer.state.get().decoded.isEmpty }
                var move = RemoteInput(kind: .move)
                move.x = 0.5; move.y = 0.5; move.relativeMouse = true; move.pointerDeltaX = 5; move.pointerDeltaY = -2
                try viewer.send(move)
                var absolute = RemoteInput(kind: .move)
                absolute.x = 0.125; absolute.y = 0.25
                try viewer.send(absolute)
                try require(try probe.next("inject")["operations"] as? [String] == ["Move { x: 0.125, y: 0.25 }"],
                            "Windows injected a locked movement without advertising the capability")
            }
        }

        run("Windows receives Mac trackpad gestures and pixel scrolling at the intended target") {
            try withWindowsHost(["--synthetic-trackpad"]) { probe, viewer in
                try until("the Mac receives the trackpad capability and a Windows picture") {
                    let state = viewer.state.get()
                    return state.hello?.trackpadGesturesV1 == true && !state.decoded.isEmpty
                }
                func next() throws -> [String] { try probe.next("inject")["operations"] as? [String] ?? [] }
                func gesture(_ operation: String, _ phase: String) -> String {
                    "Gesture { gesture: \(operation), phase: Some(\(phase)), x: 0.25, y: 0.5, relative: false }"
                }
                var pinch = RemoteInput(kind: .magnify)
                pinch.x = 0.25; pinch.y = 0.5; pinch.magnification = 0.375; pinch.gesturePhase = .changed
                try viewer.send(pinch)
                let opening = try probe.next("inject") { event in
                    (event["operations"] as? [String])?.first?.hasPrefix("Gesture {") == true
                }
                try require(opening["operations"] as? [String] == [gesture("Magnify(0.0)", "Began"), gesture("Magnify(0.375)", "Changed")],
                            "Windows lost the zoom, target or missing beginning of the Mac pinch")
                var rotate = RemoteInput(kind: .rotate)
                rotate.x = 0.25; rotate.y = 0.5; rotate.rotation = -18.5; rotate.gesturePhase = .began
                try viewer.send(rotate)
                try require(try next() == [gesture("Rotate(-18.5)", "Began")], "The Mac rotation lost its degree value or its phase")
                var smart = RemoteInput(kind: .smartMagnify)
                smart.x = 0.25; smart.y = 0.5; smart.gesturePhase = .ended
                try viewer.send(smart)
                try require(try next() == [gesture("SmartMagnify", "Ended")], "A discrete Mac smart zoom did not reach Windows exactly once")
                viewer.peer.send(Message(.releaseInput))
                try require(try next() == ["CancelGestures"], "Releasing control left the Windows gesture open")
                var wheel = RemoteInput(kind: .scroll)
                wheel.x = 0.25; wheel.y = 0.5; wheel.scrollPhase = .changed; wheel.deltaX = 20; wheel.deltaY = -8
                try viewer.send(wheel)
                try require(try next() == ["Move { x: 0.25, y: 0.5 }", "Wheel { vertical: -12, horizontal: -30 }"],
                            "Windows interpreted precise Mac pixel scrolling as wheel notches")
                wheel.lineDeltaX = 0; wheel.lineDeltaY = -3
                viewer.peer.send(try Wire.json(.input, wheel))
                let rejected = try probe.next("ended")
                try require((rejected["reason"] as? String)?.contains("无效") == true, "Windows accepted a line wheel carrying trackpad phases")
            }
            try withWindowsHost { probe, viewer in
                try until("the Mac has a picture from the Windows host without trackpad gestures") { !viewer.state.get().decoded.isEmpty }
                var smart = RemoteInput(kind: .smartMagnify)
                smart.x = 0.2; smart.y = 0.8; smart.gesturePhase = .ended
                try viewer.send(smart)
                var wheel = RemoteInput(kind: .scroll)
                wheel.x = 0.25; wheel.y = 0.5; wheel.deltaY = 36; wheel.lineDeltaX = 0; wheel.lineDeltaY = 3
                try viewer.send(wheel)
                try require(try probe.next("inject")["operations"] as? [String] == ["Move { x: 0.25, y: 0.5 }", "Wheel { vertical: 120, horizontal: 0 }"],
                            "An older Windows host acted on a new gesture or lost the legacy line wheel")
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

        run("A Mac viewer learns the Windows host ID and may rename its own device within the authenticated session") {
            try withWindowsHost(["--device-id", windowsID.uuidString], identity: macIdentity) { probe, viewer in
                let received = try probe.next("viewerIdentity")
                try until("the authenticated Windows hello is applied") { viewer.state.get().hello != nil }
                let hello = viewer.state.get().hello
                try require(hello?.deviceID == windowsID && hello?.deviceIdentityExchange == true, "The Windows hello omitted its stable host ID or the exchange flag")
                try require(received["id"] as? String == macIdentity.id.uuidString.lowercased() && received["name"] as? String == macIdentity.displayName,
                            "Windows reported a different viewer ID or display name: \(received)")
                let renamed = DeviceIdentity(id: macIdentity.id, name: "Mac 已改名")
                viewer.peer.send(try Wire.json(.deviceIdentity, renamed))
                try require(try probe.next("viewerIdentity")["name"] as? String == renamed.name, "The same viewer could not update its name")
                let nextViewer = DeviceIdentity(id: UUID(), name: "另一台 Mac")
                viewer.peer.send(try Wire.json(.deviceIdentity, nextViewer))
                let end = try probe.next("ended")
                try require((end["reason"] as? String)?.contains("设备标识发生变化") == true && probe.all("viewerIdentity").count == 2,
                            "Windows accepted a different UUID in the same session: \(end)")
                guard let port = probe.all("listening").first?["port"] as? UInt16 else { throw Failure("The Windows listener lost its port") }
                let newSession = MacViewer(port: port, key: key, preferred: .init(longestEdge: 1920, framesPerSecond: 30, megabits: 8), useMedia: false, identity: nextViewer)
                defer { newSession.stop() }
                let identity = try probe.next("viewerIdentity")
                try until("another authenticated viewer decodes the new session") { !newSession.state.get().decoded.isEmpty }
                try require(identity["id"] as? String == nextViewer.id.uuidString.lowercased() && newSession.state.get().hello?.deviceID == windowsID,
                            "The host's own ID changed, or the previous session's viewer ID leaked into the new session")
            }
        }

        run("A Windows host rejects unnegotiated or malformed viewer identity messages") {
            try withWindowsHost(identity: macIdentity) { probe, viewer in
                try until("a viewer with an identity decodes video from the legacy host") { !viewer.state.get().decoded.isEmpty }
                try require(viewer.state.get().hello?.deviceID == nil && probe.all("viewerIdentity").isEmpty, "The legacy host exchanged device identities")
                viewer.peer.send(try Wire.json(.deviceIdentity, macIdentity))
                try require(try (probe.next("ended")["reason"] as? String)?.contains("不支持") == true && probe.all("viewerIdentity").isEmpty,
                            "Windows accepted an unsolicited identity")
            }
            try withWindowsHost(["--device-id", windowsID.uuidString]) { probe, viewer in
                try until("the host streams to a viewer without a device ID") { !viewer.state.get().decoded.isEmpty }
                let compactID = macIdentity.id.uuidString.replacingOccurrences(of: "-", with: "")
                viewer.peer.send(try Wire.json(.deviceIdentity, ["id": compactID, "name": "Mac"]))
                _ = try probe.next("ended")
                try require(probe.all("viewerIdentity").isEmpty, "Windows recorded a UUID that Swift cannot decode")
            }
        }

        run("A Mac viewer with another pairing code gets no further with a Windows host than with a Mac host") {
            try withWindowsHost(["--device-id", windowsID.uuidString], viewerKey: try PairingKey.generate(), identity: macIdentity) { probe, viewer in
                try require(try probe.next("rejected")["reason"] as? String != nil, "The Windows host did not record the refusal")
                // Network.framework reports the host's bad-record-MAC alert while it keeps the connection
                // waiting, exactly as it does against a Mac host; Peer then ends the attempt at its
                // handshake timeout. The session never becomes ready and no hello is delivered.
                usleep(300_000)
                let current = viewer.state.get()
                try require(!current.ready && current.hello == nil && current.received.isEmpty, "A viewer without the key got through")
                try require(probe.all("accepted").isEmpty && probe.all("viewerIdentity").isEmpty, "The Windows host accepted or identified a viewer without the key")
            }
        }

        func withMacHost(advertiseMedia: Bool = true, udp: Bool = false, route: ((UInt16) throws -> UInt16)? = nil, fec: CheckFEC? = nil, legacyMedia: Bool = false, cursorImage: CursorImage? = nil, twoDisplays: Bool = false, inputActions: Bool = true, relativeMouse: Bool = true,
                         trackpadGestures: Bool = true, deviceID: UUID? = UUID(), identityExchange: Bool? = true, prepareHello: @escaping (Message) throws -> Message = { $0 },
                         viewerKey: PairingKey? = nil, quality: String = "1920,60,20", clipboard: InteropClipboard? = nil, advertiseAudio: Bool = true,
                         _ extra: [String] = [], _ body: (MacHost, Probe) throws -> Void) throws {
            let host = try MacHost(key: key, packets: packets, size: size, advertiseMedia: advertiseMedia, cursorImage: cursorImage,
                                   externalPackets: twoDisplays ? externalPackets : [], inputActions: inputActions, relativeMouse: relativeMouse, trackpadGestures: trackpadGestures,
                                   deviceID: deviceID, identityExchange: identityExchange, prepareHello: prepareHello, clipboard: clipboard, advertiseAudio: advertiseAudio, fec: fec, legacyMedia: legacyMedia)
            defer { host.stop() }
            let port = try route?(host.port) ?? host.port
            let probe = try Probe(probePath, ["viewer", "--code", (viewerKey ?? key).code, "--port", "\(port)", "--quality", quality] + (udp ? [] : ["--no-udp"]) + extra)
            defer { probe.stop() }
            try body(host, probe)
            let failures = host.state.get().failures
            try require(failures.isEmpty, "The macOS host rejected what the Windows viewer sent: \(failures)")
        }

        for windowsHost in [true, false] {
            let role = windowsHost ? "host" : "viewer"
            run("The Windows \(role) transfers on-demand clipboard content and approved file roots with the Mac over TLS") {
                let directory = URL(fileURLWithPath: work).appendingPathComponent("clipboard-\(role)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let board = InteropClipboard(directory)
                let arguments = ["--synthetic-clipboard", directory.path]
                if windowsHost {
                    try withWindowsHost(arguments, clipboard: board) { probe, viewer in
                        try until("the Mac viewer commits dedicated TCP video") { viewer.state.get().commitPaths == ["tcp"] }
                        try checkPhysicalClipboard(board, probe)
                    }
                } else {
                    try withMacHost(clipboard: board, arguments) { host, probe in
                        try until("the Mac host receives the bulk bind and TCP commit") {
                            let s = host.state.get()
                            return s.messagesByAuxiliary[.bulk]?.first == .mediaControl && s.commits.first?.path == "tcp"
                        }
                        try checkPhysicalClipboard(board, probe)
                    }
                }
                let all = board.received.get(), bulk = board.bulkReceived.get()
                try require(all.contains(.clipboardManifest) && !bulk.contains(.clipboardManifest),
                            "Windows clipboard manifests did not arrive on the ordered control connection")
                for kind in [MessageKind.clipboardPull, .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd,
                             .clipboardReceipt, .clipboardCancel] {
                    try require(all.contains(kind) && all.filter { $0 == kind }.count == bulk.filter { $0 == kind }.count,
                                "A clipboard transfer record bypassed the authenticated bulk socket: \(kind)")
                }
            }
        }

        run("A Windows viewer omits root names when the Mac accepts physical file paste without fileRootNamesV1") {
            let directory = URL(fileURLWithPath: work).appendingPathComponent("unnamed-file-paste", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let board = InteropClipboard(directory, receivesFileRootNames: false)
            let file = directory.appendingPathComponent("仅在粘贴时读取.txt")
            try Data([1, 2]).write(to: file)
            try withMacHost(advertiseMedia: false, clipboard: board, ["--synthetic-clipboard", directory.path]) { _, probe in
                try until("the older physical-paste preferences arrive") { board.transfer.get() != nil }
                try probe.send(["command": "copyFiles", "names": [file.lastPathComponent]])
                try until("Windows announces a count-only file manifest") { board.manifest.get()?.kind == .files }
                guard let manifest = board.manifest.get() else { throw Failure("Missing count-only manifest") }
                try require(manifest.fileRootCount == 1 && manifest.fileRootNames == nil &&
                            board.received.get() == [.clipboardManifest] && probe.all("clipboardRead").isEmpty,
                            "Windows disclosed names, rendered a file, or offered contents to the older receiver on copy")
            }
        }

        run("A Windows viewer uses the original file approval with a Mac that offers only on-demand text and images") {
            let directory = URL(fileURLWithPath: work).appendingPathComponent("legacy-clipboard", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let board = InteropClipboard(directory, physical: false)
            let file = directory.appendingPathComponent("legacy.txt")
            try Data([7, 5, 1]).write(to: file)
            try withMacHost(advertiseMedia: false, clipboard: board, ["--synthetic-clipboard", directory.path]) { _, probe in
                try until("legacy clipboard negotiation") { board.transfer.get() != nil }
                guard let transfer = board.transfer.get() else { throw Failure("No legacy file transfer") }
                try probe.send(["command": "copyFiles", "names": [file.lastPathComponent]])
                try until("the old Mac gets the Windows file offer") { !board.offers.get().isEmpty }
                guard let offer = board.offers.get().first else { throw Failure("No legacy file offer") }
                try require(board.received.get() == [.clipboardBegin] && offer.count == 1, "Windows sent a file pull or data before the old Mac approved")
                transfer.respondToFileOffer(id: offer.id, accept: true)
                try until("the old Mac stores the file") { !board.applied.get().isEmpty }
                guard case .files(let files)? = board.applied.get().last, let url = files.first else { throw Failure("Wrong legacy payload") }
                try require(try Data(contentsOf: url) == Data([7, 5, 1]), "Legacy file contents changed")
            }
        }

        func verifyWindowsViewerWindow(_ host: MacHost, _ probe: Probe, expected: Int, onWindowVerified: () -> Void = {}) throws {
            try probe.send(["command": "holdAcknowledgements", "hold": true])
            let snapshot = host.state.get()
            let window = VideoFrameFlow.maximumOutstandingFrames(for: snapshot.applied.settings, receiverLimit: snapshot.receiverLimit)
            try require(window == expected, "The Mac selected \(window) credits with the Rust receiver, expected \(expected)")
            let sequences = try (0..<window).map { _ -> UInt32 in
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
            onWindowVerified()
            try probe.send(["command": "holdAcknowledgements", "hold": false])
            for sequence in sequences { try probe.send(["command": "acknowledge", "sequence": Int(sequence)]) }
            try until("decode receipts reopen the Mac capture window") { probe.all("frame").count > frames.count + 6 }
        }

        for (window, delay) in [(8, 0.046), (24, 0.27)] {
            run("A Windows viewer receives the Mac's negotiated \(window)-frame window on a delayed UDP route") {
                var route: InteropMediaRoute?
                defer { route?.stop() }
                try withMacHost(udp: true, route: { port in
                    let relay = try InteropMediaRoute(target: port, forwardUDP: true, pongDelay: delay)
                    route = relay
                    return relay.port
                }) { host, probe in
                    let maximum = MediaBufferLimits.maximumDynamicFrameWindow
                    let matchesLimit: (Int?) -> Bool = { limit in
                        guard let limit else { return false }
                        return window == maximum ? limit == maximum : (window..<maximum).contains(limit)
                    }
                    try until("the measured path selects \(window) credits", seconds: 15) {
                        let state = host.state.get()
                        return state.commits.last?.path == "udp" && matchesLimit(state.receiverLimit)
                    }
                    route?.holdProbes(true)
                    defer { route?.holdProbes(false) }
                    usleep(5_000)
                    guard let negotiated = host.state.get().receiverLimit, matchesLimit(negotiated) else {
                        throw Failure("The delayed UDP route lost its negotiated window: \(String(describing: host.state.get().receiverLimit))")
                    }
                    try verifyWindowsViewerWindow(host, probe, expected: negotiated, onWindowVerified: { route?.holdProbes(false) })
                }
            }
        }

        run("A Windows viewer preserves the full recovery exchange and three credits with an older Mac host") {
            try withMacHost(legacyMedia: true, ["--no-auxiliary"]) { host, probe in
                _ = try probe.next("mediaCommitted")
                try until("the legacy host commits the initial stream") { host.state.get().commits.count == 1 }
                try verifyWindowsViewerWindow(host, probe, expected: 3)
                try probe.send(["command": "quality", "settings": "2560,30,8"])
                _ = try probe.next("mediaCommitted")
                try until("the legacy host commits its same-path recovery") { host.state.get().commits.count == 2 }
                let s = host.state.get()
                for commit in s.commits {
                    let stages = s.transactions.filter { $0.transactionID == commit.transactionID }
                    try require(commit.path == "shared" && stages.first?.fast == nil
                                && stages.map(\.operation) == [.prepare, .ready, .decodedReady, .committed],
                                "A viewer shortened an unnegotiated recovery exchange")
                }
            }
        }

        run("A Windows viewer decodes Mac stereo Opus, discards stale sound and stops on request") {
            try withMacHost(["--synthetic-audio"]) { host, probe in
                try require(try probe.next("connected")["remoteAudio"] as? Bool == true, "The Mac audio capability was lost")
                _ = try probe.next("mediaCommitted")
                let source = try StereoTone.encode()
                guard let peer = host.state.get().peer, let media = host.state.get().media else { throw Failure("The Mac has no active session") }
                try probe.send(["command": "remoteAudio", "enabled": true])
                try until("Mac receives the sound request") { host.state.get().audioRequests.count == 1 }
                let request = host.state.get().audioRequests[0]
                try require(request.enabled && request.redundantOpus == true, "Windows did not negotiate redundant Opus")
                let epoch: UInt32 = 17
                peer.send(try RemoteAudioControl.status(requestID: UUID(), enabled: false, error: "Obsolete request").message())
                peer.send(try RemoteAudioControl.status(requestID: request.requestID, enabled: true, epoch: epoch,
                                                        magicCookie: source.cookie, redundantOpus: true).message())
                _ = try probe.next("audio") { $0["enabled"] as? Bool == true && $0["pending"] as? Bool == false }
                try require(!probe.all("audio").contains { $0["error"] as? String == "Obsolete request" }, "A stale sound response replaced the pending request")
                func packet(_ index: Int, epoch: UInt32) throws -> RemoteAudioPacket {
                    try RemoteAudioPacket(epoch: epoch, sequence: UInt64(index + 1), opusPayload: source.packets[index],
                                          previousOpusPayload: index > 0 ? source.packets[index - 1] : nil)
                }
                for i in 0..<2 { _ = try media.sendAudioPacket(packet(i, epoch: epoch - 1)) }
                for i in 0..<12 where i != 4 {
                    try require(try media.sendAudioPacket(packet(i, epoch: epoch)), "The Mac could not send an Opus packet")
                    usleep(20_000)
                }
                try until("Windows decodes the missing packet from the next redundant packet") { probe.all("audioSamples").count >= 12 }
                let samples = probe.all("audioSamples")
                try require(samples.count == 12 && samples.allSatisfy { $0["epoch"] as? Int == Int(epoch) && $0["frames"] as? Int == 960 },
                            "The viewer played a stale epoch, skipped a packet or decoded the wrong duration")
                let audible = samples.dropFirst(3).allSatisfy { sample in
                    guard let levels = sample["levels"] as? [[Double]] else { return false }
                    return StereoTone.matches(levels)
                }
                try require(audible, "The sound Windows actually decoded did not preserve the left and right Mac tones")
                try probe.send(["command": "remoteAudio", "enabled": false])
                try until("Mac receives the mute request") { host.state.get().audioRequests.count == 2 }
                let stop = host.state.get().audioRequests[1]
                try require(!stop.enabled && stop.requestID != request.requestID, "Muting reused the enable request")
                peer.send(try RemoteAudioControl.status(requestID: stop.requestID, enabled: false).message())
                _ = try probe.next("audio") { $0["enabled"] as? Bool == false && $0["pending"] as? Bool == false }
                for i in 0..<3 { _ = try media.sendAudioPacket(packet(i, epoch: epoch)) }
                let before = probe.all("frame").count
                try until("video continues after muting") { probe.all("frame").count > before + 6 }
                try require(probe.all("audioSamples").count == samples.count, "Windows played late audio after muting")
            }
        }

        run("Windows receives the Mac cursor and Opus and sends motion over negotiated datagrams before resuming on TCP") {
            var route: InteropMediaRoute?
            defer { route?.stop() }
            try withMacHost(udp: true, route: { port in
                let proxy = try InteropMediaRoute(target: port, forwardUDP: true)
                route = proxy
                return proxy.port
            }, cursorImage: SyntheticCursor.image(), ["--synthetic-audio"]) { host, probe in
                try until("the Mac has the cursor binding") { host.state.get().heldCursorPreparation != nil }
                guard let binding = host.state.update({ state in
                    defer { state.heldCursorPreparation = nil }
                    return state.heldCursorPreparation
                }) else { throw Failure("Missing cursor transaction") }
                binding.complete(true)
                try until("the Mac serves a committed UDP stream") { host.state.get().commits.last?.path == "udp" }
                try require(try host.moveCursor(sequence: 2, x: 0.875, y: 0.125), "The Mac could not submit a cursor datagram")
                _ = try probe.next("cursor") { event in
                    let p = event["position"] as? [String: Any]
                    return event["enabled"] as? Bool == true && p?["x"] as? Double == 0.875 && p?["y"] as? Double == 0.125
                }
                try probe.send(["command": "move", "x": 0.375, "y": 0.625])
                try until("the Mac receives the sequenced move on its UDP callback") {
                    host.state.get().datagramInputs.contains { $0.kind == .move && $0.x == 0.375 && $0.pointerSequence != nil }
                }
                try probe.send(["command": "button", "button": 0, "down": true, "x": 0.375, "y": 0.625, "atMilliseconds": 100, "pixel": [30, 50]])
                try until("the Mac receives the button on its reliable input handler") { host.state.get().inputs.contains { $0.kind == .down } }
                let inputs = host.state.get()
                try require(inputs.inputs.allSatisfy { $0.kind != .move } && inputs.datagramInputs.allSatisfy { $0.kind == .move }, "Pointer traffic used the wrong path")
                guard let peer = inputs.peer, let media = inputs.media else { throw Failure("Missing active host") }
                try probe.send(["command": "remoteAudio", "enabled": true])
                try until("the Windows viewer requests audio") { !host.state.get().audioRequests.isEmpty }
                let request = host.state.get().audioRequests[0], epoch: UInt32 = 5, tones = try StereoTone.encode()
                peer.send(try RemoteAudioControl.status(requestID: request.requestID, enabled: true, epoch: epoch, magicCookie: tones.cookie, redundantOpus: false).message())
                _ = try probe.next("audio") { $0["enabled"] as? Bool == true && $0["pending"] as? Bool == false }
                for (index, opus) in tones.packets.prefix(10).enumerated() {
                    let packet = try RemoteAudioPacket(epoch: epoch, sequence: UInt64(index + 1), opusPayload: opus)
                    try require(media.sendAudioPacket(packet), "Could not queue the Mac audio packet")
                    usleep(20_000)
                }
                try until("the Windows audio sink receives the stereo tones") { probe.all("audioSamples").count >= 10 }
                let samples = probe.all("audioSamples").dropFirst(3)
                try require(samples.allSatisfy { sample in
                    guard sample["epoch"] as? Int == Int(epoch), let levels = sample["levels"] as? [[Double]] else { return false }
                    return StereoTone.matches(levels)
                }, "Windows decoded the wrong stereo tones")

                try probe.send(["command": "button", "button": 0, "down": false, "x": 0.375, "y": 0.625, "atMilliseconds": 150, "pixel": [30, 50]])
                try until("the Mac receives the button release on control") { host.state.get().inputs.contains { $0.kind == .up } }
                route?.forwardUDP(false)
                try until("the Mac rebinds its cursor and Windows commits TCP video after UDP loss", seconds: 20) {
                    let binding = host.state.update { state in
                        defer { state.heldCursorPreparation = nil }
                        return state.heldCursorPreparation
                    }
                    binding?.complete(true)
                    return host.state.get().commits.last?.path == "tcp"
                }
                guard let start = host.state.get().recoverySequences.last else { throw Failure("Missing TCP recovery frame") }
                for index in 0..<5 {
                    let frame = try probe.next("frame") { $0["sequence"] as? UInt32 == start + UInt32(index) }
                    try require(frame["annexB"] as? String == hex(annexB(packets[index])) && frame["firstInMediaStream"] as? Bool == (index == 0),
                                "Windows received different H.264 bytes after UDP loss")
                }
                try require(try !host.moveCursor(sequence: 3, x: 0.625, y: 0.25), "The Mac still selected a cursor datagram after UDP loss")
                _ = try probe.next("cursor") { event in
                    let position = event["position"] as? [String: Any]
                    return event["enabled"] as? Bool == true && position?["x"] as? Double == 0.625 && position?["y"] as? Double == 0.25
                }
                try probe.send(["command": "move", "x": 0.125, "y": 0.875])
                try until("Windows resumes sequenced pointer motion on control") {
                    host.state.get().inputs.contains { $0.kind == .move && $0.x == 0.125 && $0.y == 0.875 && $0.pointerSequence != nil }
                }
                for (i, opus) in tones.packets.dropFirst(10).prefix(2).enumerated() {
                    let packet = try RemoteAudioPacket(epoch: epoch, sequence: UInt64(i + 11), opusPayload: opus)
                    try require(media.sendAudioPacket(packet), "The Mac did not accept an audio frame for fallback")
                    usleep(20_000)
                }
                _ = try probe.next("audioSamples") { sample in
                    guard sample["epoch"] as? Int == Int(epoch), sample["receivedSequence"] as? Int == 12,
                          let levels = sample["levels"] as? [[Double]] else { return false }
                    return StereoTone.matches(levels)
                }
                try require((route?.dropped.get() ?? 0) > 0, "The proxy did not drop any UDP records")
            }
        }

        run("A Windows playback error stops Mac capture while video continues") {
            try withMacHost(["--synthetic-audio", "--fail-audio"]) { host, probe in
                _ = try probe.next("connected")
                try probe.send(["command": "remoteAudio", "enabled": true])
                try until("Mac receives the request before playback fails") { host.state.get().audioRequests.count == 1 }
                guard let peer = host.state.get().peer else { throw Failure("Missing authenticated peer") }
                peer.send(try RemoteAudioControl.status(requestID: host.state.get().audioRequests[0].requestID, enabled: true, epoch: 1).message())
                _ = try probe.next("audio") { $0["enabled"] as? Bool == false && ($0["error"] as? String)?.contains("Synthetic audio playback") == true }
                try until("Windows releases the Mac's capture") { host.state.get().audioRequests.last?.enabled == false }
                peer.send(try RemoteAudioControl.status(requestID: host.state.get().audioRequests.last?.requestID, enabled: false).message())
                let count = probe.all("frame").count
                try until("pictures continue after the playback error") { probe.all("frame").count > count + 4 }
                try require(probe.all("audioSamples").isEmpty, "The unavailable playback worker reported decoded samples")
            }
        }

        run("A Windows viewer keeps sound disabled when the Mac omits remoteAudioV1") {
            try withMacHost(advertiseAudio: false, ["--synthetic-audio"]) { host, probe in
                try require(try probe.next("connected")["remoteAudio"] as? Bool == false, "Windows advertised an unavailable session capability")
                try probe.send(["command": "remoteAudio", "enabled": true])
                try probe.send(["command": "pause", "paused": true])
                _ = try probe.next("paused")
                try require(host.state.get().audioRequests.isEmpty && !host.state.get().received.contains(.audioControl),
                            "Windows sent an audio message to a legacy Mac")
            }
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
                try verifyWindowsViewerWindow(host, probe, expected: 3)
            }
        }

        for fec in CheckFEC.allCases {
            run("Windows recovers selected Mac UDP fragments using \(fec.rawValue) negotiation") {
                var route: InteropMediaRoute?
                defer { route?.stop() }
                try withMacHost(udp: true, route: { port in
                    let relay = try InteropMediaRoute(target: port, forwardUDP: true)
                    route = relay
                    return relay.port
                }, fec: fec) { host, probe in
                    try until("the isolated UDP stream commits") { host.state.get().commits.last?.path == "udp" }
                    guard let route else { throw Failure("Missing loopback route") }
                    func verify(_ source: VideoPacket, holes: Int) throws {
                        let sent = try host.sendFECFrame(source: source, fullFragments: holes)
                        do {
                            let sample = try probe.next("frame", seconds: 3) { $0["sequence"] as? UInt32 == sent.sequence }
                            try require(sample["annexB"] as? String == hex(annexB(sent)), "Recovery changed the encoder's bytes")
                        } catch { throw Failure("\(error); encrypted datagram size counts \(route.sizesAfterLoss())") }
                    }
                    // A real NACK primes the host's two-shard policy before two packets from the next block are lost.
                    route.loseVideoFragments(.firstFullFragmentAndParity)
                    try verify(packets[1], holes: 1)
                    try require((route.sizesAfterLoss()[InteropMediaRoute.full] ?? 0) >= 2, "The missing original and its repair were not both observed")
                    if fec != .legacy {
                        route.loseVideoFragments(.everyFullFragment)
                        let holes = fec == .block ? 2 : 1
                        try verify(packets[2], holes: holes)
                        let counts = route.sizesAfterLoss(), shard = fec == .block ? InteropMediaRoute.block : InteropMediaRoute.xor
                        try require(counts[shard, default: 0] >= holes && counts[InteropMediaRoute.full, default: 0] >= holes,
                                    "FEC did not recover all continuously withheld data shards")
                    } else {
                        let counts = route.sizesAfterLoss()
                        try require(counts[InteropMediaRoute.xor] == nil && counts[InteropMediaRoute.block] == nil, "A legacy peer received parity")
                    }
                }
            }
        }

        for reachable in [true, false] {
            run(reachable ? "A Windows viewer decodes Mac UDP, moves to reliable video and returns on the first timed UDP reprobe"
                          : "A Windows viewer keeps the Mac video on bound TCP when UDP traffic is discarded") {
                var route: InteropMediaRoute?
                defer { route?.stop() }
                try withMacHost(udp: true, route: { port in
                    let relay = try InteropMediaRoute(target: port, forwardUDP: reachable)
                    route = relay
                    return relay.port
                }, ["--hold-media-openers"]) { host, probe in
                    let decoder = VideoDecoder()
                    defer { decoder.stop() }
                    func check(_ path: String, seconds: Double = 15) throws -> MediaControl {
                        let deadline = SessionClock.uptime + seconds
                        while SessionClock.uptime < deadline {
                            let frame = try probe.next("frame", seconds: max(0.1, deadline - SessionClock.uptime)) {
                                $0["firstInMediaStream"] as? Bool == true
                            }
                            guard let sequence = frame["sequence"] as? UInt32 else { throw Failure("Windows omitted the recovery frame sequence") }
                            try require(frame["held"] as? Bool == true && frame["key"] as? Bool == true
                                        && frame["annexB"] as? String == hex(annexB(packets[0])), "Windows received a different recovery frame")
                            guard let encoded = frame["openingPacket"] as? [UInt8] else { throw Failure("Windows did not return its opening packet") }
                            let opening = try VideoPacket.decode(Data(encoded))
                            try require(opening.sequence == sequence, "The decoded receipt would refer to a different opening packet")
                            let ready = DispatchSemaphore(value: 0), decoded = Shared(false)
                            decoder.decode(opening) { result in
                                if case .success(let image) = result {
                                    decoded.update { $0 = CVPixelBufferGetWidth(image) == size.width && CVPixelBufferGetHeight(image) == size.height }
                                }
                                ready.signal()
                            }
                            try require(ready.wait(timeout: .now() + 2) == .success && decoded.get(), "VideoToolbox rejected the Rust receiver's opening frame")
                            try probe.send(["command": "acknowledge", "sequence": sequence])
                            let event = try probe.next("mediaCommitted")
                            try until("the Mac observes the matching commit") {
                                host.state.get().commits.contains {
                                    $0.sessionID?.uuidString.lowercased() == event["sessionID"] as? String
                                        && $0.transportEpoch == event["transportEpoch"] as? UInt32 && $0.codecEpoch == event["codecEpoch"] as? UInt32
                                }
                            }
                            guard let commit = host.state.get().commits.first(where: { $0.transportEpoch == event["transportEpoch"] as? UInt32 }),
                                  commit.path == path else { continue }
                            for index in 1..<8 {
                                let next = try probe.next("frame") { $0["sequence"] as? UInt32 == sequence + UInt32(index) }
                                try require(next["annexB"] as? String == hex(annexB(packets[index])) && next["firstInMediaStream"] as? Bool == false,
                                            "Mac \(path) frame \(index + 1) changed on Windows")
                            }
                            let ops = host.state.get().transactions.filter { $0.transactionID == commit.transactionID }
                            let expected: [MediaControl.Operation] = ops.first?.fast == true ? [.prepare, .committed] : [.prepare, .ready, .decodedReady, .committed]
                            try require(ops.map(\.operation) == expected, "Unexpected Windows exchange on \(path): \(ops.map(\.operation))")
                            return commit
                        }
                        throw Failure("No decoded Windows commit on \(path)")
                    }
                    let first = try check(reachable ? "udp" : "tcp")
                    if reachable {
                        try require(!host.state.get().decodedFeedback.contains { $0.stream.transportEpoch == first.transportEpoch }, "Windows returned UDP receipts on control")
                        // Hold the TLS copy until after commit. The authenticated UDP prepare alone must start this recovery.
                        host.state.update { $0.holdFastPrepare = true }
                        try probe.send(["command": "quality", "settings": "2560,30,8"])
                        let fast = try check("udp")
                        let snapshot = host.state.get()
                        guard let held = snapshot.deferredFastPrepare, let media = snapshot.media else { throw Failure("Windows did not send a fast TLS prepare") }
                        let deferred = try MediaControl.read(held.payload)
                        try require(deferred.transactionID == fast.transactionID && deferred.fast == true && deferred.path == "udp",
                                    "UDP and TLS prepared different transactions")
                        host.state.update { $0.holdFastPrepare = false }
                        try require(media.receive(held), "Mac rejected the delayed TLS copy")
                        try probe.send(["command": "requestClipboard"])
                        _ = try probe.next("clipboardText")
                        try require(host.state.get().recoverySequences.count == snapshot.recoverySequences.count, "The duplicate prepare restarted encoding")
                        let cut = SessionClock.uptime
                        route?.forwardUDP(false)
                        let tcp = try check("tcp")
                        route?.forwardUDP(true)
                        let restored = try check("udp", seconds: 43)
                        try require([fast, tcp, restored].allSatisfy { $0.sessionID == first.sessionID } && (tcp.transportEpoch ?? 0) > (fast.transportEpoch ?? 0)
                                    && (restored.transportEpoch ?? 0) > (tcp.transportEpoch ?? 0) && SessionClock.uptime - cut >= 30,
                                    "Windows recovered outside the original session or before its first reprobe")
                    } else {
                        try require((route?.dropped.get() ?? 0) > 0 && host.state.get().commits.allSatisfy { $0.path != "udp" },
                                    "Windows committed a path whose datagrams were discarded, or did not try UDP")
                    }
                    try probe.send(["command": "requestClipboard"])
                    try require(try probe.next("clipboardText")["text"] as? String == host.state.get().clipboard, "Control stopped answering during video")
                }
            }
        }

        run("A Windows viewer binds both Mac TLS roles, acknowledges video on control and recommits after the video link closes") {
            try withMacHost { host, probe in
                _ = try probe.next("mediaCommitted")
                try until("the Mac sees both bind requests and a TCP video commit") {
                    let s = host.state.get()
                    return s.commits.last?.path == "tcp" && [.video, .bulk].allSatisfy { s.messagesByAuxiliary[$0]?.first == .mediaControl }
                }
                let s = host.state.get()
                guard let first = s.commits.last, let sequence = s.recoverySequences.first, let video = s.auxiliary[.video] else { throw Failure("Missing bound video stream") }
                let sample = try probe.next("frame") { $0["sequence"] as? UInt32 == sequence }
                try require(sample["firstInMediaStream"] as? Bool == true && sample["annexB"] as? String == hex(annexB(packets[0])),
                            "The Windows viewer did not receive the Mac's recovery frame on bound video")
                try until("the Mac receives decoded frame receipts on control") { host.state.get().decodedFeedback.contains { $0.stream.transportEpoch == first.transportEpoch && $0.frameID >= 5 } }
                try require(host.state.get().messagesByAuxiliary[.video] == [.mediaControl], "The Windows viewer put transaction or feedback traffic on its video socket")
                video.close("Synthetic video link ended")
                _ = try probe.next("mediaCommitted")
                try until("the Mac and Windows viewer settle a new shared stream") {
                    let s = host.state.get()
                    guard let last = s.commits.last, last.path == "shared", first.sessionID == last.sessionID, last.transportEpoch != first.transportEpoch else { return false }
                    return s.decodedFeedback.contains { $0.stream.transportEpoch == last.transportEpoch && $0.frameID >= 3 }
                }
                try require(host.state.get().closed == nil && probe.all("ended").isEmpty, "Closing video ended the desktop session")
            }
        }

        run("A Windows viewer commits shared Mac streams and returns decode receipts for the encoder's exact frames") {
            try withMacHost(["--no-auxiliary"]) { host, probe in
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
                try verifyWindowsViewerWindow(host, probe, expected: 6)

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

        run("A Windows viewer subscribes to Mac displays, preserves a rejected selection and follows the next committed pictures") {
            try withMacHost(twoDisplays: true) { host, probe in
                let main = SyntheticDisplays.primary, external = SyntheticDisplays.external
                func verifyStream(_ source: [VideoPacket]) throws {
                    let stream = try probe.next("mediaCommitted")
                    try until("the Mac observes the selected stream's commit") {
                        let s = host.state.get()
                        return s.commits.last?.transportEpoch == stream["transportEpoch"] as? UInt32 && !s.recoverySequences.isEmpty
                    }
                    let first = Int(host.state.get().recoverySequences.last!)
                    for index in 0..<2 {
                        let frame = try probe.next("frame") { $0["sequence"] as? Int == first + index }
                        try require(frame["annexB"] as? String == hex(annexB(source[index])) && frame["key"] as? Bool == (index == 0),
                                    "The committed Mac screen supplied a different picture")
                    }
                }

                try verifyStream(packets)
                try until("the Mac accepts a display subscription") { host.state.get().subscribedDisplays }
                let initial = try probe.next("displays") { $0["selected"] as? UInt32 == main.id }
                let list = try Wire.readJSON([RemoteDisplayInfo].self, JSONSerialization.data(withJSONObject: initial["displays"] ?? []))
                try require(list == [main, external], "Windows did not expose the Mac's actual two displays")
                try probe.send(["command": "selectDisplay", "id": main.id])
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                try require(host.state.get().displaySelections.isEmpty && host.state.get().commits.count == 1, "A redundant local selection restarted capture")

                host.state.update { $0.rejectNextDisplay = true }
                try probe.send(["command": "selectDisplay", "id": external.id])
                let pending = try probe.next("displays") { $0["pending"] as? UInt32 == external.id }
                try require(pending["selected"] as? UInt32 == main.id, "The requested display was presented as active before the Mac confirmed it")
                let rejected = try probe.next("displays") { $0["error"] is String }
                try require(rejected["selected"] as? UInt32 == main.id && rejected["pending"] is NSNull, "A refused display remained pending or selected")
                try probe.send(["command": "selectDisplay", "id": external.id])
                _ = try probe.next("displays") { $0["selected"] as? UInt32 == external.id && $0["pending"] is NSNull }
                try verifyStream(externalPackets)

                // A valid result for an obsolete request cannot select another display.
                let current = host.state.get()
                current.peer?.send(try DisplayControl.result(id: UUID(), selectedDisplayID: main.id, displays: current.displays,
                                                            videoState: current.applied).message())
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                try require(probe.all("displays").last?["selected"] as? UInt32 == external.id, "A stale Mac result changed the Windows selection")
                try host.changeDisplay(to: main.id, available: [main])
                _ = try probe.next("displays") { $0["selected"] as? UInt32 == main.id && ($0["displays"] as? [Any])?.count == 1 }
                try verifyStream(packets)
                current.peer?.send(try DisplayControl.subscribe().message())
                let end = try probe.next("ended")
                try require(end["retryable"] as? Bool == false && end["hostEnded"] as? Bool == false,
                            "Windows accepted a display request sent in the host direction")
            }
        }

        run("A Windows viewer uses confirmed Mac keyboard actions and preserves the next key's input source") {
            func press(_ probe: Probe, start: Int, duration: Int) throws {
                try probe.send(["command": "capsPress", "down": true, "atMilliseconds": start])
                try probe.send(["command": "capsPress", "down": false, "atMilliseconds": start + duration])
            }
            try withMacHost(["--independent-caps"]) { host, probe in
                try require(try probe.next("connected")["inputActions"] as? Bool == true, "Windows did not negotiate Mac keyboard actions")
                _ = try probe.next("frame")
                try press(probe, start: 100, duration: 600)
                let upper = try probe.next("inputStatus")
                try require(upper["capsLocked"] as? Bool == true && upper["message"] as? String == "远端大写锁定已开启", "The Mac's Caps Lock confirmation was lost")
                try probe.send(["command": "key", "scanCode": 0x1e, "down": true])
                try until("the Mac injector posts a capitalized letter") {
                    host.state.get().posted.contains { $0.type == .keyDown && $0.keyCode == 0 && $0.flags.contains(.maskAlphaShift) && $0.sourceID == "abc" }
                }
                try probe.send(["command": "key", "scanCode": 0x1e, "down": false])
                try press(probe, start: 1000, duration: 100)
                let lower = try probe.next("inputStatus")
                try require(lower["capsLocked"] as? Bool == false && lower["message"] as? String == "远端大写锁定已关闭" && host.keyboard.active.get() == "abc",
                            "A short press selected an input source while Caps Lock was still active")
                try press(probe, start: 2000, duration: 100)
                try probe.send(["command": "key", "scanCode": 0x30, "down": true, "capsLock": true])
                let source = try probe.next("inputStatus")
                try require(source["message"] as? String == "远端输入源已确认：合成拼音" && source["capsLocked"] as? Bool == false,
                            "Windows did not expose the Mac's confirmed input source")
                try until("the next key uses the confirmed Mac input source") {
                    host.state.get().posted.contains { $0.type == .keyDown && $0.keyCode == 11 && !$0.flags.contains(.maskAlphaShift) && $0.sourceID == "pinyin" }
                }
                try probe.send(["command": "key", "scanCode": 0x30, "down": false])
                host.keyboard.refuse.update { $0 = true }
                try press(probe, start: 3000, duration: 100)
                let refused = try probe.next("inputStatus")
                try require((refused["message"] as? String)?.contains("Synthetic input source rejected") == true && refused["capsLocked"] as? Bool == false
                            && host.keyboard.active.get() == "pinyin", "Windows reported success after the Mac input source refused the request")
            }
            try withMacHost(inputActions: false, ["--independent-caps"]) { host, probe in
                try require(try probe.next("connected")["inputActions"] as? Bool == false, "Windows enabled keyboard actions for an older Mac")
                try press(probe, start: 1000, duration: 700)
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                try require(!host.state.get().received.contains(.input), "An older Mac received an unnegotiated keyboard action")
                host.state.get().peer?.send(try Wire.json(.inputStatus, InputFeedback(message: "Unsolicited", capsLocked: true)))
                try require(try probe.next("ended")["retryable"] as? Bool == false && probe.all("inputStatus").isEmpty,
                            "Windows trusted an unnegotiated input status")
            }
        }

        run("Windows relative input reaches the Mac injector with raw edge deltas, anchored clicks and a matching release") {
            try withMacHost { host, probe in
                try require(try probe.next("connected")["relativeMouse"] as? Bool == true, "The Windows viewer missed the Mac's relative pointer capability")
                _ = try probe.next("frame")
                host.state.update { $0.pointer = CGPoint(x: 1550, y: 50) }
                try probe.send(["command": "relativeMove", "dx": 30.5, "dy": -20.5])
                try probe.send(["command": "relativeMove", "dx": 60.5, "dy": -50.5])
                let button: [String: Any] = ["command": "button", "button": 0, "down": true, "x": 0.1, "y": 0.2,
                                             "atMilliseconds": 1000, "pixel": [200, 300], "relative": true]
                try probe.send(button)
                try probe.send(["command": "relativeMove", "dx": -7, "dy": 13])
                try probe.send(["command": "wheel", "vertical": 1, "horizontal": 0, "x": 0.1, "y": 0.2, "relative": true])
                try probe.send(["command": "release"])
                try probe.send(["command": "move", "x": 1, "y": 1])
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                let s = host.state.get()
                try require(s.inputs.map(\.kind) == [.move, .move, .down, .drag, .scroll, .move]
                            && s.inputs.compactMap(\.pointerSequence) == (1...6).map(UInt64.init),
                            "Windows lost the pointer order, drag or unlocked move")
                try require(s.inputs.prefix(5).allSatisfy { $0.relativeMouse == true && $0.x == 0.5 && $0.y == 0.5 } && s.inputs.last?.relativeMouse == nil,
                            "Windows continued to use absolute positions during pointer lock")
                let events = s.posted
                try require(events.map(\.type) == [.mouseMoved, .mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel, .leftMouseUp, .mouseMoved],
                            "Windows motion caused a lost release or extra mouse movement on the Mac")
                let edge = CGPoint(x: 1599, y: 0), dragged = CGPoint(x: 1592, y: 13)
                try require(events[0].location == CGPoint(x: 1580.5, y: 29.5) && events[0].motion == (30, -20)
                            && events[1].location == edge && events[1].motion == (61, -51), "The Mac injector lost raw motion or subpixel remainder at the screen edge")
                try require(events[2].location == edge && events[3...5].allSatisfy { $0.location == dragged } && events[6].location == CGPoint(x: 1599, y: 899),
                            "A button, scroll or release changed the virtual pointer position")
            }
            try withMacHost(relativeMouse: false) { host, probe in
                try require(try probe.next("connected")["relativeMouse"] as? Bool == false, "Windows enabled raw input for an older Mac")
                try probe.send(["command": "relativeMove", "dx": 9, "dy": 5])
                try probe.send(["command": "move", "x": 0.25, "y": 0.75])
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                let inputs = host.state.get().inputs
                try require(inputs.count == 1 && inputs[0].kind == .move && inputs[0].relativeMouse == nil && inputs[0].pointerDeltaX == nil
                            && inputs[0].x == 0.25 && inputs[0].y == 0.75, "An old Mac received a locked movement or lost its absolute move")
            }
        }

        run("Windows pixel scrolling, momentum and trackpad gestures become native phased Mac events") {
            func scroll(_ probe: Probe, phase: RemoteInput.ScrollPhase? = nil, momentum: RemoteInput.MomentumPhase? = nil, dx: Double = 0, dy: Double = 0) throws {
                var command: [String: Any] = ["command": "preciseScroll", "dx": dx, "dy": dy, "x": 0.25, "y": 0.5]
                command["phase"] = phase?.rawValue
                command["momentum"] = momentum?.rawValue
                try probe.send(command)
            }
            func smart(_ probe: Probe) throws {
                try probe.send(["command": "gesture", "gesture": "smartMagnify", "phase": 4, "x": 0.1, "y": 0.9, "relative": true])
            }
            try withMacHost { host, probe in
                try require(try probe.next("connected")["trackpadGestures"] as? Bool == true, "Windows missed the Mac gesture capability")
                _ = try probe.next("frame")
                try scroll(probe, phase: .began)
                try scroll(probe, phase: .changed, dx: 0.25, dy: -0.5)
                try scroll(probe, phase: .changed, dx: 1.75, dy: -2.5)
                try scroll(probe, phase: .ended)
                try scroll(probe, momentum: .began, dx: 1, dy: -4)
                try scroll(probe, momentum: .changed, dx: 2, dy: -1)
                try scroll(probe, momentum: .ended)
                try probe.send(["command": "gesture", "gesture": ["magnify": 0.375], "phase": 2, "x": 0.25, "y": 0.5])
                try probe.send(["command": "gesture", "gesture": ["rotate": -18.5], "phase": 1, "x": 0.25, "y": 0.5])
                try smart(probe)
                try probe.send(["command": "release"])
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                let state = host.state.get(), target = CGPoint(x: 399.75, y: 449.5)
                let wheels = state.posted.filter { $0.type == .scrollWheel }
                let native = wheels.compactMap(\.trackpad)
                try require(native.map(\.phase) == [.began, .changed, .ended, [], [], []] && native.map(\.momentum) == [[], [], [], .began, .changed, .ended]
                            && native.allSatisfy(\.precise), "A Windows touch or inertia phase was lost or became a line wheel on the Mac")
                try require(wheels.map { $0.pixels.x } == [0, 2, 0, 1, 2, 0] && wheels.map { $0.pixels.y } == [0, -3, 0, -4, -1, 0]
                            && wheels.allSatisfy { $0.location == target }, "Precise scroll lost the Windows subpixel totals or the target")
                let gestures = state.posted.compactMap(\.trackpad).filter { $0.type != .scrollWheel }
                try require(gestures.map(\.type) == [.magnify, .magnify, .rotate, .smartMagnify, .magnify, .rotate],
                            "Windows gestures arrived as different native Mac events")
                try require(gestures[0].phase == .began && gestures[1].phase == .changed && abs(gestures[1].value - 0.375) < 0.001
                            && gestures[2].phase == .began && abs(gestures[2].value + 18.5) < 0.001 && gestures.suffix(2).allSatisfy { $0.phase == .ended },
                            "A native gesture lost its scale, rotation, or release phase")
                try require(state.inputs.last?.kind == .smartMagnify && state.inputs.last?.relativeMouse == true
                            && state.posted.filter { $0.trackpad != nil }.allSatisfy { $0.location == target },
                            "Locked smart zoom did not stay on the current remote target")
            }
            try withMacHost(trackpadGestures: false) { host, probe in
                try require(try probe.next("connected")["trackpadGestures"] as? Bool == false, "Windows enabled gestures for an old Mac")
                try smart(probe)
                try scroll(probe, dx: 3, dy: -7)
                try probe.send(["command": "wheel", "vertical": 1, "horizontal": 0, "x": 0.25, "y": 0.5])
                try probe.send(["command": "requestClipboard"])
                _ = try probe.next("clipboardText")
                let state = host.state.get(), wheels = state.posted.filter { $0.type == .scrollWheel }
                try require(state.inputs.map(\.kind) == [.scroll, .scroll] && wheels.compactMap { $0.trackpad?.precise } == [true, false]
                            && wheels[0].pixels == (3, -7) && wheels[1].lines.y == 3, "Gesture negotiation disabled pixel scrolling or changed the older Mac's line wheel")
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

        run("A Windows viewer recovers its chosen settings and video after a Mac host restarts, then respects the host's ending") {
            try withMacHost(["--reconnect"]) { first, probe in
                let original = try probe.next("mediaCommitted")
                try probe.send(["command": "quality", "settings": "2560,30,8"])
                _ = try probe.next("stream") { settings($0) == [2560, 30, 8, 640, 360] }
                let changed = try probe.next("mediaCommitted")
                try until("the first host receives committed for the changed settings") {
                    first.state.get().commits.last?.transportEpoch == changed["transportEpoch"] as? UInt32
                }
                first.stop()
                let retry = try probe.next("retryWaiting")
                try require(retry["attempt"] as? Int == 1, "An interrupted first session did not start its first retry")
                let second = try MacHost(key: key, packets: packets, size: size, advertiseMedia: true, cursorImage: nil,
                                         on: NWEndpoint.Port(rawValue: first.port)!)
                defer { second.stop() }
                try require(second.port == first.port, "The restarted fixture listened on a different port")
                let fresh = try probe.next("mediaCommitted")
                try require(fresh["sessionID"] as? String != original["sessionID"] as? String, "The viewer reported the old session after the restart")
                try until("the restarted host sees new decoded frames") { second.state.get().decodedFeedback.contains { $0.frameID > 2 } }
                let restored = second.state.get()
                try require(restored.requests.first?.settings == StreamSettings(longestEdge: 2560, framesPerSecond: 30, megabits: 8)
                            && restored.subscribedTermination && restored.failures.isEmpty, "The reconnected session lost its quality or termination subscription")
                let retries = probe.all("retryWaiting").count
                second.end()
                let ended = try probe.next("ended")
                try require(ended["hostEnded"] as? Bool == true && ended["retryable"] as? Bool == false
                            && ended["reason"] as? String == SessionTermination.hostEndedReason && (try probe.exitStatus()) == 0
                            && probe.all("retryWaiting").count == retries, "A deliberate ending restarted the viewer")
            }
        }

        run("A Windows viewer sends its device identity only when a validated Mac hello requests it") {
            try withMacHost(deviceID: macIdentity.id, windowsIdentityOptions) { host, probe in
                let connected = try probe.next("connected")
                _ = try probe.next("frame")
                let expected = DeviceIdentity(id: windowsID, name: "合成 Windows 电脑")
                try require(connected["deviceID"] as? String == macIdentity.id.uuidString.lowercased() && connected["name"] as? String == "检查用 Mac"
                            && host.state.get().identities == [expected], "The authenticated peers did not exchange their own IDs and names")
            }
            try withMacHost(deviceID: nil, windowsIdentityOptions) { host, probe in
                let connected = try probe.next("connected")
                try until("the Mac decodes the viewer identity and starts capture") { !host.state.get().requests.isEmpty }
                try require(connected["deviceID"] is NSNull && host.state.get().identities.map(\.id) == [windowsID], "The viewer required the host's own ID to return its identity")
                guard let peer = host.state.get().peer else { throw Failure("The authenticated Mac peer disappeared") }
                peer.send(try Wire.json(.deviceIdentity, macIdentity))
                let ended = try probe.next("ended")
                try require((ended["reason"] as? String)?.contains("不支持") == true && ended["retryable"] as? Bool == false,
                            "Windows accepted a viewer-only message from its host: \(ended)")
            }
            try withMacHost(deviceID: macIdentity.id, identityExchange: nil, windowsIdentityOptions) { host, probe in
                let connected = try probe.next("connected")
                _ = try probe.next("frame")
                try require(connected["deviceID"] as? String == macIdentity.id.uuidString.lowercased() && host.state.get().identities.isEmpty,
                            "An older host's own UUID enabled an unsolicited viewer identity")
            }
        }

        run("A malformed device ID in a Mac hello cannot elicit a Windows viewer identity") {
            try withMacHost(prepareHello: { hello in
                guard var fields = try JSONSerialization.jsonObject(with: hello.payload) as? [String: Any] else {
                    throw Failure("The fixture did not generate a JSON hello")
                }
                fields["deviceID"] = macIdentity.id.uuidString.replacingOccurrences(of: "-", with: "")
                return Message(.hello, try JSONSerialization.data(withJSONObject: fields))
            }, windowsIdentityOptions) { host, probe in
                _ = try probe.next("secured")
                let ended = try probe.next("ended")
                try require(ended["retryable"] as? Bool == false && probe.all("connected").isEmpty && host.state.get().received.isEmpty,
                            "A malformed hello led to a connected session or outbound viewer messages: \(ended)")
            }
        }

        run("A Windows viewer with auto-reconnect and another pairing code stops after the Mac refuses it") {
            try withMacHost(viewerKey: try PairingKey.generate(), windowsIdentityOptions + ["--reconnect"]) { host, probe in
                let failed = try probe.next("failed")
                print("    the probe reported: \(failed["reason"] as? String ?? "")")
                try require((failed["reason"] as? String)?.contains("配对码") == true, "A wrong pairing code was reported as another kind of failure: \(failed)")
                try until("the Mac host gives up on the connection") { host.state.get().closed != nil }
                try require(host.state.get().peer == nil && host.state.get().closed?.contains("TLS") == true
                            && (try probe.exitStatus()) != 0 && probe.all("retryWaiting").isEmpty && host.state.get().accepted.count == 1
                            && probe.all("secured").isEmpty && host.state.get().received.isEmpty,
                            "The Mac host did not refuse the handshake itself: \(host.state.get().closed ?? "")")
            }
        }

        print("Windows interop checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
