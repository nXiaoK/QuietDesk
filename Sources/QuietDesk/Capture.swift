import AppKit
import ScreenCaptureKit
import QuietDeskCore

// Capture state is confined to queue; callbacks are installed before start.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "quietdesk.capture", qos: .userInteractive)
    var onFrame: ((VideoPacket) -> Void)?
    var onError: ((String) -> Void)?
    var onUserStop: (() -> Void)?
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var encoderID = UUID()
    private var displayID: CGDirectDisplayID?
    private var currentSettings = StreamSettings()
    private var outputWidth = 0
    private var outputHeight = 0
    private var latest: (CVPixelBuffer, CMTime)?
    private var lastCapture: (CVPixelBuffer, CMTime)?
    private var waiting: UInt32?
    private var sequence: UInt32 = 0
    private var running = false
    private var captureStarted = false
    private var encoding = false
    private var reconfiguring = false
    private var forceKeyFrame = true
    private var idleWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var watchdog: DispatchSourceTimer?
    private var sentAt = ProcessInfo.processInfo.systemUptime

    private static func configuration(width: Int, height: Int, settings: StreamSettings) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
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
                self.encoding = false
                switch result {
                case .success(let packet):
                    self.waiting = packet.sequence
                    self.sentAt = ProcessInfo.processInfo.systemUptime
                    self.onFrame?(packet)
                case .failure(let error): self.onError?(error.localizedDescription)
                }
            }
        }
        return encoder
    }

    func start(display: SCDisplay, width: Int, height: Int, settings: StreamSettings) async throws {
        let id = UUID()
        let encoder = try makeEncoder(width: width, height: height, settings: settings, id: id)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: Self.configuration(width: width, height: height, settings: settings), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.encoder = encoder
            encoderID = id
            self.stream = stream
            displayID = display.displayID
            outputWidth = width
            outputHeight = height
            currentSettings = settings
            running = true
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.schedule(deadline: .now() + 2, repeating: 2)
            watchdog.setEventHandler { [weak self] in
                guard let self, self.running, self.waiting != nil || self.encoding else { return }
                if ProcessInfo.processInfo.systemUptime - self.sentAt > 90 {
                    self.onError?(self.encoding ? "视频编码超过 90 秒无输出" : "视频解码确认超过 90 秒未返回")
                }
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
        let snapshot = try queue.sync { () throws -> (SCStream, CGDirectDisplayID, Int, Int, StreamSettings) in
            guard running, captureStarted, let stream, let displayID else { throw DeskError.invalid("屏幕采集尚未就绪，请稍后调整") }
            return (stream, displayID, outputWidth, outputHeight, currentSettings)
        }
        let (width, height) = settings.dimensions(width: CGDisplayPixelsWide(snapshot.1), height: CGDisplayPixelsHigh(snapshot.1))
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
                forceKeyFrame = true
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
                    try await snapshot.0.updateConfiguration(Self.configuration(width: snapshot.2, height: snapshot.3, settings: snapshot.4))
                    queue.sync {
                        guard running, stream === snapshot.0 else { return }
                        forceKeyFrame = true
                        discardMismatchedFrame()
                        reconfiguring = false
                        pump()
                    }
                } catch let rollbackError {
                    queue.async { [weak self] in self?.onError?("画质调整失败且无法恢复原配置：\(rollbackError.localizedDescription)") }
                }
            }
            throw error
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
                if !encoding, waiting == nil { continuation.resume(); return }
                let token = UUID()
                idleWaiter = (token, continuation)
                queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, let waiter = self.idleWaiter, waiter.0 == token else { return }
                    self.idleWaiter = nil
                    self.reconfiguring = false
                    waiter.1.resume(throwing: DeskError.invalid("上一帧仍未确认，请稍后重试画质调整"))
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
            guard let self, self.waiting == number else { return }
            self.waiting = nil
            if !self.encoding, let waiter = self.idleWaiter {
                self.idleWaiter = nil
                waiter.1.resume()
            }
            self.pump()
        }
    }

    func stop() async {
        let old: SCStream? = queue.sync {
            running = false
            captureStarted = false
            reconfiguring = false
            latest = nil
            lastCapture = nil
            waiting = nil
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
            self.onError?("屏幕采集停止：\(error.localizedDescription)")
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
        guard running, !reconfiguring, waiting == nil, !encoding else { return }
        discardMismatchedFrame()
        guard let latest, let encoder else { return }
        self.latest = nil
        sequence &+= 1
        encoding = true
        sentAt = ProcessInfo.processInfo.systemUptime
        let keyFrame = forceKeyFrame
        forceKeyFrame = false
        do { try encoder.encode(latest.0, time: latest.1, sequence: sequence, forceKeyFrame: keyFrame) }
        catch { encoding = false; onError?(error.localizedDescription) }
    }

    deinit { watchdog?.cancel() }
}

@MainActor
final class InputInjector {
    let bounds: CGRect
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPoint = CGPoint.zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private let inputSources = InputSources()
    private var remoteCapsLock: Bool?

    init(displayID: CGDirectDisplayID) { bounds = CGDisplayBounds(displayID) }

    func receive(_ input: RemoteInput) throws -> InputFeedback? {
        try input.validate()
        guard AXIsProcessTrusted() else { releaseAll(); return nil }
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
                event?.post(tap: .cghidEventTap)
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
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(input.deltaY.rounded()), wheel2: Int32(input.deltaX.rounded()), wheel3: 0)
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
        event?.post(tap: .cghidEventTap)
        return nil
    }

    func releaseAll() {
        for key in heldKeys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key) { event?.type = .flagsChanged }
            event?.flags = remoteCapsLock == true ? [.maskAlphaShift] : []
            event?.post(tap: .cghidEventTap)
        }
        for button in heldButtons {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint,
                                mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .left)
            event?.flags = remoteCapsLock == true ? [.maskAlphaShift] : []
            event?.post(tap: .cghidEventTap)
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }
}
