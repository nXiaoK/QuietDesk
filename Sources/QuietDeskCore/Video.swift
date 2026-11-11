import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

public final class VideoEncoder {
    private typealias SetProperty = (CFString, CFTypeRef) throws -> Void
    public static let hevcMain444AutoLevel: CFString = "HEVC_Main444_AutoLevel" as CFString
    private var session: VTCompressionSession?
    private let writeProperty: (VTCompressionSession, CFString, CFTypeRef?) -> OSStatus
    public let codec: VideoCodec
    public let chromaSubsampling: VideoChromaSubsampling
    public let colorSpace: VideoColorSpace
    private var configuredSettings: StreamSettings
    private var refinementBoostActive = false
    public var onOutput: ((Result<VideoPacket, Error>) -> Void)?
    public var onDropped: ((UInt32) -> Void)?

    /// Whether this Mac can switch a share to HEVC. Apple silicon's media engine encodes it about 1.5 to 1.8 times
    /// as fast as H.264 at the same size; an Intel Mac keeps H.264, and a software HEVC encoder would be far slower.
    public static let hardwareHEVCAvailable: Bool = {
        #if arch(arm64)
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else { return false }
        defer { VTCompressionSessionInvalidate(created) }
        return VTCompressionSessionPrepareToEncodeFrames(created) == noErr
        #else
        return false
        #endif
    }()

    /// Whether Apple silicon's hardware media engine supports HEVC Main 4:4:4 true-color encoding.
    public static let hardwareHEVC444Available: Bool = {
        #if arch(arm64)
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else { return false }
        defer { VTCompressionSessionInvalidate(created) }
        guard VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: hevcMain444AutoLevel) == noErr else {
            return false
        }
        return VTCompressionSessionPrepareToEncodeFrames(created) == noErr
        #else
        return false
        #endif
    }()

    public convenience init(width: Int, height: Int, settings: StreamSettings, codec: VideoCodec = .h264,
                            chromaSubsampling: VideoChromaSubsampling = .yuv420,
                            colorSpace: VideoColorSpace = .sRGB) throws {
        try self.init(width: width, height: height, settings: settings, codec: codec,
                      chromaSubsampling: chromaSubsampling, colorSpace: colorSpace,
                      writeProperty: VTSessionSetProperty)
    }

    init(width: Int, height: Int, settings: StreamSettings, codec: VideoCodec = .h264,
         chromaSubsampling: VideoChromaSubsampling = .yuv420, colorSpace: VideoColorSpace = .sRGB,
         writeProperty: @escaping (VTCompressionSession, CFString, CFTypeRef?) -> OSStatus) throws {
        guard chromaSubsampling == .yuv420 || codec == .hevc else {
            throw DeskError.invalid("4:4:4 真彩模式需要 HEVC 编码")
        }
        self.codec = codec
        self.chromaSubsampling = chromaSubsampling
        self.colorSpace = colorSpace
        self.configuredSettings = settings
        self.writeProperty = writeProperty
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if codec == .hevc { specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { context, frameContext, status, info, sample in
                guard let context else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(context).takeUnretainedValue()
                let sequence = UInt32(UInt(bitPattern: frameContext))
                switch VideoEncoder.output(status: status, info: info, sample: sample, sequence: sequence, codec: encoder.codec) {
                case .success(let packet?): encoder.onOutput?(.success(packet))
                case .success(nil): encoder.onDropped?(sequence)
                case .failure(let error): encoder.onOutput?(.failure(error))
                }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &created)
        guard status == noErr, let created else {
            throw DeskError.system(codec == .hevc ? "无法创建 HEVC 编码器" : "无法创建 H.264 编码器", status)
        }
        session = created
        let set: SetProperty = { try self.set($0, $1, on: created) }
        do {
            try set(kVTCompressionPropertyKey_RealTime,
                    Self.usesRealTimeMode(framesPerSecond: settings.framesPerSecond) ? kCFBooleanTrue : kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            let profile: CFString = codec == .h264
                ? kVTProfileLevel_H264_High_AutoLevel
                : (chromaSubsampling == .yuv444 ? Self.hevcMain444AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            try set(kVTCompressionPropertyKey_ProfileLevel, profile)
            Self.applyColorSpaceTags(colorSpace) { key, value in
                _ = self.writeProperty(created, key, value)
            }
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.framesPerSecond))
            try Self.setBitrate(settings.megabits, using: set)
            try Self.setKeyFrameInterval(framesPerSecond: settings.framesPerSecond, using: set)
            let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepared == noErr else { throw DeskError.system("无法准备视频编码器", prepared) }
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    // Real-time mode lets VideoToolbox slow the encoder toward the expected rate to save energy. At 60 fps and above
    // that throttle holds a native share well below the hardware's speed, and after a still screen the sparse capture
    // timestamps can leave it slow while motion continues. Lower rates keep the energy saving.
    static func usesRealTimeMode(framesPerSecond: Int) -> Bool { framesPerSecond < 60 }

    var realTimeMode: Bool? {
        guard let session else { return nil }
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_RealTime, allocator: nil, valueOut: &value) == noErr else { return nil }
        return (value?.takeRetainedValue() as? NSNumber)?.boolValue
    }

    static func output(status: OSStatus, info: VTEncodeInfoFlags, sample: CMSampleBuffer?,
                       sequence: UInt32, codec: VideoCodec = .h264) -> Result<VideoPacket?, Error> {
        guard status == noErr else { return .failure(DeskError.system("视频编码失败", status)) }
        // Real-time rate control may intentionally produce no compressed sample.
        guard !info.contains(.frameDropped), let sample else { return .success(nil) }
        do { return .success(try packet(from: sample, sequence: sequence, codec: codec)) }
        catch { return .failure(error) }
    }

    private func set(_ key: CFString, _ value: CFTypeRef?, on session: VTCompressionSession) throws {
        let result = writeProperty(session, key, value)
        guard result == noErr else { throw DeskError.system("设置视频参数失败：\(key)", result) }
    }

    private func updateProperties(_ change: (SetProperty) throws -> Void) throws {
        guard let session else { throw DeskError.invalid("编码器已停止") }
        var previous: [(key: CFString, value: CFTypeRef?)] = []
        do {
            try change { key, value in
                var saved: Unmanaged<CFTypeRef>?
                let status = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &saved)
                guard status == noErr else { throw DeskError.system("读取视频参数失败：\(key)", status) }
                let oldValue = saved?.takeRetainedValue()
                try self.set(key, value, on: session)
                previous.append((key, oldValue))
            }
        } catch {
            do {
                for property in previous.reversed() { try set(property.key, property.value, on: session) }
            } catch let rollbackError {
                stop()
                onOutput?(.failure(rollbackError))
                throw rollbackError
            }
            throw error
        }
    }

    public func updateBitrate(megabits: Int) throws {
        try updateProperties { try Self.setBitrate(megabits, using: $0) }
        configuredSettings.megabits = megabits
        refinementBoostActive = false
    }

    public func updateEncodingParameters(settings: StreamSettings) throws {
        try updateProperties { set in
            try set(kVTCompressionPropertyKey_RealTime,
                    Self.usesRealTimeMode(framesPerSecond: settings.framesPerSecond) ? kCFBooleanTrue : kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: settings.framesPerSecond))
            try Self.setBitrate(settings.megabits, using: set)
            try Self.setKeyFrameInterval(framesPerSecond: settings.framesPerSecond, using: set)
        }
        configuredSettings = settings
        refinementBoostActive = false
    }

    private static func applyColorSpaceTags(_ colorSpace: VideoColorSpace, using write: (CFString, CFTypeRef) -> Void) {
        switch colorSpace {
        case .displayP3:
            write(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_P3_D65)
            write(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_sRGB)
            write(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        case .sRGB:
            write(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
            write(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
            write(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        }
    }

    public static func refinementParameters(for settings: StreamSettings, pass: Int) -> (megabits: Int, expectedFPS: Int, quality: Double) {
        let clampedPass = min(max(1, pass), 4)
        let boostedMegabits = min(StreamSettings.bitRates.last!, max(settings.megabits, min(settings.megabits * 2, settings.megabits + 24)))
        let expectedFPS = max(1, min(settings.framesPerSecond, 15))
        let baseQuality = settings.megabits >= 8 ? 0.78 : 0.72
        let quality = min(0.96, baseQuality + Double(clampedPass) * 0.04)
        return (boostedMegabits, expectedFPS, quality)
    }

    public static func dataRateLimitBytes(megabits: Int) -> Int {
        // 1.5x one-second burst headroom prevents sharp text from smearing during sudden scrolling/window motion
        // while remaining inside MediaSession's 1.6x UDP datagram pacer.
        max(187_500, Int((Double(max(1, megabits)) * 1_000_000 / 8 * 1.5).rounded()))
    }

    private static func setBitrate(_ megabits: Int, using set: SetProperty) throws {
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: megabits * 1_000_000))
        try set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: dataRateLimitBytes(megabits: megabits)), NSNumber(value: 1)] as CFArray)
    }

    private static func setKeyFrameInterval(framesPerSecond: Int, using set: SetProperty) throws {
        func interval(seconds: Int) throws {
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: framesPerSecond * seconds))
            try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: seconds))
        }
        // An hour avoids periodic bursts. Some encoders only accept the original four-second interval.
        do { try interval(seconds: 3_600) }
        catch { try interval(seconds: 4) }
    }

    public func encode(_ buffer: CVPixelBuffer, time: CMTime, sequence: UInt32, forceKeyFrame: Bool = false,
                       refinementPass: Int? = nil) throws {
        guard let session else { throw DeskError.invalid("编码器已停止") }
        if let pass = refinementPass, !forceKeyFrame {
            let boost = Self.refinementParameters(for: configuredSettings, pass: pass)
            _ = writeProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: boost.expectedFPS))
            _ = writeProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: boost.megabits * 1_000_000))
            _ = writeProperty(session, kVTCompressionPropertyKey_DataRateLimits,
                              [NSNumber(value: Self.dataRateLimitBytes(megabits: boost.megabits)), NSNumber(value: 1)] as CFArray)
            _ = writeProperty(session, kVTCompressionPropertyKey_Quality, NSNumber(value: boost.quality))
            refinementBoostActive = true
        } else if refinementBoostActive {
            _ = writeProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuredSettings.framesPerSecond))
            _ = writeProperty(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: configuredSettings.megabits * 1_000_000))
            _ = writeProperty(session, kVTCompressionPropertyKey_DataRateLimits,
                              [NSNumber(value: Self.dataRateLimitBytes(megabits: configuredSettings.megabits)), NSNumber(value: 1)] as CFArray)
            _ = writeProperty(session, kVTCompressionPropertyKey_Quality, nil)
            refinementBoostActive = false
        }
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

    private static func packet(from sample: CMSampleBuffer, sequence: UInt32, codec: VideoCodec) throws -> VideoPacket {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else {
            throw DeskError.invalid("编码输出为空")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var vps = Data(), sps = Data(), pps = Data()
        if isKeyFrame, codec == .h264 {
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
        } else if isKeyFrame {
            // VideoToolbox lists VPS, SPS and PPS; anything else it may add stays out of the decoder's format.
            var count = 0
            var header: Int32 = 0
            var index = 0
            repeat {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header)
                guard result == noErr, let pointer, size >= 2, header == 4 else {
                    throw DeskError.system("无法提取 HEVC 参数", result)
                }
                let set = Data(bytes: pointer, count: size)
                switch (pointer[0] >> 1) & 0x3F {
                case 32 where vps.isEmpty: vps = set
                case 33 where sps.isEmpty: sps = set
                case 34 where pps.isEmpty: pps = set
                default: break
                }
                index += 1
            } while index < count
            guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { throw DeskError.invalid("HEVC 关键帧缺少参数集") }
        }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
        }
        guard result == noErr else { throw DeskError.system("无法读取视频帧", result) }
        return VideoPacket(sequence: sequence, codec: codec, vps: vps, sps: sps, pps: pps, avcc: bytes)
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
    private var formatCodec = VideoCodec.h264
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
            guard packet.hasParameterSets else { throw DeskError.invalid("视频参数不完整") }
            let sets = packet.codec == .hevc ? [packet.vps, packet.sps, packet.pps] : [packet.sps, packet.pps]
            let joined = sets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
            let sizes = sets.map(\.count)
            var created: CMFormatDescription?
            let status = joined.withUnsafeBufferPointer { bytes -> OSStatus in
                var offset = 0
                let pointers = sizes.map { size -> UnsafePointer<UInt8> in defer { offset += size }; return bytes.baseAddress! + offset }
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        packet.codec == .hevc
                            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil,
                                parameterSetCount: sets.count, parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4, extensions: nil,
                                formatDescriptionOut: &created)
                            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                parameterSetCount: sets.count, parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!, nalUnitHeaderLength: 4,
                                formatDescriptionOut: &created)
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
            formatCodec = packet.codec
        }
        guard let format else { throw DeskError.invalid("尚未收到视频关键帧") }
        // A frame can only continue the stream its keyframe started; a codec switch always begins with a keyframe.
        guard packet.codec == formatCodec else { throw DeskError.invalid("视频编码格式变化前缺少关键帧") }
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
