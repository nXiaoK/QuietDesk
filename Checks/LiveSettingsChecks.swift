import Foundation
import VideoToolbox
import QuietDeskCore

func runLiveSettingsChecks() {
    let initial = VideoStreamState(settings: .init(), width: 1920, height: 1080)
    let low = StreamSettings(longestEdge: 1280, framesPerSecond: 10, megabits: 1)
    let medium = StreamSettings(longestEdge: 2560, framesPerSecond: 15, megabits: 5)
    let high = StreamSettings(longestEdge: 3840, framesPerSecond: 30, megabits: 12)
    func state(_ settings: StreamSettings) -> VideoStreamState {
        let (w, h) = settings.dimensions(width: 5120, height: 2880)
        return VideoStreamState(settings: settings, width: w, height: h)
    }

    run("Live quality requests validate allowed values and preserve wire message numbers") {
        try low.validateControlValues(); try high.validateControlValues()
        for invalid in [StreamSettings(longestEdge: -1), .init(framesPerSecond: 0), .init(framesPerSecond: 60), .init(megabits: 1000)] {
            try rejects("Invalid quality parameters accepted") { try invalid.validateControlValues() }
        }
        let request = StreamSettingsRequest(settings: medium)
        let message = try Wire.json(.streamSettingsRequest, request)
        let decoded = try Wire.readJSON(StreamSettingsRequest.self, message.payload)
        try check(decoded.id == request.id && decoded.settings == medium, "Request changed over wire")
        let result = StreamSettingsResult(id: request.id, state: state(medium))
        let decodedResult = try Wire.readJSON(StreamSettingsResult.self, Wire.json(.streamSettingsResult, result).payload)
        try check(decodedResult.state == result.state, "Applied state changed over wire")
        try check(MessageKind.inputStatus.rawValue == 10 && MessageKind.clipboardCancel.rawValue == 17 && Wire.version == 1, "Legacy wire values changed")
    }

    run("Rapid quality edits coalesce while only one request is in flight") {
        var session = try VideoTuningSession(applied: initial)
        try session.choose(low)
        guard let first = session.nextRequest() else { throw CheckFailure("No first request") }
        try session.choose(medium); try session.choose(high)
        try check(session.nextRequest() == nil && session.applied == initial, "Unconfirmed settings published or concurrent request sent")
        try check(session.receive(StreamSettingsResult(id: first.id, state: state(low))), "First result not accepted")
        try check(session.desired == high, "Newer choice was overwritten by older acknowledgement")
        guard let second = session.nextRequest() else { throw CheckFailure("Latest choice not sent") }
        try check(second.settings == high && second.id != first.id, "Intermediate choice was queued")
        try check(session.receive(StreamSettingsResult(id: second.id, state: state(high))), "Latest result not accepted")
        try check(session.nextRequest() == nil && session.applied.settings == high, "Configuration did not settle")
    }

    run("Failed quality changes restore actual values without discarding newer edits") {
        var session = try VideoTuningSession(applied: initial)
        try session.choose(low)
        guard let first = session.nextRequest() else { throw CheckFailure("No request") }
        _ = try session.receive(StreamSettingsResult(id: first.id, state: initial, error: "simulated rejection"))
        try check(session.desired == initial.settings && session.pending == nil && session.nextRequest() == nil, "Failed values kept retrying")
        try session.choose(low)
        guard let next = session.nextRequest() else { throw CheckFailure("No next request") }
        try session.choose(high)
        _ = try session.receive(StreamSettingsResult(id: next.id, state: initial, error: "simulated rejection"))
        try check(session.nextRequest()?.settings == high, "New edit lost after failed prior request")
    }

    run("Late and duplicate quality replies cannot resolve a different pending request") {
        var session = try VideoTuningSession(applied: initial, preferred: low)
        guard let first = session.nextRequest() else { throw CheckFailure("Saved preference was not requested") }
        try check(!session.receive(StreamSettingsResult(id: UUID(), state: state(high))), "Unrelated reply accepted")
        _ = try session.receive(StreamSettingsResult(id: first.id, state: state(low)))
        try session.choose(high)
        guard let second = session.nextRequest() else { throw CheckFailure("No second request") }
        try check(!session.receive(StreamSettingsResult(id: first.id, state: state(low))) && session.pending?.id == second.id, "Old reply cleared newer request")
        var reconnected = try VideoTuningSession(applied: initial, preferred: low)
        try check(!reconnected.receive(StreamSettingsResult(id: second.id, state: state(high))), "Reply from prior session accepted")
        try check(reconnected.nextRequest()?.settings == low, "Reconnect did not restore last confirmed preference")
    }

    run("Invalid quality acknowledgements leave applied and pending state intact") {
        var session = try VideoTuningSession(applied: initial, preferred: low)
        guard let request = session.nextRequest() else { throw CheckFailure("No request") }
        try rejects("Odd resolution accepted") {
            _ = try session.receive(StreamSettingsResult(id: request.id, state: VideoStreamState(settings: low, width: 1279, height: 720)))
        }
        try check(session.applied == initial && session.pending?.id == request.id, "Malformed result mutated state")
        try rejects("Oversized resolution accepted") { try VideoStreamState(settings: low, width: 8192, height: 8192).validate() }
    }

    run("Legacy connection records load without quality preferences and new preferences round trip") {
        var record = ConnectionRecord(address: "home.test", port: 5908, name: "Home")
        let oldData = try JSONEncoder().encode(record)
        let oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        try check(oldObject["videoSettings"] == nil, "Empty preference changed legacy JSON")
        try check(JSONDecoder().decode(ConnectionRecord.self, from: oldData).videoSettings == nil, "Legacy record failed to load")
        record.videoSettings = high
        let data = try JSONEncoder().encode(record)
        try check(JSONDecoder().decode(ConnectionRecord.self, from: data).videoSettings == high, "Saved quality lost")
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(Set(object.keys) == Set(["id", "address", "port", "name", "lastConnected", "videoSettings"]), "Credential fields added to history")
    }

    run("One decoder accepts consecutive encoders with changing resolution, frame rate and bitrate") {
        let decoder = VideoDecoder()
        defer { decoder.stop() }
        var sequence: UInt32 = 0
        let configurations: [(Int, Int, StreamSettings)] = [(320, 180, low), (640, 360, high), (640, 360, medium), (320, 180, low)]
        for (width, height, settings) in configurations {
            var pixel: CVPixelBuffer?
            let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
            guard status == noErr, let pixel else { throw CheckFailure("Cannot create synthetic frame") }
            CVPixelBufferLockBaseAddress(pixel, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                if let pointer = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) {
                    memset(pointer, plane == 0 ? 80 : 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            let encoder = try VideoEncoder(width: width, height: height, settings: settings)
            let completed = DispatchSemaphore(value: 0), error = Box<String?>(nil)
            let firstPacket = Box(true)
            encoder.onOutput = { result in
                do {
                    let packet = try result.get()
                    if firstPacket.read() && (packet.sps.isEmpty || packet.pps.isEmpty) { error.set("New encoder missing keyframe parameters") }
                    firstPacket.set(false)
                    decoder.decode(try VideoPacket.decode(packet.encode())) { result in
                        switch result {
                        case .success(let frame):
                            if CVPixelBufferGetWidth(frame) != width || CVPixelBufferGetHeight(frame) != height { error.set("Resolution switch decoded incorrectly") }
                        case .failure(let issue): error.set(issue.localizedDescription)
                        }
                        completed.signal()
                    }
                } catch let issue { error.set(issue.localizedDescription); completed.signal() }
            }
            for index in 0..<2 {
                sequence &+= 1
                try encoder.encode(pixel, time: CMTime(value: Int64(sequence), timescale: 30), sequence: sequence, forceKeyFrame: index == 0)
                try wait(completed, "New encoder did not produce a decodable frame")
                try check(error.read() == nil, error.read() ?? "Codec switch failed")
            }
            encoder.stop()
        }
    }
}
