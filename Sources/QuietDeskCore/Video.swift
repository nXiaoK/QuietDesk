import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

public final class VideoEncoder {
    private var session: VTCompressionSession?
    public var onOutput: ((Result<VideoPacket, Error>) -> Void)?
    public var onDropped: ((UInt32) -> Void)?

    public init(width: Int, height: Int, settings: StreamSettings) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, frameContext, status, info, sample in
                guard let context else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(context).takeUnretainedValue()
                let sequence = UInt32(UInt(bitPattern: frameContext))
                switch VideoEncoder.output(status: status, info: info, sample: sample, sequence: sequence) {
                case .success(let packet?): encoder.onOutput?(.success(packet))
                case .success(nil): encoder.onDropped?(sequence)
                case .failure(let error): encoder.onOutput?(.failure(error))
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let created else { throw DeskError.system("无法创建 H.264 编码器", status) }
        session = created
        do {
            try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.framesPerSecond))
            try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: settings.megabits * 1_000_000))
            // TCP delivers every frame, and start, resume and setting changes force keyframes, so periodic ones only add
            // bursts. Zero would let VideoToolbox pick about two seconds; an hour is effectively none. Keep the old
            // four seconds if an encoder rejects the long interval.
            do { try setKeyFrameInterval(seconds: 3_600, framesPerSecond: settings.framesPerSecond) }
            catch { try setKeyFrameInterval(seconds: 4, framesPerSecond: settings.framesPerSecond) }
            // A one-second window allows codec bursts; this is not a per-packet bandwidth ceiling.
            try set(kVTCompressionPropertyKey_DataRateLimits,
                    [NSNumber(value: settings.megabits * 1_000_000 / 8), NSNumber(value: 1)] as CFArray)
            let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepared == noErr else { throw DeskError.system("无法准备视频编码器", prepared) }
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    static func output(status: OSStatus, info: VTEncodeInfoFlags, sample: CMSampleBuffer?,
                       sequence: UInt32) -> Result<VideoPacket?, Error> {
        guard status == noErr else { return .failure(DeskError.system("视频编码失败", status)) }
        // Real-time rate control may intentionally produce no compressed sample.
        guard !info.contains(.frameDropped), let sample else { return .success(nil) }
        do { return .success(try packet(from: sample, sequence: sequence)) }
        catch { return .failure(error) }
    }

    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session else { return }
        let result = VTSessionSetProperty(session, key: key, value: value)
        guard result == noErr else { throw DeskError.system("设置视频参数失败：\(key)", result) }
    }

    // Rate control follows the new target from the next frames; the stream format and reference chain stay intact.
    public func updateBitrate(megabits: Int) throws {
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: megabits * 1_000_000))
        try set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: megabits * 1_000_000 / 8), NSNumber(value: 1)] as CFArray)
    }

    private func setKeyFrameInterval(seconds: Int, framesPerSecond: Int) throws {
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: framesPerSecond * seconds))
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: seconds))
    }

    public func encode(_ buffer: CVPixelBuffer, time: CMTime, sequence: UInt32, forceKeyFrame: Bool = false) throws {
        guard let session else { throw DeskError.invalid("编码器已停止") }
        let properties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
            duration: .invalid, frameProperties: properties,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(sequence)), infoFlagsOut: nil)
        guard status == noErr else { throw DeskError.system("提交视频帧失败", status) }
    }

    public func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    public var usesHardware: Bool {
        hardwareAccelerationStatus ?? false
    }

    public var hardwareAccelerationStatus: Bool? {
        guard let session else { return nil }
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                    allocator: nil, valueOut: &value) == noErr else { return nil }
        return (value?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    private static func packet(from sample: CMSampleBuffer, sequence: UInt32) throws -> VideoPacket {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else {
            throw DeskError.invalid("编码输出为空")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var sps = Data(), pps = Data()
        if isKeyFrame {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var header: Int32 = 0
                let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header)
                guard result == noErr, let pointer, header == 4 else {
                    throw DeskError.system("无法提取 H.264 参数", result)
                }
                if index == 0 { sps = Data(bytes: pointer, count: size) }
                else { pps = Data(bytes: pointer, count: size) }
            }
        }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
        }
        guard result == noErr else { throw DeskError.system("无法读取视频帧", result) }
        return VideoPacket(sequence: sequence, sps: sps, pps: pps, avcc: bytes)
    }

    deinit { stop() }
}

public final class VideoSamples {
    private final class BlockStorage {
        let data: NSData
        private let lock = NSLock()
        private var released = false

        init(_ data: NSData) { self.data = data.copy() as! NSData }

        func releaseBlockRetain() {
            // A failed creation may already have disposed its temporary block.
            let shouldRelease = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            if shouldRelease { Unmanaged.passUnretained(self).release() }
        }
    }

    private var format: CMVideoFormatDescription?
    public init() {}

    static func block(for data: NSData, allocator: CFAllocator? = nil) throws -> CMBlockBuffer {
        guard data.length > 0 else { throw DeskError.invalid("空视频帧") }
        let storage = BlockStorage(data)
        var source = CMBlockBufferCustomBlockSource()
        source.version = UInt32(kCMBlockBufferCustomBlockSourceVersion)
        source.refCon = Unmanaged.passRetained(storage).toOpaque()
        source.FreeBlock = { context, _, _ in
            guard let context else { return }
            Unmanaged<BlockStorage>.fromOpaque(context).takeUnretainedValue().releaseBlockRetain()
        }
        var block: CMBlockBuffer?
        let status = withExtendedLifetime(storage) {
            CMBlockBufferCreateWithMemoryBlock(allocator: allocator,
                memoryBlock: UnsafeMutableRawPointer(mutating: storage.data.bytes),
                blockLength: storage.data.length, blockAllocator: kCFAllocatorNull, customBlockSource: &source,
                offsetToData: 0, dataLength: storage.data.length, flags: 0, blockBufferOut: &block)
        }
        guard status == noErr, let block else {
            if block == nil { storage.releaseBlockRetain() }
            throw DeskError.system("无法创建视频缓冲", status)
        }
        return block
    }

    public func sample(for packet: VideoPacket) throws -> CMSampleBuffer {
        if !packet.sps.isEmpty {
            var created: CMFormatDescription?
            let status = packet.sps.withUnsafeBytes { s in
                packet.pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [packet.sps.count, packet.pps.count]
                    return pointers.withUnsafeBufferPointer { pointerBuffer in
                        sizes.withUnsafeBufferPointer { sizeBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                parameterSetCount: 2, parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4,
                                formatDescriptionOut: &created)
                        }
                    }
                }
            }
            guard status == noErr, let created else { throw DeskError.system("视频参数解析失败", status) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(created)
            guard dimensions.width >= 2, dimensions.height >= 2, dimensions.width <= 8192,
                  dimensions.height <= 8192, Int64(dimensions.width) * Int64(dimensions.height) <= 36_000_000 else {
                throw DeskError.invalid("视频分辨率过大")
            }
            format = created
        }
        guard let format else { throw DeskError.invalid("尚未收到视频关键帧") }
        // NSData owns a stable immutable pointer; bridging may itself copy some Data representations.
        let block = try Self.block(for: packet.avcc as NSData)
        var sample: CMSampleBuffer?
        var size = packet.avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw DeskError.system("无法创建视频样本", status) }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if packet.sps.isEmpty {
                CFDictionarySetValue(dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
