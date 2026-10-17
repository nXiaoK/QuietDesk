import AppKit
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

    init(sequence: UInt32 = 0) { self.sequence = sequence }

    var isIdle: Bool { encoding == nil && waiting.isEmpty }

    mutating func begin(at now: TimeInterval) -> (sequence: UInt32, forceKeyFrame: Bool)? {
        // The encoding reservation also consumes a credit; there is no unbounded encoder queue.
        guard encoding == nil, waiting.count < Self.maximumOutstandingFrames else { return nil }
        repeat { sequence &+= 1 } while waiting[sequence] != nil
        encoding = sequence
        encodingStartedAt = now
        encodingKeyFrame = forceKeyFrame
        forceKeyFrame = false
        return (sequence, encodingKeyFrame)
    }

    mutating func encoded(_ number: UInt32, at now: TimeInterval) -> Bool {
        guard encoding == number else { return false }
        encoding = nil
        encodingStartedAt = nil
        consecutiveDrops = 0
        waiting[number] = now
        return true
    }

    mutating func dropped(_ number: UInt32) -> Bool {
        guard encoding == number else { return false }
        encoding = nil
        encodingStartedAt = nil
        consecutiveDrops = min(consecutiveDrops + 1, 3)
        forceKeyFrame = forceKeyFrame || encodingKeyFrame || consecutiveDrops >= 3
        return true
    }

    mutating func acknowledge(_ number: UInt32) -> Bool { waiting.removeValue(forKey: number) != nil }
    mutating func requestKeyFrame() { forceKeyFrame = true }
    mutating func cancelEncoding() { encoding = nil; encodingStartedAt = nil }

    func stalled(at now: TimeInterval) -> String? {
        if let encodingStartedAt, now - encodingStartedAt > 90 { return "视频编码超过 90 秒无输出" }
        if let oldest = waiting.values.min(), now - oldest > 90 { return "视频解码确认超过 90 秒未返回" }
        return nil
    }
}

// Capture state is confined to queue; callbacks are installed before start.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
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
    private var latest: (CVPixelBuffer, CMTime)?
    private var lastCapture: (CVPixelBuffer, CMTime)?
    private var frameFlow = VideoFrameFlow()
    private var running = false
    private var captureStarted = false
    private var reconfiguring = false
    private var sessionPaused = false
    private var idleWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var watchdog: DispatchSourceTimer?

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

    private static func configuration(width: Int, height: Int, settings: StreamSettings) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        return configuration
    }

    private func makeEncoder(width: Int, height: Int, settings: StreamSettings, id: UUID) throws -> VideoEncoder {
        let encoder = try VideoEncoder(width: width, height: height, settings: settings)
        encoder.onOutput = { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.encoderID == id else { return }
                switch result {
                case .success(let packet):
                    guard self.frameFlow.encoded(packet.sequence, at: ProcessInfo.processInfo.systemUptime) else { return }
                    self.onFrame?(packet)
                    self.completeFrameBoundary()
                case .failure(let error):
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
            self.queue.async {
                guard self.running, self.encoderID == id, self.frameFlow.dropped(number) else { return }
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
            encoderID = id
            self.stream = stream
            displayID = capture.displayID
            outputWidth = width
            outputHeight = height
            sourceWidth = capture.sourceWidth
            sourceHeight = capture.sourceHeight
            currentSettings = settings
            running = true
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.schedule(deadline: .now() + 2, repeating: 2)
            watchdog.setEventHandler { [weak self] in
                guard let self, self.running,
                      let message = self.frameFlow.stalled(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.reportError(DeskError.invalid(message))
            }
            self.watchdog = watchdog
            watchdog.resume()
        }
        do {
            try await stream.startCapture()
            queue.sync { if self.stream === stream, running { captureStarted = true } }
        } catch { await stop(); throw error }
    }

    func reconfigure(_ settings: StreamSettings) async throws -> VideoStreamState {
        try settings.validateControlValues()
        let snapshot = try queue.sync { () throws -> (SCStream, Int, Int, Int, Int, StreamSettings) in
            guard running, captureStarted, let stream, displayID != nil else { throw DeskError.invalid("屏幕采集尚未就绪，请稍后调整") }
            return (stream, sourceWidth, sourceHeight, outputWidth, outputHeight, currentSettings)
        }
        let (width, height) = settings.dimensions(width: snapshot.1, height: snapshot.2)
        let id = UUID()
        let replacement = try makeEncoder(width: width, height: height, settings: settings, id: id)
        do { try await pauseAtFrameBoundary() }
        catch { replacement.stop(); throw error }
        do {
            try Task.checkCancellation()
            try await snapshot.0.updateConfiguration(Self.configuration(width: width, height: height, settings: settings))
            try Task.checkCancellation()
            try queue.sync {
                guard running, stream === snapshot.0 else { throw CancellationError() }
                let old = encoder
                encoderID = id
                encoder = replacement
                outputWidth = width
                outputHeight = height
                currentSettings = settings
                frameFlow.requestKeyFrame()
                latest = lastCapture
                discardMismatchedFrame()
                old?.stop()
            }
            // The caller sends the settings result before resuming the new encoder.
            return VideoStreamState(settings: settings, width: width, height: height)
        } catch {
            replacement.stop()
            if queue.sync(execute: { running && stream === snapshot.0 }) {
                do {
                    try await snapshot.0.updateConfiguration(Self.configuration(width: snapshot.3, height: snapshot.4, settings: snapshot.5))
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
        let current = try queue.sync { () throws -> SCStream in
            guard running, captureStarted, let stream else { throw DeskError.invalid("屏幕采集尚未就绪") }
            return stream
        }
        try await pauseAtFrameBoundary()
        do {
            try Task.checkCancellation()
            try queue.sync {
                guard running, stream === current else { throw CancellationError() }
                sessionPaused = paused
                if paused { reconfiguring = false }
                else {
                    frameFlow.requestKeyFrame()
                    latest = lastCapture
                    discardMismatchedFrame()
                }
            }
            // The caller sends the resume result before releasing the new keyframe.
            return paused
        } catch {
            queue.sync {
                guard running, stream === current else { return }
                reconfiguring = false
                pump()
            }
            throw error
        }
    }

    func setExcludesCurrentApplication(_ enabled: Bool) async throws {
        let snapshot = try queue.sync { () throws -> (SCStream, CGDirectDisplayID) in
            guard running, let stream, let displayID else { throw DeskError.invalid("屏幕采集尚未就绪") }
            return (stream, displayID)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == snapshot.1 }) else {
            throw DeskError.invalid("共享的显示器已变化，请等待重新连接")
        }
        let filter: SCContentFilter
        if enabled {
            guard let application = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw DeskError.invalid("无法从采集中排除本应用，防窥未开启")
            }
            filter = SCContentFilter(display: display, excludingApplications: [application], exceptingWindows: [])
        } else { filter = SCContentFilter(display: display, excludingWindows: []) }
        try Task.checkCancellation()
        try await snapshot.0.updateContentFilter(filter)
        try Task.checkCancellation()
        try queue.sync {
            guard running, stream === snapshot.0 else { throw CancellationError() }
            frameFlow.requestKeyFrame()
        }
    }

    private func pauseAtFrameBoundary() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
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

    func acknowledge(_ number: UInt32) {
        queue.async { [weak self] in
            guard let self, self.frameFlow.acknowledge(number) else { return }
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
            if (error as NSError).domain == SCStreamErrorDomain,
               (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
                self.onUserStop?()
                return
            }
            self.reportError(error, message: "屏幕采集停止：\(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard running, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !reconfiguring, (CVPixelBufferGetWidth(buffer) != outputWidth || CVPixelBufferGetHeight(buffer) != outputHeight) { return }
        latest = (buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lastCapture = latest
        pump()
    }

    private func discardMismatchedFrame() {
        if let latest, CVPixelBufferGetWidth(latest.0) != outputWidth || CVPixelBufferGetHeight(latest.0) != outputHeight { self.latest = nil }
    }

    private func pump() {
        guard running, !reconfiguring, !sessionPaused else { return }
        discardMismatchedFrame()
        guard let latest, let encoder,
              let frame = frameFlow.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        self.latest = nil
        do { try encoder.encode(latest.0, time: latest.1, sequence: frame.sequence, forceKeyFrame: frame.forceKeyFrame) }
        catch {
            frameFlow.cancelEncoding()
            if let waiter = idleWaiter { idleWaiter = nil; waiter.1.resume(throwing: error) }
            reportError(error)
        }
    }

    deinit { watchdog?.cancel() }
}

@MainActor
final class InputInjector {
    let bounds: CGRect
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var scroll = ScrollAccumulator()
    private let source = CGEventSource(stateID: .hidSystemState)
    private let inputSources = InputSources()
    private var remoteCapsLock: Bool?
    private let isTrusted: () -> Bool
    private let postEvent: (CGEvent) -> Void

    convenience init(displayID: CGDirectDisplayID) { self.init(bounds: CGDisplayBounds(displayID)) }

    init(bounds: CGRect, isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.bounds = bounds
        self.isTrusted = isTrusted
        self.postEvent = postEvent
    }

    func receive(_ input: RemoteInput) throws -> InputFeedback? {
        try input.validate()
        guard isTrusted() else { releaseAll(); return nil }
        if input.independentCapsLock == true || input.kind == .switchInputSource || input.kind == .toggleCapsLock {
            if remoteCapsLock == nil { remoteCapsLock = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) }
        }
        if input.kind == .switchInputSource || input.kind == .toggleCapsLock {
            if input.kind == .toggleCapsLock || remoteCapsLock == true {
                remoteCapsLock = !(remoteCapsLock ?? false)
                let event = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: remoteCapsLock == true)
                event?.type = .flagsChanged
                var modifiers = CGEventSource.flagsState(.combinedSessionState)
                modifiers.remove(.maskAlphaShift)
                if remoteCapsLock == true { modifiers.insert(.maskAlphaShift) }
                event?.flags = modifiers
                if let event { postEvent(event) }
                return InputFeedback(message: remoteCapsLock == true ? "远端大写锁定已开启" : "远端大写锁定已关闭",
                                     capsLocked: remoteCapsLock == true)
            }
            do {
                return InputFeedback(message: "远端输入法：\(try inputSources.toggle())", capsLocked: false)
            } catch {
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
                let down = flags.contains(modifier)
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
            guard let pixels = try scroll.accumulate(deltaX: input.deltaX, deltaY: input.deltaY) else { return nil }
            let heldButton = heldButtons.min()
            let moveType: CGEventType = heldButton == nil ? .mouseMoved
                : heldButton == 0 ? .leftMouseDragged : heldButton == 1 ? .rightMouseDragged : .otherMouseDragged
            let moveButton = CGMouseButton(rawValue: UInt32(heldButton ?? 0)) ?? .left
            guard let move = CGEvent(mouseEventSource: source, mouseType: moveType, mouseCursorPosition: point, mouseButton: moveButton),
                  let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: pixels.y, wheel2: pixels.x, wheel3: 0) else {
                throw DeskError.invalid("无法建立远端滚动事件")
            }
            // A scroll's location does not move the pointer used for window and view routing.
            move.flags = flags
            postEvent(move)
            lastPoint = point
            event = wheel
            event?.location = point
        case .move, .drag, .down, .up:
            let type: CGEventType
            switch input.kind {
            case .down:
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
        if let event { postEvent(event) }
        return nil
    }

    func releaseAll() {
        scroll.reset()
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
    }
}
