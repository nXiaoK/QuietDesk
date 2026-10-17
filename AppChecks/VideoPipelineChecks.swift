import AppKit
import VideoToolbox
@testable import QuietDeskCore

private struct VideoCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VideoCheckFailure(message) }
}

@main
private struct VideoPipelineChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
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
            try require(!flow.dropped(first.sequence &+ 1) && flow.encoding == first.sequence,
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

        print("Video pipeline checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
