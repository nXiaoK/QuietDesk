import Foundation
import QuietDeskCore

// A connection owns its data handlers. Invalidation also fences late decoder callbacks.
final class SessionDataChannel: @unchecked Sendable {
    typealias VideoReceiver = (VideoPacket, @escaping () -> Void) -> Void
    private let lock = NSLock()
    private let send: (Message) -> Void
    private var valid = true
    private var video: VideoReceiver?
    private var acknowledgement: ((UInt32) -> Void)?
    private var clipboard: ((Message) -> Void)?
    private var freshFrameToken: UUID?
    private var bytes = 0
    private var frames = 0
    private let onFreshFrame: (UUID) -> Void

    init(send: @escaping (Message) -> Void, onFreshFrame: @escaping (UUID) -> Void) {
        self.send = send
        self.onFreshFrame = onFreshFrame
    }

    func configureVideo(_ receiver: @escaping VideoReceiver) { lock.withLock { if valid { video = receiver } } }
    func configureAcknowledgement(_ handler: @escaping (UInt32) -> Void) { lock.withLock { if valid { acknowledgement = handler } } }
    func configureClipboard(_ handler: ((Message) -> Void)?) { lock.withLock { if valid { clipboard = handler } } }
    func expectFreshFrame(_ token: UUID?) { lock.withLock { if valid { freshFrameToken = token } } }

    func receive(_ message: Message) throws -> Bool {
        let handlers = lock.withLock { (valid, video, acknowledgement, clipboard, freshFrameToken) }
        guard handlers.0 else { return true }
        switch message.kind {
        case .video:
            guard let video = handlers.1 else { return false }
            let packet = try VideoPacket.decode(message.payload)
            let token = packet.sps.isEmpty ? nil : handlers.4
            video(packet) { [weak self] in
                guard let self else { return }
                let accepted = self.lock.withLock {
                    guard self.valid else { return false }
                    self.frames += 1
                    return true
                }
                guard accepted else { return }
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
        case .clipboardBegin, .clipboardEntry, .clipboardChunk, .clipboardEnd, .clipboardReceipt, .clipboardCancel:
            guard let clipboard = handlers.3 else { return false }
            clipboard(message)
            return true
        default: return false
        }
    }

    func recordBytes(_ count: Int) { lock.withLock { if valid { bytes += count } } }
    func recordFrame() { lock.withLock { if valid { frames += 1 } } }
    func takeMetrics() -> (bytes: Int, frames: Int) {
        lock.withLock { defer { bytes = 0; frames = 0 }; return (bytes, frames) }
    }

    func invalidate() {
        lock.withLock {
            valid = false
            video = nil
            acknowledgement = nil
            clipboard = nil
            freshFrameToken = nil
            bytes = 0; frames = 0
        }
    }
}
