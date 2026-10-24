import AppKit
import Darwin
import ScreenCaptureKit
import QuietDeskCore

// Encoder and acknowledgement state share one queue with the capture pump.
struct VideoFrameFlow {
    static let maximumOutstandingFrames = 3
    private(set) var sequence: UInt32
    private(set) var encoding: UInt32?
    private(set) var waiting: [UInt32: TimeInterval] = [:]
    private(set) var forceKeyFrame = true
    private var encodingStartedAt: TimeInterval?
    private var encodingKeyFrame = false
    private var consecutiveDrops = 0
    private(set) var mediaHold = false
    private(set) var mediaRecoveryFrameEncoded = false
    private var mediaRecoveryRequested = false
    private var mediaRecoveryIssued = false

    init(sequence: UInt32 = 0) { self.sequence = sequence }

    var isIdle: Bool { encoding == nil && waiting.isEmpty }

    mutating func begin(at now: TimeInterval) -> (sequence: UInt32, forceKeyFrame: Bool)? {
        // The encoding reservation also consumes a credit; there is no unbounded encoder queue.
        guard encoding == nil, waiting.count < Self.maximumOutstandingFrames,
              !mediaHold || mediaRecoveryRequested else { return nil }
        repeat { sequence &+= 1 } while waiting[sequence] != nil
        encoding = sequence
        encodingStartedAt = now
        encodingKeyFrame = forceKeyFrame
        forceKeyFrame = false
        if mediaHold { mediaRecoveryRequested = false }
        return (sequence, encodingKeyFrame)
    }

    mutating func encoded(_ number: UInt32, at now: TimeInterval) -> Bool {
        guard encoding == number else { return false }
        encoding = nil
        encodingStartedAt = nil
        consecutiveDrops = 0
        waiting[number] = now
        if mediaHold { mediaRecoveryFrameEncoded = true }
        return true
    }

    mutating func dropped(_ number: UInt32) -> Bool {
        guard encoding == number else { return false }
        encoding = nil
        encodingStartedAt = nil
        consecutiveDrops = min(consecutiveDrops + 1, 3)
        forceKeyFrame = forceKeyFrame || encodingKeyFrame || consecutiveDrops >= 3
        if mediaHold { mediaRecoveryRequested = true }
        return true
    }

    mutating func acknowledge(_ number: UInt32) -> Bool { waiting.removeValue(forKey: number) != nil }
    mutating func requestKeyFrame() { forceKeyFrame = true }
    mutating func cancelEncoding() { encoding = nil; encodingStartedAt = nil }

    mutating func prepareMediaRecovery() {
        encoding = nil
        encodingStartedAt = nil
        waiting.removeAll()
        forceKeyFrame = true
        consecutiveDrops = 0
        mediaHold = true
        mediaRecoveryRequested = false
        mediaRecoveryIssued = false
        mediaRecoveryFrameEncoded = false
    }

    mutating func requestMediaRecoveryFrame() {
        guard mediaHold, !mediaRecoveryIssued else { return }
        mediaRecoveryIssued = true
        mediaRecoveryRequested = true
    }

    @discardableResult
    mutating func resumeMediaFrames() -> Bool {
        guard mediaHold, mediaRecoveryFrameEncoded else { return false }
        mediaHold = false
        mediaRecoveryRequested = false
        mediaRecoveryIssued = false
        return true
    }

    func stalled(at now: TimeInterval) -> String? {
        if let encodingStartedAt, now - encodingStartedAt > 90 { return "视频编码超过 90 秒无输出" }
        if let oldest = waiting.values.min(), now - oldest > 90 { return "视频解码确认超过 90 秒未返回" }
        return nil
    }
}

// ScreenCaptureKit sends nothing more once the screen stops changing, so its last frame keeps the quality rate
// control could give it: a keyframe or a frame in motion is often soft. Re-encoding that unchanged picture a few
// times lets the encoder sharpen it; every new frame postpones the next pass until the screen is still again.
struct StaticFrameRefinement {
    static let delays: [TimeInterval] = [0.25, 0.25, 0.5, 1]
    private(set) var remaining = 0
    private(set) var dueAt: TimeInterval?

    /// A captured frame left the encoder. A keyframe, or one using at least half the per-frame budget, earns a
    /// full set of passes; a small change keeps the passes left and only waits for stillness again.
    mutating func encoded(bytes: Int, keyFrame: Bool, budgetBytes: Int, at now: TimeInterval) {
        if keyFrame || bytes >= max(1, budgetBytes / 2) { remaining = Self.delays.count }
        schedule(at: now)
    }

    /// A pass left the encoder.
    mutating func refined(at now: TimeInterval) {
        remaining = max(0, remaining - 1)
        schedule(at: now)
    }

    /// A dropped capture still has a retained picture to refine; only a dropped pass uses an attempt.
    mutating func dropped(isRefinement: Bool, at now: TimeInterval) {
        if isRefinement { remaining = max(0, remaining - 1) }
        schedule(at: now)
    }

    func isDue(at now: TimeInterval) -> Bool { dueAt.map { now + 0.001 >= $0 } ?? false }

    /// A pass was handed to the encoder, or a new capture replaced the picture; its output schedules the next.
    mutating func wait() { dueAt = nil }

    mutating func cancel() { remaining = 0; dueAt = nil }

    private mutating func schedule(at now: TimeInterval) {
        dueAt = remaining > 0 && now.isFinite ? now + Self.delays[Self.delays.count - remaining] : nil
    }
}

struct VideoEncodeTiming {
    private var started: (encoderID: UUID, sequence: UInt32, at: TimeInterval)?

    mutating func begin(encoderID: UUID, sequence: UInt32, at now: TimeInterval) {
        started = now.isFinite ? (encoderID, sequence, now) : nil
    }

    mutating func complete(encoderID: UUID, sequence: UInt32, at now: TimeInterval) -> TimeInterval? {
        guard let started, started.encoderID == encoderID, started.sequence == sequence else { return nil }
        self.started = nil
        let duration = now - started.at
        return duration.isFinite && duration >= 0 ? duration : nil
    }

    mutating func cancel(encoderID: UUID? = nil) {
        if encoderID == nil || started?.encoderID == encoderID { started = nil }
    }
}

// displayTime is in mach absolute ticks; PTS is compared only with other SCK sample timestamps.
struct CursorCaptureGate {
    private(set) var included = true
    private(set) var needsFreshFrame = false
    private(set) var requestID: UUID?
    private(set) var configurationApplied = false
    private var presentationWatermark: CMTime?
    private var minimumPresentationTime: CMTime?
    private var minimumDisplayTime: UInt64?
    private var expectedDimensions: (Int, Int)?

    @discardableResult
    mutating func request(included: Bool, id: UUID = UUID()) -> UUID {
        self.included = included
        needsFreshFrame = true
        requestID = id
        configurationApplied = false
        minimumPresentationTime = nil
        minimumDisplayTime = nil
        expectedDimensions = nil
        return id
    }

    mutating func arm(id: UUID, afterDisplayTime: UInt64, width: Int, height: Int) -> Bool {
        guard requestID == id, needsFreshFrame, width > 0, height > 0 else { return false }
        configurationApplied = true
        minimumPresentationTime = presentationWatermark
        minimumDisplayTime = afterDisplayTime
        expectedDimensions = (width, height)
        return true
    }

    mutating func observe(_ sample: CMSampleBuffer, displayTime: UInt64?) -> (retain: Bool, completed: UUID?) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if time.isNumeric, presentationWatermark.map({ CMTimeCompare(time, $0) > 0 }) ?? true {
            presentationWatermark = time
        }
        guard needsFreshFrame else { return (true, nil) }
        guard let id = requestID, configurationApplied, time.isNumeric,
              minimumPresentationTime.map({ CMTimeCompare(time, $0) > 0 }) ?? true,
              let minimumDisplayTime, let displayTime, displayTime > minimumDisplayTime,
              let expectedDimensions, let image = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(image) == expectedDimensions.0,
              CVPixelBufferGetHeight(image) == expectedDimensions.1 else { return (false, nil) }
        needsFreshFrame = false
        requestID = nil
        configurationApplied = false
        return (true, id)
    }

    @discardableResult
    mutating func cancel(id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        configurationApplied = false
        return true
    }
}

// Capture state is confined to queue; callbacks are installed before start.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CursorConfigurationError: LocalizedError {
        case configurationTimeout, freshFrameTimeout, rollbackFailed(String)
        var errorDescription: String? {
            switch self {
            case .configurationTimeout: return "光标采集配置超过 2 秒未确认，需要重建共享"
            case .freshFrameTimeout: return "光标采集配置后超过 2 秒未收到可确认的新画面"
            case .rollbackFailed(let detail): return "光标采集无法恢复原配置及新画面，需要重建共享：\(detail)"
            }
        }
    }
    struct CapturePlan {
        fileprivate let filter: SCContentFilter
        fileprivate let displayID: CGDirectDisplayID
        let sourceWidth: Int
        let sourceHeight: Int
        fileprivate let settings: StreamSettings
        let width: Int
        let height: Int
    }

    let queue = DispatchQueue(label: "quietdesk.capture", qos: .userInteractive)
    var onFrame: ((VideoPacket) -> Void)?
    var onEncodeDuration: ((TimeInterval) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnosticError: ((Error) -> Void)?
    var onUserStop: (() -> Void)?
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var encoderID = UUID()
    private var displayID: CGDirectDisplayID?
    private var currentSettings = StreamSettings()
    private var outputWidth = 0
    private var outputHeight = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var latest: (CVPixelBuffer, CMTime, PerformanceDiagnostics.Token?)?
    private var lastCapture: (CVPixelBuffer, CMTime, PerformanceDiagnostics.Token?)?
    private var frameFlow = VideoFrameFlow()
    private var refinement = StaticFrameRefinement()
    private var refinementTimer: DispatchSourceTimer?
    private var lastCaptureAt: TimeInterval = 0
    // `latest` holds a refinement pass rather than a capture; then the sequence it is encoded as.
    private var latestIsRefinement = false
    private var refiningSequence: UInt32?
    private let diagnostics: PerformanceDiagnostics?
    private let encodingTimingLock = NSLock()
    private var encodingStarted: (id: UUID, sequence: UInt32, token: PerformanceDiagnostics.Token)?
    private var encodeTiming = VideoEncodeTiming()
    private var acknowledgements: [UInt32: PerformanceDiagnostics.Token] = [:]
    private var encoderHardwareChecked = false
    private var encoderHardware: Bool?
    private var running = false
    private var captureStarted = false
    private var excludedWindowIDs = Set<CGWindowID>()
    private var reconfiguring = false
    private var sessionPaused = false
    private var cursorGate = CursorCaptureGate()
    private var appliedCursorIncluded: Bool? = true
    private var lastConfirmedCursorIncluded = true
    private var cursorOperationID: UUID?
    private var cancelledCursorOperationID: UUID?
    private var cancelledCursorRequestID: UUID?
    private var cursorRollingBack = false
    private var cursorFrameWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var cursorFrameTimeout: DispatchSourceTimer?
    private let queueIdentity = DispatchSpecificKey<Bool>()
    private var idleWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var watchdog: DispatchSourceTimer?
    private let encoderCleanupQueue = DispatchQueue(label: "quietdesk.capture.encoder-cleanup", qos: .userInitiated)

    init(diagnostics: PerformanceDiagnostics? = nil) {
        self.diagnostics = diagnostics
        super.init()
        queue.setSpecific(key: queueIdentity, value: true)
    }

    var currentCursorIncluded: Bool? { cursorState().actual }
    var targetCursorIncluded: Bool? { cursorState().target }

    private func cursorState() -> (actual: Bool?, target: Bool?) {
        let read = { [self] in
            (actual: running && captureStarted ? appliedCursorIncluded : nil, target: running ? cursorGate.included : nil)
        }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    static func displaySnapshot(_ id: CGDirectDisplayID) -> DisplaySnapshot {
        let mode = CGDisplayCopyDisplayMode(id)
        let rotated = Int((CGDisplayRotation(id) / 90).rounded()) % 2 != 0
        let width = rotated ? mode?.pixelHeight : mode?.pixelWidth
        let height = rotated ? mode?.pixelWidth : mode?.pixelHeight
        return DisplaySnapshot(id: id, pixelWidth: width ?? CGDisplayPixelsWide(id),
                               pixelHeight: height ?? CGDisplayPixelsHigh(id), bounds: CGDisplayBounds(id))
    }

    static func prepareCapture(display: SCDisplay, settings: StreamSettings) -> CapturePlan {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let source = sourceDimensions(filter: filter, displayID: display.displayID)
        let (width, height) = settings.dimensions(width: source.width, height: source.height)
        return CapturePlan(filter: filter, displayID: display.displayID, sourceWidth: source.width,
                           sourceHeight: source.height, settings: settings, width: width, height: height)
    }

    private static func sourceDimensions(filter: SCContentFilter, displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        let fallback = displaySnapshot(displayID)
        // SCK reports the desktop rectangle in points, including on Retina displays.
        return DisplaySnapshot.capturePixelDimensions(contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale), fallbackWidth: fallback.pixelWidth,
            fallbackHeight: fallback.pixelHeight)
    }

    static func configuration(width: Int, height: Int, settings: StreamSettings, includesCursor: Bool = true) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.showsCursor = includesCursor
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        return configuration
    }

    private func makeEncoder(width: Int, height: Int, settings: StreamSettings, id: UUID) throws -> VideoEncoder {
        let encoder = try VideoEncoder(width: width, height: height, settings: settings)
        encoder.onOutput = { [weak self] result in
            guard let self else { return }
            let callbackAt = SessionClock.now
            let observation = self.encodingTimingLock.withLock { () -> (duration: TimeInterval?, diagnostic: (UInt32, PerformanceDiagnostics.Token)?) in
                let duration: TimeInterval?
                switch result {
                case .success(let packet): duration = self.encodeTiming.complete(encoderID: id, sequence: packet.sequence, at: callbackAt)
                case .failure: self.encodeTiming.cancel(encoderID: id); duration = nil
                }
                guard let started = self.encodingStarted, started.id == id else { return (duration, nil) }
                if case .success(let packet) = result, started.sequence != packet.sequence { return (duration, nil) }
                self.encodingStarted = nil
                return (duration, (started.sequence, started.token))
            }
            if let timing = observation.diagnostic { self.diagnostics?.record(.encode, since: timing.1, kind: .video, identifier: UInt64(timing.0)) }
            let encodedAt = self.diagnostics?.start()
            self.queue.async {
                guard self.running, self.encoderID == id else { return }
                if let duration = observation.duration { self.onEncodeDuration?(duration) }
                switch result {
                case .success(let packet):
                    if self.frameFlow.mediaHold {
                        guard !packet.sps.isEmpty, !packet.pps.isEmpty,
                              (try? MediaFrame.containsIDR(packet.avcc)) == true else {
                            self.frameFlow.cancelEncoding()
                            self.reportError(DeskError.invalid("媒体恢复未产生独立 IDR 帧"))
                            return
                        }
                    }
                    guard self.frameFlow.encoded(packet.sequence, at: SessionClock.now) else { return }
                    self.diagnostics?.record(.encodeCallbackQueue, since: encodedAt, kind: .video, identifier: UInt64(packet.sequence))
                    if let encodedAt { self.acknowledgements[packet.sequence] = encodedAt }
                    self.diagnostics?.recordValue(.encodedBytes, packet.avcc.count, kind: .video, identifier: UInt64(packet.sequence))
                    if !packet.sps.isEmpty {
                        self.diagnostics?.recordValue(.keyframeBytes, packet.avcc.count, kind: .video, identifier: UInt64(packet.sequence))
                    }
                    self.onFrame?(packet)
                    self.scheduleRefinement(after: packet)
                    self.completeFrameBoundary()
                case .failure(let error):
                    self.diagnostics?.record(.encodeCallbackQueue, since: encodedAt, kind: .video)
                    self.frameFlow.cancelEncoding()
                    if let waiter = self.idleWaiter {
                        self.idleWaiter = nil
                        waiter.1.resume(throwing: error)
                    }
                    self.reportError(error)
                }
            }
        }
        encoder.onDropped = { [weak self] number in
            guard let self else { return }
            let callbackAt = SessionClock.now
            let observation = self.encodingTimingLock.withLock { () -> (duration: TimeInterval?, diagnostic: PerformanceDiagnostics.Token?) in
                let duration = self.encodeTiming.complete(encoderID: id, sequence: number, at: callbackAt)
                guard let started = self.encodingStarted, started.id == id, started.sequence == number else { return (duration, nil) }
                self.encodingStarted = nil
                return (duration, started.token)
            }
            self.diagnostics?.record(.encode, since: observation.diagnostic, kind: .video, identifier: UInt64(number))
            let droppedAt = self.diagnostics?.start()
            self.queue.async {
                guard self.running, self.encoderID == id, self.frameFlow.dropped(number) else { return }
                if let duration = observation.duration { self.onEncodeDuration?(duration) }
                self.diagnostics?.record(.encodeCallbackQueue, since: droppedAt, kind: .video, identifier: UInt64(number))
                self.refinement.dropped(isRefinement: self.refiningSequence == number, at: SessionClock.now)
                self.refiningSequence = nil
                self.armRefinementTimer()
                self.completeFrameBoundary()
            }
        }
        return encoder
    }

    private func reportError(_ error: Error, message: String? = nil) {
        onDiagnosticError?(error)
        onError?(message ?? error.localizedDescription)
    }

    func start(_ capture: CapturePlan) async throws {
        let width = capture.width, height = capture.height, settings = capture.settings
        let id = UUID()
        let encoder = try makeEncoder(width: width, height: height, settings: settings, id: id)
        let stream = SCStream(filter: capture.filter,
            configuration: Self.configuration(width: width, height: height, settings: settings), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.encoder = encoder
            encoderHardwareChecked = false
            encoderHardware = nil
            encoderID = id
            self.stream = stream
            excludedWindowIDs = []
            displayID = capture.displayID
            outputWidth = width
            outputHeight = height
            sourceWidth = capture.sourceWidth
            sourceHeight = capture.sourceHeight
            currentSettings = settings
            cursorGate = CursorCaptureGate()
            appliedCursorIncluded = true
            lastConfirmedCursorIncluded = true
            running = true
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.schedule(deadline: .now() + 2, repeating: 2)
            watchdog.setEventHandler { [weak self] in
                guard let self, self.running,
                      let message = self.frameFlow.stalled(at: SessionClock.now) else { return }
                self.reportError(DeskError.invalid(message))
            }
            self.watchdog = watchdog
            watchdog.resume()
        }
        do {
            try await stream.startCapture()
            let current = queue.sync { () -> Bool in
                guard self.stream === stream, running else { return false }
                captureStarted = true
                return true
            }
            guard current else {
                try? stream.removeStreamOutput(self, type: .screen)
                try? await stream.stopCapture()
                throw CancellationError()
            }
        } catch { await stop(); throw error }
    }

    // The media coordinator suspends delivery first and resumes this reconfiguration before requesting a new IDR.
    // While paused only the target changes; currentCursorIncluded remains the last verified capture mode.
    func setCursorIncluded(_ included: Bool) async throws {
        try Task.checkCancellation()
        let operation = UUID()
        let snapshot = try queue.sync { () throws -> (stream: SCStream, previous: Bool, paused: Bool)? in
            guard running, captureStarted, let stream else { throw DeskError.invalid("屏幕采集尚未就绪") }
            guard cursorOperationID == nil, !reconfiguring, cursorFrameWaiter == nil else {
                throw DeskError.invalid("正在调整采集配置，请稍后重试光标切换")
            }
            guard included != cursorGate.included || cursorGate.needsFreshFrame else { return nil }
            cursorOperationID = operation
            cancelledCursorOperationID = nil
            cursorGate.request(included: included)
            latest = nil
            lastCapture = nil
            return (stream, appliedCursorIncluded ?? lastConfirmedCursorIncluded, sessionPaused)
        }
        guard let snapshot else { return }
        defer {
            queue.sync {
                if cursorOperationID == operation { cursorOperationID = nil; cancelledCursorOperationID = nil }
            }
        }
        if snapshot.paused { return }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await pauseAtFrameBoundary(cursorOperation: operation)
                try await applyCursorConfiguration(included, stream: snapshot.stream, operation: operation)
                try Task.checkCancellation()
                try queue.sync {
                    if cancelledCursorOperationID == operation { throw CancellationError() }
                }
            } onCancel: { [weak self] in
                self?.queue.async { [weak self] in self?.cancelCursorOperation(operation) }
            }
        } catch {
            let original = error
            guard queue.sync(execute: { running && stream === snapshot.stream }) else { throw CancellationError() }
            if case CursorConfigurationError.configurationTimeout = original {
                queue.sync { reconfiguring = false }
                throw original
            }
            do { try await restoreCursorConfiguration(snapshot.previous, stream: snapshot.stream) }
            catch {
                queue.sync { if stream === snapshot.stream { reconfiguring = false } }
                throw error
            }
            queue.sync { if stream === snapshot.stream { reconfiguring = false } }
            throw original
        }
        // Keep reconfiguring true until the coordinator sends its result and calls resumeAfterReconfiguration.
    }

    private func applyCursorConfiguration(_ included: Bool, stream expectedStream: SCStream,
                                          operation: UUID? = nil, ignoringCancellation: Bool = false) async throws {
        let request = UUID()
        let expectedStreamID = ObjectIdentifier(expectedStream)
        try await withTaskCancellationHandler {
            let alreadyCancelled = Task.isCancelled
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard running, let activeStream = stream, ObjectIdentifier(activeStream) == expectedStreamID else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    guard cursorFrameWaiter == nil else {
                        continuation.resume(throwing: DeskError.invalid("另一个光标采集更新尚未完成")); return
                    }
                    if !ignoringCancellation,
                       alreadyCancelled || cancelledCursorRequestID == request || operation.map({ cancelledCursorOperationID == $0 }) == true {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    cursorGate.request(included: included, id: request)
                    appliedCursorIncluded = nil
                    latest = nil
                    lastCapture = nil
                    cursorFrameWaiter = (request, continuation)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 2)
                    timer.setEventHandler { [weak self] in
                        guard let self, self.cursorFrameWaiter?.id == request else { return }
                        let error: CursorConfigurationError = self.cursorGate.configurationApplied ? .freshFrameTimeout : .configurationTimeout
                        self.finishCursorFrameWaiter(request, result: .failure(error))
                    }
                    cursorFrameTimeout = timer
                    timer.resume()
                    let width = outputWidth, height = outputHeight
                    activeStream.updateConfiguration(Self.configuration(width: width, height: height,
                        settings: currentSettings, includesCursor: included), completionHandler: { [weak self] error in
                            self?.queue.async { [weak self] in
                                guard let self, self.running, self.stream.map(ObjectIdentifier.init) == expectedStreamID,
                                      self.cursorFrameWaiter?.id == request else { return }
                                if let error { self.finishCursorFrameWaiter(request, result: .failure(error)); return }
                                // This queue barrier drains already delivered samples. displayTime uses the documented mach clock.
                                guard self.cursorGate.arm(id: request, afterDisplayTime: mach_absolute_time(), width: width, height: height) else {
                                    self.finishCursorFrameWaiter(request, result: .failure(CancellationError())); return
                                }
                                if !ignoringCancellation, self.cancelledCursorRequestID == request
                                    || operation.map({ self.cancelledCursorOperationID == $0 }) == true {
                                    self.finishCursorFrameWaiter(request, result: .failure(CancellationError()))
                                }
                            }
                        })
                }
            }
        } onCancel: { [weak self] in
            guard !ignoringCancellation else { return }
            self?.queue.async { [weak self] in self?.cancelCursorRequest(request) }
        }
    }

    private func restoreCursorConfiguration(_ included: Bool, stream: SCStream) async throws {
        queue.sync { cursorRollingBack = true }
        defer { queue.sync { if self.stream === stream { cursorRollingBack = false } } }
        do { try await applyCursorConfiguration(included, stream: stream, ignoringCancellation: true) }
        catch {
            guard queue.sync(execute: { running && self.stream === stream }) else { throw CancellationError() }
            throw CursorConfigurationError.rollbackFailed(error.localizedDescription)
        }
    }

    private func cancelCursorOperation(_ operation: UUID) {
        guard cursorOperationID == operation else { return }
        cancelledCursorOperationID = operation
        guard !cursorRollingBack else { return }
        if let waiter = cursorFrameWaiter { cancelCursorRequest(waiter.id) }
        if let waiter = idleWaiter {
            idleWaiter = nil
            reconfiguring = false
            waiter.1.resume(throwing: CancellationError())
        }
    }

    private func cancelCursorRequest(_ request: UUID) {
        cancelledCursorRequestID = request
        // Let an in-flight SCK update settle before rollback. If it never returns, its bounded timer forces reconnect.
        if cursorFrameWaiter?.id == request, cursorGate.configurationApplied {
            finishCursorFrameWaiter(request, result: .failure(CancellationError()))
        }
    }

    private func finishCursorFrameWaiter(_ request: UUID, result: Result<Void, Error>) {
        guard let waiter = cursorFrameWaiter, waiter.id == request else { return }
        cursorFrameWaiter = nil
        cursorFrameTimeout?.cancel()
        cursorFrameTimeout = nil
        if case .failure = result { cursorGate.cancel(id: request) }
        waiter.continuation.resume(with: result)
    }

    // Bitrate alone does not change capture, dimensions or the encoder, so no pause or keyframe is needed.
    func updateBitrate(_ settings: StreamSettings) throws -> VideoStreamState {
        try settings.validateControlValues()
        return try queue.sync {
            guard running, captureStarted, let encoder, !reconfiguring,
                  settings.longestEdge == currentSettings.longestEdge,
                  settings.framesPerSecond == currentSettings.framesPerSecond else {
                throw DeskError.invalid("画质正在调整，请稍后再试")
            }
            try encoder.updateBitrate(megabits: settings.megabits)
            currentSettings = settings
            return VideoStreamState(settings: settings, width: outputWidth, height: outputHeight)
        }
    }

    func reconfigure(_ settings: StreamSettings) async throws -> VideoStreamState {
        try settings.validateControlValues()
        let snapshot = try queue.sync { () throws -> (SCStream, Int, Int, Int, Int, StreamSettings, Bool) in
            guard running, captureStarted, let stream, displayID != nil else { throw DeskError.invalid("屏幕采集尚未就绪，请稍后调整") }
            if let operation = cursorOperationID { cancelCursorOperation(operation); throw DeskError.invalid("光标采集正在更新，请稍后调整画质") }
            if let waiter = cursorFrameWaiter {
                cancelCursorRequest(waiter.id)
                throw DeskError.invalid("正在等待光标采集的新画面")
            }
            return (stream, sourceWidth, sourceHeight, outputWidth, outputHeight, currentSettings, cursorGate.included)
        }
        let (width, height) = settings.dimensions(width: snapshot.1, height: snapshot.2)
        let id = UUID()
        let replacement = try makeEncoder(width: width, height: height, settings: settings, id: id)
        do { try await pauseAtFrameBoundary() }
        catch { replacement.stop(); throw error }
        do {
            try Task.checkCancellation()
            try await snapshot.0.updateConfiguration(Self.configuration(width: width, height: height, settings: settings, includesCursor: snapshot.6))
            try Task.checkCancellation()
            try queue.sync {
                guard running, stream === snapshot.0 else { throw CancellationError() }
                let old = encoder
                encoderID = id
                encoder = replacement
                encodingTimingLock.withLock { encodeTiming.cancel() }
                encoderHardwareChecked = false
                encoderHardware = nil
                outputWidth = width
                outputHeight = height
                currentSettings = settings
                frameFlow.requestKeyFrame()
                cancelRefinement()
                latest = cursorGate.needsFreshFrame ? nil : lastCapture
                if cursorGate.needsFreshFrame { lastCapture = nil; appliedCursorIncluded = nil }
                // Replaying a retained frame is intentional, not capture-queue congestion.
                latest?.2 = nil
                discardMismatchedFrame()
                old?.stop()
            }
            // The caller sends the settings result before resuming the new encoder.
            return VideoStreamState(settings: settings, width: width, height: height)
        } catch {
            replacement.stop()
            if queue.sync(execute: { running && stream === snapshot.0 }) {
                do {
                    try await snapshot.0.updateConfiguration(Self.configuration(width: snapshot.3, height: snapshot.4, settings: snapshot.5, includesCursor: snapshot.6))
                    queue.sync {
                        guard running, stream === snapshot.0 else { return }
                        frameFlow.requestKeyFrame()
                        discardMismatchedFrame()
                        reconfiguring = false
                        pump()
                    }
                } catch let rollbackError {
                    queue.async { [weak self] in
                        self?.reportError(rollbackError, message: "画质调整失败且无法恢复原配置：\(rollbackError.localizedDescription)")
                    }
                }
            }
            throw error
        }
    }

    func setSessionPaused(_ paused: Bool) async throws -> Bool {
        let snapshot = try queue.sync { () throws -> (SCStream, Bool, Bool) in
            guard running, captureStarted, let stream else { throw DeskError.invalid("屏幕采集尚未就绪") }
            if let operation = cursorOperationID { cancelCursorOperation(operation); throw DeskError.invalid("光标采集正在更新，请稍后暂停或恢复") }
            if let waiter = cursorFrameWaiter {
                cancelCursorRequest(waiter.id)
                throw DeskError.invalid("正在等待光标采集的新画面")
            }
            return (stream, sessionPaused, appliedCursorIncluded ?? lastConfirmedCursorIncluded)
        }
        let current = snapshot.0
        try await pauseAtFrameBoundary()
        do {
            try Task.checkCancellation()
            let pendingCursor = try queue.sync { () throws -> Bool? in
                guard running, stream === current else { throw CancellationError() }
                sessionPaused = paused
                if paused { reconfiguring = false; cancelRefinement() }
                else {
                    frameFlow.requestKeyFrame()
                    if cursorGate.needsFreshFrame { return cursorGate.included }
                    latest = lastCapture
                    latest?.2 = nil
                    discardMismatchedFrame()
                }
                return nil
            }
            if let pendingCursor {
                do { try await applyCursorConfiguration(pendingCursor, stream: current) }
                catch {
                    if case CursorConfigurationError.configurationTimeout = error { throw error }
                    try await restoreCursorConfiguration(snapshot.2, stream: current)
                    throw error
                }
            }
            // The caller sends the resume result before releasing the new keyframe.
            return paused
        } catch {
            queue.sync {
                guard running, stream === current else { return }
                sessionPaused = snapshot.1
                reconfiguring = false
                pump()
            }
            throw error
        }
    }

    /// Leaves exactly these windows (the privacy curtain) out of the capture; every other window,
    /// QuietDesk's own included, stays visible to the viewer. An empty list captures everything.
    func setExcludedWindows(_ windowIDs: [CGWindowID]) async throws {
        let wanted = Set(windowIDs)
        // A cursor change in progress finishes first; cancelling it would force a rollback that
        // needs yet another fresh frame, which a still screen may never deliver.
        var snapshot: (SCStream, CGDirectDisplayID)?
        for attempt in 0..<100 {
            let busy = try queue.sync { () throws -> Bool in
                guard running, let stream, let displayID else { throw DeskError.invalid("屏幕采集尚未就绪") }
                if cursorOperationID != nil || cursorFrameWaiter != nil { return true }
                snapshot = excludedWindowIDs == wanted ? nil : (stream, displayID)
                return false
            }
            guard busy else { break }
            guard attempt < 99 else { throw DeskError.invalid("光标采集正在更新，请稍后调整防窥") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let snapshot else { return }
        var display: SCDisplay?
        var excluded: [SCWindow] = []
        // A window ordered in a moment ago can take a few frames to show up in shareable content.
        for attempt in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first(where: { $0.displayID == snapshot.1 })
            excluded = content.windows.filter { wanted.contains($0.windowID) }
            if excluded.count == wanted.count { break }
            guard attempt < 19 else { throw DeskError.invalid("无法从采集中排除防窥遮罩，防窥未开启") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let display else { throw DeskError.invalid("共享的显示器已变化，请等待重新连接") }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        try Task.checkCancellation()
        try await snapshot.0.updateContentFilter(filter)
        try Task.checkCancellation()
        try queue.sync {
            guard running, stream === snapshot.0 else { throw CancellationError() }
            excludedWindowIDs = wanted
            frameFlow.requestKeyFrame()
        }
    }

    private func pauseAtFrameBoundary(cursorOperation: UUID? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let cursorOperation,
                   cursorOperationID != cursorOperation || cancelledCursorOperationID == cursorOperation {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard running, captureStarted, !reconfiguring else {
                    continuation.resume(throwing: DeskError.invalid("共享未就绪或正在调整画质"))
                    return
                }
                reconfiguring = true
                if frameFlow.isIdle { continuation.resume(); return }
                let token = UUID()
                idleWaiter = (token, continuation)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, let waiter = self.idleWaiter, waiter.0 == token else { return }
                    self.idleWaiter = nil
                    self.reconfiguring = false
                    waiter.1.resume(throwing: DeskError.invalid("仍有视频帧未确认，请稍后重试调整"))
                    self.pump()
                }
            }
        }
    }

    func resumeAfterReconfiguration() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.reconfiguring = false
            self.pump()
        }
    }

    // Completion runs on the capture queue. A new encoder fences outputs still arriving from the old epoch.
    func prepareMediaRecovery(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.running, self.captureStarted, !self.reconfiguring, !self.sessionPaused else {
                completion(false)
                return
            }
            let id = UUID()
            let replacement: VideoEncoder
            do { replacement = try self.makeEncoder(width: self.outputWidth, height: self.outputHeight, settings: self.currentSettings, id: id) }
            catch {
                self.onDiagnosticError?(error)
                completion(false)
                return
            }
            let old = self.encoder
            self.encoderID = id
            self.encoder = replacement
            self.encoderHardwareChecked = false
            self.encoderHardware = nil
            self.encodingTimingLock.withLock { self.encodingStarted = nil; self.encodeTiming.cancel() }
            self.acknowledgements.removeAll()
            self.frameFlow.prepareMediaRecovery()
            self.cancelRefinement()
            self.latest = self.lastCapture
            self.latest?.2 = nil
            self.discardMismatchedFrame()
            // Completing an old encoder must not block the new epoch or wait for a lost decoder ACK.
            self.encoderCleanupQueue.async { old?.stop() }
            completion(true)
        }
    }

    func produceMediaRecoveryFrame() {
        queue.async { [weak self] in
            guard let self, self.running, !self.reconfiguring, !self.sessionPaused, self.frameFlow.mediaHold else { return }
            if self.latest == nil {
                self.latest = self.lastCapture
                self.latest?.2 = nil
            }
            self.frameFlow.requestMediaRecoveryFrame()
            self.pump()
        }
    }

    func resumeMediaFrames() {
        queue.async { [weak self] in
            guard let self, self.running, !self.reconfiguring, !self.sessionPaused,
                  self.frameFlow.resumeMediaFrames() else { return }
            // A pass that fell due during the hold runs now that frames may flow again.
            self.armRefinementTimer()
            self.pump()
        }
    }

    func acknowledge(_ number: UInt32) {
        queue.async { [weak self] in
            guard let self, self.frameFlow.acknowledge(number) else { return }
            self.diagnostics?.record(.videoAck, since: self.acknowledgements.removeValue(forKey: number),
                                     kind: .video, identifier: UInt64(number))
            self.diagnostics?.recordValue(.videoOutstanding, self.frameFlow.waiting.count + (self.frameFlow.encoding == nil ? 0 : 1))
            self.completeFrameBoundary()
        }
    }

    private func completeFrameBoundary() {
        if frameFlow.isIdle, let waiter = idleWaiter {
            idleWaiter = nil
            waiter.1.resume()
        }
        pump()
    }

    func stop() async {
        let old: SCStream? = queue.sync {
            running = false
            captureStarted = false
            reconfiguring = false
            latest = nil
            lastCapture = nil
            cancelRefinement()
            refinementTimer?.cancel()
            refinementTimer = nil
            if let waiter = cursorFrameWaiter { finishCursorFrameWaiter(waiter.id, result: .failure(CancellationError())) }
            cursorGate = CursorCaptureGate()
            appliedCursorIncluded = nil
            lastConfirmedCursorIncluded = true
            cursorOperationID = nil
            cancelledCursorOperationID = nil
            cancelledCursorRequestID = nil
            cursorRollingBack = false
            encodingTimingLock.withLock { encodingStarted = nil; encodeTiming.cancel() }
            acknowledgements.removeAll()
            frameFlow = VideoFrameFlow(sequence: frameFlow.sequence)
            if let waiter = idleWaiter { idleWaiter = nil; waiter.1.resume(throwing: CancellationError()) }
            watchdog?.cancel()
            watchdog = nil
            encoder?.stop()
            encoder = nil
            let old = stream
            stream = nil
            return old
        }
        try? await old?.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if let waiter = self.cursorFrameWaiter { self.finishCursorFrameWaiter(waiter.id, result: .failure(error)) }
            if (error as NSError).domain == SCStreamErrorDomain,
               (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
                self.onUserStop?()
                return
            }
            self.reportError(error, message: "屏幕采集停止：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard running, self.stream === stream, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !reconfiguring, (CVPixelBufferGetWidth(buffer) != outputWidth || CVPixelBufferGetHeight(buffer) != outputHeight) { return }
        let cursorFrame = cursorGate.observe(sampleBuffer, displayTime: attachments.first?[.displayTime] as? UInt64)
        guard cursorFrame.retain else { return }
        if latest != nil, !latestIsRefinement, !sessionPaused, !reconfiguring { diagnostics?.recordValue(.captureReplaced, 1) }
        // SCK presentation time is not in the SessionClock domain.
        latest = (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), diagnostics?.start())
        lastCapture = latest
        lastCaptureAt = SessionClock.now
        latestIsRefinement = false
        refinement.wait()
        if let request = cursorFrame.completed {
            appliedCursorIncluded = cursorGate.included
            lastConfirmedCursorIncluded = cursorGate.included
            finishCursorFrameWaiter(request, result: .success(()))
        }
        pump()
    }

    // Runs on the capture queue once a frame's output was handed on.
    private func scheduleRefinement(after packet: VideoPacket) {
        let now = SessionClock.now
        if refiningSequence == packet.sequence {
            refiningSequence = nil
            refinement.refined(at: now)
        } else {
            let budget = currentSettings.megabits * 125_000 / max(1, min(currentSettings.framesPerSecond, 60))
            refinement.encoded(bytes: packet.avcc.count, keyFrame: !packet.sps.isEmpty, budgetBytes: budget, at: now)
        }
        armRefinementTimer()
    }

    private func armRefinementTimer() {
        guard let dueAt = refinement.dueAt else { return }
        let timer: DispatchSourceTimer
        if let refinementTimer { timer = refinementTimer }
        else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.refineIfDue() }
            refinementTimer = timer
            timer.resume()
        }
        timer.schedule(deadline: .now() + max(0, dueAt - SessionClock.now), leeway: .milliseconds(20))
    }

    // Replays the last capture only while nothing newer waits, and never across a pause, a reconfiguration,
    // a cursor change awaiting its fresh frame or a media recovery hold. Its time advances by the real wait.
    private func refineIfDue() {
        let now = SessionClock.now
        guard running, captureStarted, !reconfiguring, !sessionPaused, !cursorGate.needsFreshFrame, !frameFlow.mediaHold,
              refinement.isDue(at: now), latest == nil, let last = lastCapture,
              CVPixelBufferGetWidth(last.0) == outputWidth, CVPixelBufferGetHeight(last.0) == outputHeight else { return }
        refinement.wait()
        latest = (last.0, CMTimeAdd(last.1, CMTime(seconds: max(0, now - lastCaptureAt), preferredTimescale: 1_000_000)), nil)
        latestIsRefinement = true
        pump()
    }

    private func cancelRefinement() {
        refinement.cancel()
        refiningSequence = nil
        if latestIsRefinement { latest = nil; latestIsRefinement = false }
    }

    private func discardMismatchedFrame() {
        if let latest, CVPixelBufferGetWidth(latest.0) != outputWidth || CVPixelBufferGetHeight(latest.0) != outputHeight { self.latest = nil }
    }

    private func pump() {
        guard running, !reconfiguring, !sessionPaused, !cursorGate.needsFreshFrame else { return }
        discardMismatchedFrame()
        guard let latest else {
            // A one-shot timer may have fired during a configuration that was cancelled or rolled back.
            armRefinementTimer()
            return
        }
        guard let encoder,
              let frame = frameFlow.begin(at: SessionClock.now) else { return }
        self.latest = nil
        refiningSequence = latestIsRefinement ? frame.sequence : nil
        latestIsRefinement = false
        if diagnostics?.isEnabled == true {
            if !encoderHardwareChecked {
                encoderHardware = encoder.hardwareAccelerationStatus
                encoderHardwareChecked = true
            }
            if let encoderHardware { diagnostics?.recordValue(.encoderHardware, encoderHardware ? 1 : 0) }
        }
        diagnostics?.record(.captureAge, since: latest.2, kind: .video, identifier: UInt64(frame.sequence))
        diagnostics?.recordValue(.videoOutstanding, frameFlow.waiting.count + 1)
        let timing = diagnostics?.start()
        let submittedAt = SessionClock.now
        encodingTimingLock.withLock {
            encodingStarted = timing.map { (encoderID, frame.sequence, $0) }
            encodeTiming.begin(encoderID: encoderID, sequence: frame.sequence, at: submittedAt)
        }
        do { try encoder.encode(latest.0, time: latest.1, sequence: frame.sequence, forceKeyFrame: frame.forceKeyFrame) }
        catch {
            encodingTimingLock.withLock { encodingStarted = nil; encodeTiming.cancel() }
            frameFlow.cancelEncoding()
            reportError(error)
        }
    }

    deinit { watchdog?.cancel(); refinementTimer?.cancel() }
}

@MainActor
final class InputInjector {
    private static let modifierDeviceBits: [UInt16: UInt64] = [
        59: 0x01, 56: 0x02, 60: 0x04, 55: 0x08,
        54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000
    ]
    let bounds: CGRect
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var inputFlags: CGEventFlags = []
    private var scroll = ScrollAccumulator()
    private var lineScroll = ScrollAccumulator()
    // Gesture and momentum phases already given to apps and not yet ended.
    private var openScrollPhase: RemoteInput.ScrollPhase?
    private var momentumOpen = false
    private let source = CGEventSource(stateID: .hidSystemState)
    private let inputSources: InputSources
    private var remoteCapsLock: Bool?
    private let isTrusted: () -> Bool
    private let postEvent: (CGEvent) -> Void
    private let capsLockState: () -> Bool
    private let pointerLocation: () -> CGPoint?

    convenience init(displayID: CGDirectDisplayID) { self.init(bounds: CGDisplayBounds(displayID)) }

    init(bounds: CGRect, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         inputSources: InputSources? = nil,
         capsLockState: @escaping () -> Bool = { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) },
         pointerLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.bounds = bounds
        self.isTrusted = isTrusted
        self.postEvent = postEvent
        self.inputSources = inputSources ?? InputSources()
        self.capsLockState = capsLockState
        self.pointerLocation = pointerLocation
    }

    func receive(_ input: RemoteInput) async throws -> InputFeedback? {
        try input.validate()
        guard isTrusted() else { releaseAll(); return nil }
        if input.independentCapsLock == true || input.kind == .switchInputSource || input.kind == .toggleCapsLock {
            if remoteCapsLock == nil { remoteCapsLock = capsLockState() }
        }
        if input.kind == .switchInputSource || input.kind == .toggleCapsLock {
            guard !inputSources.requiresKeyboardRefocus else {
                return InputFeedback(message: "请点击远端输入位置后继续", capsLocked: remoteCapsLock == true)
            }
            if input.kind == .toggleCapsLock || remoteCapsLock == true {
                remoteCapsLock = !(remoteCapsLock ?? false)
                let event = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: remoteCapsLock == true)
                event?.type = .flagsChanged
                var modifiers = CGEventSource.flagsState(.combinedSessionState)
                modifiers.remove(.maskAlphaShift)
                if remoteCapsLock == true { modifiers.insert(.maskAlphaShift) }
                event?.flags = modifiers
                if let event { inputFlags = modifiers; postEvent(event) }
                return InputFeedback(message: remoteCapsLock == true ? "远端大写锁定已开启" : "远端大写锁定已关闭",
                                     capsLocked: remoteCapsLock == true)
            }
            do {
                let selected = try await inputSources.toggle()
                guard isTrusted() else { releaseAll(); return nil }
                return InputFeedback(message: "远端输入源已确认：\(selected)", capsLocked: false)
            } catch is CancellationError {
                return nil
            } catch {
                if inputSources.requiresKeyboardRefocus {
                    releaseAll()
                    return InputFeedback(message: "\(error.localizedDescription)，请点击远端输入位置后继续", capsLocked: remoteCapsLock == true)
                }
                return InputFeedback(message: error.localizedDescription, capsLocked: remoteCapsLock == true)
            }
        }
        let point = CGPoint(x: bounds.minX + input.x * max(0, bounds.width - 1),
                            y: bounds.minY + input.y * max(0, bounds.height - 1))
        let mask: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
                                  .maskCommand, .maskSecondaryFn, .maskNumericPad]
        var flags = CGEventFlags(rawValue: input.flags).intersection(mask)
        if input.independentCapsLock == true {
            flags.remove(.maskAlphaShift)
            if remoteCapsLock == true { flags.insert(.maskAlphaShift) }
        }
        var event: CGEvent?
        let button = CGMouseButton(rawValue: UInt32(input.button)) ?? .left
        switch input.kind {
        case .keyDown, .keyUp, .flags:
            guard !inputSources.requiresKeyboardRefocus else { return nil }
            if input.kind == .flags {
                // Modifier keys arrive as flagsChanged, not ordinary keyDown/keyUp.
                let modifier: CGEventFlags
                switch input.keyCode {
                case 54, 55: modifier = .maskCommand
                case 56, 60: modifier = .maskShift
                case 58, 61: modifier = .maskAlternate
                case 59, 62: modifier = .maskControl
                case 57: modifier = .maskAlphaShift
                case 63: modifier = .maskSecondaryFn
                default: return nil
                }
                let down: Bool
                if input.flags & 0x207F != 0, let bit = Self.modifierDeviceBits[input.keyCode] {
                    down = input.flags & bit != 0
                } else { down = flags.contains(modifier) }
                event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode, keyDown: down)
                event?.type = .flagsChanged
                if down { heldKeys.insert(input.keyCode) } else { heldKeys.remove(input.keyCode) }
            } else {
                let down = input.kind == .keyDown
                event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode, keyDown: down)
                event?.setIntegerValueField(.keyboardEventAutorepeat, value: input.isRepeat ? 1 : 0)
                if down { heldKeys.insert(input.keyCode) } else { heldKeys.remove(input.keyCode) }
            }
        case .scroll:
            // A wheel or an older viewer sends no phases; finish any gesture an interrupted stream left open.
            if input.scrollPhase == nil && input.momentumPhase == nil { endScrollPhases() }
            let wheels = try scrollEvents(input)
            guard let wheel = wheels.last else { return nil }
            // A scroll's location does not move the pointer used for window and view routing, so move it there
            // first. Skip the move once the pointer is already there: one per wheel event redoes hover mid-scroll.
            let current = pointerLocation()
            if current.map({ abs($0.x - point.x) >= 0.5 || abs($0.y - point.y) >= 0.5 }) ?? true {
                let heldButton = heldButtons.min()
                let moveType: CGEventType = heldButton == nil ? .mouseMoved
                    : heldButton == 0 ? .leftMouseDragged : heldButton == 1 ? .rightMouseDragged : .otherMouseDragged
                let moveButton = CGMouseButton(rawValue: UInt32(heldButton ?? 0)) ?? .left
                guard let move = CGEvent(mouseEventSource: source, mouseType: moveType, mouseCursorPosition: point,
                                         mouseButton: moveButton) else {
                    throw DeskError.invalid("无法建立远端滚动事件")
                }
                move.flags = flags
                postEvent(move)
            }
            for earlier in wheels.dropLast() {
                earlier.location = point
                earlier.flags = flags
                postEvent(earlier)
            }
            lastPoint = point
            event = wheel
            event?.location = point
        case .move, .drag, .down, .up:
            let type: CGEventType
            switch input.kind {
            case .down:
                inputSources.requiresKeyboardRefocus = false
                heldButtons.insert(input.button)
                type = input.button == 0 ? .leftMouseDown : input.button == 1 ? .rightMouseDown : .otherMouseDown
            case .up:
                heldButtons.remove(input.button)
                type = input.button == 0 ? .leftMouseUp : input.button == 1 ? .rightMouseUp : .otherMouseUp
            case .drag:
                type = input.button == 0 ? .leftMouseDragged : input.button == 1 ? .rightMouseDragged : .otherMouseDragged
            default: type = .mouseMoved
            }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clicks))
            lastPoint = point
        case .switchInputSource, .toggleCapsLock: return nil
        }
        event?.flags = flags
        if let event { inputFlags = flags; postEvent(event) }
        return nil
    }

    // Wheel events for one scroll input in posting order; the last is the input's own, earlier ones end or
    // begin a phase whose own event was lost. Empty when it moves less than a pixel and starts or ends nothing.
    private func scrollEvents(_ input: RemoteInput) throws -> [CGEvent] {
        if let lineX = input.lineDeltaX, let lineY = input.lineDeltaY {
            // A wheel stays a line wheel, so apps scroll by their own line height, as with a local mouse.
            guard lineX != 0 || lineY != 0 else { return [] }
            let pixels = try scroll.accumulate(deltaX: input.deltaX, deltaY: input.deltaY)
            let lines = try lineScroll.accumulate(deltaX: lineX, deltaY: lineY)
            let wheel = try wheelEvent(units: .line, x: lines?.x ?? 0, y: lines?.y ?? 0)
            wheel.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: lineY)
            wheel.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lineX)
            wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels?.y ?? 0))
            wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pixels?.x ?? 0))
            return [wheel]
        }
        let pixels = try scroll.accumulate(deltaX: input.deltaX, deltaY: input.deltaY)
        guard input.scrollPhase != nil || input.momentumPhase != nil else {
            // An older viewer, or a precise device outside a gesture: pixels as before.
            guard let pixels else { return [] }
            return [try wheelEvent(units: .pixel, x: pixels.x, y: pixels.y)]
        }
        func wheel(_ phase: RemoteInput.ScrollPhase?, _ momentum: RemoteInput.MomentumPhase?,
                   moving: Bool = true) throws -> CGEvent {
            let event = try wheelEvent(units: .pixel, x: moving ? pixels?.x ?? 0 : 0, y: moving ? pixels?.y ?? 0 : 0)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
            return event
        }
        // A gesture phase and a momentum phase do not occur together; the gesture phase wins. An ending lost
        // on the way is supplied before the next phase, so apps always see a gesture begin and end in order.
        var events: [CGEvent] = []
        if let phase = input.scrollPhase {
            if momentumOpen {
                momentumOpen = false
                events.append(try wheel(nil, .ended, moving: false))
            }
            switch phase {
            case .mayBegin, .began:
                if let open = openScrollPhase, open != .mayBegin { events.append(try wheel(.ended, nil, moving: false)) }
                openScrollPhase = phase
                events.append(try wheel(phase, nil))
            case .changed:
                if openScrollPhase == nil || openScrollPhase == .mayBegin { events.append(try wheel(.began, nil, moving: false)) }
                openScrollPhase = .changed
                if pixels != nil { events.append(try wheel(.changed, nil)) }
            case .ended, .cancelled:
                guard openScrollPhase != nil else { return events }
                openScrollPhase = nil
                events.append(try wheel(phase, nil))
                scroll.reset()
            }
            return events
        }
        guard let momentum = input.momentumPhase else { return [] }
        if let open = openScrollPhase {
            openScrollPhase = nil
            events.append(try wheel(open == .mayBegin ? .cancelled : .ended, nil, moving: false))
        }
        switch momentum {
        case .began:
            if momentumOpen { events.append(try wheel(nil, .ended, moving: false)) }
            momentumOpen = true
            events.append(try wheel(nil, .began))
        case .changed:
            if !momentumOpen { events.append(try wheel(nil, .began, moving: false)) }
            momentumOpen = true
            if pixels != nil { events.append(try wheel(nil, .changed)) }
        case .ended:
            guard momentumOpen else { return events }
            momentumOpen = false
            events.append(try wheel(nil, .ended))
            scroll.reset()
        }
        return events
    }

    private func wheelEvent(units: CGScrollEventUnit, x: Int32, y: Int32) throws -> CGEvent {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                                  wheel1: y, wheel2: x, wheel3: 0) else {
            throw DeskError.invalid("无法建立远端滚动事件")
        }
        return event
    }

    // Silence can be a stationary touch. Only an explicit ending, a different scroll stream or releaseAll
    // closes the gesture; the viewer sends an ending when its pointer leaves the remote picture.
    private func endScrollPhases() {
        var endings: [(RemoteInput.ScrollPhase?, RemoteInput.MomentumPhase?)] = []
        if let open = openScrollPhase { endings.append((open == .mayBegin ? .cancelled : .ended, nil)) }
        if momentumOpen { endings.append((nil, .ended)) }
        openScrollPhase = nil
        momentumOpen = false
        guard !endings.isEmpty else { return }
        scroll.reset()
        for (phase, momentum) in endings {
            guard let event = try? wheelEvent(units: .pixel, x: 0, y: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
            event.location = lastPoint
            event.flags = inputFlags
            postEvent(event)
        }
    }

    func releaseAll() {
        endScrollPhases()
        inputSources.cancel()
        scroll.reset()
        lineScroll.reset()
        for key in heldKeys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key) { event?.type = .flagsChanged }
            event?.flags = remoteCapsLock == true ? [.maskAlphaShift] : []
            if let event { postEvent(event) }
        }
        for button in heldButtons {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint,
                                mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left)
            event?.flags = remoteCapsLock == true ? [.maskAlphaShift] : []
            if let event { postEvent(event) }
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
        inputFlags = remoteCapsLock == true ? [.maskAlphaShift] : []
    }
}
