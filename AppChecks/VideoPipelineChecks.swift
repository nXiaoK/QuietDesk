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

        print("Video pipeline checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
