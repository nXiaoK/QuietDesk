import CoreAudio
import CoreMedia
import Foundation
import QuietDeskCore

private func makeTestAudioSampleBuffer(
    sampleRate: Float64,
    channels: UInt32,
    planar: Bool,
    floatFormat: Bool,
    frames: Int,
    leftGenerator: (Int) -> Float,
    rightGenerator: (Int) -> Float
) throws -> CMSampleBuffer {
    let bytesPerSample = floatFormat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
    var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
    if floatFormat {
        flags |= kAudioFormatFlagIsFloat
    } else {
        flags |= kAudioFormatFlagIsSignedInteger
    }
    if planar {
        flags |= kAudioFormatFlagIsNonInterleaved
    }
    let bytesPerFrame = planar ? UInt32(bytesPerSample) : UInt32(bytesPerSample) * channels
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: UInt32(bytesPerSample * 8),
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let fmtStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard fmtStatus == noErr, let formatDescription else {
        throw CheckFailure("CMAudioFormatDescriptionCreate failed: \(fmtStatus)")
    }

    var rawBytes = Data()
    if planar {
        if floatFormat {
            let left = (0..<frames).map(leftGenerator)
            left.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
            if channels >= 2 {
                let right = (0..<frames).map(rightGenerator)
                right.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
            }
        } else {
            let left = (0..<frames).map { Int16(max(-32_768, min(32_767, Int((leftGenerator($0) * 32_767).rounded())))) }
            left.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
            if channels >= 2 {
                let right = (0..<frames).map { Int16(max(-32_768, min(32_767, Int((rightGenerator($0) * 32_767).rounded())))) }
                right.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
            }
        }
    } else {
        if floatFormat {
            var interleaved: [Float] = []
            interleaved.reserveCapacity(frames * Int(channels))
            for i in 0..<frames {
                interleaved.append(leftGenerator(i))
                if channels >= 2 { interleaved.append(rightGenerator(i)) }
            }
            interleaved.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
        } else {
            var interleaved: [Int16] = []
            interleaved.reserveCapacity(frames * Int(channels))
            for i in 0..<frames {
                interleaved.append(Int16(max(-32_768, min(32_767, Int((leftGenerator(i) * 32_767).rounded())))))
                if channels >= 2 {
                    interleaved.append(Int16(max(-32_768, min(32_767, Int((rightGenerator(i) * 32_767).rounded())))))
                }
            }
            interleaved.withUnsafeBufferPointer { rawBytes.append(Data(buffer: $0)) }
        }
    }

    var blockBuffer: CMBlockBuffer?
    let createBlock = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: rawBytes.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: rawBytes.count,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
    )
    guard createBlock == kCMBlockBufferNoErr, let blockBuffer else {
        throw CheckFailure("CMBlockBufferCreateWithMemoryBlock failed: \(createBlock)")
    }
    try rawBytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { throw CheckFailure("Empty audio rawBytes") }
        let replace = CMBlockBufferReplaceDataBytes(
            with: base,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: raw.count
        )
        guard replace == kCMBlockBufferNoErr else {
            throw CheckFailure("CMBlockBufferReplaceDataBytes failed: \(replace)")
        }
    }

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frames,
        presentationTimeStamp: CMTime(value: 0, timescale: Int32(sampleRate)),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw CheckFailure("CMAudioSampleBufferCreateReadyWithPacketDescriptions failed: \(sampleStatus)")
    }
    return sampleBuffer
}

func runRemoteAudioChecks() {
    run("RemoteAudioControl request/status round-trip and strict validation") {
        let reqID = UUID()
        let request = RemoteAudioControl.request(id: reqID, enabled: true)
        let reqMsg = try request.message()
        try check(reqMsg.kind == .audioControl, "Unexpected message kind for RemoteAudioControl")
        let decodedReq = try RemoteAudioControl.read(reqMsg.payload)
        try check(decodedReq == request && decodedReq.requestID == reqID && decodedReq.enabled, "Request round-trip mismatch")

        let cookie = Data([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64])
        let statusOn = RemoteAudioControl.status(requestID: reqID, enabled: true, epoch: 3, magicCookie: cookie)
        let decodedOn = try RemoteAudioControl.read(try statusOn.message().payload)
        try check(decodedOn == statusOn && decodedOn.epoch == 3 && decodedOn.magicCookie == cookie, "Enabled status round-trip mismatch")

        let statusOff = RemoteAudioControl.status(requestID: reqID, enabled: false, error: "无输出设备")
        let decodedOff = try RemoteAudioControl.read(try statusOff.message().payload)
        try check(decodedOff == statusOff && !decodedOff.enabled && decodedOff.error == "无输出设备", "Disabled status round-trip mismatch")

        try rejects("Accepted request without requestID") {
            try RemoteAudioControl(.request, requestID: nil, enabled: true).validate()
        }
        try rejects("Accepted request carrying status fields") {
            try RemoteAudioControl(.request, requestID: reqID, enabled: true, epoch: 1).validate()
        }
        try rejects("Accepted enabled status with epoch 0") {
            try RemoteAudioControl(.status, requestID: reqID, enabled: true, epoch: 0, sampleRate: 48_000, channels: 2, framesPerPacket: 960).validate()
        }
        try rejects("Accepted enabled status with non-48k sampleRate") {
            try RemoteAudioControl(.status, requestID: reqID, enabled: true, epoch: 1, sampleRate: 44_100, channels: 2, framesPerPacket: 960).validate()
        }
        try rejects("Accepted oversized magicCookie") {
            try RemoteAudioControl.status(
                requestID: reqID,
                enabled: true,
                epoch: 1,
                magicCookie: Data(count: RemoteAudioControl.maximumMagicCookieBytes + 1)
            ).validate()
        }
        try rejects("Accepted disabled status carrying magicCookie") {
            try RemoteAudioControl(.status, requestID: reqID, enabled: false, magicCookie: cookie).validate()
        }
    }

    run("RemoteAudioPacket binary framing, truncation rejection and datagram MTU bound") {
        let maxPayload = Data(repeating: 0xA5, count: RemoteAudioPacket.maximumPayloadBytes)
        let packet = try RemoteAudioPacket(epoch: 7, sequence: 123_456, channels: 2, opusPayload: maxPayload)
        let encoded = packet.encode()
        try check(1 + encoded.count <= MediaFragment.maximumDatagramBytes + 1,
                  "Encoded audio datagram exceeds BoundedDatagramPeer limit")
        let decoded = try RemoteAudioPacket.decode(encoded)
        try check(decoded == packet, "RemoteAudioPacket round-trip changed fields")

        for length in 0...RemoteAudioPacket.headerBytes {
            try rejects("Accepted truncated audio packet of length \(length)") {
                _ = try RemoteAudioPacket.decode(Data(encoded.prefix(length)))
            }
        }
        try rejects("Accepted oversized audio payload") {
            _ = try RemoteAudioPacket(
                epoch: 1,
                sequence: 1,
                opusPayload: Data(count: RemoteAudioPacket.maximumPayloadBytes + 1)
            )
        }
        try rejects("Accepted epoch 0 audio packet") {
            _ = try RemoteAudioPacket(epoch: 0, sequence: 1, opusPayload: Data([1, 2]))
        }
        var badFlags = encoded
        badFlags[1] = 1
        try rejects("Accepted non-zero flags") {
            _ = try RemoteAudioPacket.decode(badFlags)
        }
        var badChannels = encoded
        badChannels[2] = 6
        try rejects("Accepted unsupported channel count") {
            _ = try RemoteAudioPacket.decode(badChannels)
        }
    }

    run("Hello remoteAudioV1 backward compatibility and MediaControl datagramAudio negotiation") {
        let legacyHello = Hello(name: "Legacy", width: 1920, height: 1080, settings: .init(), canControl: true)
        let legacyDecoded = try Wire.readJSON(Hello.self, try Wire.json(.hello, legacyHello).payload)
        try legacyDecoded.validate()
        try check(legacyDecoded.remoteAudioV1 == nil, "Legacy Hello unexpectedly set remoteAudioV1")

        let modernHello = Hello(name: "Modern", width: 1920, height: 1080, settings: .init(), canControl: true, remoteAudioV1: true)
        let modernDecoded = try Wire.readJSON(Hello.self, try Wire.json(.hello, modernHello).payload)
        try modernDecoded.validate()
        try check(modernDecoded.remoteAudioV1 == true, "Modern Hello lost remoteAudioV1")

        let req = MediaControl(.request, datagramAudio: true)
        try check(try MediaControl.read(try req.message().payload).datagramAudio == true, "MediaControl request lost datagramAudio")
        let offer = MediaControl(.offer, sessionID: UUID(), token: Data(count: 32), datagramKey: Data(count: 32), datagramAudio: true)
        try check(try MediaControl.read(try offer.message().payload).datagramAudio == true, "MediaControl offer lost datagramAudio")
        try rejects("Accepted datagramAudio on stats MediaControl") {
            try MediaControl(.stats, sessionID: UUID(), encodeMilliseconds: 1.5, datagramAudio: true).validate()
        }
    }

    run("RemoteAudioSampleExtractor handles ScreenCaptureKit planar Float32 and resamples 44.1 kHz Int16") {
        let planarSample = try makeTestAudioSampleBuffer(
            sampleRate: 48_000,
            channels: 2,
            planar: true,
            floatFormat: true,
            frames: 480,
            leftGenerator: { i in i == 0 ? .nan : 0.25 },
            rightGenerator: { i in i == 1 ? .infinity : -0.5 }
        )
        let extractedPlanar = try RemoteAudioSampleExtractor.extractInterleavedStereo48k(planarSample)
        try check(extractedPlanar.count == 480 * 2, "Expected 960 stereo floats from 480 planar frames")
        try check(extractedPlanar[0] == 0 && abs(extractedPlanar[1] - (-0.5)) < 1e-5, "Frame 0 NaN clamping or R channel failed")
        try check(abs(extractedPlanar[2] - 0.25) < 1e-5 && extractedPlanar[3] == 0, "Frame 1 Inf clamping or L channel failed")
        try check(abs(extractedPlanar[4] - 0.25) < 1e-5 && abs(extractedPlanar[5] - (-0.5)) < 1e-5, "Planar stereo sample mismatch")

        let interleaved44k = try makeTestAudioSampleBuffer(
            sampleRate: 44_100,
            channels: 2,
            planar: false,
            floatFormat: false,
            frames: 441,
            leftGenerator: { i in sin(Float(i) * 2 * .pi * 440.0 / 44_100.0) * 0.6 },
            rightGenerator: { i in -sin(Float(i) * 2 * .pi * 440.0 / 44_100.0) * 0.6 }
        )
        let resampled = try RemoteAudioSampleExtractor.extractInterleavedStereo48k(interleaved44k)
        try check(resampled.count == 480 * 2, "Expected 441 frames @ 44.1 kHz to resample to 480 frames @ 48 kHz, got \(resampled.count / 2)")
        let peak = resampled.map { abs($0) }.max() ?? 0
        try check(peak > 0.5 && peak <= 0.65, "Unexpected resampled Int16 peak: \(peak)")
    }

    run("OpusAudioEncoder and OpusAudioDecoder 48 kHz 20ms stereo round-trip across arbitrary chunk sizes") {
        let encoder = try OpusAudioEncoder()
        let decoder = try OpusAudioDecoder(magicCookie: encoder.magicCookie)

        // Feed 5 x 576-frame (12 ms) chunks = 2880 frames = exactly 3 x 960-frame (20 ms) Opus packets.
        var encodedPackets: [Data] = []
        var sampleIndex = 0
        for _ in 0..<5 {
            var chunk = [Float](repeating: 0, count: 576 * 2)
            for i in 0..<576 {
                let t = Float(sampleIndex) / 48_000.0
                chunk[i * 2] = sin(t * 2 * .pi * 440.0) * 0.5
                chunk[i * 2 + 1] = sin(t * 2 * .pi * 880.0) * 0.4
                sampleIndex += 1
            }
            encodedPackets.append(contentsOf: try encoder.encode(interleavedStereoSamples: chunk))
        }
        try check(encodedPackets.count == 3, "Expected 3 encoded 20ms Opus packets from 2880 frames, got \(encodedPackets.count)")

        var decodedLeftPeak: Float = 0
        var decodedRightPeak: Float = 0
        var totalDecodedFrames = 0
        for (idx, payload) in encodedPackets.enumerated() {
            try check(!payload.isEmpty && payload.count <= RemoteAudioPacket.maximumPayloadBytes,
                      "Packet \(idx) size \(payload.count) out of bounds")
            let wire = try RemoteAudioPacket(epoch: 1, sequence: UInt64(idx + 1), opusPayload: payload)
            let decoded = try decoder.decode(wire.opusPayload)
            try check(decoded.count % 2 == 0 && !decoded.isEmpty, "Decoded stereo sample count invalid")
            totalDecodedFrames += decoded.count / 2
            for frame in 0..<(decoded.count / 2) {
                decodedLeftPeak = max(decodedLeftPeak, abs(decoded[frame * 2]))
                decodedRightPeak = max(decodedRightPeak, abs(decoded[frame * 2 + 1]))
            }
        }
        // Packet 0 trims 120 pre-skip frames (840), packets 1 & 2 yield 960 each => 2760 frames.
        try check(totalDecodedFrames >= 2_700 && totalDecodedFrames <= 2_880,
                  "Unexpected total decoded frame count: \(totalDecodedFrames)")
        try check(decodedLeftPeak > 0.35 && decodedRightPeak > 0.25,
                  "Decoded stereo sine amplitude too low: L=\(decodedLeftPeak), R=\(decodedRightPeak)")
    }

    run("RemoteAudioJitterBuffer prebuffers, reorders out-of-order UDP, skips lost gaps and bounds latency") {
        let dummy = Data([0xFC, 0xFF, 0xFE])
        var jb = RemoteAudioJitterBuffer(prebufferPackets: 2, maxTotalBufferedPackets: 5)

        let p1 = try RemoteAudioPacket(epoch: 1, sequence: 1, opusPayload: dummy)
        let p2 = try RemoteAudioPacket(epoch: 1, sequence: 2, opusPayload: dummy)
        let p3 = try RemoteAudioPacket(epoch: 1, sequence: 3, opusPayload: dummy)

        // Single packet below prebuffer threshold holds playout.
        try check(jb.push(p1, inFlightPlayoutBuffers: 0), "Failed to push p1")
        try check(jb.popReadyPackets(inFlightPlayoutBuffers: 0).isEmpty, "Should hold until prebufferPackets (2) reached")

        // Out-of-order arrival: p3 arrives before p2; once p2 arrives before pop, order is restored.
        try check(jb.push(p3, inFlightPlayoutBuffers: 0), "Failed to push p3")
        try check(jb.push(p2, inFlightPlayoutBuffers: 0), "Failed to push p2")
        try check(jb.reorderedCount == 1, "Expected reorderedCount == 1")
        try check(!jb.push(p2, inFlightPlayoutBuffers: 0) && jb.droppedDuplicateCount == 1, "Duplicate p2 should be rejected")

        let initialBatch = jb.popReadyPackets(inFlightPlayoutBuffers: 0, maxInFlightBuffers: 3)
        try check(initialBatch.map(\.sequence) == [1, 2, 3], "Expected ordered [1, 2, 3], got \(initialBatch.map(\.sequence))")

        // Late packet (seq 2 < nextExpected 4) is dropped.
        try check(!jb.push(p2, inFlightPlayoutBuffers: 2) && jb.droppedLateCount == 1, "Late packet should be dropped")

        // Burst of 8 packets while 1 buffer is in flight trims oldest packets so latency stays <= 5 packets (100 ms).
        for seq in UInt64(4)...UInt64(11) {
            let pkt = try RemoteAudioPacket(epoch: 1, sequence: seq, opusPayload: dummy)
            _ = jb.push(pkt, inFlightPlayoutBuffers: 1)
        }
        try check(jb.count <= 4 && jb.droppedOverflowCount >= 4,
                  "Expected bounded queue <= 4 with overflow drops, got count=\(jb.count), drops=\(jb.droppedOverflowCount)")
        let trimmedBatch = jb.popReadyPackets(inFlightPlayoutBuffers: 1, maxInFlightBuffers: 3)
        try check(trimmedBatch.map(\.sequence) == [8, 9], "Expected newest contiguous sequences [8, 9], got \(trimmedBatch.map(\.sequence))")

        // Epoch advance resets cleanly; stale epoch is rejected.
        let staleEpoch = try RemoteAudioPacket(epoch: 1, sequence: 99, opusPayload: dummy)
        let newEpoch1 = try RemoteAudioPacket(epoch: 2, sequence: 1, opusPayload: dummy)
        let newEpoch2 = try RemoteAudioPacket(epoch: 2, sequence: 2, opusPayload: dummy)
        try check(jb.push(newEpoch1, inFlightPlayoutBuffers: 0), "Failed to push epoch 2 packet 1")
        try check(!jb.push(staleEpoch, inFlightPlayoutBuffers: 0), "Accepted stale epoch 1 packet after epoch 2")
        try check(jb.push(newEpoch2, inFlightPlayoutBuffers: 0), "Failed to push epoch 2 packet 2")
        let epoch2Batch = jb.popReadyPackets(inFlightPlayoutBuffers: 0, maxInFlightBuffers: 3)
        try check(epoch2Batch.map(\.sequence) == [1, 2] && epoch2Batch.allSatisfy { $0.epoch == 2 },
                  "Epoch 2 reset did not deliver [1, 2]")
    }
}
