import AppKit
import Network
import QuietDeskCore

private final class OrderingBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
private struct OrderingFailure: Error { let message: String }

@MainActor
private final class OrderingFocus: InputSourceFocusAccess {
    let originalProcessID: pid_t? = 20
    let currentProcessID: pid_t = 10
    var frontmostProcessID: pid_t? = 20
    var isRefreshWindowKey = false
    var closed = false
    func activateRefreshWindow() -> Bool { frontmostProcessID = currentProcessID; isRefreshWindowKey = true; return true }
    func restoreOriginalApplication() -> Bool { frontmostProcessID = originalProcessID; isRefreshWindowKey = false; return true }
    func closeRefreshWindow() { closed = true }
}

@MainActor
private final class DelayedInputSource: InputSourceAccess {
    let english = KeyboardSource(id: "abc", name: "ABC", isChinese: false, isASCII: true)
    let chinese = KeyboardSource(id: "pinyin", name: "拼音", isChinese: true, isASCII: true)
    var current: KeyboardSource?
    var requested: KeyboardSource?
    var turns = 0
    var contextRefresh: InputSourceContextRefresh?
    func prepareContextRefresh() -> InputSourceContextRefresh? { contextRefresh }
    init() { current = english }
    func enabledSources() throws -> [KeyboardSource] { [english, chinese] }
    func currentSource() -> KeyboardSource? { current }
    func select(_ source: KeyboardSource) throws { requested = source; turns = 0 }
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<1500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw OrderingFailure(message: message)
}

private func samplePacket(_ sequence: UInt32, idr: Bool) -> VideoPacket {
    VideoPacket(sequence: sequence, sps: idr ? Data([0x67, 0x42, 0, 0x1F]) : Data(),
        pps: idr ? Data([0x68, 0xCE, 6]) : Data(), avcc: Data([0, 0, 0, 2, idr ? 0x65 : 0x41, 0x88]))
}

@main
private struct InputSourceOrderingChecks {
    @MainActor
    static func main() async {
        do {
            for udp in [true, false] { try await exercise(udp: udp) }
            print("Input source ordering checks: 2 passed, 0 failed")
        } catch {
            print("FAIL input source ordering: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func exercise(udp: Bool) async throws {
        let key = try PairingKey.generate()
        let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: MediaChannelRole.allCases)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let listening = OrderingBox(false), host = OrderingBox<MediaSession?>(nil), accepted = OrderingBox<[Peer]>([])
        let path = OrderingBox(""), feedback = OrderingBox<[String]>([]), errors = OrderingBox<[String]>([])
        let probe = DelayedInputSource()
        let focus = OrderingFocus()
        probe.contextRefresh = InputSourceContextRefresh(access: focus) { try await Task.sleep(nanoseconds: 20_000_000) }
        let sources = InputSources(access: probe) {
            probe.turns += 1
            if probe.turns == 4 { probe.current = probe.requested }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        var keySources: [String] = []
        let injector = InputInjector(bounds: .zero, isTrusted: { true }, postEvent: { _ in
            keySources.append(focus.closed && focus.frontmostProcessID == focus.originalProcessID ? probe.current?.id ?? "missing" : "unrefreshed")
        }, inputSources: sources, capsLockState: { false })
        listener.stateUpdateHandler = {
            if case .ready = $0 { listening.update { $0 = true } }
            if case .failed = $0 { errors.update { $0.append("Synthetic listener failed") } }
        }
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection)
            accepted.update { $0.append(peer) }
            peer.onReady = { [weak peer] in
                guard let peer else { return }
                if let role = MediaSecureTransport.negotiatedRole(on: connection), role != .control {
                    host.read()?.acceptAuxiliary(peer, role: role)
                    return
                }
                do {
                    let session = try MediaSession.host(control: peer, key: key, port: listener.port!.rawValue, settings: .init())
                    host.update { $0 = session }
                    session.onPrepareRecovery = { $0(true) }
                    session.onProduceRecoveryFrame = { [weak session] in session?.sendVideo(samplePacket(1, idr: true)) }
                    session.onResumeFrames = { [weak session] in session?.sendVideo(samplePacket(2, idr: false)) }
                    peer.onMessageHandled = { [weak peer] message, resume in
                        if session.receive(message) { resume(); return }
                        Task { @MainActor in
                            defer { resume() }
                            do {
                                guard message.kind == .input else { throw OrderingFailure(message: "Unexpected control message") }
                                let input = try Wire.readJSON(RemoteInput.self, message.payload)
                                if let result = try await injector.receive(input) {
                                    peer?.send(try Wire.json(.inputStatus, result))
                                }
                            } catch { errors.update { $0.append("Synthetic input handling failed") } }
                        }
                    }
                    session.start()
                } catch { errors.update { $0.append("Synthetic host setup failed") } }
            }
            peer.start()
        }
        listener.start(queue: DispatchQueue(label: "checks.caps-ordering-listener"))
        defer { host.read()?.stop(); accepted.read().forEach { $0.close("check finished") }; listener.cancel() }
        try await eventually("Loopback listener never became ready") { listening.read() }
        guard let port = listener.port else { throw OrderingFailure(message: "Missing loopback port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
        let viewer = try MediaSession.viewer(control: client, key: key, host: "127.0.0.1", port: port.rawValue,
                                             settings: .init(), udpEnabled: udp)
        viewer.onVideo = { _, complete in complete(true) }
        viewer.onState = { state in path.update { $0 = state } }
        client.onMessageHandled = { message, resume in
            defer { resume() }
            if viewer.receive(message) { return }
            if let result = try? Wire.readJSON(InputFeedback.self, message.payload), message.kind == .inputStatus {
                feedback.update { $0.append(result.message) }
            }
        }
        client.onReady = { viewer.start() }
        client.start()
        defer { viewer.stop(); client.close("check finished") }
        try await eventually("Expected media path was not committed") { path.read() == (udp ? "UDP 视频" : "TCP 视频") }
        let monitor = CapsLockMonitor(permissionsGranted: { true }, restoreTap: { _ in true })
        monitor.isActive = { true }
        monitor.onAction = { kind in
            if let message = try? Wire.json(.input, RemoteInput(kind: kind)) { client.send(message) }
        }
        monitor.receiveCapsLockValue(device: 1, isDown: true, time: 1)
        monitor.receiveCapsLockValue(device: 1, isDown: false, time: 1.1)
        var keyDown = RemoteInput(kind: .keyDown)
        keyDown.keyCode = 0; keyDown.independentCapsLock = true
        client.send(try Wire.json(.input, keyDown))
        try await eventually("Keyboard input did not follow the source confirmation") { !keySources.isEmpty }
        guard keySources == [probe.chinese.id], probe.turns >= 5, feedback.read().first?.contains("已确认") == true,
              errors.read().isEmpty else { throw OrderingFailure(message: "A fast key overtook delayed Pinyin activation") }
        print("PASS Caps Lock context refresh and restoration precede following TCP input with \(udp ? "UDP" : "TCP") video")
    }
}
