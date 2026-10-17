import Foundation
import VideoToolbox

public final class VideoDecoder {
    private let queue = DispatchQueue(label: "quietdesk.decode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let samples = VideoSamples()
    private var stopped = false

    public init() {}

    public func decode(_ packet: VideoPacket, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                let sample = try samples.sample(for: packet)
                guard let description = CMSampleBufferGetFormatDescription(sample) else { throw DeskError.invalid("缺少视频格式") }
                if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: description) {
                    if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
                    session = nil
                    let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                        decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                        outputCallback: nil, decompressionSessionOut: &session)
                    guard result == noErr else { throw DeskError.system("创建视频解码器失败", result) }
                    format = description
                }
                guard let session else { throw DeskError.invalid("视频解码器不可用") }
                let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                    flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
                        if status == noErr, let image { completion(.success(image)) }
                        else { completion(.failure(DeskError.system("视频解码失败", status))) }
                    }
                guard result == noErr else { throw DeskError.system("提交视频解码失败", result) }
            } catch { completion(.failure(error)) }
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
            session = nil
        }
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

// A busy or hidden window retains one decoded frame, never a queue of pixel buffers.
public final class LatestFrameMailbox {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var scheduled = false
    private var latestSequence: UInt32?
    public init() {}
    public func offer(_ frame: CVPixelBuffer, sequence: UInt32? = nil) -> Bool {
        lock.withLock {
            if let sequence {
                if let latestSequence {
                    // Keep the watermark after take; late decode callbacks must not regress the display.
                    let distance = sequence &- latestSequence
                    guard distance > 0, distance < 0x8000_0000 else { return false }
                }
                latestSequence = sequence
            }
            self.frame = frame
            if scheduled { return false }
            scheduled = true
            return true
        }
    }
    public func take() -> CVPixelBuffer? {
        lock.withLock { defer { scheduled = false }; return frame }
    }
}
