import Foundation
import CoreVideo
import QuietDeskCore

func runFrameMailboxChecks() {
    func pixel() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32ARGB, nil, &value)
        guard result == kCVReturnSuccess, let value else { throw CheckFailure("Unable to create mailbox fixture pixels") }
        return value
    }

    run("Sequenced frame mailboxes ignore out-of-order and duplicate decode completions across display drains") {
        let first = try pixel(), newest = try pixel(), stale = try pixel()
        let inbox = LatestFrameMailbox()
        try check(inbox.offer(first, sequence: 5), "First frame failed to schedule display")
        try check(!inbox.offer(newest, sequence: 7), "Pending display acquired another callback")
        try check(!inbox.offer(stale, sequence: 6), "Old decode completion scheduled display")
        try check(!inbox.offer(stale, sequence: 7), "Duplicate decode completion scheduled display")
        try check(inbox.take() === newest, "An old or duplicate completion replaced the latest frame")
        try check(!inbox.offer(stale, sequence: 6) && !inbox.offer(stale, sequence: 7), "Draining forgot the sequence watermark")
        try check(inbox.take() === newest, "A late completion regressed the displayed frame after drain")
        try check(inbox.offer(first, sequence: 8) && inbox.take() === first, "The next new frame failed to schedule after drain")
    }

    run("Frame sequence ordering accepts UInt32 wraparound and rejects ambiguous half-range jumps") {
        let first = try pixel(), wrapped = try pixel(), stale = try pixel()
        let inbox = LatestFrameMailbox()
        try check(inbox.offer(first, sequence: UInt32.max - 1), "Initial sequence was restricted")
        try check(!inbox.offer(first, sequence: UInt32.max), "Pending display scheduled twice before wrap")
        try check(!inbox.offer(wrapped, sequence: 0), "Pending display scheduled twice at wrap")
        try check(!inbox.offer(wrapped, sequence: 1), "Pending display scheduled twice after wrap")
        try check(inbox.take() === wrapped, "Wrapped sequence did not replace the previous cycle")
        try check(!inbox.offer(stale, sequence: UInt32.max) && !inbox.offer(stale, sequence: 0), "Pre-wrap frame replaced the new cycle")
        try check(!inbox.offer(stale, sequence: 0x8000_0001), "Ambiguous half-range jump was accepted")
        try check(inbox.take() === wrapped, "Rejected sequence changed the current frame")
        try check(inbox.offer(first, sequence: 0x8000_0000), "The largest unambiguous forward distance was rejected")
    }

    run("Legacy unsequenced offers preserve replacement and scheduling behavior and new connections start fresh") {
        let first = try pixel(), second = try pixel()
        let legacy = LatestFrameMailbox()
        try check(legacy.offer(first) && !legacy.offer(second), "Legacy offers changed callback coalescing")
        try check(legacy.take() === second, "Legacy offers stopped replacing the pending frame")
        try check(legacy.offer(first) && legacy.take() === first, "Legacy offers did not schedule after drain")

        let previous = LatestFrameMailbox(), current = LatestFrameMailbox()
        _ = previous.offer(first, sequence: 900)
        try check(current.offer(second, sequence: 0) && current.take() === second, "A new mailbox inherited another connection's sequence")
    }

    run("Concurrent decode completions retain the highest sequence with one display callback") {
        let older = try pixel(), newest = try pixel()
        let inbox = LatestFrameMailbox(), schedules = Box(0)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            if inbox.offer(index == 255 ? newest : older, sequence: UInt32(index)) {
                schedules.update { $0 += 1 }
            }
        }
        try check(schedules.read() == 1 && inbox.take() === newest, "Concurrent decode order regressed or scheduled duplicate display work")
        try check(!inbox.offer(older, sequence: 254), "A late callback survived concurrent drain")
        try check(inbox.offer(newest, sequence: 256), "Concurrent updates lost the next display schedule")
    }
}
