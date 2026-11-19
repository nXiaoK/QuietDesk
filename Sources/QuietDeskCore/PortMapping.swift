import Foundation
import Network

public struct PortMappingTarget: Codable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        guard port > 0 else { throw DeskError.invalid("目标端口必须在 1 至 65535 之间") }
        if let ip = IPv4Address(host), ip.interface == nil {
            let octets = Array(ip.rawValue)
            guard ip.isLoopback || octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else { throw Self.invalidAddress }
            self.host = ip.debugDescription
        } else if let ip = IPv6Address(host), ip.interface == nil,
                  ip.isLoopback || (ip.rawValue.first.map { $0 & 0xfe == 0xfc } ?? false) {
            self.host = ip.debugDescription
        } else { throw Self.invalidAddress }
        self.port = port
    }

    private static let invalidAddress = DeskError.invalid("目标须为回环或私有局域网 IP 地址")
    private enum CodingKeys: String, CodingKey { case host, port }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: values.decode(String.self, forKey: .host), port: values.decode(UInt16.self, forKey: .port))
    }
}

public enum PortMappingState: Equatable, Sendable {
    case authorizing
    case listening(port: UInt16, connections: Int)
    case targetFailed(port: UInt16, reason: String)
    case failed(String)
    case stopped
}

// Each direction shares one budget across mappings. Only bytes released to a live flow
// consume credit. Disconnecting a flow removes its queued block immediately.
public final class PortMappingTraffic: @unchecked Sendable {
    static let chunkBytes = 16 * 1024
    private struct Request {
        let owner: UUID
        let bytes: Int
        let release: () -> Void
    }
    private final class Direction {
        var waiting: [Request] = []
        var next: TimeInterval = 0
        var timer: DispatchWorkItem?
    }
    private let queue = DispatchQueue(label: "quietdesk.mapping.traffic", qos: .utility)
    private let sending = Direction()
    private let receiving = Direction()
    private var desktopActive = false
    private var lastPressure: TimeInterval?
    private let payloadLock = NSLock()
    private var lastPayloadAt: TimeInterval?

    public init() {}

    var hasRecentPayload: Bool {
        payloadLock.withLock { lastPayloadAt.map { SessionClock.now - $0 <= 1 } ?? false }
    }

    fileprivate func recordPayload() {
        payloadLock.withLock { lastPayloadAt = SessionClock.now }
    }

    fileprivate var readSize: Int {
        // At 14 Mbit/s a full 16 KiB TLS payload occupies the link for about 9 ms.
        // Short writes leave room between records for interactive input and video.
        queue.sync { desktopActive ? 4 * 1024 : Self.chunkBytes }
    }

    public func setDesktopActive(_ active: Bool) {
        queue.async { [self] in
            guard active != desktopActive else { return }
            desktopActive = active
            lastPressure = nil
            for direction in [sending, receiving] {
                direction.next = 0
                direction.timer?.cancel()
                direction.timer = nil
                drain(direction)
            }
        }
    }

    public func noteVideoPressure() {
        queue.async { [self] in
            if desktopActive { lastPressure = SessionClock.now }
        }
    }

    public func noteVideoDeliveryDelay(_ milliseconds: Double) {
        // Give bandwidth back before a growing video queue reaches the encoder's downgrade threshold.
        if milliseconds >= 40 { noteVideoPressure() }
    }

    private func bytesPerSecond(at now: TimeInterval) -> Double {
        guard let lastPressure else { return 262_144 }
        // Step back up over multiple video sampling windows so one good frame cannot refill the link.
        switch now - lastPressure {
        case ..<5: return 32_768
        case ..<12: return 65_536
        case ..<22: return 131_072
        default: return 262_144
        }
    }

    fileprivate func submit(owner: UUID, bytes: Int, incoming: Bool, release: @escaping () -> Void) {
        queue.async { [self] in
            let direction = incoming ? receiving : sending
            direction.waiting.append(Request(owner: owner, bytes: bytes, release: release))
            drain(direction)
        }
    }

    fileprivate func cancel(owner: UUID) {
        queue.async { [self] in
            sending.waiting.removeAll { $0.owner == owner }
            receiving.waiting.removeAll { $0.owner == owner }
        }
    }

    private func drain(_ direction: Direction) {
        guard direction.timer == nil else { return }
        while !direction.waiting.isEmpty {
            let now = SessionClock.now
            if desktopActive, direction.next > now {
                let timer = DispatchWorkItem { [weak self, weak direction] in
                    guard let self, let direction else { return }
                    direction.timer = nil
                    self.drain(direction)
                }
                direction.timer = timer
                queue.asyncAfter(deadline: .now() + (direction.next - now), execute: timer)
                return
            }
            let block = direction.waiting.removeFirst()
            if desktopActive {
                direction.next = now + Double(block.bytes) / bytesPerSecond(at: now)
            }
            block.release()
        }
    }
}

public enum PortMappingControl: Codable, Equatable, Sendable {
    case authorize(PortMappingTarget, deviceID: UUID? = nil)
    case granted(UUID)
    case attach(UUID)
    case connected
    case receivedEOF
    case rejected(Rejection)

    public enum Rejection: String, Codable, Equatable, Sendable {
        case denied, busy, target, timeout
        public var explanation: String {
            switch self {
            case .denied: return "被控端未允许此目标"
            case .busy: return "映射连接数量已达上限"
            case .target: return "被控端连接目标服务失败，请检查地址、端口及服务状态"
            case .timeout: return "等待被控端确认或连接已超时"
            }
        }
    }

    public static func read(_ message: Message) throws -> Self {
        guard message.kind == .mappingControl else { throw DeskError.invalid("端口映射消息顺序无效") }
        return try Wire.readJSON(Self.self, message.payload)
    }

    func send(to peer: Peer, completion: ((Bool) -> Void)? = nil) {
        do { peer.send(try Wire.json(.mappingControl, self), completion: completion) }
        catch { peer.close(error.localizedDescription); completion?(false) }
    }
}

// Both directions run on the owning transport's serial queue. A receive is armed only after
// the last socket write completed. EOF crosses the encrypted stream independently in each direction.
final class PortMappingPipe {
    let socket: NWConnection
    private let peer: Peer
    private let queue: DispatchQueue
    private let traffic: PortMappingTraffic
    private let id = UUID()
    private var closed = false
    private var sentEOF = false
    private var receivedEOF = false
    private var acknowledgedLocalEOF = false
    private var acknowledgedRemoteEOF = false
    private(set) var readingStarted = false

    init(socket: NWConnection, peer: Peer, queue: DispatchQueue, traffic: PortMappingTraffic) {
        self.socket = socket; self.peer = peer; self.queue = queue; self.traffic = traffic
    }

    func startReading() {
        guard !readingStarted else { return }
        readingStarted = true
        read()
    }

    func receive(_ message: Message, processed: @escaping () -> Void) throws {
        switch message.kind {
        case .mappingData:
            guard !receivedEOF, !message.payload.isEmpty else { throw DeskError.invalid("映射数据顺序无效") }
            let bytes = message.payload
            pace(bytes.count, incoming: true) { [weak self] in
                self?.socket.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if let error { self.fail(error.localizedDescription); return }
                    self.traffic.recordPayload()
                    processed()
                })
            }
        case .mappingEOF:
            guard !receivedEOF, message.payload.isEmpty else { throw DeskError.invalid("无效的映射半关闭消息") }
            receivedEOF = true
            socket.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if let error { self.fail(error.localizedDescription); return }
                PortMappingControl.receivedEOF.send(to: self.peer) { [weak self] success in
                    self?.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.acknowledgedRemoteEOF = success
                        self.finishIfComplete()
                    }
                }
                processed()
            })
        default:
            guard case .receivedEOF = try PortMappingControl.read(message), sentEOF, !acknowledgedLocalEOF else {
                throw DeskError.invalid("映射数据连接确认无效")
            }
            acknowledgedLocalEOF = true
            finishIfComplete()
            processed()
        }
    }

    private func pace(_ bytes: Int, incoming: Bool, _ perform: @escaping () -> Void) {
        traffic.submit(owner: id, bytes: bytes, incoming: incoming) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                perform()
            }
        }
    }

    private func read() {
        guard !closed else { return }
        socket.receive(minimumIncompleteLength: 1, maximumLength: traffic.readSize) { [weak self] bytes, _, ended, error in
            guard let self, !self.closed else { return }
            let next = { [weak self] in
                guard let self, !self.closed else { return }
                if let error { self.fail(error.localizedDescription) }
                else if ended {
                    self.sentEOF = true
                    self.peer.send(Message(.mappingEOF))
                } else { self.read() }
            }
            if let bytes, !bytes.isEmpty {
                self.pace(bytes.count, incoming: false) { [weak self] in
                    self?.peer.send(Message(.mappingData, bytes)) { [weak self] success in
                        guard success, let self else { return }
                        self.traffic.recordPayload()
                        self.queue.async { next() }
                    }
                }
            } else { next() }
        }
    }

    private func finishIfComplete() {
        if acknowledgedLocalEOF && acknowledgedRemoteEOF { peer.close("映射连接已结束") }
    }

    private func fail(_ reason: String) {
        stop()
        peer.close(reason)
    }

    func stop() {
        closed = true
        traffic.cancel(owner: id)
        socket.stateUpdateHandler = nil
        socket.cancel()
    }
}
