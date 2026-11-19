import CoreMedia
import CoreVideo
import Foundation
import Network
import QuietDeskCore

// A reproducible scrolling texture with sharp edges and fine detail. Its luma can be compared
// directly to the same locations in each decoded frame without retaining captured desktops.
private final class ScrollingScene {
    let width = 1280, height = 720
    private let tileHeight = 256
    private var luma: [UInt8] = []
    // An optional 320×192 animated region prevents motion compensation from predicting the
    // whole desktop from the preceding frame. Keep 32 deterministic frames for pixel comparison.
    private let panelWidth = 320, panelHeight = 192, panelX = 640, panelY = 248
    private var panel: [UInt8] = []

    init(mixedMotion: Bool) {
        for row in 0..<tileHeight {
            for column in 0..<width {
                let cell = (column / 9 ^ row / 7) & 1
                let detail = (column &* 13 ^ (row &* 29) ^ (row * column >> 3)) & 31
                luma.append(UInt8(32 + cell * 124 + detail))
            }
        }
        if mixedMotion {
            var state: UInt32 = 0x714A386C
            panel.reserveCapacity(panelWidth * panelHeight * 32)
            for _ in 0..<(panelWidth * panelHeight * 32) {
                state = state &* 1_664_525 &+ 1_013_904_223
                panel.append(UInt8(16 + (state >> 24) * 219 / 255))
            }
        }
    }

    private func panelOffset(_ row: Int, _ seq: UInt32) -> Int { (Int(seq % 32) * panelHeight + row) * panelWidth }
    private func offset(_ row: Int, _ sequence: UInt32) -> Int { ((row + Int(sequence) * 3) % tileHeight) * width }

    func buffer(_ sequence: UInt32) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw MappingCheckFailure("Cannot allocate video fixture surface") }
        CVPixelBufferLockBaseAddress(image, []); defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!, pitch = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        luma.withUnsafeBytes { source in
            for row in 0..<height { memcpy(y + row * pitch, source.baseAddress! + offset(row, sequence), width) }
        }
        if !panel.isEmpty {
            panel.withUnsafeBytes { content in
                for row in 0..<panelHeight {
                    memcpy(y + (panelY + row) * pitch + panelX, content.baseAddress! + panelOffset(row, sequence), panelWidth)
                }
            }
        }
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * (height / 2))
        return image
    }

    func meanSquaredError(_ image: CVPixelBuffer, sequence: UInt32) throws -> Double {
        let format = CVPixelBufferGetPixelFormatType(image)
        try expect(format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                   "Unsupported decoded luma format \(format)")
        try expect(CVPixelBufferGetWidth(image) == width && CVPixelBufferGetHeight(image) == height, "Decoded frame size changed")
        CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let pitch = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var squared = 0.0, samples = 0
        for row in stride(from: 0, to: height, by: 13) {
            let start = offset(row, sequence)
            for column in stride(from: 0, to: width, by: 17) {
                let raw = Double(y[row * pitch + column])
                let actual = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 16 + 219 * raw / 255 : raw
                let reference = !panel.isEmpty && (panelY..<panelY + panelHeight).contains(row) && (panelX..<panelX + panelWidth).contains(column)
                    ? panel[panelOffset(row - panelY, sequence) + column - panelX] : luma[start + column]
                let delta = Double(reference) - actual
                squared += delta * delta; samples += 1
            }
        }
        return squared / Double(samples)
    }
}

private struct SourceCounts {
    var submitted = 0, encoded = 0, acknowledged = 0, dropped = 0, replaced = 0
    func report(since earlier: Self) {
        print("  Source submitted/encoded/acknowledged/dropped: \(submitted - earlier.submitted)/\(encoded - earlier.encoded)/\(acknowledged - earlier.acknowledged)/\(dropped - earlier.dropped); older pending captures replaced: \(replaced - earlier.replaced)")
    }
}

// Use the same credit, encoding and minimum-interval rules as ScreenStreamer. Capture keeps
// advancing at the requested cadence; only its newest sample is retained while credits are full.
private final class FrameSource {
    let scene: ScrollingScene
    let problems = FixtureValue<[String]>([])
    let counts = FixtureValue(SourceCounts())
    let referencePhases = FixtureValue<[UInt32: UInt32]>([:])
    private let encoder: VideoEncoder
    private let encoderID = UUID()
    private let encodeTiming = FixtureValue(VideoEncodeTiming())
    private let queue = DispatchQueue(label: "checks.mapping.scene", qos: .userInitiated)
    private var timer: DispatchSourceTimer?, pacing: DispatchSourceTimer?
    private weak var media: MediaSession?
    private var settings: StreamSettings
    private var captureNumber: UInt32 = 0
    private var latest: (number: UInt32, at: Double)?
    private var flow = VideoFrameFlow()
    private var dropper = TimeBudgetFrameDropper()
    private var window: Int?
    private var sending = false
    private var lastCreditWaitReport: TimeInterval = 0

    init(settings: StreamSettings, mixedMotion: Bool) throws {
        scene = ScrollingScene(mixedMotion: mixedMotion)
        self.settings = settings
        encoder = try VideoEncoder(width: scene.width, height: scene.height, settings: settings)
    }
    func attach(_ media: MediaSession) {
        self.media = media
        encoder.onOutput = { [weak self] result in
            switch result {
            case .success(let packet): self?.complete(packet.sequence, packet: packet)
            case .failure(let error): self?.problems.change { $0.append(error.localizedDescription) }
            }
        }
        encoder.onDropped = { [weak self] number in self?.complete(number, packet: nil) }
        media.onReceiveFrameWindow = { [weak self] value in
            self?.queue.async { [weak self] in self?.window = value; self?.pump() }
        }
        media.onAcknowledged = { [weak self] number in
            self?.queue.async { [weak self] in
                guard let self, self.flow.acknowledge(number) else { return }
                self.referencePhases.change { $0.removeValue(forKey: number) }
                self.counts.change { $0.acknowledged += 1 }; self.pump()
            }
        }
        media.onPrepareRecovery = { [weak self] done in
            self?.queue.async { [weak self] in
                guard let self else { done(false); return }
                self.flow.prepareMediaRecovery(); self.sending = false; done(true)
            }
        }
        media.onProduceRecoveryFrame = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.sending = true; self.flow.requestMediaRecoveryFrame(); self.capture()
            }
        }
        media.onResumeFrames = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.flow.resumeMediaFrames() else { return }; self.pump()
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.capture() }
        scheduleTimer(); timer.resume()
        let pacing = DispatchSource.makeTimerSource(queue: queue)
        self.pacing = pacing
        pacing.setEventHandler { [weak self] in self?.pump() }; pacing.resume()
    }
    private func complete(_ number: UInt32, packet: VideoPacket?) {
        let finished = SessionClock.now
        let duration = encodeTiming.change { $0.complete(encoderID: encoderID, sequence: number, at: finished) }
        queue.async { [self] in
            guard flow.complete(.init(sequence: number, packet: packet, callbackAt: finished, duration: duration, diagnostic: nil)) else { return }
            while let (frame, completion) = flow.takeCompleted() {
                if let latency = completion.duration,
                   let service = encodeTiming.change({ $0.serviceDuration(encoderID: encoderID, latency: latency, completedAt: completion.callbackAt) }) {
                    media?.recordComputeTiming(encodeMilliseconds: service * 1000)
                }
                if let data = completion.packet {
                    guard flow.encoded(frame.sequence, at: SessionClock.now) else { return }
                    counts.change { $0.encoded += 1 }
                    media?.sendVideo(data)
                } else {
                    guard flow.dropped(frame.sequence) else { return }
                    referencePhases.change { $0.removeValue(forKey: frame.sequence) }; counts.change { $0.dropped += 1 }
                }
            }
            pump()
        }
    }
    private func scheduleTimer() {
        timer?.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / settings.framesPerSecond), leeway: .microseconds(100))
    }
    private func capture() {
        if latest != nil && sending && !flow.mediaHold { counts.change { $0.replaced += 1 } }
        captureNumber += 1
        latest = (captureNumber, SessionClock.now)
        pump()
    }
    private func pump() {
        guard sending, let sample = latest else { return }
        let now = SessionClock.now
        if let delay = dropper.retryDelay(at: now, framesPerSecond: settings.framesPerSecond,
                                          forceKeyFrame: flow.forceKeyFrame || flow.mediaHold, isRefinement: false) {
            pacing?.schedule(deadline: .now() + delay, leeway: .milliseconds(1)); return
        }
        let concurrent = settings.framesPerSecond >= 60 ? 2 : 1
        let outstanding = VideoFrameFlow.maximumOutstandingFrames(for: settings, receiverLimit: window)
        guard let frame = flow.begin(at: now, maximumConcurrentEncodes: concurrent, maximumOutstandingFrames: outstanding) else {
            if now - lastCreditWaitReport >= 0.2,
               flow.isWaitingForReceiverCredit(maximumConcurrentEncodes: concurrent, maximumOutstandingFrames: outstanding) {
                lastCreditWaitReport = now
                media?.recordFrameCreditWait()
            }
            return
        }
        latest = nil; dropper.recordSubmission(at: now, isRefinement: false)
        do {
            let image = try scene.buffer(sample.number)
            referencePhases.change { $0[frame.sequence] = sample.number }
            encodeTiming.change { $0.begin(encoderID: encoderID, sequence: frame.sequence, at: SessionClock.now) }
            try encoder.encode(image, time: CMTime(seconds: sample.at, preferredTimescale: 90_000), sequence: frame.sequence, forceKeyFrame: frame.forceKeyFrame)
            counts.change { $0.submitted += 1 }
        } catch { problems.change { $0.append(error.localizedDescription) } }
    }
    func apply(_ next: StreamSettings) throws {
        try queue.sync { try encoder.updateEncodingParameters(settings: next); settings = next; scheduleTimer(); pump() }
    }
    func stop() {
        queue.sync { sending = false; timer?.cancel(); timer = nil; pacing?.cancel(); pacing = nil; encoder.stop(); media = nil }
    }
}

private struct FrameObservation { let at: Double, bytes: Int, mse: Double? }
private struct RTTObservation { let at: Double, milliseconds: Double }
private struct QualityObservation { let at: Double, settings: StreamSettings, reason: String }

private struct Measurements {
    var frames: [FrameObservation] = [], echoes: [RTTObservation] = [], settings: [QualityObservation] = []
    var probes = 0

    func report(_ title: String, from: Double, until: Double) throws -> (fps: Double, gap: Double, p95: Double, psnr: Double, changes: Int, bitrate: Double) {
        let duration = until - from
        let frames = frames.filter { (from..<until).contains($0.at) }, echoes = echoes.filter { (from..<until).contains($0.at) }
        let errors = frames.compactMap(\.mse)
        try expect(frames.count > 2 && echoes.count > 2 && !errors.isEmpty, "Empty \(title) measurement window")
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let ordered = values.sorted(); return ordered[max(0, Int(ceil(Double(ordered.count) * p)) - 1)]
        }
        let fps = Double(frames.count) / duration
        let mbps = Double(frames.reduce(0) { $0 + $1.bytes }) * 8 / duration / 1_000_000
        let psnr = 10 * log10(219 * 219 / (errors.reduce(0, +) / Double(errors.count)))
        let echo = echoes.map(\.milliseconds), p95 = percentile(echo, 0.95)
        let gaps = zip(frames.dropFirst(), frames).map { ($0.at - $1.at) * 1000 }
        let changes = settings.filter { (from..<until).contains($0.at) }
        print(String(format: "%@ %.2f s: %d frames, %.2f fps, frame gap p95 %.2f ms; H.264 %.2f Mbit/s, sampled Y-PSNR %.2f dB; %d input echoes p50/p95 %.2f/%.2f ms; %d profile changes",
                     title, duration, frames.count, fps, percentile(gaps, 0.95), mbps, psnr, echoes.count, percentile(echo, 0.50), p95, changes.count))
        for change in changes { print(String(format: "  +%.2f s", change.at - from), change.settings.summary, change.reason) }
        return (fps, percentile(gaps, 0.95), p95, psnr, changes.count, mbps)
    }
}

func runPortMappingPerformanceCheck(_ directory: URL) throws {
    let env = ProcessInfo.processInfo.environment
    let mib = Int(env["QUIETDESK_MAPPING_BENCH_MIB"] ?? "32") ?? 32
    let linkMbps = Double(env["QUIETDESK_MAPPING_BENCH_MBPS"] ?? "14") ?? 14
    let baselineSeconds = Double(env["QUIETDESK_MAPPING_BASELINE_SECONDS"] ?? "8") ?? 8
    let recoverySeconds = Double(env["QUIETDESK_MAPPING_RECOVERY_SECONDS"] ?? "8") ?? 8
    try expect((4...180).contains(baselineSeconds), "Invalid baseline duration")
    try expect((4...180).contains(recoverySeconds), "Invalid recovery duration")
    try expect((4...128).contains(mib) && (4...100).contains(linkMbps), "Invalid mapping benchmark size or rate")
    let file = try FixtureFileServer(directory: directory, mebibytes: mib)
    let target = try PortMappingTarget(host: "127.0.0.1", port: file.start())
    defer { file.stop() }
    let key = try PairingKey.generate()
    let host = try MappingTestHost(key: key) { request, allow in allow(request == target) }
    let serverPort = try host.start()
    defer { host.stop() }
    let proxy = try RelayOpaqueProxy(target: serverPort, downlinkBytesPerSecond: linkMbps * 125_000)
    let ready = DispatchSemaphore(value: 0)
    proxy.onReady = { ready.signal() }; proxy.start()
    defer { proxy.stop() }
    try expect(ready.wait(timeout: .now() + 5) == .success, "Shared bandwidth fixture did not start")
    let proxyPort = proxy.port!
    let traffic = PortMappingTraffic()
    let mapping = try MappingTestClient(port: proxyPort, key: key, target: target, traffic: traffic)
    mapping.viewer.start(); defer { mapping.viewer.stop() }
    let local = try mapping.listening()
    let settings = StreamSettings(longestEdge: 1280, framesPerSecond: 60, megabits: 8)
    let scene = env["QUIETDESK_MAPPING_BENCH_SCENE"] ?? "mixed"
    try expect(["scroll", "mixed"].contains(scene), "Benchmark scene must be scroll or mixed")
    let source = try FrameSource(settings: settings, mixedMotion: scene == "mixed")
    defer { source.stop() }
    let decoder = VideoDecoder()
    defer { decoder.stop() }
    let measurements = FixtureValue(Measurements())
    let problems = source.problems
    let hostMedia = FixtureValue<MediaSession?>(nil), viewerMedia = FixtureValue<MediaSession?>(nil)
    defer { viewerMedia.get()?.stop(); hostMedia.get()?.stop() }
    host.onDesktop = { [weak host] peer, role in
        guard let host else { return }
        if role != .control { hostMedia.get()?.acceptAuxiliary(peer, role: role); return }
        do {
            let media = try MediaSession.host(control: peer, key: key, port: serverPort, settings: settings)
            source.attach(media); hostMedia.change { $0 = media }
            media.onVideoDeliveryDelay = { [weak host] in host?.host.noteVideoDeliveryDelay($0) }
            media.hasRecentMappedPayload = { [weak server = host.host] in server?.hasRecentPayload == true }
            peer.onMessageHandled = { message, resume in
                defer { resume() }
                if media.receive(message) { return }
                do {
                    try expect(message.kind == .input, "Unexpected test input")
                    let input = try Wire.readJSON(RemoteInput.self, message.payload)
                    try input.validate()
                    peer.send(Message(.inputStatus, message.payload))
                } catch { problems.change { $0.append(error.localizedDescription) } }
            }
            media.start()
        } catch { problems.change { $0.append(error.localizedDescription) } }
    }
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!,
                                  using: try MediaSecureTransport.tlsParameters(key: key, roles: [.control]))
    let control = Peer(connection: connection)
    defer { control.close("test ended") }
    let committed = DispatchSemaphore(value: 0)
    let paths = FixtureValue<[String]>([])
    control.onReady = {
        do {
            let media = try MediaSession.viewer(control: control, key: key, host: "127.0.0.1", port: proxyPort, settings: settings, udpEnabled: false)
            viewerMedia.change { $0 = media }
            var quality = try MediaQualityPolicy(hostDefault: settings, applied: settings, bitRates: StreamSettings.adaptiveBitRates,
                                                 appliedSize: (source.scene.width, source.scene.height), now: SessionClock.now)
            let apply: (StreamSettings?, String) -> Void = { [weak media] next, reason in
                guard let next, let media else { return }
                do {
                    try source.apply(next)
                    hostMedia.get()?.updateSettings(next, restartsStream: false); media.updateSettings(next, restartsStream: false)
                    _ = quality.confirmApplied(next, now: SessionClock.now)
                    let adjustment = quality.lastAdjustment.map { String(describing: $0) } ?? "unreported"
                    measurements.change { $0.settings.append(.init(at: SessionClock.now, settings: next, reason: "\(adjustment) | \(reason)")) }
                } catch { problems.change { $0.append(error.localizedDescription) } }
            }
            media.onLocalNetwork = { quality.setLocalNetwork($0, now: SessionClock.now) }
            media.onReduceLoad = { cause in
                if cause == .network { traffic.noteVideoPressure() }
                apply(quality.reduceLoad(for: cause, severe: cause == .network, now: SessionClock.now), "media reduction: \(cause)")
            }
            media.onPathSwitch = { path, _ in paths.change { $0.append(path) }; quality.resetObservation(now: SessionClock.now) }
            media.onSample = { sample in
                if let delay = sample.deliveryMilliseconds { traffic.noteVideoDeliveryDelay(delay) }
                if sample.networkCondition == .congested || sample.networkCondition == .severe { traffic.noteVideoPressure() }
                if let next = quality.observe(sample, now: SessionClock.now) {
                    func measured(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "unmeasured" }
                    let reason = "sample fps \(measured(Double(sample.decodedFrames) / sample.duration)), encode/decode ms \(measured(sample.encodeMilliseconds))/\(measured(sample.decodeMilliseconds)), frame budget ms \(measured(sample.frameBudgetMilliseconds)), video Mbit/s \(measured(sample.receivedMegabits)), delivery ms \(measured(sample.deliveryMilliseconds)), mapping \(String(describing: sample.mappedTransfer))"
                    apply(next, reason)
                }
            }
            media.onVideo = { [weak media] frame, done in
                guard let media else { done(false); return }
                let started = SessionClock.now
                let seq = frame.packet.sequence
                let referencePhase = source.referencePhases.get()[seq]
                decoder.decode(frame.packet) { result in
                    let at = SessionClock.now
                    media.recordComputeTiming(decodeMilliseconds: (at - started) * 1000)
                    do {
                        let image = try result.get()
                        guard let phase = referencePhase else { throw MappingCheckFailure("Missing source capture for decoded frame") }
                        let mse = seq % 6 == 0 ? try source.scene.meanSquaredError(image, sequence: phase) : nil
                        measurements.change { $0.frames.append(.init(at: at, bytes: frame.packet.avcc.count, mse: mse)) }; done(true)
                    } catch { problems.change { $0.append(error.localizedDescription) }; done(false) }
                }
            }
            media.onCommitStream = { _, _ in committed.signal() }
            control.onMessageHandled = { message, resume in
                defer { resume() }
                if media.receive(message) { return }
                guard message.kind == .inputStatus, let input = try? Wire.readJSON(RemoteInput.self, message.payload), let sent = input.pointerSequence else { return }
                let rtt = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                measurements.change { $0.echoes.append(.init(at: SessionClock.now, milliseconds: rtt)) }
                media.recordControlRoundTrip(milliseconds: rtt)
            }
            media.start()
        } catch { problems.change { $0.append(error.localizedDescription) } }
    }
    control.start()
    try expect(committed.wait(timeout: .now() + 12) == .success, "No real H.264 frame committed: \(problems.get())")
    traffic.setDesktopActive(true); host.host.setDesktopActive(true)
    let inputTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "checks.mapping.input", qos: .userInteractive))
    inputTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
    inputTimer.setEventHandler {
        var input = RemoteInput(kind: .move)
        input.pointerSequence = DispatchTime.now().uptimeNanoseconds
        if let message = try? Wire.json(.input, input) { measurements.change { $0.probes += 1 }; control.send(message) }
    }
    inputTimer.resume(); defer { inputTimer.cancel() }
    print("\(scene) H.264 1280x720 @ 60 fps, 8 Mbit/s requested; one shared \(linkMbps) Mbit/s TLS downlink; TCP input echo @ 10 Hz; HTTP body \(mib) MiB")
    Thread.sleep(forTimeInterval: 3)
    let start = SessionClock.now
    let startCounts = source.counts.get()
    print("Baseline encoder profile:", measurements.get().settings.last?.settings.summary ?? settings.summary)
    Thread.sleep(forTimeInterval: baselineSeconds)
    let before = SessionClock.now
    let beforeCounts = source.counts.get()
    let baseline = try measurements.get().report("Baseline", from: start, until: before)
    beforeCounts.report(since: startCounts)
    if CommandLine.arguments.contains("--desktop-only") {
        let seconds = Double(env["QUIETDESK_MAPPING_CONTROL_SECONDS"] ?? "60") ?? 60
        try expect((4...600).contains(seconds), "Invalid desktop-only control duration")
        Thread.sleep(forTimeInterval: seconds)
        let ended = SessionClock.now
        let endedCounts = source.counts.get()
        _ = try measurements.get().report("No-download control", from: before, until: ended)
        endedCounts.report(since: beforeCounts)
        Thread.sleep(forTimeInterval: recoverySeconds)
        _ = try measurements.get().report("After control", from: ended, until: SessionClock.now)
        source.counts.get().report(since: endedCounts)
        return
    }
    let transfer = FileDownload()
    transfer.start(port: local, destination: directory.appendingPathComponent("desktop-download.bin"), file: file)
    let elapsed = try transfer.wait(seconds: max(240, 30 + Double(file.bytes) / 32_768 * 1.5))
    let after = SessionClock.now
    let afterCounts = source.counts.get()
    Thread.sleep(forTimeInterval: recoverySeconds)
    let end = SessionClock.now
    try expect(problems.get().isEmpty, "Media processing failed: \(problems.get().prefix(3))")
    let data = measurements.get()
    try expect(paths.get().last == "TCP 视频", "Video did not use negotiated TCP media: \(paths.get())")
    let download = try data.report("Whole download", from: before, until: after)
    afterCounts.report(since: beforeCounts)
    let recovery = try data.report("After download", from: after, until: end)
    source.counts.get().report(since: afterCounts)
    print(String(format: "Mapped file %d bytes, %.2f s, %.2f Mbit/s, SHA-256 match. Input sent/echoed %d/%d.",
                 file.bytes, elapsed, Double(file.bytes) * 8 / elapsed / 1_000_000, data.probes, data.echoes.count))
    try expect(baseline.fps >= 45 && download.fps >= baseline.fps * 0.90, "Decoded frame rate regressed during the download")
    try expect(recovery.fps >= baseline.fps * 0.90, "Decoded frame rate remained below baseline after the download")
    try expect(download.gap <= baseline.gap + 17, "Frame gap p95 increased by more than one 60 Hz frame")
    try expect(download.changes <= 1, "Repeated automatic quality transitions during the download")
    try expect(!data.settings.contains { (before..<after).contains($0.at) && ($0.settings.framesPerSecond < settings.framesPerSecond || $0.settings.longestEdge < settings.longestEdge) },
               "Automatic frame rate or resolution was reduced during download")
    if scene == "mixed" { try expect(baseline.bitrate >= 5, "Mixed scene failed to exercise bandwidth contention") }
    try expect(download.p95 <= baseline.p95 + 25, "Control echo p95 increased by more than 25 ms")
    try expect(download.psnr >= baseline.psnr - 2, "Sampled luma PSNR dropped by more than 2 dB")
    try expect(data.probes - data.echoes.count <= 1, "Control echo missing during benchmark")

    // Keep the same approved listener across desktop disconnect and verify it can complete
    // another download with the interactive bandwidth budget released.
    inputTimer.cancel(); viewerMedia.get()?.stop(); hostMedia.get()?.stop(); control.close("desktop test ended")
    traffic.setDesktopActive(false); host.host.setDesktopActive(false)
    let standalone = FileDownload()
    standalone.start(port: local, destination: directory.appendingPathComponent("standalone-download.bin"), file: file)
    let standaloneSeconds = try standalone.wait()
    print(String(format: "Same mapping after desktop disconnect: %d bytes, %.2f s, %.2f Mbit/s, SHA-256 match.",
                 file.bytes, standaloneSeconds, Double(file.bytes) * 8 / standaloneSeconds / 1_000_000))
}
