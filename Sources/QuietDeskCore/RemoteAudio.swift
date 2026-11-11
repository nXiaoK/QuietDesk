import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

public struct RemoteAudioControl: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case request, status
    }

    public static let sampleRate = 48_000
    public static let channels = 2
    public static let framesPerPacket = 960 // 20 ms @ 48 kHz
    public static let targetBitRate = 96_000
    public static let maximumMagicCookieBytes = 256
    public static let maximumErrorCharacters = 240

    public let operation: Operation
    public let requestID: UUID?
    public let enabled: Bool
    public let epoch: UInt32?
    public let sampleRate: Int?
    public let channels: Int?
    public let framesPerPacket: Int?
    public let magicCookie: Data?
    public let error: String?

    public init(
        _ operation: Operation,
        requestID: UUID? = nil,
        enabled: Bool,
        epoch: UInt32? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        framesPerPacket: Int? = nil,
        magicCookie: Data? = nil,
        error: String? = nil
    ) {
        self.operation = operation
        self.requestID = requestID
        self.enabled = enabled
        self.epoch = epoch
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.magicCookie = magicCookie
        self.error = error
    }

    public static func request(id: UUID = UUID(), enabled: Bool) -> Self {
        Self(.request, requestID: id, enabled: enabled)
    }

    public static func status(
        requestID: UUID?,
        enabled: Bool,
        epoch: UInt32? = nil,
        magicCookie: Data? = nil,
        error: String? = nil
    ) -> Self {
        Self(
            .status,
            requestID: requestID,
            enabled: enabled,
            epoch: enabled ? epoch : nil,
            sampleRate: enabled ? Self.sampleRate : nil,
            channels: enabled ? Self.channels : nil,
            framesPerPacket: enabled ? Self.framesPerPacket : nil,
            magicCookie: enabled ? magicCookie : nil,
            error: error
        )
    }

    public func validate() throws {
        switch operation {
        case .request:
            guard requestID != nil,
                  epoch == nil,
                  sampleRate == nil,
                  channels == nil,
                  framesPerPacket == nil,
                  magicCookie == nil,
                  error == nil else {
                throw DeskError.invalid("远端音频请求参数无效")
            }
        case .status:
            if let error {
                guard !error.isEmpty, error.count <= Self.maximumErrorCharacters else {
                    throw DeskError.invalid("远端音频错误描述无效")
                }
            }
            if let magicCookie {
                guard !magicCookie.isEmpty, magicCookie.count <= Self.maximumMagicCookieBytes else {
                    throw DeskError.invalid("远端音频编码描述无效")
                }
            }
            if enabled {
                guard let epoch, epoch > 0,
                      sampleRate == Self.sampleRate,
                      channels == Self.channels,
                      framesPerPacket == Self.framesPerPacket,
                      error == nil else {
                    throw DeskError.invalid("远端音频启用状态参数无效")
                }
            } else {
                guard epoch == nil,
                      sampleRate == nil,
                      channels == nil,
                      framesPerPacket == nil,
                      magicCookie == nil else {
                    throw DeskError.invalid("远端音频关闭状态参数无效")
                }
            }
        }
    }

    public func message() throws -> Message {
        try validate()
        return try Wire.json(.audioControl, self)
    }

    public static func read(_ payload: Data) throws -> Self {
        let value = try Wire.readJSON(Self.self, payload)
        try value.validate()
        return value
    }
}

public struct RemoteAudioPacket: Equatable, Sendable {
    public static let formatVersion: UInt8 = 1
    public static let headerBytes = 16
    // Fits within MediaFragment.maximumDatagramBytes (1100) so 1 (datagram kind) + 16 + payload <= 1101.
    public static let maximumPayloadBytes = MediaFragment.maximumDatagramBytes - headerBytes

    public let epoch: UInt32
    public let sequence: UInt64
    public let channels: UInt8
    public let opusPayload: Data

    public init(epoch: UInt32, sequence: UInt64, channels: UInt8 = UInt8(RemoteAudioControl.channels), opusPayload: Data) throws {
        guard epoch > 0 else {
            throw DeskError.invalid("远端音频数据包代次无效")
        }
        guard channels == 1 || channels == 2 else {
            throw DeskError.invalid("远端音频声道数无效")
        }
        guard !opusPayload.isEmpty, opusPayload.count <= Self.maximumPayloadBytes else {
            throw DeskError.invalid("远端音频负载长度无效")
        }
        self.epoch = epoch
        self.sequence = sequence
        self.channels = channels
        self.opusPayload = opusPayload
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerBytes + opusPayload.count)
        out.append(Self.formatVersion)
        out.append(0) // flags
        out.append(channels)
        out.append(0) // reserved
        out.put(epoch)
        out.put(sequence)
        out.append(opusPayload)
        return out
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count > Self.headerBytes,
              data.count <= Self.headerBytes + Self.maximumPayloadBytes else {
            throw DeskError.invalid("远端音频数据包长度无效")
        }
        var reader = ByteReader(data)
        let version: UInt8 = try reader.take()
        let flags: UInt8 = try reader.take()
        let channels: UInt8 = try reader.take()
        let reserved: UInt8 = try reader.take()
        guard version == Self.formatVersion, flags == 0, reserved == 0 else {
            throw DeskError.invalid("远端音频数据包头部版本或标志无效")
        }
        let epoch: UInt32 = try reader.take()
        let sequence: UInt64 = try reader.take()
        let payload = try reader.bytes(data.count - Self.headerBytes)
        return try Self(epoch: epoch, sequence: sequence, channels: channels, opusPayload: payload)
    }
}

public enum RemoteAudioSampleExtractor {
    /// Extracts planar or interleaved Float32/Int16 PCM from a `CMSampleBuffer` into interleaved stereo Float32 at 48 kHz.
    public static func extractInterleavedStereo48k(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            throw DeskError.invalid("音频采样缓冲区尚未就绪")
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= 48_000 else {
            return []
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw DeskError.invalid("缺少音频格式描述")
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate >= 8_000, asbd.mSampleRate <= 192_000,
              (1...8).contains(asbd.mChannelsPerFrame) else {
            throw DeskError.invalid("不支持的采集音频 PCM 格式")
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        guard !isBigEndian else {
            throw DeskError.invalid("不支持大端序 PCM 音频")
        }
        guard (isFloat && asbd.mBitsPerChannel == 32) || (isSignedInt && asbd.mBitsPerChannel == 16) else {
            throw DeskError.invalid("仅支持 32-bit Float 或 16-bit PCM 音频")
        }

        var bufferListSizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSizeNeeded >= MemoryLayout<AudioBufferList>.size else {
            throw DeskError.system("无法读取音频缓冲区大小", sizeStatus)
        }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }
        let ablPointer = rawABL.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard fillStatus == noErr else {
            throw DeskError.system("无法提取音频采样数据", fillStatus)
        }

        return try withExtendedLifetime(retainedBlockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            let channels = Int(asbd.mChannelsPerFrame)
            var stereo = [Float](repeating: 0, count: frameCount * 2)

            if isNonInterleaved {
                guard buffers.count >= 1 else {
                    throw DeskError.invalid("平面音频缓冲区数量为空")
                }
                let leftBuffer = buffers[0]
                let rightBuffer = buffers.count >= 2 ? buffers[1] : buffers[0]
                if isFloat {
                    guard let leftData = leftBuffer.mData,
                          let rightData = rightBuffer.mData,
                          Int(leftBuffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size,
                          Int(rightBuffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size else {
                        throw DeskError.invalid("平面浮点音频缓冲区字节不足")
                    }
                    let left = leftData.assumingMemoryBound(to: Float.self)
                    let right = rightData.assumingMemoryBound(to: Float.self)
                    for i in 0..<frameCount {
                        stereo[i * 2] = sanitizeSample(left[i])
                        stereo[i * 2 + 1] = sanitizeSample(right[i])
                    }
                } else {
                    guard let leftData = leftBuffer.mData,
                          let rightData = rightBuffer.mData,
                          Int(leftBuffer.mDataByteSize) >= frameCount * MemoryLayout<Int16>.size,
                          Int(rightBuffer.mDataByteSize) >= frameCount * MemoryLayout<Int16>.size else {
                        throw DeskError.invalid("平面整型音频缓冲区字节不足")
                    }
                    let left = leftData.assumingMemoryBound(to: Int16.self)
                    let right = rightData.assumingMemoryBound(to: Int16.self)
                    let scale: Float = 1.0 / 32_768.0
                    for i in 0..<frameCount {
                        stereo[i * 2] = sanitizeSample(Float(left[i]) * scale)
                        stereo[i * 2 + 1] = sanitizeSample(Float(right[i]) * scale)
                    }
                }
            } else {
                guard let first = buffers.first, let rawData = first.mData else {
                    throw DeskError.invalid("交错音频缓冲区为空")
                }
                if isFloat {
                    guard Int(first.mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size else {
                        throw DeskError.invalid("交错浮点音频缓冲区字节不足")
                    }
                    let ptr = rawData.assumingMemoryBound(to: Float.self)
                    for i in 0..<frameCount {
                        let base = i * channels
                        let l = sanitizeSample(ptr[base])
                        let r = channels >= 2 ? sanitizeSample(ptr[base + 1]) : l
                        stereo[i * 2] = l
                        stereo[i * 2 + 1] = r
                    }
                } else {
                    guard Int(first.mDataByteSize) >= frameCount * channels * MemoryLayout<Int16>.size else {
                        throw DeskError.invalid("交错整型音频缓冲区字节不足")
                    }
                    let ptr = rawData.assumingMemoryBound(to: Int16.self)
                    let scale: Float = 1.0 / 32_768.0
                    for i in 0..<frameCount {
                        let base = i * channels
                        let l = sanitizeSample(Float(ptr[base]) * scale)
                        let r = channels >= 2 ? sanitizeSample(Float(ptr[base + 1]) * scale) : l
                        stereo[i * 2] = l
                        stereo[i * 2 + 1] = r
                    }
                }
            }

            if abs(asbd.mSampleRate - Double(RemoteAudioControl.sampleRate)) <= 1.0 {
                return stereo
            }
            return resampleInterleavedStereo(
                stereo,
                inputFrames: frameCount,
                fromRate: asbd.mSampleRate,
                toRate: Double(RemoteAudioControl.sampleRate)
            )
        }
    }

    @inline(__always)
    private static func sanitizeSample(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        if sample > 1.0 { return 1.0 }
        if sample < -1.0 { return -1.0 }
        return sample
    }

    public static func resampleInterleavedStereo(
        _ input: [Float],
        inputFrames: Int,
        fromRate: Double,
        toRate: Double
    ) -> [Float] {
        guard inputFrames > 0, fromRate > 0, toRate > 0 else { return [] }
        let outputFrames = max(1, Int((Double(inputFrames) * toRate / fromRate).rounded()))
        if outputFrames == inputFrames { return input }
        var output = [Float](repeating: 0, count: outputFrames * 2)
        let step = fromRate / toRate
        for outIndex in 0..<outputFrames {
            let sourcePos = Double(outIndex) * step
            let idx0 = min(inputFrames - 1, max(0, Int(sourcePos)))
            let idx1 = min(inputFrames - 1, idx0 + 1)
            let frac = Float(sourcePos - Double(idx0))
            let l0 = input[idx0 * 2]
            let r0 = input[idx0 * 2 + 1]
            let l1 = input[idx1 * 2]
            let r1 = input[idx1 * 2 + 1]
            output[outIndex * 2] = sanitizeSample(l0 + (l1 - l0) * frac)
            output[outIndex * 2 + 1] = sanitizeSample(r0 + (r1 - r0) * frac)
        }
        return output
    }
}

public final class OpusAudioEncoder {
    private static let endOfInputStatus: OSStatus = 100
    private let converter: AudioConverterRef
    public let framesPerPacket: Int
    public let magicCookie: Data?

    private let pcmChunkFloats: Int
    private let pcmInputBuffer: UnsafeMutablePointer<Float>
    private let encodedOutputBuffer: UnsafeMutablePointer<UInt8>
    private var pendingSamples: [Float] = []
    private var pendingOffset = 0
    fileprivate var callbackConsumed = false

    public init(bitRate: Int = RemoteAudioControl.targetBitRate) throws {
        var sourceFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(RemoteAudioControl.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: UInt32(RemoteAudioControl.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(RemoteAudioControl.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(RemoteAudioControl.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(RemoteAudioControl.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var ref: AudioConverterRef?
        let createStatus = AudioConverterNew(&sourceFormat, &destinationFormat, &ref)
        guard createStatus == noErr, let ref else {
            throw DeskError.system("无法创建系统 Opus 音频编码器", createStatus)
        }
        self.converter = ref

        var targetBitRate = UInt32(max(24_000, min(256_000, bitRate)))
        _ = AudioConverterSetProperty(
            ref,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &targetBitRate
        )

        var actualDestination = destinationFormat
        var descSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioConverterGetProperty(ref, kAudioConverterCurrentOutputStreamDescription, &descSize, &actualDestination)
        let resolvedFrames = actualDestination.mFramesPerPacket > 0
            ? Int(actualDestination.mFramesPerPacket)
            : RemoteAudioControl.framesPerPacket
        guard resolvedFrames == RemoteAudioControl.framesPerPacket else {
            AudioConverterDispose(ref)
            throw DeskError.invalid("Opus 编码帧长与协议不匹配（\(resolvedFrames)）")
        }
        self.framesPerPacket = resolvedFrames
        self.pcmChunkFloats = resolvedFrames * RemoteAudioControl.channels
        self.pcmInputBuffer = .allocate(capacity: pcmChunkFloats)
        self.pcmInputBuffer.initialize(repeating: 0, count: pcmChunkFloats)
        self.encodedOutputBuffer = .allocate(capacity: RemoteAudioPacket.maximumPayloadBytes)
        self.encodedOutputBuffer.initialize(repeating: 0, count: RemoteAudioPacket.maximumPayloadBytes)

        var cookieSize: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioConverterGetPropertyInfo(ref, kAudioConverterCompressionMagicCookie, &cookieSize, &writable) == noErr,
           cookieSize > 0, Int(cookieSize) <= RemoteAudioControl.maximumMagicCookieBytes {
            var bytes = [UInt8](repeating: 0, count: Int(cookieSize))
            let status = AudioConverterGetProperty(ref, kAudioConverterCompressionMagicCookie, &cookieSize, &bytes)
            self.magicCookie = status == noErr && cookieSize > 0 ? Data(bytes.prefix(Int(cookieSize))) : nil
        } else {
            self.magicCookie = nil
        }
    }

    deinit {
        pcmInputBuffer.deinitialize(count: pcmChunkFloats)
        pcmInputBuffer.deallocate()
        encodedOutputBuffer.deinitialize(count: RemoteAudioPacket.maximumPayloadBytes)
        encodedOutputBuffer.deallocate()
        AudioConverterDispose(converter)
    }

    public func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
        pendingOffset = 0
        AudioConverterReset(converter)
    }

    public func encode(interleavedStereoSamples samples: [Float]) throws -> [Data] {
        guard !samples.isEmpty else { return [] }
        guard samples.count % RemoteAudioControl.channels == 0 else {
            throw DeskError.invalid("立体声采样长度必须为偶数")
        }
        pendingSamples.append(contentsOf: samples)
        // Bound buffered PCM to 200 ms if input ever arrives in an unexpected burst.
        let maxPendingFloats = pcmChunkFloats * 10
        if pendingSamples.count - pendingOffset > maxPendingFloats {
            pendingOffset = pendingSamples.count - maxPendingFloats
        }

        var packets: [Data] = []
        while pendingSamples.count - pendingOffset >= pcmChunkFloats {
            pendingSamples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                pcmInputBuffer.update(from: base.advanced(by: pendingOffset), count: pcmChunkFloats)
            }
            pendingOffset += pcmChunkFloats
            packets.append(try encodeSingleChunk())
        }
        if pendingOffset >= pcmChunkFloats * 4 {
            pendingSamples.removeFirst(pendingOffset)
            pendingOffset = 0
        } else if pendingOffset == pendingSamples.count {
            pendingSamples.removeAll(keepingCapacity: true)
            pendingOffset = 0
        }
        return packets
    }

    private func encodeSingleChunk() throws -> Data {
        callbackConsumed = false
        var ioPackets: UInt32 = 1
        var outPacketDescription = AudioStreamPacketDescription()
        var outputABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(RemoteAudioControl.channels),
                mDataByteSize: UInt32(RemoteAudioPacket.maximumPayloadBytes),
                mData: UnsafeMutableRawPointer(encodedOutputBuffer)
            )
        )
        let status = withUnsafeMutablePointer(to: &outPacketDescription) { descPtr in
            AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, _, inUserData -> OSStatus in
                    guard let inUserData else {
                        ioNumberDataPackets.pointee = 0
                        return OpusAudioEncoder.endOfInputStatus
                    }
                    let encoder = Unmanaged<OpusAudioEncoder>.fromOpaque(inUserData).takeUnretainedValue()
                    if encoder.callbackConsumed {
                        ioNumberDataPackets.pointee = 0
                        return OpusAudioEncoder.endOfInputStatus
                    }
                    encoder.callbackConsumed = true
                    ioNumberDataPackets.pointee = UInt32(encoder.framesPerPacket)
                    ioData.pointee.mBuffers.mNumberChannels = UInt32(RemoteAudioControl.channels)
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(encoder.pcmChunkFloats * MemoryLayout<Float>.size)
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(encoder.pcmInputBuffer)
                    return noErr
                },
                Unmanaged.passUnretained(self).toOpaque(),
                &ioPackets,
                &outputABL,
                descPtr
            )
        }
        let encodedBytes = Int(outPacketDescription.mDataByteSize > 0
            ? outPacketDescription.mDataByteSize
            : outputABL.mBuffers.mDataByteSize)
        guard (status == noErr || status == Self.endOfInputStatus),
              ioPackets == 1,
              encodedBytes > 0,
              encodedBytes <= RemoteAudioPacket.maximumPayloadBytes else {
            throw DeskError.system("Opus 音频编码失败", status)
        }
        return Data(bytes: encodedOutputBuffer, count: encodedBytes)
    }
}

public final class OpusAudioDecoder {
    private static let endOfInputStatus: OSStatus = 101
    private let converter: AudioConverterRef
    private let framesPerPacket = RemoteAudioControl.framesPerPacket
    private let outputChunkFloats = RemoteAudioControl.framesPerPacket * RemoteAudioControl.channels
    private let inputPacketBuffer: UnsafeMutablePointer<UInt8>
    private let inputPacketDesc: UnsafeMutablePointer<AudioStreamPacketDescription>
    private let decodedOutputBuffer: UnsafeMutablePointer<Float>
    private var currentPacketByteCount = 0
    fileprivate var callbackFed = false

    public init(magicCookie: Data? = nil) throws {
        var sourceFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(RemoteAudioControl.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(RemoteAudioControl.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(RemoteAudioControl.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(RemoteAudioControl.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: UInt32(RemoteAudioControl.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var ref: AudioConverterRef?
        let createStatus = AudioConverterNew(&sourceFormat, &destinationFormat, &ref)
        guard createStatus == noErr, let ref else {
            throw DeskError.system("无法创建系统 Opus 音频解码器", createStatus)
        }
        if let magicCookie, !magicCookie.isEmpty {
            guard magicCookie.count <= RemoteAudioControl.maximumMagicCookieBytes else {
                AudioConverterDispose(ref)
                throw DeskError.invalid("Opus 解码配置过大")
            }
            _ = magicCookie.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return noErr }
                return AudioConverterSetProperty(
                    ref,
                    kAudioConverterDecompressionMagicCookie,
                    UInt32(raw.count),
                    base
                )
            }
        }
        self.converter = ref
        self.inputPacketBuffer = .allocate(capacity: RemoteAudioPacket.maximumPayloadBytes)
        self.inputPacketBuffer.initialize(repeating: 0, count: RemoteAudioPacket.maximumPayloadBytes)
        self.inputPacketDesc = .allocate(capacity: 1)
        self.inputPacketDesc.initialize(to: AudioStreamPacketDescription())
        self.decodedOutputBuffer = .allocate(capacity: outputChunkFloats)
        self.decodedOutputBuffer.initialize(repeating: 0, count: outputChunkFloats)
    }

    deinit {
        inputPacketBuffer.deinitialize(count: RemoteAudioPacket.maximumPayloadBytes)
        inputPacketBuffer.deallocate()
        inputPacketDesc.deinitialize(count: 1)
        inputPacketDesc.deallocate()
        decodedOutputBuffer.deinitialize(count: outputChunkFloats)
        decodedOutputBuffer.deallocate()
        AudioConverterDispose(converter)
    }

    public func reset() {
        AudioConverterReset(converter)
    }

    public func decode(_ opusPacket: Data) throws -> [Float] {
        guard !opusPacket.isEmpty, opusPacket.count <= RemoteAudioPacket.maximumPayloadBytes else {
            throw DeskError.invalid("Opus 数据包大小无效")
        }
        opusPacket.copyBytes(to: inputPacketBuffer, count: opusPacket.count)
        currentPacketByteCount = opusPacket.count
        inputPacketDesc.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(opusPacket.count)
        )
        callbackFed = false

        var ioFrames = UInt32(framesPerPacket)
        var outputABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(RemoteAudioControl.channels),
                mDataByteSize: UInt32(outputChunkFloats * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(decodedOutputBuffer)
            )
        )
        let status = AudioConverterFillComplexBuffer(
            converter,
            { _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData -> OSStatus in
                guard let inUserData else {
                    ioNumberDataPackets.pointee = 0
                    return OpusAudioDecoder.endOfInputStatus
                }
                let decoder = Unmanaged<OpusAudioDecoder>.fromOpaque(inUserData).takeUnretainedValue()
                if decoder.callbackFed {
                    ioNumberDataPackets.pointee = 0
                    return OpusAudioDecoder.endOfInputStatus
                }
                decoder.callbackFed = true
                ioNumberDataPackets.pointee = 1
                ioData.pointee.mBuffers.mNumberChannels = UInt32(RemoteAudioControl.channels)
                ioData.pointee.mBuffers.mDataByteSize = UInt32(decoder.currentPacketByteCount)
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(decoder.inputPacketBuffer)
                if let outDataPacketDescription {
                    outDataPacketDescription.pointee = decoder.inputPacketDesc
                }
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &ioFrames,
            &outputABL,
            nil
        )
        // Packet 0 trims Opus pre-skip (returning 840 frames and endOfInputStatus when fed one packet at a time).
        guard (status == noErr || status == Self.endOfInputStatus),
              ioFrames > 0,
              Int(ioFrames) <= framesPerPacket else {
            throw DeskError.system("Opus 音频解码失败", status)
        }
        let sampleCount = Int(ioFrames) * RemoteAudioControl.channels
        var output = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let sample = decodedOutputBuffer[i]
            output[i] = sample.isFinite ? max(-1.0, min(1.0, sample)) : 0
        }
        return output
    }
}

/// Bounded sequence-reordering jitter buffer for 20 ms remote audio packets.
/// Caps total queued audio latency so network bursts never cause audio to drift behind live video.
public struct RemoteAudioJitterBuffer: Sendable {
    public let prebufferPackets: Int
    public let maxTotalBufferedPackets: Int
    public private(set) var epoch: UInt32 = 0
    public private(set) var startedPlayout = false
    public private(set) var nextExpectedSequence: UInt64?
    public private(set) var droppedLateCount = 0
    public private(set) var droppedDuplicateCount = 0
    public private(set) var droppedOverflowCount = 0
    public private(set) var reorderedCount = 0
    public private(set) var gapSkippedCount = 0
    private var buffered: [UInt64: RemoteAudioPacket] = [:]
    private var highestSeenSequence: UInt64?

    public init(prebufferPackets: Int = 2, maxTotalBufferedPackets: Int = 5) {
        self.prebufferPackets = max(1, prebufferPackets)
        self.maxTotalBufferedPackets = max(self.prebufferPackets + 1, maxTotalBufferedPackets)
    }

    public var count: Int { buffered.count }

    public mutating func reset(epoch: UInt32 = 0) {
        self.epoch = epoch
        self.startedPlayout = false
        self.nextExpectedSequence = nil
        self.buffered.removeAll(keepingCapacity: true)
        self.highestSeenSequence = nil
    }

    @discardableResult
    public mutating func push(_ packet: RemoteAudioPacket, inFlightPlayoutBuffers: Int = 0) -> Bool {
        if packet.epoch < epoch {
            droppedLateCount += 1
            return false
        }
        if packet.epoch > epoch {
            reset(epoch: packet.epoch)
        }
        if let expected = nextExpectedSequence, packet.sequence < expected {
            droppedLateCount += 1
            return false
        }
        if buffered[packet.sequence] != nil {
            droppedDuplicateCount += 1
            return false
        }
        if let highest = highestSeenSequence, packet.sequence < highest {
            reorderedCount += 1
        } else {
            highestSeenSequence = packet.sequence
        }
        buffered[packet.sequence] = packet

        let allowedInQueue = max(1, maxTotalBufferedPackets - max(0, inFlightPlayoutBuffers))
        while buffered.count > allowedInQueue, let oldest = buffered.keys.min() {
            buffered.removeValue(forKey: oldest)
            droppedOverflowCount += 1
            if let expected = nextExpectedSequence, expected <= oldest {
                nextExpectedSequence = oldest &+ 1
            }
        }
        return true
    }

    public mutating func popReadyPackets(
        inFlightPlayoutBuffers: Int,
        maxInFlightBuffers: Int = 3
    ) -> [RemoteAudioPacket] {
        if inFlightPlayoutBuffers == 0 && buffered.isEmpty {
            // Playout underran cleanly; re-arm short prebuffer so the next burst resumes smoothly.
            startedPlayout = false
        }
        if !startedPlayout {
            guard buffered.count >= prebufferPackets else { return [] }
            startedPlayout = true
            if nextExpectedSequence == nil {
                nextExpectedSequence = buffered.keys.min()
            }
        }

        var ready: [RemoteAudioPacket] = []
        var currentInFlight = max(0, inFlightPlayoutBuffers)
        while currentInFlight < maxInFlightBuffers, !buffered.isEmpty {
            guard let expected = nextExpectedSequence ?? buffered.keys.min() else { break }
            if let exact = buffered.removeValue(forKey: expected) {
                nextExpectedSequence = expected &+ 1
                ready.append(exact)
                currentInFlight += 1
                continue
            }
            // Missing expected packet: if playout still has >= 2 buffers queued and < 2 later packets waiting,
            // hold briefly so an out-of-order UDP datagram arriving within 20 ms can fill the slot.
            if currentInFlight >= 2 && buffered.count < 2 {
                break
            }
            guard let nextAvailable = buffered.keys.min(),
                  let packet = buffered.removeValue(forKey: nextAvailable) else {
                break
            }
            if nextAvailable > expected {
                gapSkippedCount += Int(min(UInt64(1_000), nextAvailable - expected))
            }
            nextExpectedSequence = nextAvailable &+ 1
            ready.append(packet)
            currentInFlight += 1
        }
        return ready
    }
}
