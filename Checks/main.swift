import Foundation
import Network
import VideoToolbox
import QuietDeskCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message) }
}

func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message)
}

func wait(_ semaphore: DispatchSemaphore, seconds: Double = 10, _ message: String) throws {
    try check(semaphore.wait(timeout: .now() + seconds) == .success, message)
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

var failures = 0
var successes = 0
func run(_ name: String, _ body: () throws -> Void) {
    do { try body(); successes += 1; print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}

run("256-bit pairing key generation, round trip and strict validation") {
    let first = try PairingKey.generate()
    let second = try PairingKey.generate()
    try check(first.data.count == 32 && first.data != second.data, "Bad random keys")
    try check(PairingKey(code: first.code.lowercased() + "\n").data == first.data, "Key round trip")
    for value in ["123456", String(repeating: "G", count: 64), String(repeating: "0", count: 63), "😀"] {
        try rejects("Accepted malformed key") { _ = try PairingKey(code: value) }
    }
}

run("Big-endian framing, binary payload and size limits") {
    let message = Message(.clipboard, Data([0, 128, 255]))
    let framed = try message.framed()
    try check(framed == Data([0, 0, 0, 4, MessageKind.clipboard.rawValue, 0, 128, 255]), "Invalid framing")
    let decoded = try Wire.decodeBody(Data(framed.dropFirst(4)))
    try check(decoded.kind == .clipboard && decoded.payload == message.payload, "Binary data changed")
    try rejects("Accepted empty message") { _ = try Wire.decodeBody(Data()) }
    try rejects("Accepted unknown message") { _ = try Wire.decodeBody(Data([255])) }
    try rejects("Accepted oversized message") { _ = try Message(.video, Data(count: Wire.maximumMessageBytes)).framed() }
}

run("Video packet round trip, every truncation and invalid NAL length") {
    let packet = VideoPacket(sequence: UInt32.max, sps: Data([0x67, 0x64]), pps: Data([0x68]),
                             avcc: Data([0, 0, 0, 2, 0x65, 0x88]))
    let bytes = try packet.encode()
    let decoded = try VideoPacket.decode(bytes)
    try check(decoded.sequence == UInt32.max && decoded.sps == packet.sps && decoded.pps == packet.pps
              && decoded.avcc == packet.avcc, "Video packet changed")
    for length in 0..<bytes.count {
        try rejects("Accepted truncated video at \(length)") { _ = try VideoPacket.decode(Data(bytes.prefix(length))) }
    }
    var invalid = Data()
    invalid.put(UInt32(1)); invalid.put(UInt16(0)); invalid.put(UInt16(0))
    invalid.append(contentsOf: [255, 255, 255, 255, 0x65])
    try rejects("Accepted invalid NAL") { _ = try VideoPacket.decode(invalid) }
}

run("Input validation and control message limits") {
    var input = RemoteInput(kind: .move)
    input.x = 1; input.y = 0.5
    try input.validate()
    let message = try Wire.json(.input, input)
    try check(Wire.readJSON(RemoteInput.self, message.payload).x == 1, "Input round trip")
    input.x = .nan
    try rejects("Accepted NaN") { try input.validate() }
    input.x = 0.5; input.deltaY = 3001
    try rejects("Accepted huge scroll") { try input.validate() }
    try rejects("Accepted huge control packet") { _ = try Wire.readJSON(RemoteInput.self, Data(count: 4097)) }
}

run("Resolution scaling, portrait display and no upscaling") {
    let settings = StreamSettings()
    let large = settings.dimensions(width: 5120, height: 2880)
    try check(large.0 == 1920 && large.1 == 1080, "Bad landscape dimensions")
    let small = settings.dimensions(width: 1279, height: 719)
    try check(small.0 == 1278 && small.1 == 718, "Bad odd dimensions")
    let portrait = settings.dimensions(width: 1440, height: 2560)
    try check(portrait.0 == 1080 && portrait.1 == 1920, "Bad portrait dimensions")
}

run("Version and decoded image dimension validation") {
    let hello = Hello(name: "test", width: 1920, height: 1080, settings: .init(), canControl: true)
    try hello.validate()
    var mismatched = hello
    mismatched.version = 999
    try rejects("Accepted wrong version") { try mismatched.validate() }
    try rejects("Accepted huge dimensions") {
        try Hello(name: "test", width: 8192, height: 8192, settings: .init(), canControl: true).validate()
    }
}

run("Caps Lock short press, long press, duplicate reports and cancelled focus") {
    var press = CapsLockPress()
    try check(press.update(isDown: false, time: 1) == nil, "Unmatched release produced action")
    try check(press.update(isDown: true, time: 2) == nil, "Key down produced action")
    try check(press.update(isDown: true, time: 2.1) == nil, "Repeated key down produced action")
    try check(press.update(isDown: false, time: 2.2) == .switchInputSource, "Short press not detected")
    _ = press.update(isDown: true, time: 3)
    try check(press.update(isDown: false, time: 4) == .toggleCapsLock, "Long press not detected")
    _ = press.update(isDown: true, time: 5)
    press.reset()
    try check(press.update(isDown: false, time: 6) == nil, "Focus loss must cancel pending press")
    _ = press.update(isDown: true, time: 7)
    try check(press.update(isDown: false, time: 6) == nil, "Backwards timestamp produced action")
    try check(press.update(isDown: true, time: .nan) == nil, "Non-finite timestamp produced action")
}

run("Chinese / ASCII input source selection remembers the user's enabled sources") {
    let abc = KeyboardSource(id: "abc", name: "ABC", isChinese: false, isASCII: true)
    let us = KeyboardSource(id: "us", name: "US", isChinese: false, isASCII: true)
    let pinyin = KeyboardSource(id: "pinyin", name: "拼音", isChinese: true, isASCII: true)
    let wubi = KeyboardSource(id: "wubi", name: "五笔", isChinese: true, isASCII: false)
    var choice = InputSourceChoice()
    let enabled = [abc, us, pinyin, wubi]
    try check(choice.target(current: wubi, enabled: enabled) == abc, "Chinese should switch to ASCII")
    try check(choice.target(current: us, enabled: enabled) == wubi, "Last Chinese source not restored")
    try check(choice.target(current: pinyin, enabled: enabled) == us, "Chinese ASCII-capable source classified as Latin")
    try check(choice.target(current: abc, enabled: [abc, pinyin]) == pinyin, "Disabled remembered source selected")
    try check(choice.target(current: abc, enabled: [abc]) == nil, "Missing Chinese input source not reported")
    try check(choice.target(current: pinyin, enabled: [pinyin]) == nil, "Missing Latin input source not reported")
}

run("Optional keyboard capability preserves legacy session and input decoding") {
    let hello = Hello(name: "legacy", width: 1920, height: 1080, settings: .init(), canControl: true)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as! [String: Any]
    legacy.removeValue(forKey: "inputActions")
    legacy.removeValue(forKey: "clipboardSync")
    legacy.removeValue(forKey: "liveSettings")
    legacy.removeValue(forKey: "controlStatusUpdates")
    let oldHello = try Wire.readJSON(Hello.self, JSONSerialization.data(withJSONObject: legacy))
    try check(oldHello.inputActions == nil && oldHello.clipboardSync == nil && oldHello.liveSettings == nil && oldHello.controlStatusUpdates == nil, "Old host must not advertise new actions")
    var input = RemoteInput(kind: .flags)
    input.keyCode = 57
    let ordinary = try Wire.readJSON(RemoteInput.self, JSONEncoder().encode(input))
    try check(ordinary.independentCapsLock == nil && ordinary.kind == .flags, "Legacy Caps Lock behavior changed")
    input.kind = .toggleCapsLock
    input.independentCapsLock = true
    let action = try Wire.readJSON(RemoteInput.self, JSONEncoder().encode(input))
    try action.validate()
    try check(action.kind == .toggleCapsLock && action.independentCapsLock == true, "New action round trip failed")
}

run("H.264 keyframe and predicted frame encode / packet / decode") {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else { throw CheckFailure("CVPixelBufferCreate: \(status)") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
        memset(address, plane == 0 ? 64 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let encoder = try VideoEncoder(width: 320, height: 180, settings: .init())
    defer { encoder.stop() }
    print("  System selected hardware encoder: \(encoder.usesHardware)")
    let encoded = DispatchSemaphore(value: 0)
    let decoded = DispatchSemaphore(value: 0)
    let packet = Box<Result<VideoPacket, Error>?>(nil)
    let decodeError = Box<String?>(nil)
    encoder.onOutput = { result in packet.set(result); encoded.signal() }
    let samples = VideoSamples()
    var decoder: VTDecompressionSession?
    defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
    for sequence in UInt32(1)...2 {
        try encoder.encode(pixelBuffer, time: CMTime(value: Int64(sequence), timescale: 15),
                           sequence: sequence, forceKeyFrame: sequence == 1)
        try wait(encoded, "No encoded frame")
        guard let result = packet.read() else { throw CheckFailure("Missing encoded output") }
        let value = try result.get()
        try check(value.sequence == sequence, "Wrong frame sequence")
        if sequence == 1 { try check(!value.sps.isEmpty && !value.pps.isEmpty, "Missing keyframe parameters") }
        else { try check(value.sps.isEmpty && value.pps.isEmpty, "Expected predicted frame") }
        let wireValue = try VideoPacket.decode(value.encode())
        let sample = try samples.sample(for: wireValue)
        if decoder == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { throw CheckFailure("No video format") }
            let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
                decompressionSessionOut: &decoder)
            try check(created == noErr, "VTDecompressionSessionCreate: \(created)")
        }
        guard let decoder else { throw CheckFailure("No decoder") }
        let submitted = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
            flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status != noErr || image == nil { decodeError.set("Decode status: \(status)") }
                else if let image, CVPixelBufferGetWidth(image) != 320 || CVPixelBufferGetHeight(image) != 180 {
                    decodeError.set("Wrong decoded dimensions")
                }
                decoded.signal()
            }
        try check(submitted == noErr, "Decode submit: \(submitted)")
        try wait(decoded, "No decoded frame")
        try check(decodeError.read() == nil, decodeError.read() ?? "Decode error")
    }
}

func makeListener(_ key: PairingKey, queue: DispatchQueue) throws -> NWListener {
    let parameters = SecureTransport.parameters(key: key)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    let failure = Box<String?>(nil)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.signal()
        case .failed(let error): failure.set(error.localizedDescription); ready.signal()
        default: break
        }
    }
    // Accept handlers are installed by each test before the client connects.
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: queue)
    try wait(ready, seconds: 5, "No listener state")
    if let failure = failure.read() { listener.cancel(); throw CheckFailure(failure) }
    return listener
}

if !CommandLine.arguments.contains("--skip-network") {
    run("TLS PSK authenticated 256 KB binary round trip over loopback") {
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.tls"))
        let server = Box<Peer?>(nil)
        let received = DispatchSemaphore(value: 0)
        let failure = Box<String?>(nil)
        let payload = Data((0..<262_144).map { UInt8($0 % 251) })
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            server.set(peer)
            peer.onMessage = { message in
                if message.kind != .clipboard || message.payload != payload { failure.set("Server payload changed") }
                peer.send(message)
            }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.onReady = { client.send(Message(.clipboard, payload)) }
        client.onMessage = { message in
            if message.kind != .clipboard || message.payload != payload { failure.set("Client payload changed") }
            received.signal()
        }
        client.start()
        try wait(received, "Encrypted round trip timed out")
        try check(failure.read() == nil, failure.read() ?? "Round trip failure")
    }

    run("Wrong pairing key is rejected before authentication") {
        let key = try PairingKey.generate()
        let wrong = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.wrong-key"))
        let server = Box<Peer?>(nil)
        let rejected = DispatchSemaphore(value: 0)
        let authenticated = Box(false)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            server.set(peer)
            peer.onReady = { authenticated.set(true) }
            peer.onClose = { _ in rejected.signal() }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: wrong)))
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.onReady = { authenticated.set(true) }
        client.start()
        try wait(rejected, seconds: 12, "Wrong key was not rejected")
        try check(!authenticated.read(), "Incorrect key authenticated")
    }

    run("TCP fragments reassemble and oversized frame header closes connection") {
        let key = try PairingKey.generate()
        let queue = DispatchQueue(label: "checks.fragments")
        let listener = try makeListener(key, queue: queue)
        let server = Box<Peer?>(nil)
        let received = DispatchSemaphore(value: 0)
        let rejected = DispatchSemaphore(value: 0)
        let failure = Box<String?>(nil)
        let message = try Message(.input, Data([1, 2, 3, 4])).framed()
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            server.set(peer)
            peer.onMessage = { message in
                if message.kind != .input || message.payload != Data([1, 2, 3, 4]) { failure.set("Fragmented data changed") }
                received.signal()
            }
            peer.onClose = { _ in rejected.signal() }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No port") }
        let client = NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key))
        defer { client.cancel(); server.read()?.close(); listener.cancel() }
        client.stateUpdateHandler = { state in
            if case .ready = state {
                for (offset, byte) in message.enumerated() {
                    queue.asyncAfter(deadline: .now() + Double(offset) * 0.01) {
                        client.send(content: Data([byte]), completion: .contentProcessed { _ in })
                    }
                }
                queue.asyncAfter(deadline: .now() + 0.2) {
                    client.send(content: Data([255, 255, 255, 255]), completion: .contentProcessed { _ in })
                }
            }
        }
        client.start(queue: queue)
        try wait(received, "Fragmented message not received")
        try wait(rejected, "Oversized header not rejected")
        try check(failure.read() == nil, failure.read() ?? "Fragment test failure")
    }
}

runTransportChecks()
runInteractiveTransportChecks()
runVideoPacingChecks()
runKeyFrameChecks()
runPerformanceDiagnosticsChecks()
runTransportDiagnosticsChecks()
runProtocolFuzzChecks()
runPeerDeliveryChecks()
runHandshakeAdmissionChecks()
runReliabilityChecks()
runLiveSettingsChecks()
runFileApprovalChecks()
runClipboardWindowChecks()
runClipboardStorageChecks()
runConnectionMetricsChecks()
runPermissionUpdateChecks()
runScrollChecks()
runDisplaySelectionChecks()
runTrafficChecks()
runSessionEffectsChecks()
runSystemShortcutChecks()
runSessionIdleChecks()
runSessionClockChecks()
runFrameMailboxChecks()
runMediaProtocolChecks(check: run)
print("\(successes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
