import Foundation
import CoreMedia
import CoreVideo
import QuietDeskCore

func runKeyFrameChecks() {
    run("The encoder adds no periodic keyframes past the former four-second limit but honors forced ones") {
        let frames = (0..<4).map { shade -> CVPixelBuffer? in
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<180 { for x in 0..<320 { luma[y * stride + x] = UInt8(truncatingIfNeeded: (x + y) * 3 + shade * 40) } }
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }.compactMap { $0 }
        try check(frames.count == 4, "Could not create synthetic frames")
        // The former limit was 240 frames or 4 s at 60 fps; VideoToolbox's own default inserts one every 120 frames.
        let encoder = try VideoEncoder(width: 320, height: 180, settings: StreamSettings(longestEdge: 1920, framesPerSecond: 60, megabits: 8))
        defer { encoder.stop() }
        let keyframes = Box<[UInt32]>([]), outputs = Box(0), failure = Box<String?>(nil), done = DispatchSemaphore(value: 0)
        encoder.onOutput = { result in
            switch result {
            case .success(let packet):
                outputs.update { $0 += 1 }
                if !packet.sps.isEmpty { keyframes.update { $0.append(packet.sequence) } }
            case .failure(let error): failure.set(error.localizedDescription)
            }
            done.signal()
        }
        encoder.onDropped = { _ in done.signal() }
        for sequence in UInt32(1)...600 {
            try encoder.encode(frames[Int(sequence) % frames.count], time: CMTime(value: Int64(sequence), timescale: 60),
                               sequence: sequence, forceKeyFrame: sequence == 1 || sequence == 450)
            try wait(done, "Encoder produced no result for frame \(sequence)")
        }
        try check(failure.read() == nil, failure.read() ?? "Encoding failed")
        try check(outputs.read() > 500, "Too many frames were dropped to judge keyframe placement")
        try check(keyframes.read() == [1, 450], "Unexpected keyframes at \(keyframes.read())")
    }
}
