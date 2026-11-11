import AppKit
import Darwin
import ScreenCaptureKit
import QuietDeskCore

// Encoder and acknowledgement state share one queue with the capture pump.
struct VideoFrameFlow {
    static func maximumOutstandingFrames(for settings: StreamSettings, receiverLimit: Int?) -> Int {
        guard let receiverLimit else { return MediaBufferLimits.legacyFrameWindow }
        if receiverLimit > MediaBufferLimits.receiveFrameWindow {
            return min(MediaBufferLimits.maximumDynamicFrameWindow, receiverLimit)
        }
        return min(receiverLimit, settings.framesPerSecond >= 60 ? MediaBufferLimits.receiveFrameWindow : 4)
    }
    struct Encoding {
        let sequence: UInt32
        let startedAt: TimeInterval
        let forceKeyFrame: Bool
        let isRefinement: Bool
    }
    struct Completion {
        let sequence: UInt32
        let packet: VideoPacket?
        let callbackAt: TimeInterval
        let duration: TimeInterval?
        let diagnostic: PerformanceDiagnostics.Token?
        var encodingDiagnostic: PerformanceDiagnostics.Token? = nil
    }
    private(set) var sequence: UInt32
    private(set) var encoding: [Encoding] = []
    private var completed: [UInt32: Completion] = [:]
    private(set) var waiting: [UInt32: TimeInterval] = [:]
    private(set) var forceKeyFrame = true
    private(set) var encodingFailed = false
    private var consecutiveDrops = 0
    private(set) var mediaHold = false
    private(set) var mediaRecoveryFrameEncoded = false
    private var mediaRecoveryRequested = false
    private var mediaRecoveryIssued = false

    init(sequence: UInt32 = 0) { self.sequence = sequence }

    var isIdle: Bool { encoding.isEmpty && waiting.isEmpty }
    var outstanding: Int { encoding.count + waiting.count }

    mutating func begin(at now: TimeInterval, maximumConcurrentEncodes: Int = 1,
                        maximumOutstandingFrames: Int = MediaBufferLimits.legacyFrameWindow,
                        isRefinement: Bool = false) -> Encoding? {
        // Encoding and completed-but-not-yet-delivered output share the bounded credit window.
        // A forced IDR is serialized so its drop cannot leave an already-submitted P frame behind it.
        guard !encodingFailed, encoding.count < min(2, max(1, maximumConcurrentEncodes)),
              outstanding < maximumOutstandingFrames,
              !encoding.contains(where: { $0.forceKeyFrame }), !forceKeyFrame || encoding.isEmpty,
              !isRefinement || encoding.isEmpty,
              !mediaHold || mediaRecoveryRequested else { return nil }
        repeat { sequence &+= 1 } while waiting[sequence] != nil || encoding.contains(where: { $0.sequence == sequence })
        let frame = Encoding(sequence: sequence, startedAt: now, forceKeyFrame: forceKeyFrame, isRefinement: isRefinement)
        encoding.append(frame)
        forceKeyFrame = false
        if mediaHold { mediaRecoveryRequested = false }
        return frame
    }

    // Callback processing may reach the capture queue out of order. At most two results are retained,
    // and their reservations remain occupied until the head is delivered or dropped.
    mutating func complete(_ result: Completion) -> Bool {
        guard !encodingFailed, encoding.contains(where: { $0.sequence == result.sequence }), completed[result.sequence] == nil else { return false }
        completed[result.sequence] = result
        return true
    }

    mutating func takeCompleted() -> (Encoding, Completion)? {
        guard let first = encoding.first, let result = completed.removeValue(forKey: first.sequence) else { return nil }
        return (first, result)
    }

    mutating func encoded(_ number: UInt32, at now: TimeInterval) -> Bool {
        guard encoding.first?.sequence == number else { return false }
        encoding.removeFirst(); completed.removeValue(forKey: number)
        consecutiveDrops = 0
        waiting[number] = now
        if mediaHold { mediaRecoveryFrameEncoded = true }
        return true
    }

    mutating func dropped(_ number: UInt32) -> Bool {
        guard let frame = encoding.first, frame.sequence == number else { return false }
        encoding.removeFirst(); completed.removeValue(forKey: number)
        consecutiveDrops = min(consecutiveDrops + 1, 3)
        forceKeyFrame = forceKeyFrame || frame.forceKeyFrame || consecutiveDrops >= 3
        if mediaHold { mediaRecoveryRequested = true }
        return true
    }

    mutating func acknowledge(_ number: UInt32) -> Bool { waiting.removeValue(forKey: number) != nil }
    mutating func requestKeyFrame() { forceKeyFrame = true }
    mutating func cancelEncoding() { encoding.removeAll(); completed.removeAll() }
    mutating func failEncoding() { cancelEncoding(); encodingFailed = true }

    mutating func prepareMediaRecovery() {
        cancelEncoding(); encodingFailed = false
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
        guard !encodingFailed else { return nil }
        if let oldest = encoding.first?.startedAt, now - oldest > 90 { return "视频编码超过 90 秒无输出" }
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

    /// 1-based pass index (1...delays.count) for the next scheduled static refinement pass.
    var nextPassNumber: Int? { remaining > 0 ? (Self.delays.count - remaining + 1) : nil }

    /// A pass was handed to the encoder, or a new capture replaced the picture; its output schedules the next.
    mutating func wait() { dueAt = nil }

    mutating func cancel() { remaining = 0; dueAt = nil }

    private mutating func schedule(at now: TimeInterval) {
        dueAt = remaining > 0 && now.isFinite ? now + Self.delays[Self.delays.count - remaining] : nil
    }
}

struct TimeBudgetFrameDropper {
    static let standardFrameRates = [30, 60, 90, 120, 144, 240]
    private(set) var lastSubmittedAt: TimeInterval?

    static func normalizedFramesPerSecond(_ fps: Int) -> Int {
        let clamped = max(1, fps)
        if let standard = standardFrameRates.first(where: { abs($0 - clamped) <= 2 }) {
            return standard
        }
        return clamped
    }

    static func minimumInterval(framesPerSecond: Int) -> TimeInterval {
        (1.0 / Double(normalizedFramesPerSecond(framesPerSecond))) * 0.85
    }

    static func hasDirtyRegions(_ attachments: [[SCStreamFrameInfo: Any]]?) -> Bool {
        guard let rawRects = attachments?.first?[.dirtyRects] else { return true }
        guard let rects = rawRects as? [NSDictionary] else { return true }
        return rects.contains { dictionary in
            guard let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return !rect.isEmpty && rect.width > 0 && rect.height > 0
        }
    }

    func retryDelay(at now: TimeInterval, framesPerSecond: Int, forceKeyFrame: Bool, isRefinement: Bool) -> TimeInterval? {
        guard now.isFinite, !forceKeyFrame, !isRefinement,
              let last = lastSubmittedAt, now >= last else { return nil }
        let interval = Self.minimumInterval(framesPerSecond: framesPerSecond)
        let elapsed = now - last
        guard elapsed + 0.000_5 < interval else { return nil }
        return max(0.001, interval - elapsed)
    }

    mutating func recordSubmission(at now: TimeInterval, isRefinement: Bool) {
        if !isRefinement, now.isFinite {
            lastSubmittedAt = now
        }
    }

    mutating func shouldSubmit(at now: TimeInterval, framesPerSecond: Int, forceKeyFrame: Bool,
                               isRefinement: Bool) -> (allow: Bool, retryAfter: TimeInterval?) {
        if let delay = retryDelay(at: now, framesPerSecond: framesPerSecond,
                                  forceKeyFrame: forceKeyFrame, isRefinement: isRefinement) {
            return (false, delay)
        }
        recordSubmission(at: now, isRefinement: isRefinement)
        return (true, nil)
    }

    mutating func reset() {
        lastSubmittedAt = nil
    }
}

struct VideoEncodeTiming {
    private var encoderID: UUID?
    private var started: [UInt32: TimeInterval] = [:]
    private var lastCompletedAt: TimeInterval?

    @discardableResult
    mutating func begin(encoderID: UUID, sequence: UInt32, at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if self.encoderID != encoderID {
            self.encoderID = encoderID; started.removeAll(); lastCompletedAt = nil
        }
        guard started.count < 2, started[sequence] == nil else { return false }
        started[sequence] = now
        return true
    }

    mutating func complete(encoderID: UUID, sequence: UInt32, at now: TimeInterval) -> TimeInterval? {
        guard self.encoderID == encoderID, let beganAt = started.removeValue(forKey: sequence) else { return nil }
        let duration = now - beganAt
        return duration.isFinite && duration >= 0 ? duration : nil
    }

    // Called in submission order. The diagnostic latency includes the encoder's queue; adaptation
    // needs its sustained output time, excluding time already accounted for by the previous frame.
    mutating func serviceDuration(encoderID: UUID, latency: TimeInterval, completedAt: TimeInterval) -> TimeInterval? {
        guard self.encoderID == encoderID, latency.isFinite, latency >= 0, completedAt.isFinite else { return nil }
        let duration = min(latency, max(0, completedAt - (lastCompletedAt ?? (completedAt - latency))))
        lastCompletedAt = max(lastCompletedAt ?? completedAt, completedAt)
        return duration
    }

    mutating func cancel(encoderID: UUID? = nil) {
        if encoderID == nil || self.encoderID == encoderID {
            self.encoderID = nil; started.removeAll(); lastCompletedAt = nil
        }
    }
}

// SCK timestamps and retained-frame replays share one encoder timeline. A late capture after a replay
// may be older than the last submission; advancing only that timestamp preserves VT's strict ordering.
struct VideoPresentationTimeline {
    private var encoderID: UUID?
    private var lastSubmitted: CMTime?

    mutating func next(encoderID: UUID, time: CMTime) throws -> CMTime {
        guard time.isNumeric else { throw DeskError.invalid("视频帧时间戳无效") }
        if self.encoderID != encoderID { self.encoderID = encoderID; lastSubmitted = nil }
        var next = time
        if let lastSubmitted, CMTimeCompare(next, lastSubmitted) <= 0 {
            next = CMTimeAdd(lastSubmitted, CMTime(value: 1, timescale: 1_000_000))
            guard next.isNumeric, CMTimeCompare(next, lastSubmitted) > 0 else { throw DeskError.invalid("视频帧时间戳无法递增") }
        }
        lastSubmitted = next
        return next
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

    mutating func completeStaticSample(id: UUID, image: CVPixelBuffer, capturedAfterDisplayTime: UInt64,
                                       sampleTime: CMTime? = nil) -> CMTime? {
        guard requestID == id, needsFreshFrame, configurationApplied,
              let minimumDisplayTime, capturedAfterDisplayTime > minimumDisplayTime,
              let expectedDimensions,
              CVPixelBufferGetWidth(image) == expectedDimensions.0,
              CVPixelBufferGetHeight(image) == expectedDimensions.1 else { return nil }
        let resolvedTime: CMTime
        if let sampleTime, sampleTime.isNumeric,
           minimumPresentationTime.map({ CMTimeCompare(sampleTime, $0) > 0 }) ?? true {
            resolvedTime = sampleTime
        } else if let watermark = minimumPresentationTime ?? presentationWatermark {
            resolvedTime = CMTimeAdd(watermark, CMTime(value: 1, timescale: 1_000_000))
        } else {
            resolvedTime = CMTime(value: 1, timescale: 1_000_000)
        }
        guard resolvedTime.isNumeric else { return nil }
        if presentationWatermark.map({ CMTimeCompare(resolvedTime, $0) > 0 }) ?? true {
            presentationWatermark = resolvedTime
        }
        needsFreshFrame = false
        requestID = nil
        configurationApplied = false
        return resolvedTime
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
        let colorSpace: VideoColorSpace
    }

    let queue = DispatchQueue(label: "quietdesk.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "quietdesk.audio-capture", qos: .userInteractive)
    private let audioCallbackLock = NSLock()
    private var _onAudioSample: ((CMSampleBuffer) -> Void)?
    private var audioDeliveryActive = false
    var onAudioSample: ((CMSampleBuffer) -> Void)? {
        get { audioCallbackLock.withLock { _onAudioSample } }
        set { audioCallbackLock.withLock { _onAudioSample = newValue } }
    }
    var onFrame: ((VideoPacket) -> Void)?
    var onEncodeDuration: ((TimeInterval) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnosticError: ((Error) -> Void)?
    var onUserStop: (() -> Void)?
    private var stream: SCStream?
    private var lifecycle: CaptureLifecycle?
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
    private var receiverFrameWindow: Int?
    private var refinement = StaticFrameRefinement()
    private var refinementTimer: DispatchSourceTimer?
    private var frameDropper = TimeBudgetFrameDropper()
    private var framePacingTimer: DispatchSourceTimer?
    private var lastCaptureAt: TimeInterval = 0
    // `latest` holds a refinement pass rather than a capture; submitted frames retain that identity.
    private var latestIsRefinement = false
    private var latestRefinementPass: Int?
    private var captureColorSpace: VideoColorSpace = .sRGB
    private var lastCaptureDiagnostics: PerformanceDiagnostics.Token?
    private let diagnostics: PerformanceDiagnostics?
    private let encodingTimingLock = NSLock()
    private var encodingStarted: [UInt32: (id: UUID, token: PerformanceDiagnostics.Token)] = [:]
    private var encodeTiming = VideoEncodeTiming()
    private var presentationTimeline = VideoPresentationTimeline()
    private var acknowledgements: [UInt32: PerformanceDiagnostics.Token] = [:]
    private var encoderHardwareChecked = false
    private var encoderHardware: Bool?
    private var running = false
    private var captureStarted = false
    private var activeFilter: SCContentFilter?
    private var excludedWindowIDs = Set<CGWindowID>()
    private var reconfiguring = false
    private var sessionPaused = false
    private var capturesAudio = false
    private var audioOutputAttached = false
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
    private var qualityProbeUntil: TimeInterval?
    private var qualityProbeTimer: DispatchSourceTimer?
    private var qualityProbeTicks: UInt64 = 0
    private let encoderCleanupQueue = DispatchQueue(label: "quietdesk.capture.encoder-cleanup", qos: .userInitiated)

    init(diagnostics: PerformanceDiagnostics? = nil) {
        self.diagnostics = diagnostics
        super.init()
        queue.setSpecific(key: queueIdentity, value: true)
    }

    var currentCursorIncluded: Bool? { cursorState().actual }
    var targetCursorIncluded: Bool? { cursorState().target }

    /// The codec of the running encoder; HEVC can fall back to H.264 when the encoder rejects it.
    var videoCodec: VideoCodec {
        let read = { [self] in encoder?.codec ?? .h264 }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    var videoChromaSubsampling: VideoChromaSubsampling {
        let read = { [self] in encoder?.chromaSubsampling ?? .yuv420 }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    var videoColorSpace: VideoColorSpace {
        let read = { [self] in encoder?.colorSpace ?? captureColorSpace }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    var currentDisplayID: CGDirectDisplayID? {
        let read = { [self] in displayID }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    var currentExcludedWindowIDs: Set<CGWindowID> {
        let read = { [self] in excludedWindowIDs }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    var isAudioCaptureEnabled: Bool {
        let read = { [self] in capturesAudio && audioOutputAttached }
        return DispatchQueue.getSpecific(key: queueIdentity) == true ? read() : queue.sync(execute: read)
    }

    private func syncAudioDeliveryState() {
        let active = running && captureStarted && !sessionPaused && capturesAudio && audioOutputAttached
        audioCallbackLock.withLock { audioDeliveryActive = active }
    }

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

    static func displayColorSpace(_ id: CGDirectDisplayID) -> VideoColorSpace {
        CGDisplayCopyColorSpace(id).isWideGamutRGB ? .displayP3 : .sRGB
    }

    static func prepareCapture(display: SCDisplay, settings: StreamSettings,
                               excludingWindows: [SCWindow] = []) -> CapturePlan {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let source = sourceDimensions(filter: filter, displayID: display.displayID)
        let (width, height) = settings.dimensions(width: source.width, height: source.height)
        return CapturePlan(filter: filter, displayID: display.displayID, sourceWidth: source.width,
                           sourceHeight: source.height, settings: settings, width: width, height: height,
                           colorSpace: displayColorSpace(display.displayID))
    }

    private static func sourceDimensions(filter: SCContentFilter, displayID: CGDirectDisplayID) -> (width: Int, height: Int) {
        let fallback = displaySnapshot(displayID)
        // SCK reports the desktop rectangle in points, including on Retina displays.
        return DisplaySnapshot.capturePixelDimensions(contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale), fallbackWidth: fallback.pixelWidth,
            fallbackHeight: fallback.pixelHeight)
    }

    static func configuration(width: Int, height: Int, settings: StreamSettings, includesCursor: Bool = true,
                              chromaSubsampling: VideoChromaSubsampling = .yuv420,
                              colorSpace: VideoColorSpace = .sRGB,
                              capturesAudio: Bool = false) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        let targetFPS = TimeBudgetFrameDropper.normalizedFramesPerSecond(settings.framesPerSecond)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(targetFPS))
        // Two retained encoder inputs plus the newest capture still leave producer buffers available.
        configuration.queueDepth = settings.framesPerSecond >= 60 ? 5 : 3
        configuration.showsCursor = includesCursor
        configuration.capturesAudio = capturesAudio
        if capturesAudio {
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = RemoteAudioControl.sampleRate
            configuration.channelCount = RemoteAudioControl.channels
        }
        configuration.colorSpaceName = colorSpace == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        if chromaSubsampling == .yuv444 {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        }
        return configuration
    }

    private func makeEncoder(width: Int, height: Int, settings: StreamSettings, codec: VideoCodec = .h264,
                             chromaSubsampling: VideoChromaSubsampling = .yuv420,
                             colorSpace: VideoColorSpace = .sRGB, id: UUID) throws -> VideoEncoder {
        // A size or mode the hardware HEVC / 4:4:4 encoder rejects gracefully steps down to 4:2:0 or H.264.
        let encoder: VideoEncoder
        if codec == .hevc, chromaSubsampling == .yuv444,
           let hevc444 = try? VideoEncoder(width: width, height: height, settings: settings, codec: .hevc,
                                           chromaSubsampling: .yuv444, colorSpace: colorSpace) {
            encoder = hevc444
        } else if codec == .hevc,
                  let hevc = try? VideoEncoder(width: width, height: height, settings: settings, codec: .hevc,
                                               chromaSubsampling: .yuv420, colorSpace: colorSpace) {
            encoder = hevc
        } else {
            encoder = try VideoEncoder(width: width, height: height, settings: settings, codec: .h264,
                                       chromaSubsampling: .yuv420, colorSpace: colorSpace)
        }
        encoder.onOutput = { [weak self] result in
            guard let self else { return }
            let callbackAt = SessionClock.now
            let observation = self.encodingTimingLock.withLock { () -> (duration: TimeInterval?, diagnostic: PerformanceDiagnostics.Token?) in
                switch result {
                case .success(let packet):
                    let duration = self.encodeTiming.complete(encoderID: id, sequence: packet.sequence, at: callbackAt)
                    guard self.encodingStarted[packet.sequence]?.id == id else { return (duration, nil) }
                    return (duration, self.encodingStarted.removeValue(forKey: packet.sequence)?.token)
                case .failure:
                    self.encodeTiming.cancel(encoderID: id)
                    self.encodingStarted = self.encodingStarted.filter { $0.value.id != id }
                    return (nil, nil)
                }
            }
            if case .success(let packet) = result {
                self.diagnostics?.record(.encode, since: observation.diagnostic, kind: .video, identifier: UInt64(packet.sequence))
            }
            let encodedAt = self.diagnostics?.start()
            self.queue.async {
                guard self.running, self.encoderID == id, !self.frameFlow.encodingFailed else { return }
                switch result {
                case .success(let packet):
                    guard self.frameFlow.complete(.init(sequence: packet.sequence, packet: packet, callbackAt: callbackAt,
                        duration: observation.duration, diagnostic: encodedAt, encodingDiagnostic: observation.diagnostic)) else { return }
                    self.completeEncodedFrames()
                case .failure(let error):
                    self.diagnostics?.record(.encodeCallbackQueue, since: encodedAt, kind: .video)
                    self.failEncoding(error)
                }
            }
        }
        encoder.onDropped = { [weak self] number in
            guard let self else { return }
            let callbackAt = SessionClock.now
            let observation = self.encodingTimingLock.withLock { () -> (duration: TimeInterval?, diagnostic: PerformanceDiagnostics.Token?) in
                let duration = self.encodeTiming.complete(encoderID: id, sequence: number, at: callbackAt)
                guard self.encodingStarted[number]?.id == id else { return (duration, nil) }
                return (duration, self.encodingStarted.removeValue(forKey: number)?.token)
            }
            self.diagnostics?.record(.encode, since: observation.diagnostic, kind: .video, identifier: UInt64(number))
            let droppedAt = self.diagnostics?.start()
            self.queue.async {
                guard self.running, self.encoderID == id,
                      self.frameFlow.complete(.init(sequence: number, packet: nil, callbackAt: callbackAt,
                        duration: observation.duration, diagnostic: droppedAt, encodingDiagnostic: observation.diagnostic)) else { return }
                self.completeEncodedFrames()
            }
        }
        return encoder
    }

    private func completeEncodedFrames() {
        while let (frame, result) = frameFlow.takeCompleted() {
            if let latency = result.duration,
               let duration = encodingTimingLock.withLock({
                   encodeTiming.serviceDuration(encoderID: encoderID, latency: latency, completedAt: result.callbackAt)
               }) {
                onEncodeDuration?(duration)
            }
            diagnostics?.record(.encodeCallbackQueue, since: result.diagnostic, kind: .video, identifier: UInt64(frame.sequence))
            if let packet = result.packet {
                if frameFlow.mediaHold {
                    guard packet.hasParameterSets,
                          (try? MediaFrame.containsIDR(packet.avcc, codec: packet.codec)) == true else {
                        failEncoding(DeskError.invalid("媒体恢复未产生独立 IDR 帧"))
                        return
                    }
                }
                guard frameFlow.encoded(frame.sequence, at: SessionClock.now) else { return }
                if let encodedAt = result.diagnostic { acknowledgements[packet.sequence] = encodedAt }
                diagnostics?.recordValue(.encodedBytes, packet.avcc.count, kind: .video, identifier: UInt64(packet.sequence))
                if !packet.sps.isEmpty { diagnostics?.recordValue(.keyframeBytes, packet.avcc.count, kind: .video, identifier: UInt64(packet.sequence)) }
                onFrame?(packet)
                scheduleRefinement(after: packet, isRefinement: frame.isRefinement)
            } else {
                guard frameFlow.dropped(frame.sequence) else { return }
                if let token = result.encodingDiagnostic {
                    diagnostics?.recordValue(.encoderDropped, 1, kind: .video, identifier: UInt64(frame.sequence), token: token)
                }
                refinement.dropped(isRefinement: frame.isRefinement, at: SessionClock.now)
                armRefinementTimer()
            }
        }
        completeFrameBoundary()
    }

    private func failEncoding(_ error: Error) {
        guard !frameFlow.encodingFailed else { return }
        frameFlow.failEncoding()
        encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
        cancelRefinement()
        if let waiter = idleWaiter {
            idleWaiter = nil
            waiter.1.resume(throwing: error)
        }
        reportError(error)
    }

    private func reportError(_ error: Error, message: String? = nil) {
        onDiagnosticError?(error)
        onError?(message ?? error.localizedDescription)
    }

    func start(_ capture: CapturePlan, codec: VideoCodec = .h264,
               chromaSubsampling: VideoChromaSubsampling = .yuv420,
               capturesAudio: Bool = false,
               includesCursor: Bool = true) async throws {
        try Task.checkCancellation()
        let width = capture.width, height = capture.height, settings = capture.settings
        let id = UUID()
        let encoder = try makeEncoder(width: width, height: height, settings: settings, codec: codec,
                                      chromaSubsampling: chromaSubsampling, colorSpace: capture.colorSpace, id: id)
        let stream = SCStream(filter: capture.filter,
            configuration: Self.configuration(width: width, height: height, settings: settings,
                                              includesCursor: includesCursor,
                                              chromaSubsampling: encoder.chromaSubsampling,
                                              colorSpace: capture.colorSpace,
                                              capturesAudio: capturesAudio), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        let lifecycle = CaptureLifecycle(stream: stream)
        queue.sync {
            self.encoder = encoder
            self.captureColorSpace = capture.colorSpace
            encoderHardwareChecked = false
            encoderHardware = nil
            encoderID = id
            frameFlow = VideoFrameFlow(sequence: frameFlow.sequence)
            frameDropper.reset()
            presentationTimeline = VideoPresentationTimeline()
            encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
            lastCaptureDiagnostics = nil
            self.stream = stream
            self.lifecycle = lifecycle
            activeFilter = capture.filter
            excludedWindowIDs = []
            displayID = capture.displayID
            outputWidth = width
            outputHeight = height
            sourceWidth = capture.sourceWidth
            sourceHeight = capture.sourceHeight
            currentSettings = settings
            self.capturesAudio = capturesAudio
            self.audioOutputAttached = capturesAudio
            cursorGate = CursorCaptureGate()
            appliedCursorIncluded = includesCursor
            lastConfirmedCursorIncluded = includesCursor
            running = true
            syncAudioDeliveryState()
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
            try await lifecycle.start()
            try Task.checkCancellation()
            let current = queue.sync { () -> Bool in
                guard self.stream === stream, running else { return false }
                captureStarted = true
                syncAudioDeliveryState()
                return true
            }
            guard current else {
                try? stream.removeStreamOutput(self, type: .screen)
                if capturesAudio { try? stream.removeStreamOutput(self, type: .audio) }
                await lifecycle.stop()
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
                    let currentChroma = encoder?.chromaSubsampling ?? .yuv420
                    let currentColorSpace = captureColorSpace
                    let updatedConfiguration = Self.configuration(width: width, height: height,
                                                                  settings: currentSettings, includesCursor: included,
                                                                  chromaSubsampling: currentChroma,
                                                                  colorSpace: currentColorSpace,
                                                                  capturesAudio: capturesAudio)
                    let screenshotConfiguration = Self.configuration(width: width, height: height,
                                                                     settings: currentSettings, includesCursor: included,
                                                                     chromaSubsampling: currentChroma,
                                                                     colorSpace: currentColorSpace,
                                                                     capturesAudio: false)
                    activeStream.updateConfiguration(updatedConfiguration, completionHandler: { [weak self] error in
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
                                    return
                                }
                                self.scheduleStaticCursorFrameFallback(request: request, expectedStreamID: expectedStreamID,
                                                                       configuration: screenshotConfiguration)
                            }
                        })
                }
            }
        } onCancel: { [weak self] in
            guard !ignoringCancellation else { return }
            self?.queue.async { [weak self] in self?.cancelCursorRequest(request) }
        }
    }

    private func scheduleStaticCursorFrameFallback(request: UUID, expectedStreamID: ObjectIdentifier,
                                                   configuration: SCStreamConfiguration) {
        queue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self, self.running, let activeStream = self.stream,
                  ObjectIdentifier(activeStream) == expectedStreamID,
                  self.cursorFrameWaiter?.id == request, self.cursorGate.configurationApplied,
                  let filter = self.activeFilter else { return }
            activeStream.updateContentFilter(filter, completionHandler: nil)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                guard let self, self.running, self.stream.map(ObjectIdentifier.init) == expectedStreamID,
                      self.cursorFrameWaiter?.id == request, self.cursorGate.configurationApplied,
                      let currentFilter = self.activeFilter else { return }
                let capturedAfter = mach_absolute_time()
                Task { [weak self] in
                    struct StaticScreenshotSample: @unchecked Sendable {
                        let image: CVPixelBuffer
                        let sampleTime: CMTime
                    }
                    guard let sample = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: currentFilter,
                                                                                          configuration: configuration),
                          CMSampleBufferIsValid(sample),
                          let image = CMSampleBufferGetImageBuffer(sample) else { return }
                    let captured = StaticScreenshotSample(image: image, sampleTime: CMSampleBufferGetPresentationTimeStamp(sample))
                    self?.queue.async { [weak self] in
                        guard let self, self.running, self.stream.map(ObjectIdentifier.init) == expectedStreamID,
                              self.cursorFrameWaiter?.id == request else { return }
                        guard let resolvedTime = self.cursorGate.completeStaticSample(id: request, image: captured.image,
                            capturedAfterDisplayTime: capturedAfter, sampleTime: captured.sampleTime) else { return }
                        self.latest = (captured.image, resolvedTime, self.diagnostics?.start())
                        self.lastCapture = self.latest
                        self.lastCaptureAt = SessionClock.now
                        self.latestIsRefinement = false
                        self.refinement.wait()
                        self.appliedCursorIncluded = self.cursorGate.included
                        self.lastConfirmedCursorIncluded = self.cursorGate.included
                        self.finishCursorFrameWaiter(request, result: .success(()))
                        self.pump()
                    }
                }
            }
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

    // Same-size, same-codec, same-chroma changes (bitrate and/or frame rate) update the running encoder and
    // capture interval in place without draining in-flight frames or restarting the media epoch.
    func updateEncodingParameters(_ settings: StreamSettings, codec: VideoCodec? = nil,
                                  chromaSubsampling: VideoChromaSubsampling? = nil) throws -> VideoStreamState {
        try settings.validateControlValues()
        return try queue.sync {
            guard running, captureStarted, let stream, let encoder, !reconfiguring, !frameFlow.encodingFailed,
                  cursorOperationID == nil, cursorFrameWaiter == nil else {
                throw DeskError.invalid("画质正在调整，请稍后再试")
            }
            let targetCodec = codec ?? encoder.codec
            let targetChroma: VideoChromaSubsampling = targetCodec == .hevc
                ? (chromaSubsampling ?? encoder.chromaSubsampling)
                : .yuv420
            let (width, height) = settings.dimensions(width: sourceWidth, height: sourceHeight)
            guard targetCodec == encoder.codec, targetChroma == encoder.chromaSubsampling,
                  width == outputWidth, height == outputHeight else {
                throw DeskError.invalid("画质尺寸或编码格式变化需要重新配置")
            }
            let frameRateChanged = settings.framesPerSecond != currentSettings.framesPerSecond
            if frameRateChanged {
                try encoder.updateEncodingParameters(settings: settings)
            } else if settings.megabits != currentSettings.megabits {
                try encoder.updateBitrate(megabits: settings.megabits)
            }
            currentSettings = settings
            if frameRateChanged {
                stream.updateConfiguration(Self.configuration(width: outputWidth, height: outputHeight,
                    settings: settings, includesCursor: cursorGate.included,
                    chromaSubsampling: encoder.chromaSubsampling, colorSpace: captureColorSpace,
                    capturesAudio: capturesAudio), completionHandler: nil)
                pump()
            }
            return VideoStreamState(settings: settings, width: outputWidth, height: outputHeight)
        }
    }

    /// `codec` and `chromaSubsampling` nil keep the running encoder's values.
    func reconfigure(_ settings: StreamSettings, codec: VideoCodec? = nil,
                     chromaSubsampling: VideoChromaSubsampling? = nil) async throws -> VideoStreamState {
        try settings.validateControlValues()
        let snapshot = try queue.sync { () throws -> (SCStream, Int, Int, Int, Int, StreamSettings, Bool, VideoCodec, VideoChromaSubsampling, VideoColorSpace, SCContentFilter?, Bool, Bool) in
            guard running, captureStarted, let stream, displayID != nil else { throw DeskError.invalid("屏幕采集尚未就绪，请稍后调整") }
            if let operation = cursorOperationID { cancelCursorOperation(operation); throw DeskError.invalid("光标采集正在更新，请稍后调整画质") }
            if let waiter = cursorFrameWaiter {
                cancelCursorRequest(waiter.id)
                throw DeskError.invalid("正在等待光标采集的新画面")
            }
            return (stream, sourceWidth, sourceHeight, outputWidth, outputHeight, currentSettings, cursorGate.included,
                    encoder?.codec ?? .h264, encoder?.chromaSubsampling ?? .yuv420, captureColorSpace, activeFilter,
                    encoder != nil && !frameFlow.encodingFailed, capturesAudio)
        }
        let (width, height) = settings.dimensions(width: snapshot.1, height: snapshot.2)
        let targetCodec = codec ?? snapshot.7
        let requestedChroma: VideoChromaSubsampling = targetCodec == .hevc ? (chromaSubsampling ?? snapshot.8) : .yuv420
        let canUpdateInPlace = snapshot.11 && width == snapshot.3 && height == snapshot.4
            && targetCodec == snapshot.7 && requestedChroma == snapshot.8
        let id = UUID()
        let replacement = canUpdateInPlace ? nil : try makeEncoder(width: width, height: height, settings: settings,
                                                                   codec: targetCodec, chromaSubsampling: requestedChroma,
                                                                   colorSpace: snapshot.9, id: id)
        let effectiveChroma = replacement?.chromaSubsampling ?? snapshot.8
        let nextConfiguration = Self.configuration(width: width, height: height, settings: settings,
                                                   includesCursor: snapshot.6, chromaSubsampling: effectiveChroma,
                                                   colorSpace: snapshot.9, capturesAudio: snapshot.12)
        let screenshotConfiguration = Self.configuration(width: width, height: height, settings: settings,
                                                         includesCursor: snapshot.6, chromaSubsampling: effectiveChroma,
                                                         colorSpace: snapshot.9, capturesAudio: false)
        do { try await pauseAtFrameBoundary() }
        catch { replacement?.stop(); throw error }
        do {
            try Task.checkCancellation()
            try await snapshot.0.updateConfiguration(nextConfiguration)
            try Task.checkCancellation()
            var freshStaticSample: (CVPixelBuffer, CMTime)?
            if effectiveChroma != snapshot.8 || width != snapshot.3 || height != snapshot.4,
               let filter = snapshot.10, !queue.sync(execute: { cursorGate.needsFreshFrame }),
               let sample = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: screenshotConfiguration),
               CMSampleBufferIsValid(sample), let image = CMSampleBufferGetImageBuffer(sample) {
                freshStaticSample = (image, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            try Task.checkCancellation()
            try queue.sync {
                guard running, stream === snapshot.0 else { throw CancellationError() }
                if canUpdateInPlace, frameFlow.encoding.isEmpty, !frameFlow.encodingFailed,
                   let existing = encoder, (try? existing.updateEncodingParameters(settings: settings)) != nil {
                    encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
                } else {
                    let nextEncoder = try replacement ?? makeEncoder(width: width, height: height, settings: settings,
                                                                     codec: targetCodec, chromaSubsampling: requestedChroma,
                                                                     colorSpace: snapshot.9, id: id)
                    let old = encoder
                    encoderID = id
                    encoder = nextEncoder
                    encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
                    encoderHardwareChecked = false
                    encoderHardware = nil
                    presentationTimeline = VideoPresentationTimeline()
                    old?.stop()
                }
                lastCaptureDiagnostics = nil
                outputWidth = width
                outputHeight = height
                currentSettings = settings
                let wasMediaHeld = frameFlow.mediaHold
                frameFlow = VideoFrameFlow(sequence: frameFlow.sequence)
                // The media coordinator suspended this configuration before draining capture. Its
                // replacement must still wait for a new recovery IDR and the coordinator's commit.
                if wasMediaHeld { frameFlow.prepareMediaRecovery() }
                frameDropper.reset()
                cancelRefinement()
                if cursorGate.needsFreshFrame {
                    latest = nil
                    lastCapture = nil
                    appliedCursorIncluded = nil
                } else if let freshStaticSample {
                    latest = (freshStaticSample.0, freshStaticSample.1, nil)
                    lastCapture = latest
                    lastCaptureAt = SessionClock.now
                } else {
                    latest = lastCapture
                    // Replaying a retained frame is intentional, not capture-queue congestion.
                    latest?.2 = nil
                }
                discardMismatchedFrame()
            }
            // The caller sends the settings result before resuming the new encoder.
            return VideoStreamState(settings: settings, width: width, height: height)
        } catch {
            replacement?.stop()
            if queue.sync(execute: { running && stream === snapshot.0 }) {
                do {
                    try await snapshot.0.updateConfiguration(Self.configuration(width: snapshot.3, height: snapshot.4,
                        settings: snapshot.5, includesCursor: snapshot.6,
                        chromaSubsampling: snapshot.8, colorSpace: snapshot.9, capturesAudio: snapshot.12))
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

    /// Hot-switches the active `SCStream` to another display or updated display mode/resolution in place.
    func switchCapture(_ capture: CapturePlan, excludedWindows: Set<CGWindowID>? = nil) async throws -> VideoStreamState {
        let snapshot = try queue.sync { () throws -> (SCStream, StreamSettings, Bool, VideoCodec, VideoChromaSubsampling, CGDirectDisplayID?, SCContentFilter?, Int, Int, Int, Int, VideoColorSpace, Set<CGWindowID>, Bool, Bool) in
            guard running, captureStarted, let stream else {
                throw DeskError.invalid("屏幕采集尚未就绪，请稍后切换显示器")
            }
            if let operation = cursorOperationID {
                cancelCursorOperation(operation)
                throw DeskError.invalid("光标采集正在更新，请稍后切换显示器")
            }
            if let waiter = cursorFrameWaiter {
                cancelCursorRequest(waiter.id)
                throw DeskError.invalid("正在等待光标采集的新画面")
            }
            return (stream, currentSettings, cursorGate.included, encoder?.codec ?? .h264,
                    encoder?.chromaSubsampling ?? .yuv420, displayID, activeFilter,
                    sourceWidth, sourceHeight, outputWidth, outputHeight, captureColorSpace,
                    excludedWindowIDs, encoder != nil && !frameFlow.encodingFailed, capturesAudio)
        }
        let settings = snapshot.1
        let (width, height) = settings.dimensions(width: capture.sourceWidth, height: capture.sourceHeight)
        let targetCodec = snapshot.3
        let requestedChroma: VideoChromaSubsampling = targetCodec == .hevc ? snapshot.4 : .yuv420
        let canReuseEncoder = snapshot.13 && width == snapshot.9 && height == snapshot.10 && capture.colorSpace == snapshot.11
        let id = UUID()
        let replacement = canReuseEncoder ? nil : try makeEncoder(width: width, height: height, settings: settings,
                                                                  codec: targetCodec, chromaSubsampling: requestedChroma,
                                                                  colorSpace: capture.colorSpace, id: id)
        let effectiveChroma = replacement?.chromaSubsampling ?? snapshot.4
        let nextConfiguration = Self.configuration(width: width, height: height, settings: settings,
                                                   includesCursor: snapshot.2, chromaSubsampling: effectiveChroma,
                                                   colorSpace: capture.colorSpace, capturesAudio: snapshot.14)
        let screenshotConfiguration = Self.configuration(width: width, height: height, settings: settings,
                                                         includesCursor: snapshot.2, chromaSubsampling: effectiveChroma,
                                                         colorSpace: capture.colorSpace, capturesAudio: false)
        do { try await pauseAtFrameBoundary() }
        catch { replacement?.stop(); throw error }
        do {
            try Task.checkCancellation()
            try await snapshot.0.updateContentFilter(capture.filter)
            try await snapshot.0.updateConfiguration(nextConfiguration)
            try Task.checkCancellation()
            var freshStaticSample: (CVPixelBuffer, CMTime)?
            if !queue.sync(execute: { cursorGate.needsFreshFrame }),
               let sample = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: capture.filter,
                                                                               configuration: screenshotConfiguration),
               CMSampleBufferIsValid(sample), let image = CMSampleBufferGetImageBuffer(sample) {
                freshStaticSample = (image, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            try Task.checkCancellation()
            try queue.sync {
                guard running, stream === snapshot.0 else { throw CancellationError() }
                if !canReuseEncoder || encoder == nil || frameFlow.encodingFailed {
                    let nextEncoder = try replacement ?? makeEncoder(width: width, height: height, settings: settings,
                                                                     codec: targetCodec, chromaSubsampling: requestedChroma,
                                                                     colorSpace: capture.colorSpace, id: id)
                    let old = encoder
                    encoderID = id
                    encoder = nextEncoder
                    encoderHardwareChecked = false
                    encoderHardware = nil
                    presentationTimeline = VideoPresentationTimeline()
                    old?.stop()
                }
                encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
                lastCaptureDiagnostics = nil
                displayID = capture.displayID
                activeFilter = capture.filter
                if let excludedWindows { excludedWindowIDs = excludedWindows }
                sourceWidth = capture.sourceWidth
                sourceHeight = capture.sourceHeight
                captureColorSpace = capture.colorSpace
                outputWidth = width
                outputHeight = height
                let wasMediaHeld = frameFlow.mediaHold
                frameFlow = VideoFrameFlow(sequence: frameFlow.sequence)
                if wasMediaHeld { frameFlow.prepareMediaRecovery() }
                frameDropper.reset()
                cancelRefinement()
                if cursorGate.needsFreshFrame {
                    latest = nil
                    lastCapture = nil
                    appliedCursorIncluded = nil
                } else if let freshStaticSample {
                    latest = (freshStaticSample.0, freshStaticSample.1, nil)
                    lastCapture = latest
                    lastCaptureAt = SessionClock.now
                } else {
                    latest = nil
                    lastCapture = nil
                }
                discardMismatchedFrame()
            }
            return VideoStreamState(settings: settings, width: width, height: height)
        } catch {
            replacement?.stop()
            if queue.sync(execute: { running && stream === snapshot.0 }) {
                do {
                    if let oldFilter = snapshot.6 { try await snapshot.0.updateContentFilter(oldFilter) }
                    try await snapshot.0.updateConfiguration(Self.configuration(width: snapshot.9, height: snapshot.10,
                        settings: snapshot.1, includesCursor: snapshot.2,
                        chromaSubsampling: snapshot.4, colorSpace: snapshot.11, capturesAudio: snapshot.14))
                    queue.sync {
                        guard running, stream === snapshot.0 else { return }
                        frameFlow.requestKeyFrame()
                        discardMismatchedFrame()
                        reconfiguring = false
                        pump()
                    }
                } catch let rollbackError {
                    queue.async { [weak self] in
                        self?.reportError(rollbackError, message: "显示器切换失败且无法恢复原配置：\(rollbackError.localizedDescription)")
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
                syncAudioDeliveryState()
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
                syncAudioDeliveryState()
                reconfiguring = false
                pump()
            }
            throw error
        }
    }

    func setAudioCaptureEnabled(_ enabled: Bool) async throws {
        try Task.checkCancellation()
        let prepared = try queue.sync { () throws -> (stream: SCStream, config: SCStreamConfiguration, newlyAttached: Bool)? in
            guard running, captureStarted, let stream else {
                throw DeskError.invalid("屏幕采集尚未就绪")
            }
            guard !reconfiguring, cursorOperationID == nil, cursorFrameWaiter == nil else {
                throw DeskError.invalid("正在调整画面采集配置，请稍后重试远端声音")
            }
            if capturesAudio == enabled && audioOutputAttached == enabled {
                return nil
            }
            var newlyAttached = false
            if enabled && !audioOutputAttached {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                audioOutputAttached = true
                newlyAttached = true
            }
            if !enabled {
                capturesAudio = false
                syncAudioDeliveryState()
            }
            let nextConfig = Self.configuration(
                width: outputWidth,
                height: outputHeight,
                settings: currentSettings,
                includesCursor: cursorGate.included,
                chromaSubsampling: encoder?.chromaSubsampling ?? .yuv420,
                colorSpace: captureColorSpace,
                capturesAudio: enabled
            )
            return (stream, nextConfig, newlyAttached)
        }
        guard let prepared else { return }
        do {
            try await prepared.stream.updateConfiguration(prepared.config)
            try queue.sync {
                guard running, stream === prepared.stream else { throw CancellationError() }
                capturesAudio = enabled
                if !enabled, audioOutputAttached {
                    try? prepared.stream.removeStreamOutput(self, type: .audio)
                    audioOutputAttached = false
                }
                syncAudioDeliveryState()
            }
        } catch {
            queue.sync {
                guard running, stream === prepared.stream else { return }
                if enabled {
                    capturesAudio = false
                    if prepared.newlyAttached, audioOutputAttached {
                        try? prepared.stream.removeStreamOutput(self, type: .audio)
                        audioOutputAttached = false
                    }
                }
                syncAudioDeliveryState()
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
            activeFilter = filter
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
                lastCaptureDiagnostics = nil
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

    // Completion runs on the capture queue. When the running encoder is healthy, it emits the next
    // recovery IDR directly while VideoFrameFlow fences any earlier in-flight callbacks; only a failed
    // or missing encoder requires a replacement VTCompressionSession.
    func prepareMediaRecovery(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.running, self.captureStarted, !self.reconfiguring, !self.sessionPaused else {
                completion(false)
                return
            }
            if !self.frameFlow.encodingFailed, self.encoder != nil {
                self.encodingTimingLock.withLock { self.encodingStarted.removeAll(); self.encodeTiming.cancel() }
            } else {
                let id = UUID()
                let replacement: VideoEncoder
                do {
                    replacement = try self.makeEncoder(width: self.outputWidth, height: self.outputHeight,
                                                       settings: self.currentSettings,
                                                       codec: self.encoder?.codec ?? .h264,
                                                       chromaSubsampling: self.encoder?.chromaSubsampling ?? .yuv420,
                                                       colorSpace: self.captureColorSpace, id: id)
                }
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
                self.encodingTimingLock.withLock { self.encodingStarted.removeAll(); self.encodeTiming.cancel() }
                self.presentationTimeline = VideoPresentationTimeline()
                // Completing an old encoder must not block the new epoch or wait for a lost decoder ACK.
                self.encoderCleanupQueue.async { old?.stop() }
            }
            self.lastCaptureDiagnostics = nil
            self.acknowledgements.removeAll()
            self.frameFlow.prepareMediaRecovery()
            self.frameDropper.reset()
            self.cancelRefinement()
            self.latest = self.lastCapture
            self.latest?.2 = nil
            self.discardMismatchedFrame()
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

    func setReceiverFrameWindow(_ limit: Int?) {
        queue.async { [self] in
            receiverFrameWindow = limit
            pump()
        }
    }

    func acknowledge(_ number: UInt32) {
        queue.async { [weak self] in
            guard let self, self.frameFlow.acknowledge(number) else { return }
            self.diagnostics?.record(.videoAck, since: self.acknowledgements.removeValue(forKey: number),
                                     kind: .video, identifier: UInt64(number))
            self.diagnostics?.recordValue(.videoOutstanding, self.frameFlow.outstanding)
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
        let old: CaptureLifecycle? = queue.sync {
            running = false
            captureStarted = false
            reconfiguring = false
            latest = nil
            lastCapture = nil
            lastCaptureDiagnostics = nil
            cancelRefinement()
            refinementTimer?.cancel()
            refinementTimer = nil
            frameDropper.reset()
            framePacingTimer?.cancel()
            framePacingTimer = nil
            stopQualityProbeOnQueue()
            if let waiter = cursorFrameWaiter { finishCursorFrameWaiter(waiter.id, result: .failure(CancellationError())) }
            cursorGate = CursorCaptureGate()
            appliedCursorIncluded = nil
            lastConfirmedCursorIncluded = true
            cursorOperationID = nil
            cancelledCursorOperationID = nil
            cancelledCursorRequestID = nil
            cursorRollingBack = false
            encodingTimingLock.withLock { encodingStarted.removeAll(); encodeTiming.cancel() }
            acknowledgements.removeAll()
            frameFlow = VideoFrameFlow(sequence: frameFlow.sequence)
            frameDropper.reset()
            presentationTimeline = VideoPresentationTimeline()
            if let waiter = idleWaiter { idleWaiter = nil; waiter.1.resume(throwing: CancellationError()) }
            watchdog?.cancel()
            watchdog = nil
            encoder?.stop()
            encoder = nil
            let old = lifecycle
            if let stream {
                try? stream.removeStreamOutput(self, type: .screen)
                if audioOutputAttached { try? stream.removeStreamOutput(self, type: .audio) }
            }
            capturesAudio = false
            audioOutputAttached = false
            syncAudioDeliveryState()
            activeFilter = nil
            stream = nil
            lifecycle = nil
            return old
        }
        await old?.stop()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.running, self.stream === stream else { return }
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
        if type == .audio {
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
            let handler = audioCallbackLock.withLock { audioDeliveryActive ? _onAudioSample : nil }
            handler?(sampleBuffer)
            return
        }
        guard type == .screen else { return }
        guard running, self.stream === stream, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !reconfiguring, (CVPixelBufferGetWidth(buffer) != outputWidth || CVPixelBufferGetHeight(buffer) != outputHeight) { return }
        let cursorFrame = cursorGate.observe(sampleBuffer, displayTime: attachments.first?[.displayTime] as? UInt64)
        guard cursorFrame.retain else { return }
        if cursorFrame.completed == nil, !cursorGate.needsFreshFrame, lastCapture != nil,
           !frameFlow.forceKeyFrame, !frameFlow.mediaHold,
           !TimeBudgetFrameDropper.hasDirtyRegions(attachments) {
            return
        }
        if captureStarted, !sessionPaused, !reconfiguring, diagnostics?.isEnabled == true {
            diagnostics?.record(.captureInterval, since: lastCaptureDiagnostics, kind: .video)
            lastCaptureDiagnostics = diagnostics?.start()
        } else { lastCaptureDiagnostics = nil }
        if latest != nil, !latestIsRefinement, !sessionPaused, !reconfiguring { diagnostics?.recordValue(.captureReplaced, 1) }
        // SCK presentation time is not in the SessionClock domain.
        latest = (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), diagnostics?.start())
        lastCapture = latest
        lastCaptureAt = SessionClock.now
        latestIsRefinement = false
        latestRefinementPass = nil
        refinement.wait()
        if let request = cursorFrame.completed {
            appliedCursorIncluded = cursorGate.included
            lastConfirmedCursorIncluded = cursorGate.included
            finishCursorFrameWaiter(request, result: .success(()))
        }
        pump()
    }

    // Runs on the capture queue once a frame's output was handed on.
    private func scheduleRefinement(after packet: VideoPacket, isRefinement: Bool) {
        let now = SessionClock.now
        if isRefinement {
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
        guard running, captureStarted, !reconfiguring, !sessionPaused, !cursorGate.needsFreshFrame,
              !frameFlow.mediaHold, !frameFlow.encodingFailed,
              refinement.isDue(at: now), latest == nil, let last = lastCapture,
              CVPixelBufferGetWidth(last.0) == outputWidth, CVPixelBufferGetHeight(last.0) == outputHeight else { return }
        let passNumber = refinement.nextPassNumber
        refinement.wait()
        latest = (last.0, CMTimeAdd(last.1, CMTime(seconds: max(0, now - lastCaptureAt), preferredTimescale: 1_000_000)), nil)
        latestIsRefinement = true
        latestRefinementPass = passNumber
        pump()
    }

    private func cancelRefinement() {
        refinement.cancel()
        if latestIsRefinement { latest = nil; latestIsRefinement = false; latestRefinementPass = nil }
    }

    /// Enables or stops bounded test-frame generation on a static screen during a manual route benchmark.
    func setQualityProbe(enabled: Bool, durationSeconds: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard enabled, durationSeconds > 0 else {
                self.stopQualityProbeOnQueue()
                return
            }
            let clamped = Double(min(QualityProbeControl.maximumDurationSeconds,
                                     max(QualityProbeControl.minimumDurationSeconds, durationSeconds)))
            self.qualityProbeUntil = SessionClock.now + clamped
            self.qualityProbeTicks = 0
            let timer: DispatchSourceTimer
            if let existing = self.qualityProbeTimer {
                timer = existing
            } else {
                timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.setEventHandler { [weak self] in self?.tickQualityProbeOnQueue() }
                self.qualityProbeTimer = timer
                timer.resume()
            }
            timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33), leeway: .milliseconds(5))
        }
    }

    private func stopQualityProbeOnQueue() {
        qualityProbeUntil = nil
        qualityProbeTicks = 0
        qualityProbeTimer?.cancel()
        qualityProbeTimer = nil
    }

    private func tickQualityProbeOnQueue() {
        let now = SessionClock.now
        guard let until = qualityProbeUntil, now < until else {
            stopQualityProbeOnQueue()
            return
        }
        guard running, captureStarted, !reconfiguring, !sessionPaused, !cursorGate.needsFreshFrame,
              !frameFlow.mediaHold, !frameFlow.encodingFailed else { return }
        let targetFPS = max(10, min(30, currentSettings.framesPerSecond))
        let minIdle = 0.85 / Double(targetFPS)
        guard latest == nil, now - lastCaptureAt >= minIdle, let last = lastCapture,
              CVPixelBufferGetWidth(last.0) == outputWidth, CVPixelBufferGetHeight(last.0) == outputHeight else { return }
        qualityProbeTicks += 1
        // Emit a full keyframe once per ~1s and high-quality refinement slices between them so even a motionless
        // remote desktop exercises real multi-fragment UDP video bitrate, pacing, and packet-loss detection.
        if qualityProbeTicks % UInt64(targetFPS) == 0 {
            frameFlow.requestKeyFrame()
            latestIsRefinement = false
            latestRefinementPass = nil
        } else if qualityProbeTicks % 8 == 0 {
            latestIsRefinement = true
            latestRefinementPass = 4
        } else {
            latestIsRefinement = false
            latestRefinementPass = nil
        }
        latest = (last.0, CMTimeAdd(last.1, CMTime(seconds: max(0.001, now - lastCaptureAt), preferredTimescale: 1_000_000)), nil)
        pump()
    }

    private func discardMismatchedFrame() {
        if let latest, CVPixelBufferGetWidth(latest.0) != outputWidth || CVPixelBufferGetHeight(latest.0) != outputHeight { self.latest = nil }
    }

    private func armFramePacingTimer(after delay: TimeInterval) {
        let timer: DispatchSourceTimer
        if let framePacingTimer { timer = framePacingTimer }
        else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.pump() }
            framePacingTimer = timer
            timer.resume()
        }
        timer.schedule(deadline: .now() + max(0.001, delay), leeway: .milliseconds(1))
    }

    private func pump() {
        guard running, !reconfiguring, !sessionPaused, !cursorGate.needsFreshFrame, !frameFlow.encodingFailed else { return }
        discardMismatchedFrame()
        guard let latest else {
            // A one-shot timer may have fired during a configuration that was cancelled or rolled back.
            armRefinementTimer()
            return
        }
        let now = SessionClock.now
        if let delay = frameDropper.retryDelay(at: now, framesPerSecond: currentSettings.framesPerSecond,
                                               forceKeyFrame: frameFlow.forceKeyFrame || frameFlow.mediaHold,
                                               isRefinement: latestIsRefinement) {
            armFramePacingTimer(after: delay)
            return
        }
        guard let encoder,
              let frame = frameFlow.begin(at: now,
                maximumConcurrentEncodes: currentSettings.framesPerSecond >= 60 ? 2 : 1,
                maximumOutstandingFrames: VideoFrameFlow.maximumOutstandingFrames(for: currentSettings, receiverLimit: receiverFrameWindow),
                isRefinement: latestIsRefinement) else { return }
        frameDropper.recordSubmission(at: now, isRefinement: latestIsRefinement)
        let submittedRefinementPass = latestIsRefinement ? latestRefinementPass : nil
        self.latest = nil
        latestIsRefinement = false
        latestRefinementPass = nil
        let presentationTime: CMTime
        do { presentationTime = try presentationTimeline.next(encoderID: encoderID, time: latest.1) }
        catch { failEncoding(error); return }
        if diagnostics?.isEnabled == true {
            if !encoderHardwareChecked {
                encoderHardware = encoder.hardwareAccelerationStatus
                encoderHardwareChecked = true
            }
            if let encoderHardware { diagnostics?.recordValue(.encoderHardware, encoderHardware ? 1 : 0) }
        }
        diagnostics?.record(.captureAge, since: latest.2, kind: .video, identifier: UInt64(frame.sequence))
        diagnostics?.recordValue(.videoOutstanding, frameFlow.outstanding)
        let timing = diagnostics?.start()
        let submittedAt = SessionClock.now
        encodingTimingLock.withLock {
            if let timing { encodingStarted[frame.sequence] = (encoderID, timing) }
            encodeTiming.begin(encoderID: encoderID, sequence: frame.sequence, at: submittedAt)
        }
        let submitTiming = diagnostics?.start()
        do {
            try encoder.encode(latest.0, time: presentationTime, sequence: frame.sequence,
                               forceKeyFrame: frame.forceKeyFrame,
                               refinementPass: frame.isRefinement ? (submittedRefinementPass ?? 1) : nil)
            diagnostics?.record(.encodeSubmit, since: submitTiming, kind: .video, identifier: UInt64(frame.sequence))
        } catch {
            diagnostics?.record(.encodeSubmit, since: submitTiming, kind: .video, identifier: UInt64(frame.sequence))
            failEncoding(error)
        }
    }

    deinit { watchdog?.cancel(); refinementTimer?.cancel(); framePacingTimer?.cancel() }
}

final class HostImmediateInputQueue: @unchecked Sendable {
    struct Item: Sendable {
        let input: RemoteInput
        let fromDatagram: Bool
    }

    private let lock = NSLock()
    private var pending: [Item] = []
    private var backpressureResumes: [() -> Void] = []
    private var flushScheduled = false
    let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func enqueue(_ input: RemoteInput, resume: @escaping () -> Void) -> Bool {
        let item = Item(input: input, fromDatagram: false)
        let result = lock.withLock { () -> (resumeNow: Bool, scheduleFlush: Bool) in
            if let last = pending.last, Self.canCoalesce(previous: last, next: item) {
                pending[pending.count - 1] = Item(input: item.input.accumulatingPointerDelta(from: last.input), fromDatagram: false)
            } else {
                pending.append(item)
            }
            let resumeNow = pending.count < capacity && backpressureResumes.isEmpty
            if !resumeNow {
                backpressureResumes.append(resume)
            }
            let scheduleFlush = !flushScheduled
            flushScheduled = true
            return (resumeNow, scheduleFlush)
        }
        if result.resumeNow { resume() }
        return result.scheduleFlush
    }

    func enqueueDatagram(_ input: RemoteInput) -> Bool {
        let item = Item(input: input, fromDatagram: true)
        return lock.withLock { () -> Bool in
            if let last = pending.last, Self.canCoalesce(previous: last, next: item) {
                pending[pending.count - 1] = Item(input: item.input.accumulatingPointerDelta(from: last.input), fromDatagram: true)
            } else if pending.count < capacity {
                pending.append(item)
            } else {
                return false
            }
            let scheduleFlush = !flushScheduled
            flushScheduled = true
            return scheduleFlush
        }
    }

    func drainItems() -> (items: [Item], resumes: [() -> Void]) {
        lock.withLock {
            flushScheduled = false
            let items = pending
            let resumes = backpressureResumes
            pending.removeAll(keepingCapacity: true)
            backpressureResumes.removeAll()
            return (items, resumes)
        }
    }

    func drain() -> (inputs: [RemoteInput], resumes: [() -> Void]) {
        let drained = drainItems()
        return (drained.items.map(\.input), drained.resumes)
    }

    private static func canCoalesce(previous: Item, next: Item) -> Bool {
        guard previous.fromDatagram == next.fromDatagram,
              previous.input.flags == next.input.flags,
              previous.input.independentCapsLock == next.input.independentCapsLock,
              previous.input.relativeMouse == next.input.relativeMouse else { return false }
        if let prevSeq = previous.input.pointerSequence, let nextSeq = next.input.pointerSequence, nextSeq <= prevSeq {
            return false
        }
        switch (previous.input.kind, next.input.kind) {
        case (.move, .move): return true
        case (.drag, .drag): return previous.input.button == next.input.button
        default: return false
        }
    }
}

@MainActor
final class InputInjector: @unchecked Sendable {
    nonisolated private static let modifierDeviceBits: [UInt16: UInt64] = [
        59: 0x01, 56: 0x02, 60: 0x04, 55: 0x08,
        54: 0x10, 58: 0x20, 61: 0x40, 62: 0x2000
    ]

    private final class Engine: @unchecked Sendable {
        private var bounds: CGRect
        let inputSources: InputSources
        private let lock = NSRecursiveLock()
        private var heldKeys = Set<UInt16>()
        private var heldButtons = Set<Int>()
        private var highestPointerSequence: UInt64 = 0
        private var lastPoint = CGPoint.zero
        private var hasKnownPoint = false
        private var pointerRemainderX: Double = 0
        private var pointerRemainderY: Double = 0
        private var inputFlags: CGEventFlags = []
        private var scroll = ScrollAccumulator()
        private var lineScroll = ScrollAccumulator()
        // Gesture and momentum phases already given to apps and not yet ended.
        private var openScrollPhase: RemoteInput.ScrollPhase?
        private var momentumOpen = false
        private var openMagnifyPhase: RemoteInput.ScrollPhase?
        private var openRotatePhase: RemoteInput.ScrollPhase?
        private static let gestureEventType = CGEventType(rawValue: 29)!
        private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
        private static let gestureValueField = CGEventField(rawValue: 113)!
        private static let gesturePhaseField = CGEventField(rawValue: 132)!
        private static let hidTypeRotate: Int64 = 5
        private static let hidTypeMagnify: Int64 = 8
        private static let hidTypeSmartMagnify: Int64 = 22
        private let source = CGEventSource(stateID: .hidSystemState)
        private var remoteCapsLock: Bool?
        private let isTrusted: () -> Bool
        private let postEvent: (CGEvent) -> Void
        private let capsLockState: () -> Bool
        private let pointerLocation: () -> CGPoint?

        init(bounds: CGRect, isTrusted: @escaping () -> Bool, postEvent: @escaping (CGEvent) -> Void,
             inputSources: InputSources, capsLockState: @escaping () -> Bool, pointerLocation: @escaping () -> CGPoint?) {
            self.bounds = bounds
            self.isTrusted = isTrusted
            self.postEvent = postEvent
            self.inputSources = inputSources
            self.capsLockState = capsLockState
            self.pointerLocation = pointerLocation
        }

        func currentBounds() -> CGRect {
            lock.withLock { bounds }
        }

        func updateBounds(_ next: CGRect) {
            lock.withLock {
                guard bounds != next else { return }
                releaseAllUnlocked()
                bounds = next
                hasKnownPoint = false
                pointerRemainderX = 0
                pointerRemainderY = 0
            }
        }

        func checkTrustedOrRelease() -> Bool {
            lock.withLock {
                guard isTrusted() else { releaseAllUnlocked(); return false }
                return true
            }
        }

        func prepareSwitchInputSource(_ input: RemoteInput) -> Bool {
            lock.withLock {
                if input.independentCapsLock == true || input.kind == .switchInputSource || input.kind == .toggleCapsLock {
                    if remoteCapsLock == nil { remoteCapsLock = capsLockState() }
                }
                return !inputSources.requiresKeyboardRefocus && remoteCapsLock != true
            }
        }

        func currentCapsLocked() -> Bool {
            lock.withLock { remoteCapsLock == true }
        }

        func receiveImmediate(_ input: RemoteInput, validated: Bool = false, fromDatagram: Bool = false) throws -> InputFeedback? {
            try lock.withLock {
                if !validated { try input.validate() }
                guard isTrusted() else { releaseAllUnlocked(); return nil }
                if fromDatagram, input.kind == .drag, !heldButtons.contains(input.button) {
                    return nil
                }
                if let pointerSequence = input.pointerSequence {
                    if input.kind == .move || input.kind == .drag {
                        guard pointerSequence > highestPointerSequence else { return nil }
                        highestPointerSequence = pointerSequence
                    } else if pointerSequence > highestPointerSequence {
                        highestPointerSequence = pointerSequence
                    }
                }
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
                    return nil
                }
                let absolutePoint = CGPoint(x: bounds.minX + input.x * max(0, bounds.width - 1),
                                            y: bounds.minY + input.y * max(0, bounds.height - 1))
                let point: CGPoint
                if input.relativeMouse == true {
                    let basePoint: CGPoint
                    if hasKnownPoint {
                        basePoint = clampToBounds(lastPoint)
                    } else if let current = pointerLocation() {
                        basePoint = clampToBounds(current)
                    } else {
                        basePoint = absolutePoint
                    }
                    if input.kind == .move || input.kind == .drag {
                        point = clampToBounds(CGPoint(x: basePoint.x + (input.pointerDeltaX ?? 0),
                                                      y: basePoint.y + (input.pointerDeltaY ?? 0)))
                    } else {
                        point = basePoint
                    }
                } else {
                    point = absolutePoint
                }
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
                        if input.flags & 0x207F != 0, let bit = InputInjector.modifierDeviceBits[input.keyCode] {
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
                    if input.scrollPhase == nil && input.momentumPhase == nil { endScrollPhasesUnlocked() }
                    let wheels = try scrollEventsUnlocked(input)
                    guard let wheel = wheels.last else { return nil }
                    try movePointerForTargetEventUnlocked(point: point, flags: flags, errorMessage: "无法建立远端滚动事件")
                    for earlier in wheels.dropLast() {
                        earlier.location = point
                        earlier.flags = flags
                        postEvent(earlier)
                    }
                    lastPoint = point
                    hasKnownPoint = true
                    pointerRemainderX = 0
                    pointerRemainderY = 0
                    event = wheel
                    event?.location = point
                case .magnify, .rotate, .smartMagnify:
                    let gestures = try trackpadGestureEventsUnlocked(input)
                    guard let lastGesture = gestures.last else { return nil }
                    try movePointerForTargetEventUnlocked(point: point, flags: flags, errorMessage: "无法建立远端触控板手势事件")
                    for earlier in gestures.dropLast() {
                        earlier.location = point
                        earlier.flags = flags
                        postEvent(earlier)
                    }
                    lastPoint = point
                    hasKnownPoint = true
                    pointerRemainderX = 0
                    pointerRemainderY = 0
                    event = lastGesture
                    event?.location = point
                case .move, .drag, .down, .up:
                    let type: CGEventType
                    switch input.kind {
                    case .down:
                        inputSources.requiresKeyboardRefocus = false
                        heldButtons.insert(input.button)
                        pointerRemainderX = 0
                        pointerRemainderY = 0
                        type = input.button == 0 ? .leftMouseDown : input.button == 1 ? .rightMouseDown : .otherMouseDown
                    case .up:
                        heldButtons.remove(input.button)
                        pointerRemainderX = 0
                        pointerRemainderY = 0
                        type = input.button == 0 ? .leftMouseUp : input.button == 1 ? .rightMouseUp : .otherMouseUp
                    case .drag:
                        type = input.button == 0 ? .leftMouseDragged : input.button == 1 ? .rightMouseDragged : .otherMouseDragged
                    default: type = .mouseMoved
                    }
                    event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                    if input.kind != .move {
                        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(input.button))
                    }
                    if input.kind == .move || input.kind == .drag {
                        let rawDX = input.pointerDeltaX ?? (hasKnownPoint ? Double(point.x - lastPoint.x) : 0)
                        let rawDY = input.pointerDeltaY ?? (hasKnownPoint ? Double(point.y - lastPoint.y) : 0)
                        let totalDX = pointerRemainderX + rawDX
                        let totalDY = pointerRemainderY + rawDY
                        let intDX = totalDX.rounded(.towardZero)
                        let intDY = totalDY.rounded(.towardZero)
                        pointerRemainderX = totalDX - intDX
                        pointerRemainderY = totalDY - intDY
                        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(intDX))
                        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(intDY))
                    }
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clicks))
                    lastPoint = point
                    hasKnownPoint = true
                case .switchInputSource, .toggleCapsLock: return nil
                }
                event?.flags = flags
                if let event { inputFlags = flags; postEvent(event) }
                return nil
            }
        }

        private func scrollEventsUnlocked(_ input: RemoteInput) throws -> [CGEvent] {
            if let lineX = input.lineDeltaX, let lineY = input.lineDeltaY {
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

        private func clampToBounds(_ point: CGPoint) -> CGPoint {
            let maxX = bounds.minX + max(0, bounds.width - 1)
            let maxY = bounds.minY + max(0, bounds.height - 1)
            return CGPoint(x: min(maxX, max(bounds.minX, point.x)),
                           y: min(maxY, max(bounds.minY, point.y)))
        }

        private func movePointerForTargetEventUnlocked(point: CGPoint, flags: CGEventFlags, errorMessage: String) throws {
            let current = pointerLocation()
            if current.map({ abs($0.x - point.x) >= 0.5 || abs($0.y - point.y) >= 0.5 }) ?? true {
                let heldButton = heldButtons.min()
                let moveType: CGEventType = heldButton == nil ? .mouseMoved
                    : heldButton == 0 ? .leftMouseDragged : heldButton == 1 ? .rightMouseDragged : .otherMouseDragged
                let moveButton = CGMouseButton(rawValue: UInt32(heldButton ?? 0)) ?? .left
                guard let move = CGEvent(mouseEventSource: source, mouseType: moveType, mouseCursorPosition: point,
                                         mouseButton: moveButton) else {
                    throw DeskError.invalid(errorMessage)
                }
                if let heldButton {
                    move.setIntegerValueField(.mouseEventButtonNumber, value: Int64(heldButton))
                }
                move.flags = flags
                postEvent(move)
            }
        }

        private func makeGestureEvent(hidType: Int64, value: Double?, phase: RemoteInput.ScrollPhase?) throws -> CGEvent {
            guard let event = CGEvent(source: source) else {
                throw DeskError.invalid("无法建立远端触控板手势事件")
            }
            event.type = Self.gestureEventType
            event.setIntegerValueField(Self.gestureHIDTypeField, value: hidType)
            if let value {
                event.setDoubleValueField(Self.gestureValueField, value: value)
            }
            event.setIntegerValueField(Self.gesturePhaseField, value: Int64(phase?.rawValue ?? 0))
            return event
        }

        private func trackpadGestureEventsUnlocked(_ input: RemoteInput) throws -> [CGEvent] {
            switch input.kind {
            case .smartMagnify:
                return [try makeGestureEvent(hidType: Self.hidTypeSmartMagnify, value: nil, phase: input.gesturePhase)]
            case .magnify:
                let mag = input.magnification ?? 0
                return try phasedGestureEventsUnlocked(
                    hidType: Self.hidTypeMagnify,
                    value: mag,
                    phase: input.gesturePhase,
                    openState: &openMagnifyPhase
                )
            case .rotate:
                let rot = input.rotation ?? 0
                return try phasedGestureEventsUnlocked(
                    hidType: Self.hidTypeRotate,
                    value: rot,
                    phase: input.gesturePhase,
                    openState: &openRotatePhase
                )
            default:
                return []
            }
        }

        private func phasedGestureEventsUnlocked(
            hidType: Int64,
            value: Double,
            phase: RemoteInput.ScrollPhase?,
            openState: inout RemoteInput.ScrollPhase?
        ) throws -> [CGEvent] {
            guard let phase else {
                guard value != 0 else { return [] }
                return [try makeGestureEvent(hidType: hidType, value: value, phase: nil)]
            }
            var events: [CGEvent] = []
            switch phase {
            case .mayBegin, .began:
                if let open = openState, open != .mayBegin {
                    events.append(try makeGestureEvent(hidType: hidType, value: 0, phase: .ended))
                }
                openState = phase
                events.append(try makeGestureEvent(hidType: hidType, value: value, phase: phase))
            case .changed:
                if openState == nil || openState == .mayBegin {
                    events.append(try makeGestureEvent(hidType: hidType, value: 0, phase: .began))
                }
                openState = .changed
                events.append(try makeGestureEvent(hidType: hidType, value: value, phase: .changed))
            case .ended, .cancelled:
                guard openState != nil else { return events }
                openState = nil
                events.append(try makeGestureEvent(hidType: hidType, value: value, phase: phase))
            }
            return events
        }

        private func endTrackpadGesturesUnlocked() {
            var endings: [(Int64, RemoteInput.ScrollPhase)] = []
            if let open = openMagnifyPhase {
                endings.append((Self.hidTypeMagnify, open == .mayBegin ? .cancelled : .ended))
            }
            if let open = openRotatePhase {
                endings.append((Self.hidTypeRotate, open == .mayBegin ? .cancelled : .ended))
            }
            openMagnifyPhase = nil
            openRotatePhase = nil
            for (hidType, phase) in endings {
                guard let event = try? makeGestureEvent(hidType: hidType, value: 0, phase: phase) else { continue }
                event.location = lastPoint
                event.flags = inputFlags
                postEvent(event)
            }
        }

        private func endScrollPhasesUnlocked() {
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
            lock.withLock { releaseAllUnlocked() }
        }

        private func releaseAllUnlocked() {
            endScrollPhasesUnlocked()
            endTrackpadGesturesUnlocked()
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
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                event?.flags = remoteCapsLock == true ? [.maskAlphaShift] : []
                if let event { postEvent(event) }
            }
            heldKeys.removeAll()
            heldButtons.removeAll()
            pointerRemainderX = 0
            pointerRemainderY = 0
            hasKnownPoint = false
            inputFlags = remoteCapsLock == true ? [.maskAlphaShift] : []
        }
    }

    nonisolated var bounds: CGRect { engine.currentBounds() }
    nonisolated let supportsConcurrentQueue: Bool
    private let engine: Engine

    convenience init(displayID: CGDirectDisplayID) {
        self.init(concurrentBounds: CGDisplayBounds(displayID))
    }

    nonisolated init(concurrentBounds bounds: CGRect,
                     isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
                     postEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
                     inputSources: InputSources? = nil,
                     capsLockState: @escaping @Sendable () -> Bool = { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) },
                     pointerLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.supportsConcurrentQueue = true
        self.engine = Engine(bounds: bounds, isTrusted: isTrusted, postEvent: postEvent,
                             inputSources: inputSources ?? InputSources(),
                             capsLockState: capsLockState, pointerLocation: pointerLocation)
    }

    init(bounds: CGRect, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         inputSources: InputSources? = nil,
         capsLockState: @escaping () -> Bool = { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) },
         pointerLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.supportsConcurrentQueue = false
        self.engine = Engine(bounds: bounds, isTrusted: isTrusted, postEvent: postEvent,
                             inputSources: inputSources ?? InputSources(),
                             capsLockState: capsLockState, pointerLocation: pointerLocation)
    }

    nonisolated func updateBounds(_ next: CGRect) {
        engine.updateBounds(next)
    }

    func receive(_ input: RemoteInput) async throws -> InputFeedback? {
        try input.validate()
        guard engine.checkTrustedOrRelease() else { return nil }
        if input.kind == .switchInputSource, engine.prepareSwitchInputSource(input) {
            do {
                let selected = try await engine.inputSources.toggle()
                guard engine.checkTrustedOrRelease() else { return nil }
                return InputFeedback(message: "远端输入源已确认：\(selected)", capsLocked: false)
            } catch is CancellationError {
                return nil
            } catch {
                if engine.inputSources.requiresKeyboardRefocus {
                    engine.releaseAll()
                    return InputFeedback(message: "\(error.localizedDescription)，请点击远端输入位置后继续",
                                         capsLocked: engine.currentCapsLocked())
                }
                return InputFeedback(message: error.localizedDescription, capsLocked: engine.currentCapsLocked())
            }
        }
        return try engine.receiveImmediate(input, validated: true)
    }

    func receiveImmediate(_ input: RemoteInput, validated: Bool = false, fromDatagram: Bool = false) throws -> InputFeedback? {
        try engine.receiveImmediate(input, validated: validated, fromDatagram: fromDatagram)
    }

    nonisolated func receiveImmediateOnInputQueue(_ input: RemoteInput, validated: Bool = false, fromDatagram: Bool = false) throws -> InputFeedback? {
        precondition(supportsConcurrentQueue)
        return try engine.receiveImmediate(input, validated: validated, fromDatagram: fromDatagram)
    }

    func releaseAll() {
        engine.releaseAll()
    }

    nonisolated func releaseAllOnInputQueue() {
        precondition(supportsConcurrentQueue)
        engine.releaseAll()
    }
}
