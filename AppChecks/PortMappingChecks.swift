import CryptoKit
import Darwin
import Foundation
import Network
import QuietDeskCore

struct MappingCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw MappingCheckFailure(message) }
}

func eventually(_ message: String, seconds: Double = 10, until condition: () -> Bool) throws {
    let end = SessionClock.now + seconds
    while !condition() {
        guard SessionClock.now < end else { throw MappingCheckFailure(message) }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

final class FixtureValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    @discardableResult
    func change<U>(_ body: (inout T) -> U) -> U { lock.withLock { body(&value) } }
}

func loopbackListener(_ parameters: NWParameters = .tcp) throws -> NWListener {
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    return try NWListener(using: parameters)
}

func listen(_ listener: NWListener, queue: DispatchQueue) throws -> UInt16 {
    let result = FixtureValue<Result<UInt16, Error>?>(nil)
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: result.change { $0 = .success(listener.port!.rawValue) }
        case .failed(let error): result.change { $0 = .failure(error) }
        default: break
        }
    }
    listener.start(queue: queue)
    try eventually("Loopback listener did not start") { result.get() != nil }
    return try result.get()!.get()
}

// A real file service that waits for the HTTP client to half-close its write side before responding.
final class FixtureFileServer {
    let url: URL
    let hash: SHA256.Digest
    let bytes: Int
    let listener: NWListener
    let connections = FixtureValue(0)
    private let queue = DispatchQueue(label: "checks.port-mapping.file")
    private let sockets = FixtureValue<[NWConnection]>([])

    init(directory: URL, mebibytes: Int) throws {
        url = directory.appendingPathComponent("source.bin")
        bytes = mebibytes * 1024 * 1024
        let chunk = Data((0..<65_536).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ ($0 >> 5)) })
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        var digest = SHA256()
        for index in 0..<(bytes / chunk.count) {
            var block = chunk
            block[0] = UInt8(truncatingIfNeeded: index); block[1] = UInt8(truncatingIfNeeded: index >> 8)
            try file.write(contentsOf: block); digest.update(data: block)
        }
        try file.close()
        hash = digest.finalize()
        listener = try loopbackListener()
    }

    func start() throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connections.change { $0 += 1 }
            sockets.change { $0.append(connection) }
            connection.start(queue: queue)
            var request = Data()
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, eof, error in
                    if let data { request.append(data) }
                    guard error == nil, request.count <= 2048 else { connection.cancel(); return }
                    if !eof { read(); return }
                    guard request == Data("GET /fixture.bin HTTP/1.0\r\n\r\n".utf8),
                          let file = try? FileHandle(forReadingFrom: self.url) else { connection.cancel(); return }
                    func sendFile() {
                        do {
                            let content = try file.read(upToCount: 64 * 1024)
                            if let content, !content.isEmpty {
                                connection.send(content: content, completion: .contentProcessed { error in
                                    if error == nil { sendFile() } else { try? file.close(); connection.cancel() }
                                })
                            } else {
                                try file.close()
                                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                                completion: .contentProcessed { error in if error != nil { connection.cancel() } })
                            }
                        } catch { try? file.close(); connection.cancel() }
                    }
                    let header = Data("HTTP/1.0 200 OK\r\nContent-Length: \(self.bytes)\r\n\r\n".utf8)
                    connection.send(content: header, completion: .contentProcessed { error in
                        if error == nil { sendFile() } else { try? file.close(); connection.cancel() }
                    })
                }
            }
            read()
        }
        return try listen(listener, queue: queue)
    }
    func stop() {
        listener.cancel()
        sockets.change { connections in connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

func openClient(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MappingCheckFailure("socket errno \(errno)") }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { let code = errno; close(fd); throw MappingCheckFailure("connect errno \(code)") }
    var timeout = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

final class FileDownload {
    let received = FixtureValue(0)
    let result = FixtureValue<Result<Double, Error>?>(nil)
    func start(port: UInt16, destination: URL, file: FixtureFileServer) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let start = SessionClock.now
            let outcome = Result<Double, Error> {
                let socket = try openClient(port)
                let stream = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
                defer { try? stream.close() }
                try stream.write(contentsOf: Data("GET /fixture.bin HTTP/1.0\r\n\r\n".utf8))
                try expect(shutdown(socket, SHUT_WR) == 0, "Local request half-close failed")
                try Data().write(to: destination)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var header = Data(), sawHeader = false
                let separator = Data("\r\n\r\n".utf8)
                while let data = try stream.read(upToCount: 32 * 1024), !data.isEmpty {
                    var body = data
                    if !sawHeader {
                        header.append(data)
                        guard let split = header.range(of: separator) else {
                            try expect(header.count <= 1024, "Invalid HTTP fixture header"); continue
                        }
                        try expect(String(decoding: header[..<split.lowerBound], as: UTF8.self)
                            == "HTTP/1.0 200 OK\r\nContent-Length: \(file.bytes)", "HTTP fixture status or length changed")
                        body = Data(header[split.upperBound...]); header.removeAll(); sawHeader = true
                    }
                    try output.write(contentsOf: body)
                    received.change { $0 += body.count }
                }
                try expect(sawHeader && received.get() == file.bytes, "\(destination.lastPathComponent) HTTP body truncated: \(received.get())/\(file.bytes)")
                try output.synchronize()
                let elapsed = SessionClock.now - start
                let bytes = try Data(contentsOf: destination, options: .mappedIfSafe)
                try expect(SHA256.hash(data: bytes) == file.hash, "Destination file SHA-256 differs from source")
                return elapsed
            }
            result.change { $0 = outcome }
        }
    }
    func wait(seconds: Double = 240) throws -> Double {
        try eventually("File download exceeded its deadline", seconds: seconds) { result.get() != nil }
        return try result.get()!.get()
    }
}

final class MappingTestHost {
    let listener: NWListener
    let host: PortMappingHost
    let peers = FixtureValue<[Peer]>([])
    var onDesktop: ((Peer, MediaChannelRole) -> Void)?
    let otherRoles = FixtureValue(0)

    convenience init(key: PairingKey, roles: [MediaChannelRole] = MediaChannelRole.allCases,
                     authorize: @escaping (PortMappingTarget, @escaping (Bool) -> Void) -> Void) throws {
        try self.init(key: key, roles: roles) { target, _, reply in authorize(target, reply) }
    }

    init(key: PairingKey, roles: [MediaChannelRole] = MediaChannelRole.allCases,
         authorize: @escaping (PortMappingTarget, UUID?, @escaping (Bool) -> Void) -> Void) throws {
        host = PortMappingHost(authorize: authorize)
        listener = try loopbackListener(MediaSecureTransport.tlsParameters(key: key, roles: roles))
    }
    func start(idleTimeout: TimeInterval = 30, heartbeatInterval: TimeInterval = 5) throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = Peer(connection: connection, idleTimeout: idleTimeout, heartbeatInterval: heartbeatInterval)
            peers.change { $0.append(peer) }
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer else { return }
                let role = MediaSecureTransport.negotiatedRole(on: connection) ?? .control
                if role == .portMapping { host.accept(peer) }
                else { otherRoles.change { $0 += 1 }; onDesktop?(peer, role) }
            }
            peer.start()
        }
        return try listen(listener, queue: DispatchQueue(label: "checks.port-mapping.accept"))
    }
    func stop() {
        host.stop(); listener.cancel(); peers.change { list in list.forEach { $0.close("test ended") }; list.removeAll() }
    }
}

final class MappingTestClient {
    let viewer: PortMappingViewer
    let events = FixtureValue<[PortMappingState]>([])
    init(port: UInt16, key: PairingKey, target: PortMappingTarget, traffic: PortMappingTraffic,
         localPort: UInt16 = 0, deviceID: UUID? = nil) throws {
        viewer = try PortMappingViewer(host: "127.0.0.1", port: port, key: key, target: target,
                                       localPort: localPort, traffic: traffic, deviceID: deviceID)
        viewer.onState = { [events] event in events.change { $0.append(event) } }
    }
    var hasFailed: Bool { events.get().contains { if case .failed = $0 { return true }; return false } }
    func listening() throws -> UInt16 {
        var port: UInt16?
        try eventually("Mapping did not reach listening; states: \(events.get())", seconds: 12) {
            for state in self.events.get() {
                if case .listening(let bound, _) = state { port = bound; return true }
                if case .failed = state { return true }
            }
            return false
        }
        guard let port else { throw MappingCheckFailure("Mapping failed: \(events.get())") }
        return port
    }
}

func checkMapping(_ directory: URL) throws {
    let key = try PairingKey.generate()
    let file = try FixtureFileServer(directory: directory, mebibytes: 4)
    let filePort = try file.start()
    defer { file.stop() }
    let target = try PortMappingTarget(host: "127.0.0.1", port: filePort)
    let allow = FixtureValue(false), requests = FixtureValue(0)
    let host = try MappingTestHost(key: key) { request, reply in requests.change { $0 += 1 }; reply(request == target && allow.get()) }
    let port = try host.start()
    defer { host.stop() }
    let traffic = PortMappingTraffic()
    let legacy = try MappingTestHost(key: key, roles: [.control, .video, .bulk]) { _, reply in reply(false) }
    let legacyPort = try legacy.start()
    defer { legacy.stop() }
    let oldClient = try MappingTestClient(port: legacyPort, key: key, target: target, traffic: traffic)
    oldClient.viewer.start()
    try eventually("Legacy-host mapping attempt did not terminate", seconds: 24) { oldClient.hasFailed }
    try expect(legacy.otherRoles.get() == 0, "Connecting to a legacy host entered a desktop role")
    oldClient.viewer.stop()
    let wrongKey = try MappingTestClient(port: port, key: PairingKey.generate(), target: target, traffic: traffic)
    wrongKey.viewer.start()
    try eventually("Incorrect-key mapping attempt did not terminate", seconds: 24) { wrongKey.hasFailed }
    wrongKey.viewer.stop()
    try expect(requests.get() == 0, "Incorrect pairing key reached the authorization prompt")
    let denied = try MappingTestClient(port: port, key: key, target: target, traffic: traffic)
    denied.viewer.start()
    try eventually("Unapproved mapping did not report rejection") {
        denied.hasFailed
    }
    try expect(file.connections.get() == 0 && host.otherRoles.get() == 0,
               "An unapproved target received a connection or opened a desktop peer")
    denied.viewer.stop()
    let direct = FileDownload()
    direct.start(port: filePort, destination: directory.appendingPathComponent("direct-reference.bin"), file: file)
    _ = try direct.wait()
    allow.change { $0 = true }
    let client = try MappingTestClient(port: port, key: key, target: target, traffic: traffic)
    client.viewer.start()
    defer { client.viewer.stop() }
    let local = try client.listening()
    let occupied = try MappingTestClient(port: port, key: key, target: target, traffic: traffic, localPort: local)
    occupied.viewer.start()
    try eventually("A second enabled rule did not report an occupied port") {
        occupied.hasFailed
    }
    occupied.viewer.stop()
    try expect(!host.host.hasRecentPayload, "Mapping authorization or listener setup counted as transfer")
    let fileTransfer = FileDownload()
    fileTransfer.start(port: local, destination: directory.appendingPathComponent("quick-download.bin"), file: file)
    try eventually("A mapped file produced no payload evidence") { host.host.hasRecentPayload }
    _ = try fileTransfer.wait()
    try expect(host.otherRoles.get() == 0, "Standalone mapping started desktop or media")
    let active = try openClient(local)
    defer { close(active) }
    try eventually("Second target connection was not established") { file.connections.get() == 3 }
    try eventually("An idle open mapping retained stale payload evidence", seconds: 3) { !host.host.hasRecentPayload }
    file.listener.cancel()
    try eventually("File service did not close its listener") { file.listener.state == .cancelled }
    let failedFlow = try openClient(local)
    defer { close(failedFlow) }
    try eventually("Refused target did not report a per-connection failure", seconds: 15) {
        client.events.get().contains { if case .targetFailed = $0 { return true }; return false }
    }
    host.host.revoke(target)
    try eventually("Revoking a target left local listener active") {
        if let fd = try? openClient(local) { close(fd); return false }
        return true
    }
    var byte: UInt8 = 0
    let count = recv(active, &byte, 1, 0)
    try expect(count == 0 || (count < 0 && errno == ECONNRESET), "Active mapping outlived host revocation")
    print("PASS legacy-host isolation, pairing, authorization, local port conflict, standalone transfer, half-close, SHA-256, target refusal and active revocation")
}

// The service deliberately leaves its TCP receive window full. This prevents the
// mapped host from completing its write or reading the next TLS heartbeat.
private func checkSlowMappingConsumer() throws {
    let key = try PairingKey.generate()
    let serviceQueue = DispatchQueue(label: "checks.mapping.slow-consumer")
    let service = try loopbackListener()
    let accepted = FixtureValue<[NWConnection]>([])
    service.newConnectionHandler = { connection in
        accepted.change { $0.append(connection) }
        connection.start(queue: serviceQueue)
    }
    let target = try PortMappingTarget(host: "127.0.0.1", port: listen(service, queue: serviceQueue))
    let host = try MappingTestHost(key: key) { request, reply in reply(request == target) }
    let idleTimeout = 0.6
    let hostPort = try host.start(idleTimeout: idleTimeout, heartbeatInterval: 0.1)
    defer { host.stop(); service.cancel(); accepted.get().forEach { $0.cancel() } }

    var blocks = Data()
    for index in 0..<512 { blocks.append(Data(repeating: UInt8(truncatingIfNeeded: index), count: 32 * 1024)) }
    let payload = blocks
    for cancelWhileBlocked in [false, true] {
        let previous = accepted.get().count
        let client = try MappingTestClient(port: hostPort, key: key, target: target, traffic: PortMappingTraffic())
        client.viewer.start()
        defer { client.viewer.stop() }
        let writer = FileHandle(fileDescriptor: try openClient(client.listening()), closeOnDealloc: true)
        defer { shutdown(writer.fileDescriptor, SHUT_RDWR) }
        let sent = FixtureValue<Result<Void, Error>?>(nil)
        DispatchQueue.global(qos: .utility).async {
            let result = Result<Void, Error> {
                try writer.write(contentsOf: payload)
                try expect(shutdown(writer.fileDescriptor, SHUT_WR) == 0, "Slow writer could not half-close")
            }
            sent.change { $0 = result }
        }
        try eventually("Slow TCP service did not accept") { accepted.get().count > previous }
        let socket = accepted.get()[previous]
        var lastBytes: UInt64 = 0, lastChange = SessionClock.now
        try eventually("Mapped receiver never reached TCP backpressure") {
            guard let dataPeer = host.peers.get().last else { return false }
            let bytes = dataPeer.trafficMeter.snapshot().totals.receivedBytes
            if bytes != lastBytes { lastBytes = bytes; lastChange = SessionClock.now }
            return bytes > 64 * 1024 && bytes < payload.count && SessionClock.now - lastChange > 0.2
        }
        Thread.sleep(forTimeInterval: idleTimeout * 3)
        if cancelWhileBlocked {
            host.host.revoke(target)
            try eventually("Revoking a backpressured mapping left its lease open") { client.hasFailed }
            try eventually("Revocation did not wake the TCP writer") { sent.get() != nil }
            var byte: UInt8 = 0
            let count = recv(writer.fileDescriptor, &byte, 1, 0)
            try expect(count == 0 || (count < 0 && errno == ECONNRESET), "Revocation left the blocked TCP socket open")
        } else {
            let received = FixtureValue<Result<Data, Error>?>(nil)
            serviceQueue.async {
                var body = Data()
                func read() {
                    socket.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { bytes, _, eof, error in
                        if let bytes { body.append(bytes) }
                        if let error { received.change { $0 = .failure(error) } }
                        else if eof { received.change { $0 = .success(body) } }
                        else { read() }
                    }
                }
                read()
            }
            try eventually("Resumed slow service did not receive EOF") { received.get() != nil }
            try expect(try received.get()!.get() == payload, "Paused mapping lost bytes after its peer idle deadline")
            try eventually("Mapped writer did not finish") { sent.get() != nil }
            try sent.get()!.get()
        }
    }
    print("PASS mapped TCP backpressure survives three idle intervals, preserves 16 MiB and allows revocation")
}

private func checkTrustedDeviceMapping(_ directory: URL) throws {
    let key = try PairingKey.generate()
    let file = try FixtureFileServer(directory: directory, mebibytes: 1)
    let filePort = try file.start()
    defer { file.stop() }
    let target = try PortMappingTarget(host: "127.0.0.1", port: filePort)
    let trustedFirst = UUID(), trustedSecond = UUID(), untrusted = UUID()
    let trusted = FixtureValue<Set<UUID>>([trustedFirst, trustedSecond])
    let host = try MappingTestHost(key: key) { _, deviceID, reply in
        reply(deviceID.map { trusted.get().contains($0) } ?? false)
    }
    let hostPort = try host.start()
    defer { host.stop() }

    let traffic = PortMappingTraffic()
    for candidateID in [untrusted as UUID?, nil] {
        let rejected = try MappingTestClient(port: hostPort, key: key, target: target, traffic: traffic, deviceID: candidateID)
        rejected.viewer.start()
        try eventually("Untrusted or legacy device without approval was not rejected") { rejected.hasFailed }
        rejected.viewer.stop()
    }
    try expect(file.connections.get() == 0, "Rejected device opened a target connection")

    let firstClient = try MappingTestClient(port: hostPort, key: key, target: target, traffic: traffic, deviceID: trustedFirst)
    let secondClient = try MappingTestClient(port: hostPort, key: key, target: target, traffic: traffic, deviceID: trustedSecond)
    firstClient.viewer.start()
    secondClient.viewer.start()
    defer { firstClient.viewer.stop(); secondClient.viewer.stop() }
    let firstLocal = try firstClient.listening()
    let secondLocal = try secondClient.listening()

    let firstDownload = FileDownload()
    firstDownload.start(port: firstLocal, destination: directory.appendingPathComponent("trusted-first.bin"), file: file)
    _ = try firstDownload.wait()

    let activeFirst = try openClient(firstLocal)
    defer { close(activeFirst) }
    try eventually("First trusted device did not establish a second target socket") { file.connections.get() == 2 }

    trusted.change { $0.remove(trustedFirst) }
    host.host.revokeDevice(trustedFirst)
    try eventually("Revoking a trusted device left its local listener active") { firstClient.hasFailed }
    var byte: UInt8 = 0
    let count = recv(activeFirst, &byte, 1, 0)
    try expect(count == 0 || (count < 0 && errno == ECONNRESET), "Revoking a trusted device left its active socket open")

    // Another trusted device on the same target must remain unaffected.
    try expect(!secondClient.hasFailed, "Revoking one trusted device affected a different trusted device")
    let secondDownload = FileDownload()
    secondDownload.start(port: secondLocal, destination: directory.appendingPathComponent("trusted-second.bin"), file: file)
    _ = try secondDownload.wait()
    print("PASS trusted remote device auto-approval, untrusted/legacy rejection, and per-device revocation isolation")
}

@main
struct PortMappingChecks {
    static func main() {
        setlinebuf(stdout)
        do { try run() }
        catch { fputs("Port mapping checks failed: \(error)\n", stderr); exit(1) }
    }
    private static func run() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.contains("--benchmark") { try runPortMappingPerformanceCheck(directory) }
        else {
            try checkSlowMappingConsumer()
            try checkMapping(directory)
            try checkTrustedDeviceMapping(directory)
        }
    }
}
