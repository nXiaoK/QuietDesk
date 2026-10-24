import Foundation
import VideoToolbox

public final class VideoDecoder {
    private let queue = DispatchQueue(label: "quietdesk.decode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let samples = VideoSamples()
    private var stopped = false
    private let diagnostics: PerformanceDiagnostics?
    private let timingLock = NSLock()
    private var timings: [UUID: PerformanceDiagnostics.Token] = [:]
    private var timingStopped = false
    private var hardwareChecked = false
    private var hardware: Bool?

    public init(diagnostics: PerformanceDiagnostics? = nil) { self.diagnostics = diagnostics }

    /// A viewer asks for HEVC only when it decodes it in hardware; software decoding would cost the frame rate HEVC buys.
    public static var hardwareHEVCAvailable: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) }

    public func decode(_ packet: VideoPacket, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        let timingID: UUID? = diagnostics?.start().flatMap { token in
            timingLock.withLock {
                guard !timingStopped, timings.count < 3 else { return nil }
                let id = UUID()
                timings[id] = token
                return id
            }
        }
        queue.async { [self] in
            guard !stopped else { return }
            let preparationStarted = diagnostics?.start()
            var prepared = false
            if let timingID {
                diagnostics?.record(.decodeQueue, since: timingLock.withLock { timings[timingID] },
                                    kind: .video, identifier: UInt64(packet.sequence))
            }
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
                    hardwareChecked = false
                    hardware = nil
                }
                guard let session else { throw DeskError.invalid("视频解码器不可用") }
                if diagnostics?.isEnabled == true {
                    if !hardwareChecked {
                        var value: Unmanaged<CFTypeRef>?
                        let status = VTSessionCopyProperty(session,
                            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                            allocator: nil, valueOut: &value)
                        if status == noErr { hardware = (value?.takeRetainedValue() as? NSNumber)?.boolValue }
                        hardwareChecked = true
                    }
                    if let hardware { diagnostics?.recordValue(.decoderHardware, hardware ? 1 : 0) }
                }
                diagnostics?.record(.decodePrepare, since: preparationStarted, kind: .video, identifier: UInt64(packet.sequence))
                prepared = true
                if let timingID {
                    let token = diagnostics?.start()
                    timingLock.withLock {
                        if timings[timingID] != nil { timings[timingID] = token }
                    }
                }
                let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                    flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                        if let self, let timingID {
                            self.diagnostics?.record(.decode, since: self.timingLock.withLock { self.timings.removeValue(forKey: timingID) },
                                                     kind: .video, identifier: UInt64(packet.sequence))
                        }
                        if status == noErr, let image { completion(.success(image)) }
                        else { completion(.failure(DeskError.system("视频解码失败", status))) }
                    }
                guard result == noErr else { throw DeskError.system("提交视频解码失败", result) }
            } catch {
                if !prepared {
                    diagnostics?.record(.decodePrepare, since: preparationStarted, kind: .video, identifier: UInt64(packet.sequence))
                }
                if let timingID { _ = timingLock.withLock { timings.removeValue(forKey: timingID) } }
                completion(.failure(error))
            }
        }
    }

    public func stop() {
        timingLock.withLock { timingStopped = true; timings.removeAll() }
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
    private var frameSequence: UInt32?
    private let diagnostics: PerformanceDiagnostics?
    private var decodedAt: PerformanceDiagnostics.Token?
    private var timingStopped = false
    public init(diagnostics: PerformanceDiagnostics? = nil) { self.diagnostics = diagnostics }
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
            if scheduled, !timingStopped { diagnostics?.recordValue(.displayReplaced, 1) }
            self.frame = frame
            frameSequence = sequence
            decodedAt = timingStopped ? nil : diagnostics?.start()
            if scheduled { return false }
            scheduled = true
            return true
        }
    }
    public func take() -> CVPixelBuffer? {
        takeWithTiming()?.frame
    }
    public func takeWithTiming() -> (frame: CVPixelBuffer, decodedAt: PerformanceDiagnostics.Token?, sequence: UInt32?)? {
        lock.withLock {
            defer { scheduled = false; decodedAt = nil }
            guard let frame else { return nil }
            return (frame, decodedAt, frameSequence)
        }
    }
    public func stopDiagnostics() {
        lock.withLock { timingStopped = true; decodedAt = nil }
    }
}
