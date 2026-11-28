import Foundation
import QuietDeskCore

// A connection owns its data handlers. Invalidation also fences late decoder callbacks.
final class SessionDataChannel: @unchecked Sendable {
    typealias VideoReceiver = (VideoPacket, @escaping () -> Void) -> Void
    struct ChannelTraffic {
        var controlTCP = DiagnosticTrafficBucket()
        var videoTCP = DiagnosticTrafficBucket()
        var bulkTCP = DiagnosticTrafficBucket()
        var mediaUDP = DiagnosticTrafficBucket()
        // Relayed datagrams are measured at the forwarding pipe, not again on loopback.
        var unrelayedMediaUDP = DiagnosticTrafficBucket()
    }
    private let lock = NSLock()
    private let send: (Message) -> Void
    private let firstFrameClock: (() -> TimeInterval)?
    private var firstFrameAt: TimeInterval?
    private var valid = true
    private var video: VideoReceiver?
    private var acknowledgement: ((UInt32) -> Void)?
    private var clipboard: ((Message) -> Void)?
    private var media: ((Message) -> Bool)?
    private var reliableData: ((Message) -> Void)?
    private var cursorPosition: ((CursorPosition) -> Void)?
    private var audioPacket: ((RemoteAudioPacket) -> Void)?
    private var latestCursorPosition: CursorPosition?
    private var cursorFlushScheduled = false
    private var freshFrameToken: UUID?
    private var mediaFreshFrame: (stream: MediaStreamID, token: UUID?)?
    private var bytes = 0
    private var legacyBytes = 0
    private var channelTraffic = ChannelTraffic()
    private var frames = 0
    private var settledFragments = 0
    private var lostFragments = 0
    private var lastDisplaySample = (bytes: 0, frames: 0)
    private let onFreshFrame: (UUID) -> Void

    init(send: @escaping (Message) -> Void, firstFrameClock: (() -> TimeInterval)? = nil,
         onFreshFrame: @escaping (UUID) -> Void) {
        self.send = send
        self.firstFrameClock = firstFrameClock
        self.onFreshFrame = onFreshFrame
    }

    func configureVideo(_ receiver: @escaping VideoReceiver) { lock.withLock { if valid { video = receiver } } }
    func configureAcknowledgement(_ handler: @escaping (UInt32) -> Void) { lock.withLock { if valid { acknowledgement = handler } } }
    func configureClipboard(_ handler: ((Message) -> Void)?) { lock.withLock { if valid { clipboard = handler } } }
    func configureMedia(_ handler: @escaping (Message) -> Bool) { lock.withLock { if valid { media = handler } } }
    func configureReliableData(_ handler: @escaping (Message) -> Void) { lock.withLock { if valid { reliableData = handler } } }
    func configureCursorPosition(_ handler: ((CursorPosition) -> Void)?) {
        lock.withLock {
            guard valid else { return }
            cursorPosition = handler
            if handler == nil { latestCursorPosition = nil; cursorFlushScheduled = false }
        }
    }
    func configureAudioPacket(_ handler: ((RemoteAudioPacket) -> Void)?) {
        lock.withLock {
            guard valid else { return }
            audioPacket = handler
        }
    }
    @discardableResult
    func receiveAudioPacket(_ packet: RemoteAudioPacket) -> Bool {
        let handler = lock.withLock { valid ? audioPacket : nil }
        guard let handler else { return false }
        handler(packet)
        return true
    }
    func flushCursorPosition() {
        let next = lock.withLock { () -> (CursorPosition, (CursorPosition) -> Void)? in
            cursorFlushScheduled = false
            guard valid, let position = latestCursorPosition, let handler = cursorPosition else {
                latestCursorPosition = nil
                return nil
            }
            latestCursorPosition = nil
            return (position, handler)
        }
        if let (position, handler) = next { handler(position) }
    }
    @discardableResult
    func receiveCursorPosition(_ position: CursorPosition) -> Bool {
        let state = lock.withLock { () -> (accepted: Bool, shouldSchedule: Bool) in
            guard valid, cursorPosition != nil else { return (false, false) }
            if let existing = latestCursorPosition,
               existing.cursorID == position.cursorID,
               (position.epoch < existing.epoch || (position.epoch == existing.epoch && position.sequence <= existing.sequence)) {
                return (true, false)
            }
            latestCursorPosition = position
            guard !cursorFlushScheduled else { return (true, false) }
            cursorFlushScheduled = true
            return (true, true)
        }
        if state.shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.flushCursorPosition() }
        }
        return state.accepted
    }

    func sendReliableData(_ message: Message) {
        let handler = lock.withLock { valid ? (reliableData ?? send) : nil }
        handler?(message)
    }
    func expectFreshFrame(_ token: UUID?) { lock.withLock { if valid { freshFrameToken = token } } }

    func receive(_ message: Message) throws -> Bool {
        let handlers = lock.withLock { (valid, video, acknowledgement, clipboard, freshFrameToken, media) }
        guard handlers.0 else { return true }
        if handlers.5?(message) == true { return true }
        switch message.kind {
        case .video:
            guard let video = handlers.1 else { return false }
            let packet = try VideoPacket.decode(message.payload)
            let token = packet.sps.isEmpty ? nil : handlers.4
            video(packet) { [weak self] in
                guard let self, self.recordFrame() else { return }
                var data = Data()
                data.put(packet.sequence)
                self.send(Message(.acknowledgement, data))
                if let token { self.onFreshFrame(token) }
            }
            return true
        case .acknowledgement:
            guard let acknowledgement = handlers.2 else { return false }
            guard message.payload.count == 4 else { throw DeskError.invalid("画面确认无效") }
            var reader = ByteReader(message.payload)
            acknowledgement(try reader.take())
            return true
        case .cursorPosition:
            let configured = lock.withLock { valid && cursorPosition != nil }
            guard configured else { return false }
            let position = try CursorPosition.decode(message.payload)
            return receiveCursorPosition(position)
        case .audioFrame:
            let handler = lock.withLock { valid ? audioPacket : nil }
            guard let handler else { return false }
            let packet = try RemoteAudioPacket.decode(message.payload)
            handler(packet)
            return true
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd,
             .clipboardReceipt, .clipboardCancel, .clipboardManifest, .clipboardPull:
            guard let clipboard = handlers.3 else { return false }
            clipboard(message)
            return true
        default: return false
        }
    }

    func recordBytes(_ count: Int) {
        lock.withLock {
            if valid { bytes += count; legacyBytes += count }
        }
    }

    func recordChannelTraffic(_ channel: MediaTrafficChannel, sent: UInt64, received: UInt64) {
        lock.withLock {
            guard valid else { return }
            switch channel {
            case .controlTCP: channelTraffic.controlTCP.add(sent: sent, received: received)
            case .videoTCP: channelTraffic.videoTCP.add(sent: sent, received: received)
            case .bulkTCP: channelTraffic.bulkTCP.add(sent: sent, received: received)
            case .mediaUDP:
                channelTraffic.mediaUDP.add(sent: sent, received: received)
                channelTraffic.unrelayedMediaUDP.add(sent: sent, received: received)
            }
            addDisplayTraffic(sent: sent, received: received)
        }
    }

    func recordDatagramTraffic(relayed: Bool, sent: UInt64, received: UInt64) {
        lock.withLock {
            guard valid else { return }
            channelTraffic.mediaUDP.add(sent: sent, received: received)
            if !relayed { channelTraffic.unrelayedMediaUDP.add(sent: sent, received: received) }
            addDisplayTraffic(sent: sent, received: received)
        }
    }

    private func addDisplayTraffic(sent: UInt64, received: UInt64) {
        let (sum, overflow) = bytes.addingReportingOverflow(Int(clamping: sent))
        let (total, totalOverflow) = sum.addingReportingOverflow(Int(clamping: received))
        bytes = overflow || totalOverflow ? .max : total
    }

    func channelTrafficSnapshot() -> ChannelTraffic { lock.withLock { channelTraffic } }

    func diagnosticSnapshot() -> (traffic: ChannelTraffic, legacyBytes: Int, frames: Int, settled: Int, lost: Int) {
        lock.withLock { (channelTraffic, legacyBytes, frames, settledFragments, lostFragments) }
    }
    @discardableResult
    func recordFrame() -> Bool {
        lock.withLock {
            guard valid else { return false }
            frames += 1
            if frames == 1 { firstFrameAt = firstFrameClock?() }
            return true
        }
    }
    func mediaFrameReceived(_ header: MediaFrameHeader) {
        lock.withLock {
            if valid, header.isIDR { mediaFreshFrame = (header.stream, freshFrameToken) }
        }
    }
    func mediaStreamCommitted(_ stream: MediaStreamID) {
        let token = lock.withLock { () -> UUID? in
            guard valid, let received = mediaFreshFrame, received.stream == stream,
                  received.token == freshFrameToken else { return nil }
            return received.token
        }
        if let token { onFreshFrame(token) }
    }
    func takeMetrics() -> (bytes: Int, frames: Int) {
        lock.withLock {
            defer { lastDisplaySample = (bytes, frames) }
            return (bytes - lastDisplaySample.bytes, frames - lastDisplaySample.frames)
        }
    }

    func recordDiagnosticFragments(settled: Int, lost: Int) {
        lock.withLock {
            if valid { settledFragments += settled; lostFragments += lost }
        }
    }

    func metricsSnapshot() -> (bytes: Int, frames: Int, settled: Int, lost: Int) {
        lock.withLock { (bytes, frames, settledFragments, lostFragments) }
    }

    /// Closing a benchmark connection also collects its first decode time under the frame counter's lock.
    @discardableResult
    func invalidate() -> TimeInterval? {
        lock.withLock {
            valid = false
            video = nil
            acknowledgement = nil
            clipboard = nil
            media = nil
            reliableData = nil
            cursorPosition = nil
            audioPacket = nil
            latestCursorPosition = nil
            cursorFlushScheduled = false
            mediaFreshFrame = nil
            freshFrameToken = nil
            bytes = 0; frames = 0
            legacyBytes = 0
            channelTraffic = ChannelTraffic()
            lastDisplaySample = (0, 0)
            settledFragments = 0; lostFragments = 0
            defer { firstFrameAt = nil }
            return firstFrameAt
        }
    }
}
