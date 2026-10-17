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

private func encodedPackets() throws -> [VideoPacket] {
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
    let encoder = try VideoEncoder(width: 320, height: 180, settings: .init())
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
        try encoder.encode(buffer, time: CMTime(value: Int64(sequence), timescale: 15),
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

        print("Video sample checks: \(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
