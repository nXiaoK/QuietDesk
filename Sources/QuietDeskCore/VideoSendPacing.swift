import Foundation

// Spreads a video message over time so a keyframe does not leave as one line-rate burst.
// Only submission timing changes; message bytes and their order on the wire stay the same.
public struct VideoSendPacing: Equatable, Sendable {
    public static let sliceBytes = 16 * 1_024
    public static let burstBytes = 64 * 1_024
    public let bytesPerSecond: Double

    // About 2.5 times the encoder target, kept between 40 and 200 Mbps.
    public init(megabits: Int) {
        bytesPerSecond = min(200, max(40, Double(megabits) * 2.5)) * 1_000_000 / 8
    }
}

// Byte credit refills at the pacing rate and is capped at one burst, so a late timer cannot release a whole frame.
public struct VideoSendPacer {
    public let pacing: VideoSendPacing
    private var credit: Double
    private var updatedAt: TimeInterval

    public init(_ pacing: VideoSendPacing, now: TimeInterval) {
        self.pacing = pacing
        credit = Double(VideoSendPacing.burstBytes)
        updatedAt = now
    }

    // Returns the bytes that may be submitted now, or how long to wait before asking again.
    public mutating func next(remaining: Int, now: TimeInterval) -> (bytes: Int, delay: TimeInterval) {
        guard remaining > 0 else { return (0, 0) }
        if now > updatedAt {
            credit = min(Double(VideoSendPacing.burstBytes), credit + (now - updatedAt) * pacing.bytesPerSecond)
            updatedAt = now
        }
        let bytes = min(remaining, VideoSendPacing.sliceBytes)
        // One byte of tolerance absorbs floating-point refill error after waiting the exact delay.
        guard credit + 1 >= Double(bytes) else { return (0, (Double(bytes) - credit) / pacing.bytesPerSecond) }
        credit = max(0, credit - Double(bytes))
        return (bytes, 0)
    }
}
