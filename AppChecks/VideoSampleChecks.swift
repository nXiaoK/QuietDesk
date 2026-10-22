import Foundation
import VideoToolbox
@testable import QuietDeskCore

private struct SampleCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SampleCheckFailure(message) }
}

private func bytes(in block: CMBlockBuffer) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    let status = bytes.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    try require(status == noErr, "Reading retained bytes failed: \(status)")
    return bytes
}

private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value { lock.withLock { value } }
}

private func encodedPackets(framesPerSecond: Int = 15) throws -> [VideoPacket] {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw SampleCheckFailure("Creating synthetic pixels failed: \(status)") }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        if let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
            memset(address, plane == 0 ? 64 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let encoder = try VideoEncoder(width: 320, height: 180, settings: .init(framesPerSecond: framesPerSecond))
    defer { encoder.stop() }
    let ready = DispatchSemaphore(value: 0)
    let result = ResultBox<Result<VideoPacket, Error>?>(nil)
    encoder.onOutput = { result.set($0); ready.signal() }
    encoder.onDropped = { _ in
        result.set(.failure(SampleCheckFailure("Synthetic frame was dropped")))
        ready.signal()
    }
    var packets: [VideoPacket] = []
    for sequence in UInt32(1)...2 {
        try encoder.encode(buffer, time: CMTime(value: Int64(sequence), timescale: Int32(framesPerSecond)),
                           sequence: sequence, forceKeyFrame: sequence == 1)
        try require(ready.wait(timeout: .now() + 10) == .success, "Synthetic encoder did not finish")
        guard let output = result.get() else { throw SampleCheckFailure("No synthetic output") }
        packets.append(try VideoPacket.decode(output.get().encode()))
    }
    return packets
}

@main
private struct VideoSampleChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Higher-rate VideoToolbox configurations encode and decode synthetic frames") {
            for rate in [75, 90, 120, 144, 165, 240] {
                let packets = try encodedPackets(framesPerSecond: rate)
                let decoder = VideoDecoder()
                defer { decoder.stop() }
                for packet in packets {
                    let ready = DispatchSemaphore(value: 0)
                    let decoded = ResultBox(false)
                    decoder.decode(packet) { result in
                        if case .success(let frame) = result {
                            decoded.set(CVPixelBufferGetWidth(frame) == 320 && CVPixelBufferGetHeight(frame) == 180)
                        }
                        ready.signal()
                    }
                    try require(ready.wait(timeout: .now() + 10) == .success && decoded.get(),
                                "Synthetic encode/decode failed at \(rate) fps")
                }
            }
        }

        run("CoreMedia directly references immutable storage and releases its owner with the block") {
            var block: CMBlockBuffer?
            weak var observed: NSData?
            try autoreleasepool {
                var source: NSData? = NSData(data: Data(repeating: 0x7b, count: 4096))
                observed = source
                block = try VideoSamples.block(for: source!)
                var pointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(block!, atOffset: 0, lengthAtOffsetOut: nil,
                    totalLengthOut: nil, dataPointerOut: &pointer)
                try require(status == noErr && UnsafeRawPointer(pointer) == source!.bytes,
                            "CoreMedia copied the immutable storage again")
                source = nil
            }
            try require(observed != nil, "The block lost its backing object")
            try require(try bytes(in: block!) == [UInt8](repeating: 0x7b, count: 4096), "Retained backing bytes changed")
            block = nil
            try require(observed == nil, "The custom free callback leaked its backing object")
        }

        run("Small, large and sliced Data remain stable after their source changes and leaves scope") {
            for count in [1, 6, 15, 16, 4096, 262144] {
                let expected = (0..<count).map { UInt8(truncatingIfNeeded: $0) }
                let block: CMBlockBuffer = try autoreleasepool {
                    var source = Data(repeating: 0xff, count: 9)
                    source.append(contentsOf: expected)
                    var slice = source.dropFirst(9)
                    let block = try VideoSamples.block(for: slice as NSData)
                    source.resetBytes(in: source.startIndex..<source.endIndex)
                    slice.resetBytes(in: slice.startIndex..<slice.endIndex)
                    return block
                }
                try require(try bytes(in: block) == expected, "Source mutation changed a \(count)-byte block")
            }
        }

        run("Mutable NSData is snapshotted before its bytes are exposed to CoreMedia") {
            let expected: [UInt8] = [0, 0, 0, 2, 0x65, 0x88]
            let block: CMBlockBuffer = try autoreleasepool {
                let source = NSMutableData(data: Data(expected))
                let block = try VideoSamples.block(for: source)
                source.resetBytes(in: NSRange(location: 0, length: source.length))
                return block
            }
            try require(try bytes(in: block) == expected, "Mutable NSData changed compressed bytes after submission")
        }

        run("Failed CoreMedia allocation and empty input release their storage without a leak") {
            weak var observed: NSData?
            try autoreleasepool {
                var source: NSData? = NSData(data: Data(repeating: 0xa5, count: 4096))
                observed = source
                var rejected = false
                do { _ = try VideoSamples.block(for: source!, allocator: kCFAllocatorNull) }
                catch { rejected = true }
                try require(rejected, "A null structure allocator unexpectedly succeeded")
                source = nil
            }
            try require(observed == nil, "A failed allocation leaked its retained input")
            var rejected = false
            do { _ = try VideoSamples.block(for: NSData()) }
            catch { rejected = true }
            try require(rejected, "Empty video bytes were accepted")
        }

        run("Retained samples preserve H.264 parameters, keyframe flags and decode after packets are released") {
            let samples = VideoSamples()
            var packets = try encodedPackets()
            let expected = packets.map { [UInt8]($0.avcc) }
            let retained = try packets.map { try samples.sample(for: $0) }
            packets.removeAll()
            var decoder: VTDecompressionSession?
            defer { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
            for (index, sample) in retained.enumerated() {
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let format = CMSampleBufferGetFormatDescription(sample) else {
                    throw SampleCheckFailure("A retained sample lost its data or format")
                }
                try require(try bytes(in: block) == expected[index], "A sample changed after its source packet was released")
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                try require(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true,
                            "Immediate-display flag changed")
                try require((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true) == (index > 0),
                            "Keyframe/predicted-frame flag changed")
                if decoder == nil {
                    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                        decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
                        decompressionSessionOut: &decoder)
                    try require(status == noErr, "Creating a decoder failed: \(status)")
                }
                let ready = DispatchSemaphore(value: 0)
                let result = ResultBox<Bool>(false)
                let status = VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample,
                    flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                        result.set(status == noErr && image.map { CVPixelBufferGetWidth($0) == 320 && CVPixelBufferGetHeight($0) == 180 } == true)
                        ready.signal()
                    }
                try require(status == noErr && ready.wait(timeout: .now() + 10) == .success && result.get(),
                            "A retained sample failed to decode with its original dimensions")
            }
        }

        run("Mailbox timing follows only the latest accepted frame and cannot cross diagnostic epochs") {
            var time: TimeInterval = 10
            let diagnostics = PerformanceDiagnostics(enabled: true, clock: { time })
            let mailbox = LatestFrameMailbox(diagnostics: diagnostics)
            var image: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &image)
            guard status == kCVReturnSuccess, let image else { throw SampleCheckFailure("Creating mailbox pixels failed") }
            try require(mailbox.offer(image, sequence: UInt32.max), "The initial frame was not scheduled")
            time = 10.1
            try require(!mailbox.offer(image, sequence: 0), "A replacement scheduled a second display callback")
            try require(!mailbox.offer(image, sequence: UInt32.max), "A stale decode replaced the current frame")
            time = 10.25
            let newest = mailbox.takeWithTiming()
            try require(newest?.sequence == 0 && newest?.decodedAt?.startedAt == 10.1,
                        "Frame timing did not follow the accepted sequence through wraparound")
            diagnostics.record(.decodeToDisplay, since: newest?.decodedAt)
            let repeated = mailbox.takeWithTiming()
            try require(repeated?.frame === image && repeated?.decodedAt == nil,
                        "A layout replay lost the retained image or reused its timing")
            let first = diagnostics.drain()
            try require(first.first(where: { $0.metric == .displayReplaced })?.count == 1,
                        "A stale frame was counted as a pending display replacement")
            try require(first.first(where: { $0.metric == .decodeToDisplay })?.maximum == 150_000,
                        "Display timing included the replaced frame's wait")
            _ = mailbox.offer(image, sequence: 1)
            diagnostics.setEnabled(false)
            diagnostics.setEnabled(true)
            diagnostics.record(.decodeToDisplay, since: mailbox.takeWithTiming()?.decodedAt)
            try require(diagnostics.drain().isEmpty, "A previous diagnostic epoch leaked into the new window")
            _ = mailbox.offer(image, sequence: 2)
            mailbox.stopDiagnostics()
            _ = mailbox.offer(image, sequence: 3)
            let stopped = mailbox.takeWithTiming()
            try require(stopped?.sequence == 3 && stopped?.decodedAt == nil && diagnostics.drain().isEmpty,
                        "Stopping diagnostics changed latest-frame behavior or retained timing from late callbacks")
            _ = mailbox.offer(image)
            try require(mailbox.takeWithTiming()?.sequence == nil && !mailbox.offer(image, sequence: 2),
                        "An unnumbered frame inherited stale metadata or erased the sequence watermark")
        }

        run("Decode diagnostics can be enabled after session creation and stay quiet while disabled") {
            let packets = try encodedPackets()
            let diagnostics = PerformanceDiagnostics()
            let decoder = VideoDecoder(diagnostics: diagnostics)
            defer { decoder.stop() }
            for (index, packet) in packets.enumerated() {
                if index == 1 { diagnostics.setEnabled(true) }
                let ready = DispatchSemaphore(value: 0)
                let result = ResultBox<Bool>(false)
                decoder.decode(packet) {
                    if case .success = $0 { result.set(true) }
                    ready.signal()
                }
                try require(ready.wait(timeout: .now() + 10) == .success && result.get(),
                            "The instrumented synthetic frame did not decode")
                let summaries = diagnostics.drain()
                if index == 0 {
                    try require(summaries.isEmpty, "Disabled decode diagnostics emitted samples")
                } else {
                    try require(summaries.first(where: { $0.metric == .decodeQueue })?.count == 1,
                                "Enabling diagnostics missed decode queue timing")
                    try require(summaries.first(where: { $0.metric == .decodePrepare })?.count == 1,
                                "Enabling diagnostics missed sample and session preparation timing")
                    try require(summaries.first(where: { $0.metric == .decode })?.count == 1,
                                "Enabling diagnostics missed decoder completion timing")
                    if let hardware = summaries.first(where: { $0.metric == .decoderHardware }) {
                        try require(hardware.minimum >= 0 && hardware.maximum <= 1, "Hardware status was not boolean")
                    }
                }
            }
        }

        run("Rejected samples retain preparation timing and release their diagnostic slots") {
            let diagnostics = PerformanceDiagnostics(enabled: true)
            let decoder = VideoDecoder(diagnostics: diagnostics)
            defer { decoder.stop() }
            for sequence in UInt32(1)...5 {
                let ready = DispatchSemaphore(value: 0)
                let rejected = ResultBox<Bool>(false)
                decoder.decode(VideoPacket(sequence: sequence, sps: Data(), pps: Data(), avcc: Data([1]))) {
                    if case .failure = $0 { rejected.set(true) }
                    ready.signal()
                }
                try require(ready.wait(timeout: .now() + 10) == .success && rejected.get(),
                            "The invalid synthetic sample did not fail")
            }
            let summaries = diagnostics.drain()
            try require(summaries.first(where: { $0.metric == .decodeQueue })?.count == 5,
                        "Preparation failure consumed a diagnostic tracking slot permanently")
            try require(summaries.first(where: { $0.metric == .decodePrepare })?.count == 5,
                        "Failed sample preparation was omitted from diagnostics")
            try require(!summaries.contains(where: { $0.metric == .decode }),
                        "A sample rejected before submission reported decoder work")
        }

        print("Video sample checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
