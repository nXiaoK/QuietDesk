import AppKit
import VideoToolbox
import ScreenCaptureKit
@testable import QuietDeskCore

private struct VideoCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VideoCheckFailure(message) }
}

private func cursorSample(_ time: CMTime, width: Int = 64, height: Int = 64) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let created = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard created == kCVReturnSuccess, let pixelBuffer else { throw VideoCheckFailure("Could not create synthetic cursor sample pixels") }
    var format: CMVideoFormatDescription?
    let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
    guard described == noErr, let format else { throw VideoCheckFailure("Could not describe synthetic cursor sample") }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                         sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw VideoCheckFailure("Could not create synthetic cursor sample") }
    return sample
}

private final class EncodedRecoveryPacket: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<VideoPacket, Error>?
    private var timing = VideoEncodeTiming()
    private var callbacks = 0
    private var duration: TimeInterval?
    func begin(encoderID: UUID, sequence: UInt32) {
        _ = lock.withLock { timing.begin(encoderID: encoderID, sequence: sequence, at: SessionClock.now) }
    }
    func set(_ result: Result<VideoPacket, Error>, encoderID: UUID) {
        let callbackAt = SessionClock.now
        lock.withLock {
            self.result = result
            callbacks += 1
            if case .success(let packet) = result {
                duration = timing.complete(encoderID: encoderID, sequence: packet.sequence, at: callbackAt)
            } else { timing.cancel(encoderID: encoderID) }
        }
    }
    func get() -> (result: Result<VideoPacket, Error>?, callbacks: Int, duration: TimeInterval?) {
        lock.withLock { (result, callbacks, duration) }
    }
}

@main
private struct VideoPipelineChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        func predictiveFlow(sequence: UInt32 = 0) -> VideoFrameFlow {
            var flow = VideoFrameFlow(sequence: sequence)
            let initial = flow.begin(at: 0)!
            _ = flow.encoded(initial.sequence, at: 0)
            _ = flow.acknowledge(initial.sequence)
            return flow
        }
        func completed(_ frame: VideoFrameFlow.Encoding, dropped: Bool = false, at: TimeInterval = 1) -> VideoFrameFlow.Completion {
            let packet = dropped ? nil : VideoPacket(sequence: frame.sequence, sps: Data(), pps: Data(), avcc: Data([0, 0, 0, 2, 0x41, 0]))
            return .init(sequence: frame.sequence, packet: packet, callbackAt: at, duration: nil, diagnostic: nil)
        }

        run("VideoToolbox rate-control drops and empty successful output are nonfatal") {
            for flags: VTEncodeInfoFlags in [[], [.frameDropped]] {
                let packet = try VideoEncoder.output(status: noErr, info: flags, sample: nil, sequence: 4).get()
                try require(packet == nil, "A dropped frame produced an invalid video packet")
            }
        }

        run("A real VideoToolbox error is fatal even if marked dropped") {
            let result = VideoEncoder.output(status: -12915, info: [.frameDropped], sample: nil, sequence: 4)
            guard case .failure = result else { throw VideoCheckFailure("An encoder error was hidden as a normal drop") }
        }

        run("Dropping the first keyframe drains encoding and preserves its replacement") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            try require(first.forceKeyFrame && !flow.isIdle, "The initial frame was not a forced keyframe")
            try require(flow.dropped(first.sequence) && flow.isIdle, "A drop left the pipeline waiting for an impossible ack")
            let next = flow.begin(at: 1)
            try require(next?.forceKeyFrame == true, "The replacement keyframe was lost after a normal encoder drop")
        }

        run("Three consecutive drops request a keyframe and successful output resets the streak") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            _ = flow.encoded(first.sequence, at: 0)
            _ = flow.acknowledge(first.sequence)
            for index in 1...3 {
                let frame = flow.begin(at: Double(index))!
                try require(!frame.forceKeyFrame, "A keyframe was requested before the drop threshold")
                _ = flow.dropped(frame.sequence)
                try require(flow.forceKeyFrame == (index == 3), "The consecutive drop threshold was not respected")
            }
            let recovery = flow.begin(at: 4)!
            _ = flow.encoded(recovery.sequence, at: 4)
            _ = flow.acknowledge(recovery.sequence)
            let normal = flow.begin(at: 5)!
            _ = flow.dropped(normal.sequence)
            try require(!flow.forceKeyFrame, "A successful output did not reset the drop streak")
        }

        run("An unrelated drop cannot release the active encoder or overwrite a keyframe request") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            try require(!flow.dropped(first.sequence &+ 1) && flow.encoding.first?.sequence == first.sequence,
                        "A stale drop released another frame")
            flow.requestKeyFrame()
            _ = flow.encoded(first.sequence, at: 1)
            _ = flow.acknowledge(first.sequence)
            try require(flow.begin(at: 2)?.forceKeyFrame == true, "A pending reconfiguration keyframe request was overwritten")
        }

        run("Failed submissions release encoding and dropped frames cannot trip the watchdog") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            try require(flow.stalled(at: 91)?.contains("编码") == true, "A stuck encoder escaped the watchdog")
            _ = flow.dropped(first.sequence)
            try require(flow.isIdle && flow.stalled(at: 100) == nil, "A normal drop left a stalled frame")
            _ = flow.begin(at: 100)
            flow.cancelEncoding()
            try require(flow.isIdle && flow.stalled(at: 200) == nil, "A failed submission did not drain its encoder state")
        }

        run("Two encoder reservations still share three total credits and the legacy default remains one") {
            var flow = predictiveFlow()
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            try require(flow.encoding.count == 2 && flow.outstanding == 2
                        && flow.begin(at: 3, maximumConcurrentEncodes: 3) == nil,
                        "The encoder window exceeded two reservations")
            _ = flow.encoded(first.sequence, at: 3)
            let third = flow.begin(at: 4, maximumConcurrentEncodes: 2)!
            try require(flow.outstanding == 3 && flow.begin(at: 5, maximumConcurrentEncodes: 2) == nil
                        && !flow.acknowledge(second.sequence), "Encoding bypassed the three-credit limit")
            _ = flow.dropped(second.sequence)
            try require(flow.outstanding == 2 && flow.encoding.first?.sequence == third.sequence
                        && flow.waiting[first.sequence] != nil, "A drop released an unrelated credit")
            _ = flow.acknowledge(first.sequence)
            try require(flow.begin(at: 6) == nil, "The default call allowed overlapping encodes")
            try require(flow.begin(at: 6, maximumConcurrentEncodes: 2) != nil && flow.outstanding == 2,
                        "An ACK did not return exactly its own credit")
        }

        run("Out-of-order encoder completions are bounded and delivered in submission order") {
            var flow = predictiveFlow()
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            try require(flow.complete(completed(second)) && !flow.complete(completed(second))
                        && flow.takeCompleted() == nil && !flow.encoded(second.sequence, at: 3),
                        "A later or duplicate callback escaped the ordering barrier")
            try require(flow.complete(completed(first)), "The first callback was not retained")
            let a = flow.takeCompleted()!
            try require(a.0.sequence == first.sequence && a.1.packet?.sequence == first.sequence
                        && flow.outstanding == 2, "Taking a completion released its reservation early")
            _ = flow.encoded(first.sequence, at: 3)
            let b = flow.takeCompleted()!
            try require(b.0.sequence == second.sequence && b.1.packet?.sequence == second.sequence,
                        "The buffered output lost submission order")
            _ = flow.encoded(second.sequence, at: 3)
            try require(!flow.complete(completed(first)) && flow.takeCompleted() == nil && flow.waiting.count == 2,
                        "A stale callback was delivered twice")
        }

        run("A dropped head releases the buffered second result without inventing an ACK") {
            var flow = predictiveFlow()
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            _ = flow.complete(completed(second))
            _ = flow.complete(completed(first, dropped: true))
            let a = flow.takeCompleted()!
            try require(a.1.packet == nil && flow.dropped(a.0.sequence), "A dropped head could not drain")
            let b = flow.takeCompleted()!
            _ = flow.encoded(b.0.sequence, at: 3)
            try require(!flow.acknowledge(first.sequence) && flow.acknowledge(second.sequence) && flow.isIdle,
                        "A drop consumed the surviving frame's acknowledgement")
        }

        run("Initial, requested and dropped IDRs remain serialized with two encoder slots") {
            var flow = VideoFrameFlow()
            let initial = flow.begin(at: 0, maximumConcurrentEncodes: 2)!
            try require(initial.forceKeyFrame && flow.begin(at: 1, maximumConcurrentEncodes: 2) == nil,
                        "Prediction was submitted before the initial IDR completed")
            _ = flow.encoded(initial.sequence, at: 1)
            _ = flow.acknowledge(initial.sequence)
            let normal = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            flow.requestKeyFrame()
            try require(flow.begin(at: 3, maximumConcurrentEncodes: 2) == nil,
                        "An explicit IDR overlapped an older encoder reservation")
            _ = flow.encoded(normal.sequence, at: 3)
            let key = flow.begin(at: 4, maximumConcurrentEncodes: 2)!
            try require(key.forceKeyFrame && flow.begin(at: 5, maximumConcurrentEncodes: 2) == nil,
                        "Prediction overtook a requested IDR")
            _ = flow.dropped(key.sequence)
            try require(flow.begin(at: 6, maximumConcurrentEncodes: 2)?.forceKeyFrame == true,
                        "A dropped IDR was replaced with a P frame")
        }

        run("Encoder failure fences both reservations and buffered results until a fresh recovery generation") {
            var flow = predictiveFlow()
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            _ = flow.complete(completed(second))
            flow.failEncoding()
            try require(flow.encodingFailed && flow.isIdle && flow.takeCompleted() == nil
                        && !flow.complete(completed(first)) && flow.begin(at: 3, maximumConcurrentEncodes: 2) == nil
                        && flow.stalled(at: 100) == nil, "A fatal generation continued producing output")
            flow.prepareMediaRecovery()
            flow.requestMediaRecoveryFrame()
            let recovery = flow.begin(at: 4, maximumConcurrentEncodes: 2)!
            try require(recovery.forceKeyFrame && flow.begin(at: 5, maximumConcurrentEncodes: 2) == nil
                        && !flow.complete(completed(second)), "Old output revived or recovery produced two frames")
            _ = flow.encoded(recovery.sequence, at: 5)
            _ = flow.acknowledge(recovery.sequence)
            try require(flow.begin(at: 6, maximumConcurrentEncodes: 2) == nil && flow.resumeMediaFrames(),
                        "An ACK crossed the recovery commit barrier")
            try require(flow.begin(at: 7, maximumConcurrentEncodes: 2) != nil
                        && flow.begin(at: 8, maximumConcurrentEncodes: 2) != nil,
                        "A committed replacement could not use its two slots")
        }

        run("Replacing an encoder during a media-held configuration preserves the fresh recovery barrier") {
            for oldStage in 0...2 {
                var flow = predictiveFlow()
                flow.prepareMediaRecovery()
                if oldStage >= 1 { flow.requestMediaRecoveryFrame() }
                if oldStage == 2 {
                    let oldRecovery = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
                    _ = flow.encoded(oldRecovery.sequence, at: 1)
                    _ = flow.acknowledge(oldRecovery.sequence)
                }
                let previousSequence = flow.sequence
                let wasMediaHeld = flow.mediaHold
                flow = VideoFrameFlow(sequence: flow.sequence)
                if wasMediaHeld { flow.prepareMediaRecovery() }
                try require(flow.mediaHold && !flow.mediaRecoveryFrameEncoded && flow.isIdle
                            && flow.sequence == previousSequence
                            && flow.begin(at: 2, maximumConcurrentEncodes: 2) == nil && !flow.resumeMediaFrames(),
                            "Configuration replacement bypassed or inherited an old recovery barrier")
                flow.requestMediaRecoveryFrame()
                let recovery = flow.begin(at: 3, maximumConcurrentEncodes: 2)!
                flow.requestMediaRecoveryFrame()
                try require(recovery.forceKeyFrame && recovery.sequence == previousSequence &+ 1
                            && flow.begin(at: 4, maximumConcurrentEncodes: 2) == nil,
                            "The replacement produced more than one recovery frame")
                _ = flow.encoded(recovery.sequence, at: 4)
                _ = flow.acknowledge(recovery.sequence)
                try require(flow.begin(at: 5, maximumConcurrentEncodes: 2) == nil && flow.resumeMediaFrames(),
                            "A replacement IDR ACK released prediction before media commit")
                try require(flow.begin(at: 6, maximumConcurrentEncodes: 2) != nil
                            && flow.begin(at: 7, maximumConcurrentEncodes: 2) != nil,
                            "Media commit did not restore the replacement's two-frame window")
            }
        }

        run("Pause boundaries and cancellation account for every encoding and buffered completion") {
            var flow = predictiveFlow()
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            _ = flow.complete(completed(second))
            try require(!flow.isIdle && flow.stalled(at: 92)?.contains("编码") == true,
                        "A later completion hid the oldest stalled encoder")
            _ = flow.complete(completed(first))
            for _ in 0..<2 {
                let next = flow.takeCompleted()!
                _ = flow.encoded(next.0.sequence, at: 3)
            }
            _ = flow.acknowledge(second.sequence)
            try require(!flow.isIdle, "A pause completed before the oldest ACK")
            _ = flow.acknowledge(first.sequence)
            try require(flow.isIdle, "The full pause boundary could not drain")
            let third = flow.begin(at: 4, maximumConcurrentEncodes: 2)!
            let fourth = flow.begin(at: 5, maximumConcurrentEncodes: 2)!
            _ = flow.complete(completed(fourth))
            flow.cancelEncoding()
            try require(flow.isIdle && flow.takeCompleted() == nil && !flow.complete(completed(third)),
                        "Cancelled reservations retained a queued completion")
        }

        run("Two in-progress encodes preserve wraparound order and ignore duplicate ACKs") {
            var flow = predictiveFlow(sequence: UInt32.max - 2)
            let first = flow.begin(at: 1, maximumConcurrentEncodes: 2)!
            let second = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            try require(first.sequence == UInt32.max && second.sequence == 0, "Parallel capture identities did not wrap")
            _ = flow.complete(completed(second)); _ = flow.complete(completed(first))
            for expected in [UInt32.max, 0] {
                let next = flow.takeCompleted()!
                try require(next.0.sequence == expected, "Numeric sorting reordered a wrapped output")
                _ = flow.encoded(next.0.sequence, at: 3)
            }
            try require(flow.acknowledge(0) && !flow.acknowledge(0) && flow.waiting[UInt32.max] != nil,
                        "A wrapped or duplicate ACK released another frame")
            _ = flow.acknowledge(UInt32.max)
            try require(flow.isIdle, "Wrapped output did not drain")
        }

        run("A concurrent capture cannot overwrite the identity of an in-progress refinement") {
            var flow = predictiveFlow()
            var refinement = StaticFrameRefinement()
            refinement.encoded(bytes: 1, keyFrame: true, budgetBytes: 100, at: 0)
            let pass = flow.begin(at: 1, maximumConcurrentEncodes: 2, isRefinement: true)!
            let capture = flow.begin(at: 2, maximumConcurrentEncodes: 2)!
            _ = flow.complete(completed(capture, dropped: true))
            _ = flow.complete(completed(pass, dropped: true))
            let first = flow.takeCompleted()!
            try require(first.0.isRefinement, "The new capture overwrote the pass identity")
            _ = flow.dropped(first.0.sequence)
            refinement.dropped(isRefinement: first.0.isRefinement, at: 3)
            let second = flow.takeCompleted()!
            try require(!second.0.isRefinement, "A capture consumed a refinement attempt")
            _ = flow.dropped(second.0.sequence)
            refinement.dropped(isRefinement: second.0.isRefinement, at: 3)
            try require(refinement.remaining == 3 && flow.isIdle, "One pass spent more than one attempt")
            _ = flow.begin(at: 4, maximumConcurrentEncodes: 2)
            try require(flow.begin(at: 5, maximumConcurrentEncodes: 2, isRefinement: true) == nil,
                        "A refinement competed with a busy capture encoder")
        }

        run("Three outstanding frames fill the credit window and encoding also reserves a credit") {
            var flow = VideoFrameFlow()
            var sent: [UInt32] = []
            for index in 0..<3 {
                guard let frame = flow.begin(at: Double(index)) else { throw VideoCheckFailure("The window stopped before three frames") }
                try require(flow.begin(at: Double(index)) == nil, "More than one encoding operation was submitted")
                _ = flow.encoded(frame.sequence, at: Double(index))
                sent.append(frame.sequence)
            }
            try require(flow.waiting.count == 3 && flow.begin(at: 3) == nil, "The window exceeded its three-frame bound")
            _ = flow.acknowledge(sent[1])
            let fourth = flow.begin(at: 4)
            try require(fourth != nil && flow.waiting.count == 2, "A released credit did not allow another frame")
            try require(flow.begin(at: 4) == nil, "An encoding frame was not counted against the window")
            _ = flow.encoded(fourth!.sequence, at: 4)
            try require(flow.waiting.count == 3 && flow.begin(at: 5) == nil, "An encoded replacement overfilled the window")
        }

        run("Out-of-order and duplicate acknowledgements release only their own credit") {
            var flow = VideoFrameFlow()
            var sent: [UInt32] = []
            for index in 0..<3 {
                let frame = flow.begin(at: Double(index))!
                _ = flow.encoded(frame.sequence, at: Double(index))
                sent.append(frame.sequence)
            }
            try require(!flow.acknowledge(sent[2] &+ 1) && flow.waiting.count == 3, "An unknown ack released a credit")
            try require(flow.acknowledge(sent[2]) && flow.waiting.count == 2, "An out-of-order ack was ignored")
            try require(!flow.acknowledge(sent[2]) && flow.waiting.count == 2, "A duplicate ack released a second credit")
            try require(!flow.isIdle, "A partial acknowledgement drained the frame boundary")
            _ = flow.acknowledge(sent[0])
            try require(!flow.isIdle, "The boundary ignored the remaining older frame")
            _ = flow.acknowledge(sent[1])
            try require(flow.isIdle, "All acknowledged frames did not drain the boundary")
        }

        run("A keyframe or a large frame earns four refinement passes once the screen stays still") {
            var refinement = StaticFrameRefinement()
            refinement.encoded(bytes: 10_000, keyFrame: false, budgetBytes: 100_000, at: 0)
            try require(refinement.remaining == 0 && refinement.dueAt == nil && !refinement.isDue(at: 10),
                        "A small change asked for refinement on its own")
            refinement.encoded(bytes: 900_000, keyFrame: true, budgetBytes: 100_000, at: 1)
            try require(refinement.remaining == 4 && !refinement.isDue(at: 1.2) && refinement.isDue(at: 1.25),
                        "A keyframe was not refined a quarter second after the screen went still")
            var time = 1.25
            for (index, gap) in [0.25, 0.5, 1].enumerated() {
                refinement.wait()
                try require(!refinement.isDue(at: time + 5), "A pass handed to the encoder was scheduled again before its output")
                refinement.refined(at: time)
                try require(refinement.remaining == 3 - index && !refinement.isDue(at: time + gap - 0.01)
                            && refinement.isDue(at: time + gap), "Refinement passes did not slow down after each output")
                time += gap
            }
            refinement.wait()
            refinement.refined(at: time)
            try require(refinement.remaining == 0 && refinement.dueAt == nil, "Refinement continued past four passes")
            refinement.encoded(bytes: 50_000, keyFrame: false, budgetBytes: 100_000, at: time + 1)
            try require(refinement.remaining == 4, "A frame using half its budget did not earn new passes")
        }

        run("New frames postpone refinement, small changes keep the passes left and cancellation clears them") {
            var refinement = StaticFrameRefinement()
            refinement.encoded(bytes: 300_000, keyFrame: false, budgetBytes: 100_000, at: 0)
            refinement.wait()
            refinement.refined(at: 0.25)
            try require(refinement.remaining == 3, "The first pass was not counted")
            refinement.wait()
            try require(!refinement.isDue(at: 100), "A captured frame did not postpone the pending pass")
            refinement.encoded(bytes: 2_000, keyFrame: false, budgetBytes: 100_000, at: 0.3)
            try require(refinement.remaining == 3 && !refinement.isDue(at: 0.5) && refinement.isDue(at: 0.55),
                        "A small change reset or dropped the remaining passes instead of waiting for stillness")
            refinement.cancel()
            try require(refinement.remaining == 0 && refinement.dueAt == nil && !refinement.isDue(at: 100),
                        "Cancellation left a refinement pass scheduled")
            refinement.encoded(bytes: 0, keyFrame: true, budgetBytes: 0, at: .nan)
            try require(refinement.remaining == 4 && refinement.dueAt == nil, "An invalid clock reading scheduled a pass")
        }

        run("Dropping the last captured frame preserves and reschedules only the remaining refinement attempts") {
            var flow = VideoFrameFlow()
            var refinement = StaticFrameRefinement()
            let first = flow.begin(at: 0)!
            _ = flow.encoded(first.sequence, at: 0)
            refinement.encoded(bytes: 300_000, keyFrame: true, budgetBytes: 100_000, at: 0)
            _ = flow.acknowledge(first.sequence)
            refinement.wait()
            let capture = flow.begin(at: 0.1)!
            try require(flow.dropped(capture.sequence), "The captured frame did not release its encoding credit")
            refinement.dropped(isRefinement: false, at: 0.2)
            try require(flow.isIdle && refinement.remaining == 4 && !refinement.isDue(at: 0.4)
                        && refinement.isDue(at: 0.45), "The last captured frame's drop stranded or consumed refinement")

            var now = 0.45
            for remaining in stride(from: 3, through: 0, by: -1) {
                refinement.wait()
                let pass = flow.begin(at: now)!
                try require(flow.dropped(pass.sequence), "A dropped refinement retained its encoding credit")
                refinement.dropped(isRefinement: true, at: now)
                try require(refinement.remaining == remaining, "A dropped refinement failed to consume one attempt")
                if let next = refinement.dueAt { now = next }
            }
            try require(flow.isIdle && refinement.dueAt == nil, "Repeated drops created unbounded retries")
            refinement.dropped(isRefinement: false, at: 10)
            try require(refinement.remaining == 0 && refinement.dueAt == nil, "A normal drop invented new attempts")
        }

        run("A capture arriving during refinement can be dropped without losing the remaining passes") {
            var flow = VideoFrameFlow()
            var refinement = StaticFrameRefinement()
            refinement.encoded(bytes: 300_000, keyFrame: true, budgetBytes: 100_000, at: 0)
            refinement.wait()
            let pass = flow.begin(at: 0.25)!
            // A new capture replaces the retained picture while the pass is still encoding.
            refinement.wait()
            try require(flow.begin(at: 0.3) == nil, "The new capture overlapped the active encoder")
            _ = flow.encoded(pass.sequence, at: 0.35)
            refinement.refined(at: 0.35)
            let capture = flow.begin(at: 0.35)!
            _ = flow.acknowledge(pass.sequence)
            _ = flow.dropped(capture.sequence)
            refinement.dropped(isRefinement: false, at: 0.4)
            try require(flow.isIdle && refinement.remaining == 3 && !refinement.isDue(at: 0.6)
                        && refinement.isDue(at: 0.65), "A replacement capture lost or replenished remaining passes")
            refinement.cancel()
            refinement.dropped(isRefinement: false, at: 0.5)
            try require(refinement.remaining == 0 && refinement.dueAt == nil, "A cancelled refinement restarted on drop")
        }

        run("An overdue refinement survives a media hold without spending an attempt") {
            var flow = VideoFrameFlow()
            var refinement = StaticFrameRefinement()
            flow.prepareMediaRecovery()
            flow.requestMediaRecoveryFrame()
            let recovery = flow.begin(at: 0)!
            _ = flow.encoded(recovery.sequence, at: 0)
            refinement.encoded(bytes: 300_000, keyFrame: true, budgetBytes: 100_000, at: 0)
            _ = flow.acknowledge(recovery.sequence)
            try require(refinement.isDue(at: 1) && flow.begin(at: 1) == nil && refinement.remaining == 4,
                        "A hold either lost an overdue pass or let it start")
            try require(flow.resumeMediaFrames() && refinement.isDue(at: 2), "Resume lost the expired deadline")
            refinement.wait()
            let pass = flow.begin(at: 2)!
            _ = flow.encoded(pass.sequence, at: 2)
            refinement.refined(at: 2)
            try require(refinement.remaining == 3 && refinement.isDue(at: 2.25), "Resume spent more than one pass")
        }

        run("A reconfiguration or pause boundary waits for both all acknowledgements and encoding") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            _ = flow.encoded(first.sequence, at: 0)
            let second = flow.begin(at: 1)!
            _ = flow.acknowledge(first.sequence)
            try require(!flow.isIdle, "The boundary resumed while a frame was still encoding")
            _ = flow.dropped(second.sequence)
            try require(flow.isIdle, "A dropped final frame prevented the boundary from draining")
            flow.requestKeyFrame()
            try require(flow.begin(at: 2)?.forceKeyFrame == true, "Resume did not preserve its mandatory keyframe")
        }

        run("A drop returns the encoding credit without releasing older in-flight frames") {
            var flow = VideoFrameFlow()
            for index in 0..<2 {
                let frame = flow.begin(at: Double(index))!
                _ = flow.encoded(frame.sequence, at: Double(index))
            }
            let dropped = flow.begin(at: 2)!
            _ = flow.dropped(dropped.sequence)
            try require(flow.waiting.count == 2 && !flow.isIdle, "A drop released an unrelated frame or drained the boundary")
            try require(!flow.acknowledge(dropped.sequence), "A dropped frame incorrectly required an ack")
            try require(flow.begin(at: 3) != nil, "A dropped frame consumed its credit permanently")
        }

        run("New frames and acknowledgements cannot hide the oldest missing acknowledgement") {
            var flow = VideoFrameFlow()
            let first = flow.begin(at: 0)!
            _ = flow.encoded(first.sequence, at: 0)
            let second = flow.begin(at: 30)!
            _ = flow.encoded(second.sequence, at: 30)
            let third = flow.begin(at: 60)!
            _ = flow.encoded(third.sequence, at: 60)
            _ = flow.acknowledge(second.sequence)
            _ = flow.acknowledge(third.sequence)
            try require(flow.stalled(at: 91)?.contains("确认") == true, "Recent frames extended an older frame's timeout")
            _ = flow.acknowledge(first.sequence)
            try require(flow.stalled(at: 91) == nil, "An acknowledged frame remained in the watchdog")
        }

        run("The credit window and per-frame acknowledgements survive sequence wraparound") {
            var flow = VideoFrameFlow(sequence: UInt32.max - 1)
            var sent: [UInt32] = []
            for index in 0..<3 {
                let frame = flow.begin(at: Double(index))!
                _ = flow.encoded(frame.sequence, at: Double(index))
                sent.append(frame.sequence)
            }
            try require(sent == [UInt32.max, 0, 1], "Frame sequence did not wrap without trapping")
            try require(flow.acknowledge(0) && !flow.acknowledge(0), "A wrapped sequence was ignored or acknowledged twice")
            _ = flow.acknowledge(UInt32.max)
            try require(!flow.isIdle && flow.waiting[1] != nil, "A pre-wrap acknowledgement released a post-wrap frame")
            _ = flow.acknowledge(1)
            try require(flow.isIdle, "Wrapped frames did not drain")
        }

        run("Media recovery clears lost credits immediately while preserving the capture sequence") {
            var flow = VideoFrameFlow()
            for index in 0..<3 {
                let frame = flow.begin(at: Double(index))!
                _ = flow.encoded(frame.sequence, at: Double(index))
            }
            let lastSequence = flow.sequence
            flow.prepareMediaRecovery()
            try require(flow.isIdle && flow.mediaHold && flow.sequence == lastSequence && flow.stalled(at: 1_000) == nil,
                        "Recovery waited for a missing acknowledgement or reset capture identity")
            try require(flow.begin(at: 4) == nil && !flow.resumeMediaFrames(), "Prepare allowed P frames before its recovery IDR")
            flow.requestMediaRecoveryFrame()
            let recovery = flow.begin(at: 5)!
            try require(recovery.sequence == lastSequence + 1 && recovery.forceKeyFrame, "Recovery did not reserve a new forced keyframe")
        }

        run("Media hold produces one recovery output and cannot release prediction before commit") {
            var flow = VideoFrameFlow()
            flow.prepareMediaRecovery()
            flow.requestMediaRecoveryFrame()
            let recovery = flow.begin(at: 0)!
            _ = flow.encoded(recovery.sequence, at: 0)
            _ = flow.acknowledge(recovery.sequence)
            flow.requestMediaRecoveryFrame()
            try require(flow.mediaRecoveryFrameEncoded && flow.begin(at: 1) == nil,
                        "Repeated produce or an ACK released another frame while awaiting commit")
            try require(flow.resumeMediaFrames(), "A completed recovery could not commit")
            try require(flow.begin(at: 2)?.forceKeyFrame == false, "Commit did not resume the new encoder prediction chain")
        }

        run("Old media callbacks cannot release new encoding and dropped recovery output stays an IDR") {
            var flow = VideoFrameFlow(sequence: UInt32.max - 1)
            let old = flow.begin(at: 0)!
            flow.prepareMediaRecovery()
            flow.requestMediaRecoveryFrame()
            let recovery = flow.begin(at: 1)!
            try require(recovery.sequence == 0 && !flow.encoded(old.sequence, at: 2)
                        && !flow.dropped(old.sequence) && !flow.acknowledge(old.sequence)
                        && flow.encoding.first?.sequence == recovery.sequence, "An old callback changed the replacement frame")
            _ = flow.dropped(recovery.sequence)
            let retry = flow.begin(at: 3)
            try require(retry?.forceKeyFrame == true && !flow.mediaRecoveryFrameEncoded,
                        "A rate-control drop left recovery stuck or released a P frame")
            flow.prepareMediaRecovery()
            try require(flow.begin(at: 4) == nil && !flow.resumeMediaFrames(), "Abort reused the candidate reference chain")
        }

        run("Encode duration is independent of diagnostics and matches one encoder generation and sequence") {
            var timing = VideoEncodeTiming()
            let old = UUID(), replacement = UUID()
            timing.begin(encoderID: old, sequence: UInt32.max, at: 10)
            timing.cancel()
            timing.begin(encoderID: replacement, sequence: 0, at: 20)
            try require(timing.complete(encoderID: old, sequence: UInt32.max, at: 21) == nil,
                        "Old generation produced a new-session duration")
            timing.cancel(encoderID: old)
            try require(timing.complete(encoderID: replacement, sequence: 1, at: 21) == nil,
                        "Wrong capture sequence consumed the active timing")
            let duration = timing.complete(encoderID: replacement, sequence: 0, at: 20.025)
            try require(duration.map({ abs($0 - 0.025) < 0.000_001 }) == true,
                        "Duration included queueing after its callback or an unrelated frame")
            try require(timing.complete(encoderID: replacement, sequence: 0, at: 21) == nil,
                        "Duplicate output reported duration twice")
        }

        run("Encode duration cancellation and invalid clock readings cannot leave a stale sample") {
            var timing = VideoEncodeTiming()
            let id = UUID()
            timing.begin(encoderID: id, sequence: 1, at: 10)
            try require(timing.complete(encoderID: id, sequence: 1, at: 9) == nil,
                        "A backwards clock produced negative duration")
            try require(timing.complete(encoderID: id, sequence: 1, at: 11) == nil,
                        "An invalid completion kept a stale timing slot")
            timing.begin(encoderID: id, sequence: 2, at: 10)
            try require(timing.complete(encoderID: id, sequence: 2, at: .infinity) == nil,
                        "An infinite duration escaped validation")
            timing.begin(encoderID: id, sequence: 3, at: .nan)
            try require(timing.complete(encoderID: id, sequence: 3, at: 11) == nil,
                        "An invalid start time produced a duration")
            timing.begin(encoderID: id, sequence: 4, at: 10)
            timing.cancel(encoderID: id)
            try require(timing.complete(encoderID: id, sequence: 4, at: 11) == nil,
                        "Stopped encoder still produced a duration")
        }

        run("Overlapping encode timing preserves total latency but excludes previous-frame queueing from adaptation") {
            var timing = VideoEncodeTiming()
            let id = UUID()
            try require(timing.begin(encoderID: id, sequence: 1, at: 0)
                        && timing.begin(encoderID: id, sequence: 2, at: 0.01)
                        && !timing.begin(encoderID: id, sequence: 3, at: 0.012)
                        && !timing.begin(encoderID: id, sequence: 1, at: 0.013),
                        "Timing reservations overwrote or exceeded two pending frames")
            let second = timing.complete(encoderID: id, sequence: 2, at: 0.03)!
            let first = timing.complete(encoderID: id, sequence: 1, at: 0.02)!
            try require(abs(first - 0.02) < 0.000_001 && abs(second - 0.02) < 0.000_001,
                        "Per-frame total latency was lost by another frame's callback")
            let firstService = timing.serviceDuration(encoderID: id, latency: first, completedAt: 0.02)!
            let secondService = timing.serviceDuration(encoderID: id, latency: second, completedAt: 0.03)!
            try require(abs(firstService - 0.02) < 0.000_001 && abs(secondService - 0.01) < 0.000_001,
                        "Adaptive encode pressure double-counted the previous frame's work")
            try require(timing.serviceDuration(encoderID: id, latency: 0.005, completedAt: 10.005).map { abs($0 - 0.005) < 0.000_001 } == true,
                        "Idle time became codec pressure")
            let replacement = UUID()
            timing.cancel(); timing.begin(encoderID: replacement, sequence: 1, at: 20)
            timing.cancel(encoderID: id)
            try require(timing.complete(encoderID: id, sequence: 1, at: 20.01) == nil
                        && timing.serviceDuration(encoderID: id, latency: 1, completedAt: 21) == nil
                        && timing.complete(encoderID: replacement, sequence: 1, at: 20) == 0,
                        "A stale generation consumed the replacement's synchronous completion")
        }

        run("One encoder timeline minimally advances repeated or late capture timestamps after a replay") {
            var timeline = VideoPresentationTimeline()
            let id = UUID(), replacement = UUID()
            let original = CMTime(value: 120, timescale: 60)
            let first = try timeline.next(encoderID: id, time: original)
            let repeated = try timeline.next(encoderID: id, time: original)
            let late = try timeline.next(encoderID: id, time: CMTime(value: 119, timescale: 60))
            try require(CMTimeCompare(first, original) == 0
                        && abs(CMTimeGetSeconds(CMTimeSubtract(repeated, first)) - 0.000_001) < 0.000_000_1
                        && abs(CMTimeGetSeconds(CMTimeSubtract(late, repeated)) - 0.000_001) < 0.000_000_1,
                        "A replay made timestamps duplicate or introduced a whole synthetic frame interval")
            let fresh = CMTime(value: 121, timescale: 60)
            let acceptedFresh = try timeline.next(encoderID: id, time: fresh)
            try require(CMTimeCompare(acceptedFresh, fresh) == 0,
                        "A newer SCK timestamp was unnecessarily changed")
            let restarted = try timeline.next(encoderID: replacement, time: .zero)
            try require(CMTimeCompare(restarted, .zero) == 0, "The replacement encoder inherited an old PTS watermark")
            for invalid in [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity] {
                do {
                    _ = try timeline.next(encoderID: replacement, time: invalid)
                    throw VideoCheckFailure("An invalid timestamp was silently invented")
                } catch is DeskError {}
            }
            let validAfterFailure = try timeline.next(encoderID: replacement, time: CMTime(value: 1, timescale: 60))
            try require(CMTimeCompare(validAfterFailure, CMTime(value: 1, timescale: 60)) == 0,
                        "Invalid PTS corrupted the following valid submission")
        }

        run("High-refresh capture reserves five bounded buffers while lower rates retain three") {
            for rate in StreamSettings.frameRates {
                let configuration = ScreenStreamer.configuration(width: 3024, height: 1964,
                    settings: StreamSettings(longestEdge: 8192, framesPerSecond: rate, megabits: 100))
                try require(configuration.width == 3024 && configuration.height == 1964
                            && configuration.queueDepth == (rate >= 60 ? 5 : 3),
                            "The high-refresh buffer budget changed native size or the lower-rate default")
            }
        }

        run("Screen capture configuration carries each higher rate without a hidden 60 fps clamp") {
            for rate in [75, 90, 120, 144, 165, 240] {
                let settings = StreamSettings(framesPerSecond: rate)
                let configuration = ScreenStreamer.configuration(width: 1920, height: 1080, settings: settings)
                try require(CMTimeCompare(configuration.minimumFrameInterval, CMTime(value: 1, timescale: Int32(rate))) == 0,
                            "Screen capture did not receive \(rate) fps")
            }
        }

        run("Cursor capture keeps the old default and each explicit configuration inherits its selected mode") {
            let settings = StreamSettings(framesPerSecond: 60, megabits: 12)
            let original = ScreenStreamer.configuration(width: 1920, height: 1080, settings: settings)
            let separate = ScreenStreamer.configuration(width: 1920, height: 1080, settings: settings, includesCursor: false)
            let restored = ScreenStreamer.configuration(width: 1280, height: 720, settings: settings, includesCursor: true)
            try require(original.showsCursor && !separate.showsCursor && restored.showsCursor,
                        "Cursor configuration changed the legacy default or ignored its session mode")
            let streamer = ScreenStreamer()
            try require(streamer.currentCursorIncluded == nil && streamer.targetCursorIncluded == nil,
                        "An unstarted stream claimed an actual cursor capture mode")
            let onQueue = streamer.queue.sync { (streamer.currentCursorIncluded, streamer.targetCursorIncluded) }
            try require(onQueue.0 == nil && onQueue.1 == nil, "Reading cursor state from the capture queue was not reentrant")
        }

        run("Cursor freshness blocks old and in-flight samples until configuration acknowledgement") {
            var gate = CursorCaptureGate()
            let original = try cursorSample(CMTime(value: 10, timescale: 60))
            try require(gate.included && gate.observe(original, displayTime: nil).retain,
                        "Legacy sampling unexpectedly required cursor metadata")
            let request = gate.request(included: false)
            let inFlight = try cursorSample(CMTime(value: 20, timescale: 60))
            try require(!gate.observe(inFlight, displayTime: 150).retain && gate.needsFreshFrame,
                        "An in-flight sample was retained before SCK configuration completed")
            try require(gate.arm(id: request, afterDisplayTime: 200, width: 64, height: 64), "Fresh cursor gate could not arm")
            try require(!gate.observe(original, displayTime: 201).retain, "A sample below the SCK PTS watermark was reused")
            let next = try cursorSample(CMTime(value: 21, timescale: 60))
            try require(!gate.observe(next, displayTime: 199).retain && !gate.observe(next, displayTime: 200).retain,
                        "A frame displayed before the configuration barrier was accepted")
            let fresh = try cursorSample(CMTime(value: 22, timescale: 60))
            let accepted = gate.observe(fresh, displayTime: 201)
            try require(accepted.retain && accepted.completed == request && !gate.needsFreshFrame && !gate.included,
                        "A verified post-configuration sample did not complete its generation")
            try require(gate.observe(fresh, displayTime: 201).completed == nil, "The same fresh-frame request completed twice")
            try require(!gate.cancel(id: request), "A late timeout consumed an already completed cursor generation")
        }

        run("Cursor freshness fails closed on missing timestamps, invalid PTS and wrong dimensions") {
            var gate = CursorCaptureGate()
            let request = gate.request(included: false)
            _ = gate.arm(id: request, afterDisplayTime: 100, width: 64, height: 64)
            let valid = try cursorSample(CMTime(value: 10, timescale: 60))
            let wrongSize = try cursorSample(CMTime(value: 11, timescale: 60), width: 128)
            let invalidTime = try cursorSample(.invalid)
            try require(!gate.observe(valid, displayTime: nil).retain, "A missing display timestamp was guessed to be fresh")
            try require(!gate.observe(wrongSize, displayTime: 101).retain, "Old-size output crossed a configuration fence")
            try require(!gate.observe(invalidTime, displayTime: 102).retain && gate.needsFreshFrame,
                        "A nonnumeric timestamp released the capture pump")
            try require(gate.cancel(id: request) && !gate.cancel(id: request), "Timeout/cancel could consume one request twice")
            try require(!gate.observe(valid, displayTime: 103).retain, "A late frame revived a canceled cursor request")
        }

        run("Paused cursor changes defer freshness and rollback also requires a new captured frame") {
            var gate = CursorCaptureGate()
            let deferred = gate.request(included: false)
            let old = try cursorSample(CMTime(value: 10, timescale: 60))
            try require(!gate.configurationApplied && !gate.observe(old, displayTime: 100).retain,
                        "A paused target was treated as an applied cursor mode")
            _ = gate.arm(id: deferred, afterDisplayTime: 200, width: 64, height: 64)
            let new = try cursorSample(CMTime(value: 11, timescale: 60))
            try require(gate.observe(new, displayTime: 201).completed == deferred, "Resume did not require a post-configuration frame")
            let rollback = gate.request(included: true)
            _ = gate.arm(id: rollback, afterDisplayTime: 300, width: 64, height: 64)
            try require(!gate.observe(new, displayTime: 301).retain, "Rollback reused the previous cursor mode's retained frame")
            let restored = try cursorSample(CMTime(value: 12, timescale: 60))
            try require(gate.observe(restored, displayTime: 302).completed == rollback && gate.included,
                        "Rollback could not verify a fresh frame with its restored mode")
        }

        run("Cursor request replacement fences old completions and stop resets the capture gate") {
            var gate = CursorCaptureGate()
            let old = gate.request(included: false)
            _ = gate.arm(id: old, afterDisplayTime: 100, width: 64, height: 64)
            let replacement = gate.request(included: true)
            try require(!gate.arm(id: old, afterDisplayTime: 200, width: 64, height: 64)
                        && !gate.cancel(id: old) && gate.requestID == replacement,
                        "An old SCK callback changed the replacement request")
            _ = gate.arm(id: replacement, afterDisplayTime: 200, width: 64, height: 64)
            let fresh = try cursorSample(CMTime(value: 2, timescale: 60))
            try require(gate.observe(fresh, displayTime: 201).completed == replacement,
                        "The replacement cursor request did not complete once")
            gate = CursorCaptureGate()
            try require(gate.included && !gate.needsFreshFrame && gate.requestID == nil,
                        "Stopped capture retained a cursor generation or changed the next session default")
        }

        run("Fresh encoders produce real IDR frames when replaying the same retained pixel buffer") {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else { throw VideoCheckFailure("Could not create an offline video buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                    memset(base, plane == 0 ? 16 : 128,
                           CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            for sequence: UInt32 in [UInt32.max, 0] {
                let output = EncodedRecoveryPacket()
                let done = DispatchSemaphore(value: 0)
                let encoderID = UUID()
                let encoder = try VideoEncoder(width: 64, height: 64, settings: StreamSettings(framesPerSecond: 60, megabits: 3))
                encoder.onOutput = { result in output.set(result, encoderID: encoderID); done.signal() }
                encoder.onDropped = { _ in done.signal() }
                defer { encoder.stop() }
                output.begin(encoderID: encoderID, sequence: sequence)
                try encoder.encode(pixelBuffer, time: CMTime(value: 1, timescale: 60), sequence: sequence, forceKeyFrame: true)
                guard done.wait(timeout: .now() + 10) == .success else {
                    throw VideoCheckFailure("Fresh encoder did not output the retained recovery frame")
                }
                encoder.stop()
                let observation = output.get()
                guard let result = observation.result else { throw VideoCheckFailure("Native recovery frame was dropped") }
                let packet = try result.get()
                let idr = try MediaFrame.containsIDR(packet.avcc)
                try require(idr && !packet.sps.isEmpty && !packet.pps.isEmpty && packet.sequence == sequence,
                            "Recovery output was not a real IDR with its original capture identity")
                try require(observation.callbacks == 1 && observation.duration.map({ $0.isFinite && $0 >= 0 }) == true,
                            "Native output was counted twice or did not produce a finite independent duration")
            }
        }

        run("Two native submissions preserve H264 order and decode across a live bitrate change") {
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw VideoCheckFailure("Could not create immutable native test pixels") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                    memset(base, plane == 0 ? 64 : 128,
                           CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            final class Outputs: @unchecked Sendable {
                private let lock = NSLock()
                private var sequences: [UInt32] = [], packets: [VideoPacket] = []
                private var errors = 0
                func encoded(_ result: Result<VideoPacket, Error>) {
                    lock.withLock {
                        if case .success(let packet) = result { sequences.append(packet.sequence); packets.append(packet) }
                        else { errors += 1 }
                    }
                }
                func dropped(_ sequence: UInt32) { lock.withLock { sequences.append(sequence) } }
                func decoded(_ result: Result<CVPixelBuffer, Error>) {
                    lock.withLock {
                        if case .success(let image) = result, CVPixelBufferGetWidth(image) == 64, CVPixelBufferGetHeight(image) == 64 {} else { errors += 1 }
                    }
                }
                var snapshot: ([UInt32], [VideoPacket], Int) { lock.withLock { (sequences, packets, errors) } }
            }
            let outputs = Outputs(), done = DispatchSemaphore(value: 0)
            let encoder = try VideoEncoder(width: 64, height: 64, settings: StreamSettings(framesPerSecond: 60, megabits: 20))
            encoder.onOutput = { outputs.encoded($0); done.signal() }
            encoder.onDropped = { outputs.dropped($0); done.signal() }
            defer { encoder.stop() }
            try encoder.encode(pixelBuffer, time: CMTime(value: 1, timescale: 60), sequence: 1, forceKeyFrame: true)
            try require(done.wait(timeout: .now() + 10) == .success, "Initial native keyframe did not complete")
            for first: UInt32 in [2, 4] {
                try encoder.encode(pixelBuffer, time: CMTime(value: Int64(first), timescale: 60), sequence: first)
                if first == 2 { try encoder.updateBitrate(megabits: 4) }
                try encoder.encode(pixelBuffer, time: CMTime(value: Int64(first + 1), timescale: 60), sequence: first + 1)
                for _ in 0..<2 { try require(done.wait(timeout: .now() + 10) == .success, "An overlapping native submission did not terminate") }
            }
            let (sequences, packets, errors) = outputs.snapshot
            try require(errors == 0 && sequences == [1, 2, 3, 4, 5] && packets.count >= 2 && packets.first?.sequence == 1,
                        "Native overlapping callbacks lost order, keyframe or completion identity")
            let firstIDR = try MediaFrame.containsIDR(packets[0].avcc)
            try require(firstIDR, "Native first output was not an IDR")
            for packet in packets.dropFirst() {
                let isIDR = try MediaFrame.containsIDR(packet.avcc)
                try require(!isIDR, "Overlapping bitrate update restarted the reference chain")
            }
            let decoder = VideoDecoder()
            for packet in packets {
                decoder.decode(packet) { outputs.decoded($0); done.signal() }
                try require(done.wait(timeout: .now() + 10) == .success, "The overlapping reference chain did not decode")
            }
            try require(outputs.snapshot.2 == 0, "Overlapping native frames did not decode at their original size")
        }

        run("Changing a running encoder's bitrate keeps its reference chain without a new keyframe") {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else { throw VideoCheckFailure("Could not create an offline video buffer") }
            final class Outputs: @unchecked Sendable {
                private let lock = NSLock(); private var values: [Bool] = []; private var errors = 0
                func add(_ result: Result<VideoPacket, Error>) {
                    lock.withLock {
                        if case .success(let packet) = result, let idr = try? MediaFrame.containsIDR(packet.avcc) { values.append(idr) }
                        else { errors += 1 }
                    }
                }
                var snapshot: ([Bool], Int) { lock.withLock { (values, errors) } }
            }
            let outputs = Outputs(), done = DispatchSemaphore(value: 0)
            let encoder = try VideoEncoder(width: 64, height: 64, settings: StreamSettings(framesPerSecond: 60, megabits: 20))
            encoder.onOutput = { outputs.add($0); done.signal() }
            encoder.onDropped = { _ in done.signal() }
            defer { encoder.stop() }
            for index in 1...6 {
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                    if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                        memset(base, Int32(plane == 0 ? 16 + index * 20 : 128),
                               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                if index == 3 { try encoder.updateBitrate(megabits: 4) }
                try encoder.encode(pixelBuffer, time: CMTime(value: Int64(index), timescale: 60), sequence: UInt32(index), forceKeyFrame: index == 1)
                guard done.wait(timeout: .now() + 10) == .success else { throw VideoCheckFailure("Encoder produced no output") }
            }
            let (frames, errors) = outputs.snapshot
            try require(errors == 0 && frames.first == true && frames.count >= 4 && !frames.dropFirst().contains(true),
                        "A live bitrate change failed or forced a keyframe: \(frames), errors \(errors)")
        }

        print("Video pipeline checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
