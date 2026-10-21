import Foundation
import CryptoKit
import Network

/// Whether relayed UDP video may move onto a hole-punched direct path between the two Macs.
public enum RelayPeerAssistMode: String, Codable, CaseIterable, Sendable {
    case automatic, on, off
    public var title: String {
        switch self { case .automatic: return "自动"; case .on: return "开"; case .off: return "关" }
    }
}

public enum RelayPeerPathState: Equatable, Sendable {
    case relay
    case checking
    case direct(RelayCandidate.Kind)
    /// Automatic mode measured the relay as faster or less lossy than the punched path.
    case relayFaster
    /// No candidate answered or the direct path stopped; video stays on the relay until a later retry.
    case unreachable

    public var diagnosticCode: Int {
        switch self {
        case .relay: return 0
        case .checking: return 1
        case .direct: return 2
        case .relayFaster: return 3
        case .unreachable: return 4
        }
    }
}

public struct RelayPeerAddress: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func text(v4 bytes: Data) -> String { bytes.map(String.init).joined(separator: ".") }

    static func text(v6 bytes: Data) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return "" }
        return String(cString: text)
    }

    init?(storage: sockaddr_storage) {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET6:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in6.self) }
            let bytes = withUnsafeBytes(of: address.sin6_addr) { Data($0) }
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            host = mapped ? Self.text(v4: Data(bytes.suffix(4))) : Self.text(v6: bytes)
            port = UInt16(bigEndian: address.sin6_port)
        case AF_INET:
            let address = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }
            host = Self.text(v4: withUnsafeBytes(of: address.sin_addr) { Data($0) })
            port = UInt16(bigEndian: address.sin_port)
        default: return nil
        }
    }

    /// Dual-stack sockets reach IPv4 peers through IPv4-mapped IPv6 addresses.
    func withSocketAddress<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result? {
        var bytes: Data
        if let v4 = IPv4Address(host) { bytes = Data(count: 10) + Data([0xff, 0xff]) + v4.rawValue }
        else if let v6 = IPv6Address(host), v6.interface == nil { bytes = v6.rawValue }
        else { return nil }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    /// Blocking resolution of the configured node; callers run it off their transport queue.
    static func resolve(host: String, port: UInt16) -> RelayPeerAddress? {
        if let canonical = RelayCandidate.canonicalAddress(host, allowLoopback: true) { return RelayPeerAddress(host: canonical, port: port) }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr else { continue }
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(entry.pointee.ai_addrlen))) }
            if let resolved = RelayPeerAddress(storage: storage) { return RelayPeerAddress(host: resolved.host, port: port) }
        }
        return nil
    }
}

/// Counts assisted-lease datagram payload bytes by the outer path they used, in both directions.
public final class RelayPeerTrafficCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var relayed: UInt64 = 0
    private var direct: UInt64 = 0
    public init() {}
    public var snapshot: (relayed: UInt64, direct: UInt64) { lock.withLock { (relayed, direct) } }
    func record(relayed: Int = 0, direct: Int = 0) {
        lock.withLock { self.relayed &+= UInt64(relayed); self.direct &+= UInt64(direct) }
    }
}

/// Connectivity checks, nomination and failover for one relay UDP lease. The viewer (side 0) decides
/// which path carries video; the host (side 1) follows its nomination. Every packet is authenticated
/// with keys derived from the desktop media session, which the relay node never sees. Inputs and
/// outputs are explicit so the state machine runs unchanged under a simulated network.
public final class RelayPeerAgent {
    public struct Timing: Sendable {
        public var tick: TimeInterval = 0.05
        public var attempt: TimeInterval = 5
        public var grace: TimeInterval = 0.3
        public var relayWait: TimeInterval = 1
        public var nominate: TimeInterval = 1
        public var keepalive: TimeInterval = 0.25
        // Shorter than the media layer's one-second UDP pong limit, so a dead direct path returns to
        // the warm relay lease before media gives up on UDP.
        public var timeout: TimeInterval = 0.8
        public var relayProbe: TimeInterval = 1
        public var checkingRelayProbe: TimeInterval = 0.25
        public var reevaluate: TimeInterval = 60
        public var degradedFor: TimeInterval = 5
        public var retry: [TimeInterval] = [30, 60, 120, 300]
        public var stableReset: TimeInterval = 300
        public init() {}
    }

    public enum Action: Equatable {
        case send(Data, RelayPeerAddress)
        case sendViaRelay(Data)
        case state(RelayPeerPathState)
    }

    enum Kind: UInt8 { case data, check, checkAck, nominate, nominateAck, release, attempt }
    private enum Phase {
        case idle(next: TimeInterval?)
        case checking(started: TimeInterval, firstSuccess: TimeInterval?)
        case nominating(RelayPeerAddress, RelayCandidate.Kind, transaction: UInt64, started: TimeInterval, nextSend: TimeInterval)
        case direct(since: TimeInterval)
        case relayPreferred(until: TimeInterval)
    }
    private struct Remote {
        let address: RelayPeerAddress
        let kind: RelayCandidate.Kind
        var due: TimeInterval
        var sent = 0
        var roundTrip: TimeInterval?
    }
    private struct Pending { let target: RelayPeerAddress?; let sent: TimeInterval; let keepalive: Bool }

    static let magic = Data("QDP1".utf8)
    public static let overhead = 64
    public static let maximumPayloadBytes = RelayDatagram.maximumPayloadBytes
    public static func isPeerPacket(_ data: Data) -> Bool { data.starts(with: magic) }

    public static func keys(secret: Data, leaseID: Data) -> (viewer: SymmetricKey, host: SymmetricKey) {
        let material = SymmetricKey(data: secret)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: leaseID,
                                   info: Data("QuietDesk peer path v1 \(label)".utf8), outputByteCount: 32)
        }
        return (derive("viewer"), derive("host"))
    }

    public let side: UInt8
    public private(set) var mode: RelayPeerAssistMode
    public private(set) var state: RelayPeerPathState = .relay
    public private(set) var selected: RelayPeerAddress?
    public private(set) var directRoundTrip: TimeInterval?
    public private(set) var relayRoundTrip: TimeInterval?
    private let timing: Timing
    private let leaseID: Data
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let allowLoopback: Bool
    private var phase = Phase.idle(next: nil)
    private var remotes: [Remote] = []
    private var cursor = 0
    private var pending: [UInt64: Pending] = [:]
    private var transaction: UInt64
    private var failures = 0
    private var hostChecksUntil: TimeInterval = 0
    private var lastDirectReceive: TimeInterval = 0
    private var lastKeepalive: TimeInterval = 0
    private var lastRelayProbe: TimeInterval = -.infinity
    private var candidatesChanged: TimeInterval = -.infinity
    private var degradedSince: TimeInterval?
    private var directSamples: [Bool] = []
    private var relaySamples: [Bool] = []
    private var directSequence: UInt64 = 0
    private var relaySequence: UInt64 = 0
    private var directReplay = RelayReplayWindow()
    private var relayReplay = RelayReplayWindow()

    public init(side: UInt8, leaseID: Data, secret: Data, mode: RelayPeerAssistMode, allowLoopback: Bool = false,
                timing: Timing = Timing()) throws {
        guard side <= 1, leaseID.count == 16, secret.count == 32 else { throw RelayServiceError.invalid }
        let keys = Self.keys(secret: secret, leaseID: leaseID)
        self.side = side; self.leaseID = leaseID; self.mode = mode; self.allowLoopback = allowLoopback; self.timing = timing
        sendKey = side == 0 ? keys.viewer : keys.host
        receiveKey = side == 0 ? keys.host : keys.viewer
        transaction = UInt64.random(in: 1...(UInt64.max / 2))
    }

    // MARK: Inputs

    public func updateCandidates(_ candidates: [RelayCandidate], now: TimeInterval) -> [Action] {
        var merged: [Remote] = []
        for candidate in candidates.prefix(RelayCandidate.maximumPeer) where candidate.kind != .prflx && candidate.port > 0 {
            guard let host = RelayCandidate.canonicalAddress(candidate.address, allowLoopback: allowLoopback && candidate.kind == .srflx) else { continue }
            let address = RelayPeerAddress(host: host, port: candidate.port)
            if !merged.contains(where: { $0.address == address }) { merged.append(Remote(address: address, kind: candidate.kind, due: now)) }
        }
        for learned in remotes where learned.kind == .prflx && !merged.contains(where: { $0.address == learned.address }) && merged.count < 12 {
            merged.append(learned)
        }
        let changed = Set(merged.map(\.address)) != Set(remotes.map(\.address))
        // Only a replacement list means the peer moved; the first list is the ordinary start.
        if changed, !remotes.isEmpty { candidatesChanged = now }
        remotes = merged
        guard changed else { return [] }
        guard mode != .off else { return [] }
        if side == 1 { return beginHostChecks(now) }
        if case .direct = phase { return [] }
        failures = 0
        return startAttempt(now)
    }

    public func setMode(_ newMode: RelayPeerAssistMode, now: TimeInterval) -> [Action] {
        guard newMode != mode else { return [] }
        let previous = mode
        mode = newMode
        degradedSince = nil
        if newMode == .off {
            let actions = releaseNotice()
            selected = nil; phase = .idle(next: nil); hostChecksUntil = 0
            return actions + setState(.relay)
        }
        guard side == 0 else { return [] }
        if previous == .off { failures = 0; return startAttempt(now) }
        if newMode == .on, case .relayPreferred = phase { return startAttempt(now) }
        return []
    }

    /// The local network changed: our node-observed mapping and interface addresses are about to change too.
    public func networkChanged(now: TimeInterval) -> [Action] {
        failures = 0; candidatesChanged = now
        guard side == 0, mode != .off else { return [] }
        switch phase {
        case .idle, .relayPreferred: phase = .idle(next: now + 1)
        default: break
        }
        return []
    }

    public func directSendFailed(now: TimeInterval) -> [Action] {
        guard selected != nil else { return [] }
        if side == 1 { selected = nil; phase = .idle(next: nil); return setState(.relay) }
        if case .direct(let since) = phase { return lost(now, since: since) }
        return []
    }

    public func sealData(_ payload: Data) -> (Data, RelayPeerAddress)? {
        guard let selected, mode != .off, let packet = seal(.data, payload, viaRelay: false) else { return nil }
        return (packet, selected)
    }

    /// `source` is nil for packets that arrived inside the authenticated relay datagram stream.
    public func receive(_ packet: Data, from source: RelayPeerAddress?, now: TimeInterval) -> (payload: Data?, actions: [Action]) {
        guard let (kind, viaRelay, payload) = open(packet), viaRelay == (source == nil) else { return (nil, []) }
        if let source, source == selected { lastDirectReceive = now }
        switch kind {
        case .data:
            return (source == nil ? nil : payload, [])
        case .check:
            guard mode != .off, payload.count == 8 else { return (nil, []) }
            if let source { learn(source, now) }
            guard let reply = seal(.checkAck, payload, viaRelay: source == nil) else { return (nil, []) }
            return (nil, [source.map { .send(reply, $0) } ?? .sendViaRelay(reply)])
        case .checkAck:
            guard let id = Self.transaction(payload), let entry = pending.removeValue(forKey: id) else { return (nil, []) }
            let roundTrip = max(0.0005, now - entry.sent)
            guard let target = entry.target else {
                relayRoundTrip = Self.smooth(relayRoundTrip, roundTrip); Self.record(&relaySamples, true, limit: 20)
                return (nil, [])
            }
            guard source != nil else { return (nil, []) }
            if entry.keepalive {
                directRoundTrip = Self.smooth(directRoundTrip, roundTrip); Self.record(&directSamples, true, limit: 40)
                // A symmetric NAT may answer from another mapping; the completed round trip still proves the path.
                if target == selected { lastDirectReceive = now }
            } else if let index = remotes.firstIndex(where: { $0.address == target }), remotes[index].roundTrip == nil {
                remotes[index].roundTrip = roundTrip
                if case .checking(let started, nil) = phase { phase = .checking(started: started, firstSuccess: now) }
            }
            return (nil, [])
        case .nominate:
            guard side == 1, mode != .off, let source, payload.count == 8 else { return (nil, []) }
            learn(source, now)
            var actions: [Action] = []
            if selected != source {
                selected = source; phase = .direct(since: now)
                actions += setState(.direct(remotes.first { $0.address == source }?.kind ?? .prflx))
            }
            lastDirectReceive = now
            if let reply = seal(.nominateAck, payload, viaRelay: false) { actions.append(.send(reply, source)) }
            return (nil, actions)
        case .nominateAck:
            guard side == 0, source != nil, case .nominating(let target, let kind, let id, _, _) = phase,
                  Self.transaction(payload) == id else { return (nil, []) }
            selected = target; phase = .direct(since: now)
            lastDirectReceive = now; lastKeepalive = now; degradedSince = nil; directSamples.removeAll()
            directRoundTrip = remotes.first { $0.address == target }?.roundTrip
            return (nil, setState(.direct(kind)))
        case .release:
            if side == 1 {
                guard selected != nil || hostChecksUntil > now else { return (nil, []) }
                selected = nil; phase = .idle(next: nil); hostChecksUntil = 0
                return (nil, setState(.relay))
            }
            guard selected != nil else { return (nil, []) }
            return (nil, fail(now))
        case .attempt:
            guard side == 1, source == nil, mode != .off else { return (nil, []) }
            return (nil, beginHostChecks(now))
        }
    }

    public func tick(now: TimeInterval) -> [Action] {
        expirePending(now)
        guard mode != .off else { return [] }
        return side == 0 ? viewerTick(now) : hostTick(now)
    }

    // MARK: Viewer

    private func viewerTick(_ now: TimeInterval) -> [Action] {
        switch phase {
        case .idle(let next):
            guard let next, now >= next else { return [] }
            return startAttempt(now)
        case .relayPreferred(let until):
            return now >= until ? startAttempt(now) : []
        case .checking(let started, let firstSuccess):
            var actions = dueCheck(now)
            if now - lastRelayProbe >= timing.checkingRelayProbe { actions += probeRelay(now) }
            if let firstSuccess, let best = remotes.filter({ $0.roundTrip != nil }).min(by: { $0.roundTrip! < $1.roundTrip! }) {
                let settled = now - firstSuccess >= timing.grace || remotes.allSatisfy { $0.roundTrip != nil }
                let relayKnown = relayRoundTrip != nil || mode == .on || now - firstSuccess >= timing.relayWait
                guard settled, relayKnown else { return actions }
                if mode == .automatic, let relay = relayRoundTrip, Self.slower(best.roundTrip!, than: relay) {
                    phase = .relayPreferred(until: now + timing.reevaluate)
                    return actions + setState(.relayFaster)
                }
                let id = nextTransaction()
                phase = .nominating(best.address, best.kind, transaction: id, started: now, nextSend: now)
                return actions + viewerTick(now)
            }
            return now - started >= timing.attempt ? actions + fail(now) : actions
        case .nominating(let target, let kind, let id, let started, let nextSend):
            if now - started >= timing.nominate { return fail(now) }
            guard now >= nextSend else { return [] }
            phase = .nominating(target, kind, transaction: id, started: started, nextSend: now + 0.1)
            var payload = Data(); payload.put(id)
            return seal(.nominate, payload, viaRelay: false).map { [.send($0, target)] } ?? []
        case .direct(let since):
            guard let selected else { return fail(now) }
            if now - lastDirectReceive > timing.timeout { return lost(now, since: since) }
            var actions: [Action] = []
            if now - lastKeepalive >= timing.keepalive { lastKeepalive = now; actions += check(selected, now, keepalive: true) }
            if now - lastRelayProbe >= timing.relayProbe { actions += probeRelay(now) }
            if mode == .automatic, degraded(now) {
                actions += releaseNotice()
                self.selected = nil; phase = .relayPreferred(until: now + timing.reevaluate)
                actions += setState(.relayFaster)
            }
            return actions
        }
    }

    private func startAttempt(_ now: TimeInterval) -> [Action] {
        guard !remotes.isEmpty else { phase = .idle(next: nil); return [] }
        reschedule(now); pending.removeAll(); selected = nil
        phase = .checking(started: now, firstSuccess: nil)
        // Ask the host to punch toward us at the same time; one-sided checks cannot open port-restricted NATs.
        var actions = seal(.attempt, Data(), viaRelay: true).map { [Action.sendViaRelay($0)] } ?? []
        actions += setState(.checking)
        return actions + viewerTick(now)
    }

    private func fail(_ now: TimeInterval) -> [Action] {
        selected = nil; failures += 1
        phase = .idle(next: now + timing.retry[min(failures - 1, timing.retry.count - 1)])
        return setState(.unreachable)
    }

    private func lost(_ now: TimeInterval, since: TimeInterval) -> [Action] {
        // The host may still receive our keepalives while its video toward us is lost, so tell it explicitly.
        let actions = releaseNotice()
        if now - since >= timing.stableReset { failures = 0 }
        if now - candidatesChanged < 10 {
            selected = nil; phase = .idle(next: now + 1)
            return actions + setState(.unreachable)
        }
        return actions + fail(now)
    }

    private func degraded(_ now: TimeInterval) -> Bool {
        guard let direct = directRoundTrip, let relay = relayRoundTrip else { degradedSince = nil; return false }
        let directLoss = Self.loss(directSamples), relayLoss = Self.loss(relaySamples)
        let lossy = directSamples.count >= 10 && relaySamples.count >= 5 && directLoss >= 0.1 && directLoss > relayLoss + 0.05
        guard Self.slower(direct, than: relay) || lossy else { degradedSince = nil; return false }
        let since = degradedSince ?? now
        degradedSince = since
        return now - since >= timing.degradedFor
    }

    private func probeRelay(_ now: TimeInterval) -> [Action] {
        lastRelayProbe = now
        return check(nil, now, keepalive: true)
    }

    // MARK: Host

    private func beginHostChecks(_ now: TimeInterval) -> [Action] {
        hostChecksUntil = now + timing.attempt
        reschedule(now)
        return (selected == nil ? setState(.checking) : []) + hostTick(now)
    }

    private func hostTick(_ now: TimeInterval) -> [Action] {
        var actions: [Action] = []
        if selected != nil, now - lastDirectReceive > timing.timeout {
            selected = nil; phase = .idle(next: nil)
            actions += setState(.relay)
        }
        if selected == nil {
            if now < hostChecksUntil { actions += dueCheck(now) }
            else if state == .checking { actions += setState(.relay) }
        }
        return actions
    }

    // MARK: Shared

    private func reschedule(_ now: TimeInterval) {
        for index in remotes.indices { remotes[index].due = now; remotes[index].sent = 0; remotes[index].roundTrip = nil }
        cursor = 0
    }

    // One check per tick across all candidates keeps punching near 20 packets per second.
    private func dueCheck(_ now: TimeInterval) -> [Action] {
        guard !remotes.isEmpty else { return [] }
        let interval = max(0.1, timing.tick * Double(remotes.count))
        let limit = Int((timing.attempt / interval).rounded(.up))
        for offset in 0..<remotes.count {
            let index = (cursor + offset) % remotes.count
            guard remotes[index].roundTrip == nil, remotes[index].due <= now, remotes[index].sent < limit else { continue }
            remotes[index].due = now + interval; remotes[index].sent += 1
            cursor = (index + 1) % remotes.count
            return check(remotes[index].address, now, keepalive: false)
        }
        return []
    }

    private func check(_ target: RelayPeerAddress?, _ now: TimeInterval, keepalive: Bool) -> [Action] {
        let id = nextTransaction()
        var payload = Data(); payload.put(id)
        guard let packet = seal(.check, payload, viaRelay: target == nil) else { return [] }
        if pending.count >= 128, let oldest = pending.min(by: { $0.value.sent < $1.value.sent }) { pending.removeValue(forKey: oldest.key) }
        pending[id] = Pending(target: target, sent: now, keepalive: keepalive)
        return [target.map { .send(packet, $0) } ?? .sendViaRelay(packet)]
    }

    private func expirePending(_ now: TimeInterval) {
        for (id, entry) in pending where now - entry.sent > 1 {
            pending.removeValue(forKey: id)
            guard entry.keepalive else { continue }
            if entry.target == nil { Self.record(&relaySamples, false, limit: 20) } else { Self.record(&directSamples, false, limit: 40) }
        }
    }

    private func learn(_ source: RelayPeerAddress, _ now: TimeInterval) {
        guard !remotes.contains(where: { $0.address == source }), remotes.count < 12 else { return }
        remotes.append(Remote(address: source, kind: .prflx, due: now))
    }

    private func releaseNotice() -> [Action] {
        var actions = seal(.release, Data(), viaRelay: true).map { [Action.sendViaRelay($0)] } ?? []
        if let selected, let packet = seal(.release, Data(), viaRelay: false) { actions.append(.send(packet, selected)) }
        return actions
    }

    private func setState(_ next: RelayPeerPathState) -> [Action] {
        guard next != state else { return [] }
        state = next
        return [.state(next)]
    }

    private func nextTransaction() -> UInt64 { transaction &+= 1; return transaction }

    private static func transaction(_ payload: Data) -> UInt64? {
        guard payload.count == 8 else { return nil }
        var reader = ByteReader(payload)
        return try? reader.take()
    }

    private static func slower(_ direct: TimeInterval, than relay: TimeInterval) -> Bool {
        direct > relay + max(0.02, relay * 0.3)
    }

    private static func smooth(_ current: TimeInterval?, _ sample: TimeInterval) -> TimeInterval {
        current.map { $0 * 0.75 + sample * 0.25 } ?? sample
    }

    private static func record(_ samples: inout [Bool], _ value: Bool, limit: Int) {
        samples.append(value)
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }

    private static func loss(_ samples: [Bool]) -> Double {
        samples.isEmpty ? 0 : Double(samples.filter { !$0 }.count) / Double(samples.count)
    }

    // MARK: Wire format
    // "QDP1", sender side, kind (high bit: carried inside the relay stream), sequence, lease ID,
    // payload length, payload, HMAC-SHA256. The fixed 64-byte overhead matches relay datagrams.

    private func seal(_ kind: Kind, _ payload: Data, viaRelay: Bool) -> Data? {
        guard payload.count <= Self.maximumPayloadBytes else { return nil }
        let sequence: UInt64
        if viaRelay {
            guard relaySequence < .max else { return nil }
            relaySequence += 1; sequence = relaySequence
        } else {
            guard directSequence < .max else { return nil }
            directSequence += 1; sequence = directSequence
        }
        var data = Self.magic
        data.append(side); data.append(kind.rawValue | (viaRelay ? 0x80 : 0))
        data.put(sequence); data.append(leaseID); data.put(UInt16(payload.count)); data.append(payload)
        data.append(contentsOf: HMAC<SHA256>.authenticationCode(for: data, using: sendKey))
        return data
    }

    private func open(_ data: Data) -> (Kind, Bool, Data)? {
        guard data.count >= Self.overhead, data.count <= Self.overhead + Self.maximumPayloadBytes, Self.isPeerPacket(data) else { return nil }
        let body = Data(data.dropLast(32))
        guard HMAC<SHA256>.isValidAuthenticationCode(Data(data.suffix(32)), authenticating: body, using: receiveKey) else { return nil }
        var reader = ByteReader(body)
        guard (try? reader.skip(4)) != nil, let sender: UInt8 = try? reader.take(), let flags: UInt8 = try? reader.take(),
              let sequence: UInt64 = try? reader.take(), let lease = try? reader.bytes(16), let length: UInt16 = try? reader.take(),
              sender == 1 - side, lease == leaseID, Int(length) == reader.remaining,
              let kind = Kind(rawValue: flags & 0x7f), let payload = try? reader.bytes(Int(length)) else { return nil }
        let viaRelay = flags & 0x80 != 0
        let fresh = viaRelay ? relayReplay.accept(sequence) : directReplay.accept(sequence)
        return fresh ? (kind, viaRelay, Data(payload)) : nil
    }
}

/// One non-blocking dual-stack UDP socket. Reaching the node and the peer from the same local port is
/// what lets the node-observed NAT mapping serve as the peer's destination.
final class RelayPeerSocket {
    enum SendResult { case sent, dropped, failed }
    var onPacket: ((Data, RelayPeerAddress) -> Void)?
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var buffer = [UInt8](repeating: 0, count: 2048)
    private var closed = false

    init(queue: DispatchQueue) throws {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw RelayTransportError.network }
        func option(_ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
            var value = value
            return setsockopt(descriptor, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = option(IPPROTO_IPV6, IPV6_V6ONLY, 0) && option(SOL_SOCKET, SO_NOSIGPIPE, 1) &&
            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
                }
            } && fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
        guard bound else { Darwin.close(descriptor); throw RelayTransportError.network }
        // Video bursts are much larger than the default UDP buffers; a smaller system limit only means more drops.
        _ = option(SOL_SOCKET, SO_RCVBUF, 2 << 20); _ = option(SOL_SOCKET, SO_SNDBUF, 2 << 20)
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin6_port)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    private func drain() {
        for _ in 0..<256 where !closed {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &storage) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &length) }
                }
            }
            guard count >= 0 else { return }
            guard let from = RelayPeerAddress(storage: storage) else { continue }
            onPacket?(Data(buffer[0..<count]), from)
        }
    }

    func send(_ data: Data, to destination: RelayPeerAddress) -> SendResult {
        guard !closed else { return .failed }
        let written = data.withUnsafeBytes { bytes in
            destination.withSocketAddress { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, $1) }
        }
        guard let written else { return .failed }
        if written == data.count { return .sent }
        return written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) ? .dropped : .failed
    }

    func close() {
        guard !closed else { return }
        closed = true; onPacket = nil; source.cancel()
    }

    deinit { close() }
}

enum RelayPeerLocalCandidates {
    /// Interface addresses another Mac on the same LAN or IPv6 internet can try. Loopback,
    /// link-local and multicast addresses are never reported.
    static func gather(port: UInt16) -> [RelayCandidate] {
        var addresses: [(address: String, tunnel: Bool)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            defer { freeifaddrs(head) }
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee, flags = Int32(entry.ifa_flags)
                guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                      let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { Data($0) }
                }
                guard let canonical = RelayCandidate.canonicalAddress(RelayPeerAddress.text(v4: bytes), allowLoopback: false),
                      !addresses.contains(where: { $0.address == canonical }) else { continue }
                addresses.append((canonical, flags & IFF_POINTOPOINT != 0))
            }
        }
        var result = (addresses.filter { !$0.tunnel } + addresses.filter(\.tunnel)).prefix(3)
            .map { RelayCandidate(kind: .host, address: $0.address, port: port) }
        if let v6 = preferredIPv6() { result.append(RelayCandidate(kind: .host, address: v6, port: port)) }
        return Array(result.prefix(RelayCandidate.maximumLocal))
    }

    // connect() on a UDP socket only consults the routing table, so this sends nothing. The chosen
    // source prefers a temporary privacy address over the stable one when the system uses them.
    private static func preferredIPv6() -> String? {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        let connected = RelayPeerAddress(host: "2001:db8::1", port: 9).withSocketAddress { connect(descriptor, $0, $1) == 0 } ?? false
        var storage = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard connected, withUnsafeMutablePointer(to: &storage, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) == 0 }
        }), let local = RelayPeerAddress(storage: storage), let v6 = IPv6Address(local.host), !v6.isIPv4Mapped,
              v6.rawValue.first.map({ $0 & 0xe0 == 0x20 }) == true else { return nil }
        return RelayCandidate.canonicalAddress(local.host, allowLoopback: false)
    }
}

protocol RelayDatagramPipe: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onPayload: ((Data, @escaping (Bool) -> Void) -> Void)? { get set }
    var onClose: ((Error) -> Void)? { get set }
    func start()
    func send(_ payload: Data, completion: @escaping (Bool) -> Void)
    func close()
}

extension RelayUDPPipe: RelayDatagramPipe {}

/// A relay datagram route that can move its outer path onto a hole-punched direct path. Inner DTLS
/// records are forwarded unchanged on either path; the relay lease stays warm as the fallback.
final class RelayAssistedPipe: RelayDatagramPipe {
    var onReady: (() -> Void)?
    var onPayload: ((Data, @escaping (Bool) -> Void) -> Void)?
    var onClose: ((Error) -> Void)?
    /// Called after the desktop session authenticated this route, with the addresses to share through the node.
    var onConsent: (([RelayCandidate]) -> Void)?
    var onPathState: ((RelayPeerPathState) -> Void)?
    private static let relayMagic = Data("QDR1".utf8)
    private let endpoint: RelayEndpoint
    private let id: Data
    private let key: Data
    private let side: UInt8
    private let queue: DispatchQueue
    private let counter: RelayPeerTrafficCounter
    private let timing: RelayPeerAgent.Timing
    private let interfaceCandidates: Bool
    private var mode: RelayPeerAssistMode
    private var socket: RelayPeerSocket?
    private var relay: RelayPeerAddress?
    private var agent: RelayPeerAgent?
    private var secret: Data?
    private var peerCandidates: [RelayCandidate]?
    private var lastConsent: [RelayCandidate]?
    private var sequence: UInt64 = 0
    private var replay = RelayReplayWindow()
    private var started = false
    private var ready = false
    private var closed = false
    private var delivering = 0
    private var keepalive: DispatchSourceTimer?
    private var ticker: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    private var monitorPrimed = false

    /// Without `interfaceCandidates` only the node-observed mapping is tried; no interface address is shared.
    init(endpoint: RelayEndpoint, id: Data, key: Data, side: UInt8, mode: RelayPeerAssistMode, queue: DispatchQueue,
         counter: RelayPeerTrafficCounter, interfaceCandidates: Bool = true, timing: RelayPeerAgent.Timing = .init()) throws {
        guard id.count == 16, key.count == 32, side <= 1 else { throw RelayServiceError.invalid }
        self.endpoint = endpoint; self.id = id; self.key = key; self.side = side; self.mode = mode
        self.queue = queue; self.counter = counter; self.interfaceCandidates = interfaceCandidates; self.timing = timing
    }

    func start() {
        guard !started else { return }
        started = true
        let host = endpoint.host, port = endpoint.port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let address = RelayPeerAddress.resolve(host: host, port: port)
            self?.queue.async { self?.open(relay: address) }
        }
    }

    private func open(relay address: RelayPeerAddress?) {
        guard !closed else { return }
        guard let address, let socket = try? RelayPeerSocket(queue: queue) else { finish(RelayTransportError.network); return }
        self.socket = socket; relay = address; ready = true
        socket.onPacket = { [weak self] data, source in self?.receive(data, from: source) }
        guard sendRelay(Data()) else { return }
        onReady?()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in _ = self?.sendRelay(Data()) }
        keepalive = timer; timer.resume()
        activateIfAllowed()
    }

    func send(_ payload: Data, completion: @escaping (Bool) -> Void) {
        guard ready, !closed, let socket, payload.count <= RelayDatagram.maximumPayloadBytes else { completion(false); return }
        if let agent, let (packet, destination) = agent.sealData(payload) {
            if socket.send(packet, to: destination) != .failed { counter.record(direct: payload.count); completion(true); return }
            perform(agent.directSendFailed(now: SessionClock.now))
        }
        let sent = sendRelay(payload)
        if sent { counter.record(relayed: payload.count) }
        completion(sent)
    }

    func enableAssist(secret: Data) {
        guard !closed, secret.count == 32 else { return }
        self.secret = secret
        activateIfAllowed()
    }

    func receivePeerCandidates(_ candidates: [RelayCandidate]) {
        guard !closed else { return }
        peerCandidates = candidates
        if let agent { perform(agent.updateCandidates(candidates, now: SessionClock.now)) }
    }

    func setMode(_ newMode: RelayPeerAssistMode) {
        guard !closed else { return }
        mode = newMode
        if let agent { perform(agent.setMode(newMode, now: SessionClock.now)) } else { activateIfAllowed() }
    }

    func close() { finish(RelayTransportError.cancelled) }

    private func activateIfAllowed() {
        guard agent == nil, mode != .off, ready, let secret, let socket, let relay else { return }
        let loopback = IPv4Address(relay.host)?.isLoopback == true || IPv6Address(relay.host)?.isLoopback == true
        guard let agent = try? RelayPeerAgent(side: side, leaseID: id, secret: secret, mode: mode, allowLoopback: loopback, timing: timing) else { return }
        self.agent = agent
        consent(localCandidates(port: socket.port))
        if let peerCandidates { perform(agent.updateCandidates(peerCandidates, now: SessionClock.now)) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timing.tick, repeating: timing.tick)
        timer.setEventHandler { [weak self] in
            guard let self, let agent = self.agent else { return }
            self.perform(agent.tick(now: SessionClock.now))
        }
        ticker = timer; timer.resume()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self, !self.closed, let agent = self.agent, let socket = self.socket else { return }
            guard self.monitorPrimed else { self.monitorPrimed = true; return }
            // Refresh the node's view of our mapping right away rather than at the next 15-second keepalive.
            self.sendRelay(Data())
            self.consent(self.localCandidates(port: socket.port))
            self.perform(agent.networkChanged(now: SessionClock.now))
        }
        self.monitor = monitor; monitor.start(queue: queue)
    }

    private func localCandidates(port: UInt16) -> [RelayCandidate] {
        interfaceCandidates ? RelayPeerLocalCandidates.gather(port: port) : []
    }

    private func consent(_ candidates: [RelayCandidate]) {
        guard candidates != lastConsent else { return }
        lastConsent = candidates
        onConsent?(candidates)
    }

    private func receive(_ data: Data, from source: RelayPeerAddress) {
        guard !closed else { return }
        if data.starts(with: Self.relayMagic) {
            guard let packet = try? RelayDatagram.decode(data, key: key), packet.id == id, packet.side == side, packet.downstream,
                  replay.accept(packet.sequence), !packet.payload.isEmpty else { return }
            // DTLS records begin with a content type of 20-25, never the "QDP1" magic.
            if RelayPeerAgent.isPeerPacket(packet.payload) {
                if let agent { perform(agent.receive(packet.payload, from: nil, now: SessionClock.now).actions) }
                return
            }
            counter.record(relayed: packet.payload.count)
            deliver(packet.payload)
        } else if let agent, RelayPeerAgent.isPeerPacket(data) {
            let result = agent.receive(data, from: source, now: SessionClock.now)
            perform(result.actions)
            if let payload = result.payload { counter.record(direct: payload.count); deliver(payload) }
        }
    }

    private func deliver(_ payload: Data) {
        guard let onPayload, delivering < 256 else { return }
        delivering += 1
        let once = NSLock()
        var finished = false
        onPayload(payload) { [weak self] _ in
            guard once.withLock({ () -> Bool in defer { finished = true }; return !finished }) else { return }
            self?.queue.async { self?.delivering -= 1 }
        }
    }

    @discardableResult
    private func sendRelay(_ payload: Data) -> Bool {
        guard ready, !closed, let socket, let relay, sequence < .max else { return false }
        sequence += 1
        guard let data = try? RelayDatagram(side: side, sequence: sequence, id: id, payload: payload).encode(key: key),
              socket.send(data, to: relay) != .failed else { finish(RelayTransportError.network); return false }
        return true
    }

    private func perform(_ actions: [RelayPeerAgent.Action]) {
        for action in actions where !closed {
            switch action {
            case .send(let data, let address): _ = socket?.send(data, to: address)
            case .sendViaRelay(let data): sendRelay(data)
            case .state(let state): onPathState?(state)
            }
        }
    }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true; ready = false
        keepalive?.cancel(); ticker?.cancel(); monitor?.cancel(); socket?.close()
        keepalive = nil; ticker = nil; monitor = nil; socket = nil; agent = nil
        let callback = onClose
        onClose = nil; onReady = nil; onPayload = nil; onConsent = nil; onPathState = nil
        callback?(error)
    }

    deinit { keepalive?.cancel(); ticker?.cancel(); monitor?.cancel(); socket?.close() }
}
