import AppKit
import AVFoundation
import ImageIO
import QuietDeskCore
import SwiftUI
import VideoToolbox

/// A decoded remote frame handed to a background queue for PNG encoding; the buffer is never written again.
struct RemoteFrameSnapshot: @unchecked Sendable {
    let frame: CVPixelBuffer
    var width: Int { CVPixelBufferGetWidth(frame) }
    var height: Int { CVPixelBufferGetHeight(frame) }

    func pngData() -> Data? {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image) == noErr, let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

protocol MediaCanvasDecoding: AnyObject {
    func decode(_ packet: VideoPacket, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void)
    func stop()
}

extension VideoDecoder: MediaCanvasDecoding {}

enum CursorBitmap {
    private struct CacheKey: Hashable {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let logicalWidthBits: UInt64
        let logicalHeightBits: UInt64
    }

    private static let cacheLock = NSLock()
    private static var cachedImages: [CacheKey: NSImage] = [:]
    private static var cachedOrder: [CacheKey] = []
    private static let maximumCachedImages = 16

    private static let crcTable: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB88320 }
        return crc
    }

    // ImageIO may return a partial image even when compressed pixels are damaged.
    // Verify bounded PNG chunks before accepting it as a known cursor shape.
    private static func validChunks(_ data: Data) -> Bool {
        var reader = ByteReader(Data(data.dropFirst(8)))
        var header = false, pixels = false
        do {
            while reader.remaining >= 12 {
                let length: UInt32 = try reader.take()
                guard Int(length) <= reader.remaining - 8 else { return false }
                let kind = try reader.bytes(4), payload = try reader.bytes(Int(length))
                let expected: UInt32 = try reader.take()
                var crc = UInt32.max
                for bytes in [kind, payload] {
                    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
                }
                guard crc ^ UInt32.max == expected else { return false }
                if kind == Data("IHDR".utf8) {
                    guard !header, length == 13 else { return false }
                    header = true
                } else if !header { return false }
                if kind == Data("IDAT".utf8) { pixels = true }
                if kind == Data("IEND".utf8) { return pixels && length == 0 && reader.remaining == 0 }
            }
        } catch { return false }
        return false
    }

    static func image(_ value: CursorImage) -> NSImage? {
        let key = CacheKey(png: value.png, pixelWidth: value.pixelWidth, pixelHeight: value.pixelHeight,
                           logicalWidthBits: value.logicalWidth.bitPattern, logicalHeightBits: value.logicalHeight.bitPattern)
        if let cached = cacheLock.withLock({ cachedImages[key] }) { return cached }
        guard validChunks(value.png),
              let source = CGImageSourceCreateWithData(value.png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == value.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == value.pixelHeight,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == value.pixelWidth, image.height == value.pixelHeight else { return nil }
        let decoded = NSImage(cgImage: image, size: NSSize(width: value.logicalWidth, height: value.logicalHeight))
        cacheLock.withLock {
            if cachedImages[key] == nil {
                if cachedOrder.count >= maximumCachedImages, let oldest = cachedOrder.first {
                    cachedOrder.removeFirst()
                    cachedImages.removeValue(forKey: oldest)
                }
                cachedOrder.append(key)
                cachedImages[key] = decoded
            }
        }
        return decoded
    }
}

@MainActor
private final class CursorOverlayView: NSView {
    private var cachedCGImage: CGImage?
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            cachedCGImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        layer?.contentsGravity = .resize
        layer?.contents = cachedCGImage
    }
}

private final class DisplayLinkTarget: NSObject {
    weak var canvas: RemoteCanvas?
    init(_ canvas: RemoteCanvas) { self.canvas = canvas }
    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let canvas else { link.invalidate(); return }
            canvas.displayLinkFired(link)
        }
    }
}

// The authenticated media coordinator supplies ordered, complete frames. Each stream has
// its own decoder; an uncommitted candidate can decode and acknowledge without drawing.
final class MediaCanvasReceiver: @unchecked Sendable {
    private final class Stream {
        let id: MediaStreamID
        let decoder: MediaCanvasDecoding
        let mailbox: LatestFrameMailbox
        private let sampleLock = NSLock()
        private var sampleCache = VideoDisplayFormatCache()
        var pending: [UUID: (Bool) -> Void] = [:]
        var submittedAt: [UUID: TimeInterval] = [:]
        var lastCompletedAt: TimeInterval?
        var lastSubmitted: UInt64?
        var lastDecoded: UInt64?
        var hasDecodedIDR = false
        var displayScheduled = false

        init(id: MediaStreamID, decoder: MediaCanvasDecoding, diagnostics: PerformanceDiagnostics?) {
            self.id = id; self.decoder = decoder
            mailbox = LatestFrameMailbox(diagnostics: diagnostics)
        }

        func prepareSample(_ image: CVPixelBuffer) -> CMSampleBuffer? {
            sampleLock.withLock { sampleCache.sampleBuffer(for: image) }
        }
    }

    // Outer fence acquired only by commit, stop and main-actor presentation so 60-240 fps
    // receive/decode callbacks never contend with UI display work.
    private let displayFence = NSLock()
    private let lock = NSLock()
    private let diagnostics: PerformanceDiagnostics?
    private let makeDecoder: (PerformanceDiagnostics?) -> MediaCanvasDecoding
    private let display: @MainActor (LatestFrameMailbox) -> Void
    private let willDisplay: @MainActor (MediaStreamID) -> Void
    private var active: Stream?
    private var candidate: Stream?
    private var newestStream: MediaStreamID?
    private var stopped = false
    private var decodeTime: ((Double) -> Void)?

    init(diagnostics: PerformanceDiagnostics? = nil,
         makeDecoder: @escaping (PerformanceDiagnostics?) -> MediaCanvasDecoding = { VideoDecoder(diagnostics: $0) },
         willDisplay: @escaping @MainActor (MediaStreamID) -> Void = { _ in },
         display: @escaping @MainActor (LatestFrameMailbox) -> Void) {
        self.diagnostics = diagnostics; self.makeDecoder = makeDecoder; self.display = display; self.willDisplay = willDisplay
    }

    func receive(_ frame: MediaFrame, completion: @escaping (Bool) -> Void) {
        var retired: Stream?
        let submission: (Stream, UUID)? = lock.withLock {
            guard !stopped else { return nil }
            let stream: Stream
            let id = frame.header.stream
            if let active, active.id == id { stream = active }
            else if let candidate, candidate.id == id { stream = candidate }
            else {
                guard frame.header.isIDR else { return nil }
                if let newestStream {
                    guard id.sessionID == newestStream.sessionID,
                          id.transportEpoch > newestStream.transportEpoch
                            || (id.transportEpoch == newestStream.transportEpoch && id.codecEpoch > newestStream.codecEpoch) else { return nil }
                }
                stream = Stream(id: id, decoder: makeDecoder(diagnostics), diagnostics: diagnostics)
                retired = candidate
                candidate = stream; newestStream = id
            }
            guard stream.pending.count < 3,
                  stream.lastSubmitted.map({ frame.header.frameID > $0 }) ?? true else { return nil }
            let token = UUID()
            stream.lastSubmitted = frame.header.frameID
            stream.pending[token] = completion
            stream.submittedAt[token] = SessionClock.now
            return (stream, token)
        }
        if let retired { retire(retired) }
        guard let (stream, token) = submission else { completion(false); return }
        stream.decoder.decode(frame.packet) { [weak self, stream] result in
            self?.decoded(result, frame: frame, stream: stream, token: token)
        }
    }

    @discardableResult
    func commit(stream id: MediaStreamID) -> Bool {
        var retired: Stream?
        var alreadyActive = false
        let committed: Stream? = displayFence.withLock {
            lock.withLock {
                guard !stopped else { return nil }
                if let active, active.id == id { alreadyActive = true; return nil }
                guard let candidate, candidate.id == id, candidate.hasDecodedIDR else { return nil }
                retired = active; active = candidate; self.candidate = nil
                return candidate
            }
        }
        if let retired { retire(retired) }
        guard let committed else { return alreadyActive }
        scheduleDisplay(committed)
        return true
    }

    func stop() {
        let retired: [Stream] = displayFence.withLock {
            lock.withLock {
                guard !stopped else { return [] }
                stopped = true
                let streams = [active, candidate].compactMap { $0 }
                active = nil; candidate = nil; newestStream = nil
                return streams
            }
        }
        for stream in retired { retire(stream) }
    }

    /// Milliseconds the decoder spent on each decoded frame: from when it could start the frame (its submission,
    /// or the previous frame's completion while still busy) to its completion. Waiting behind earlier frames of a
    /// burst is not decode time, so this measures what the decoder sustains.
    func reportDecodeTime(_ handler: ((Double) -> Void)?) { lock.withLock { decodeTime = handler } }

    private func decoded(_ result: Result<CVPixelBuffer, Error>, frame: MediaFrame, stream: Stream, token: UUID) {
        let completedAt = SessionClock.now
        let preparedSample: CMSampleBuffer?
        if case .success(let image) = result { preparedSample = stream.prepareSample(image) }
        else { preparedSample = nil }
        var success = false
        var shouldDisplay = false
        var serviceTime: (Double, (Double) -> Void)?
        let completion: ((Bool) -> Void)? = lock.withLock {
            guard let completion = stream.pending.removeValue(forKey: token) else { return nil }
            let submittedAt = stream.submittedAt.removeValue(forKey: token)
            guard !stopped, active === stream || candidate === stream else { return completion }
            if case .success(let image) = result {
                if let submittedAt, let decodeTime {
                    serviceTime = (max(0, completedAt - max(submittedAt, stream.lastCompletedAt ?? submittedAt)) * 1_000, decodeTime)
                }
                stream.lastCompletedAt = completedAt
                success = true
                if frame.header.isIDR { stream.hasDecodedIDR = true }
                if stream.lastDecoded.map({ frame.header.frameID > $0 }) ?? true {
                    stream.lastDecoded = frame.header.frameID
                    // The media envelope has a 64-bit frame ID. Its watermark above owns
                    // ordering; the legacy packet's independent 32-bit sequence is not reused.
                    let offered = stream.mailbox.offer(image, sampleBuffer: preparedSample)
                    shouldDisplay = active === stream && offered
                }
            }
            return completion
        }
        if let (milliseconds, report) = serviceTime { report(milliseconds) }
        // ACK/failure delivery does not wait for the main queue, visibility or layer readiness.
        completion?(success)
        if shouldDisplay { scheduleDisplay(stream) }
    }

    private func scheduleDisplay(_ stream: Stream) {
        let scheduled = lock.withLock {
            guard !stopped, active === stream, !stream.displayScheduled else { return false }
            stream.displayScheduled = true
            return true
        }
        guard scheduled else { return }
        DispatchQueue.main.async { [weak self, stream] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep commit/stop serialized against presentation without blocking decode/receive callbacks.
                self.displayFence.withLock {
                    let ready: (MediaStreamID, LatestFrameMailbox)? = self.lock.withLock {
                        stream.displayScheduled = false
                        guard !self.stopped, self.active === stream else { return nil }
                        return (stream.id, stream.mailbox)
                    }
                    guard let (id, mailbox) = ready else { return }
                    self.willDisplay(id)
                    self.display(mailbox)
                }
            }
        }
    }

    private func retire(_ stream: Stream) {
        let completions = lock.withLock {
            let pending = Array(stream.pending.values)
            stream.pending.removeAll()
            stream.submittedAt.removeAll()
            return pending
        }
        stream.mailbox.stopDiagnostics()
        stream.decoder.stop()
        for completion in completions { completion(false) }
    }

    deinit { stop() }
}

struct VideoDisplayFormatCache {
    private var cached: (width: Int, height: Int, pixelFormat: OSType, description: CMVideoFormatDescription)?
    private(set) var hits = 0
    private(set) var misses = 0

    mutating func formatDescription(for image: CVPixelBuffer) -> CMVideoFormatDescription? {
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let pixelFormat = CVPixelBufferGetPixelFormatType(image)
        if let cached,
           cached.width == width,
           cached.height == height,
           cached.pixelFormat == pixelFormat,
           CMVideoFormatDescriptionMatchesImageBuffer(cached.description, imageBuffer: image) {
            hits += 1
            return cached.description
        }
        var created: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                           formatDescriptionOut: &created) == noErr,
              let format = created else { return nil }
        cached = (width, height, pixelFormat, format)
        misses += 1
        return format
    }

    mutating func sampleBuffer(for image: CVPixelBuffer) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard let format = formatDescription(for: image),
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    mutating func reset() {
        cached = nil
    }
}

enum RemoteCanvasScalingMode: String, CaseIterable, Equatable {
    case fitWindow
    case original1To1

    var title: String {
        switch self {
        case .fitWindow: return "适应窗口"
        case .original1To1: return "原始比例 1:1"
        }
    }
}

@MainActor
final class RemoteCanvas: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer
    private let renderQueue = DispatchQueue(label: "quietdesk.canvas-render", qos: .userInteractive)
    private var displayLink: CADisplayLink?
    private var lastPresentedAt: TimeInterval = 0
    private var decoder: MediaCanvasDecoding = VideoDecoder()
    private var mailbox = LatestFrameMailbox()
    private var formatCache = VideoDisplayFormatCache()
    private var diagnostics: PerformanceDiagnostics?
    private var mediaReceiver: MediaCanvasReceiver?
    private var mediaReceiverID: UUID?
    private var displayStream: MediaStreamID?
    private var awaitingDisplay = false
    /// The decoded frame most recently handed to the display layer; the curtain is never part of it.
    private(set) var displayedFrame: CVPixelBuffer?
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var movePacer = PointerMovePacer()
    private var dragPacer = PointerMovePacer(allowsDrag: true)
    private var moveTimer: Timer?
    private var dragTimer: Timer?
    private var moveGeneration = UUID()
    private var dragGeneration = UUID()
    private(set) var isFlushingPointerMoves = false
    private var activeScroll: RemoteInput?
    private var cursorState = CursorPresentationState()
    private var cursorImage: NSImage?
    private var localCursor = NSCursor.arrow
    private var cursorHotSpot = NSCursor.arrow.hotSpot
    private let remoteCursorView = CursorOverlayView()
    private var localPointerInside = false
    private var cursorPublished: (Bool, Bool)?
    var onCursorPresentation: ((Bool, Bool) -> Void)?
    var pointerInputSuspended = false {
        didSet {
            if pointerInputSuspended { cancelPointerMoves(); activeScroll = nil }
            window?.invalidateCursorRects(for: self)
            updateCursorPresentation()
        }
    }
    private var localShortcutKeys = Set<UInt16>()
    let capsLockMonitor = CapsLockMonitor()
    private let systemShortcutMonitor = SystemShortcutMonitor()
    private var shortcutSessionActive = false
    private var shortcutAccessibility = false
    private var shortcutInputMonitoring = false
    private var shortcutStartAttempted = false
    private var shortcutStatus: (String, Bool)?
    var onSystemShortcutStatus: ((String, Bool) -> Void)? {
        didSet { if let shortcutStatus { onSystemShortcutStatus?(shortcutStatus.0, shortcutStatus.1) } }
    }
    var onInput: ((RemoteInput) -> Void)?
    var onUserActivity: (() -> Void)?
    var onPaste: ((RemoteInput) -> Void)?
    var synchronizesClipboard = false
    /// false 时 ⌘V 不等剪贴板，按普通按键送到远端。
    var holdsPaste: (() -> Bool)?
    private(set) var interactionRevision: UInt64 = 0
    var onRelease: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFullScreen: ((Bool) -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onCaptureFrame: (() -> Void)?
    var remoteSize = CGSize(width: 16, height: 10) {
        didSet {
            guard oldValue != remoteSize else { return }
            needsLayout = true
            updateLayerFrame()
            window?.invalidateCursorRects(for: self)
            updateCursorPresentation()
        }
    }
    var scalingMode: RemoteCanvasScalingMode = .fitWindow {
        didSet {
            guard oldValue != scalingMode else { return }
            needsLayout = true
            updateLayerFrame()
            window?.invalidateCursorRects(for: self)
            updateCursorPresentation()
        }
    }
    var canControl = false {
        didSet {
            if !canControl { cancelPointerMoves(); activeScroll = nil }
            reconcileSystemShortcutCapture()
            window?.invalidateCursorRects(for: self)
            updateCursorPresentation()
        }
    }
    var usesCapsLockActions = false

    override var acceptsFirstResponder: Bool { canControl }
    override var isFlipped: Bool { true }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, videoLayer: AVSampleBufferDisplayLayer())
    }

    init(frame frameRect: NSRect, videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        remoteCursorView.isHidden = true
        remoteCursorView.wantsLayer = true
        remoteCursorView.layer?.zPosition = 1
        addSubview(remoteCursorView)
        capsLockMonitor.isActive = { [weak self] in
            guard let self else { return false }
            return self.usesCapsLockActions && self.canControl && self.window?.isKeyWindow == true
                && self.window?.firstResponder === self
        }
        capsLockMonitor.onAction = { [weak self] kind in self?.onInput?(RemoteInput(kind: kind)) }
        systemShortcutMonitor.scope = { [weak self] in self?.shortcutScope ?? SystemShortcutScope() }
        systemShortcutMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .keyDown: self.keyDown(with: event)
            case .keyUp: self.keyUp(with: event)
            case .flagsChanged: self.flagsChanged(with: event)
            default: break
            }
        }
        systemShortcutMonitor.onFailure = { [weak self] message in
            guard let self else { return }
            let token = self.systemShortcutMonitor.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.systemShortcutMonitor.generation == token else { return }
                self.releaseControl()
                self.publishShortcutStatus(message, running: false)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func isInputTarget(of event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return window.firstResponder === self
        default:
            guard let content = window.contentView,
                  let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) else { return false }
            return hit === self || hit.isDescendant(of: self)
        }
    }

    override func layout() {
        super.layout()
        updateLayerFrame()
        if videoLayer.status == .failed || displayedFrame == nil || mailbox.hasPendingFrame {
            showLatestFrame()
        }
        updateCursorPresentation()
    }

    private func updateLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = scalingMode == .fitWindow ? bounds : pictureRect
        videoLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        cancelScrollGesture()
        cancelPointerMoves()
        needsLayout = true
        if systemShortcutMonitor.isRunning { releaseControl() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        systemShortcutMonitor.stop()
        shortcutStartAttempted = false
        guard let window else { publishShortcutStatus("全屏控制画面获得焦点后自动转发系统快捷键", running: false); return }
        window.acceptsMouseMovedEvents = true
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseControl(); self?.updateCursorPresentation() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileSystemShortcutCapture(); self?.updateCursorPresentation() }
            })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onFullScreen?(self.window?.styleMask.contains(.fullScreen) == true)
                    self.reconcileSystemShortcutCapture()
                }
            })
        }
        onFullScreen?(window.styleMask.contains(.fullScreen))
        reconcileSystemShortcutCapture()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if cursorState.enabled, canControl, !pointerInputSuspended {
            addCursorRect(pictureRect, cursor: localCursor)
        }
    }

    func receiveCursorStatus(_ control: CursorControl) { if cursorState.status(control) { refreshCursorImage() } }
    func receiveCursorBinding(_ control: CursorControl) { _ = cursorState.bind(control) }
    func receiveCursorShape(_ shape: CursorShape) { if cursorState.update(shape) { refreshCursorImage() } }
    func receiveCursorPosition(_ position: CursorPosition) { if cursorState.update(position) { updateCursorPresentation() } }

    private func refreshCursorImage(forcePublish: Bool = false) {
        let decoded = cursorState.image.flatMap(CursorBitmap.image)
        cursorImage = decoded ?? NSCursor.arrow.image
        if let value = cursorState.image, let decoded {
            cursorHotSpot = NSPoint(x: value.hotSpotX, y: value.hotSpotY)
            localCursor = NSCursor(image: decoded, hotSpot: cursorHotSpot)
        } else { localCursor = .arrow; cursorHotSpot = NSCursor.arrow.hotSpot }
        let flags = (cursorState.enabled, decoded != nil)
        if forcePublish || cursorPublished?.0 != flags.0 || cursorPublished?.1 != flags.1 {
            cursorPublished = flags
            onCursorPresentation?(flags.0, flags.1)
        }
        window?.invalidateCursorRects(for: self)
        updateCursorPresentation()
    }

    private func updateCursorPresentation() {
        let localOwnsPointer = localPointerInside && window?.isKeyWindow == true && canControl && !pointerInputSuspended
        guard cursorState.enabled, !localOwnsPointer, let position = cursorState.position, position.insideDisplay else {
            if !remoteCursorView.isHidden { remoteCursorView.isHidden = true }
            return
        }
        let image = cursorImage ?? NSCursor.arrow.image
        let hotSpot = cursorHotSpot
        let rect = pictureRect
        remoteCursorView.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        remoteCursorView.frame = NSRect(x: rect.minX + position.x * rect.width - hotSpot.x,
                                       y: rect.minY + position.y * rect.height - hotSpot.y,
                                       width: image.size.width, height: image.size.height)
        remoteCursorView.isHidden = false
        CATransaction.commit()
    }

    func setPointerFrameRate(_ framesPerSecond: Int) {
        let interval = PointerMovePacer.interval(forFramesPerSecond: framesPerSecond)
        movePacer.setInterval(interval)
        dragPacer.setInterval(interval)
        if moveTimer != nil { moveTimer?.invalidate(); moveTimer = nil; moveGeneration = UUID(); schedulePointerMove() }
        if dragTimer != nil { dragTimer?.invalidate(); dragTimer = nil; dragGeneration = UUID(); schedulePointerDrag() }
    }

    private func schedulePointerMove() {
        guard moveTimer == nil, let delay = movePacer.nextDelay(now: SessionClock.now) else { return }
        let token = moveGeneration
        let timer = Timer(timeInterval: max(0.0001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.moveGeneration == token else { return }
                self.moveTimer = nil
                if let input = self.movePacer.takeDue(now: SessionClock.now), self.canControl, !self.pointerInputSuspended {
                    self.onInput?(input)
                }
                self.schedulePointerMove()
            }
        }
        timer.tolerance = 0.001
        moveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func schedulePointerDrag() {
        guard dragTimer == nil, let delay = dragPacer.nextDelay(now: SessionClock.now) else { return }
        let token = dragGeneration
        let timer = Timer(timeInterval: max(0.0001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dragGeneration == token else { return }
                self.dragTimer = nil
                if let input = self.dragPacer.takeDue(now: SessionClock.now), self.canControl, !self.pointerInputSuspended {
                    self.onInput?(input)
                }
                self.schedulePointerDrag()
            }
        }
        timer.tolerance = 0.001
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitFlushedPointer(_ input: RemoteInput?) {
        guard let input, canControl, !pointerInputSuspended else { return }
        let previous = isFlushingPointerMoves
        isFlushingPointerMoves = true
        defer { isFlushingPointerMoves = previous }
        onInput?(input)
    }

    private func flushMovePacerOnly() {
        moveTimer?.invalidate(); moveTimer = nil; moveGeneration = UUID()
        emitFlushedPointer(movePacer.flush(now: SessionClock.now))
    }

    private func flushDragPacerOnly() {
        dragTimer?.invalidate(); dragTimer = nil; dragGeneration = UUID()
        emitFlushedPointer(dragPacer.flush(now: SessionClock.now))
    }

    private func flushPointerMoves() {
        flushMovePacerOnly()
        flushDragPacerOnly()
    }

    private func cancelPointerMoves() {
        moveTimer?.invalidate(); moveTimer = nil; moveGeneration = UUID(); movePacer.cancel()
        dragTimer?.invalidate(); dragTimer = nil; dragGeneration = UUID(); dragPacer.cancel()
    }

    func makeVideoReceiver(diagnostics: PerformanceDiagnostics? = nil,
                           makeDecoder: (PerformanceDiagnostics?) -> MediaCanvasDecoding = { VideoDecoder(diagnostics: $0) }) -> (VideoPacket, @escaping () -> Void) -> Void {
        mediaReceiverID = nil
        displayStream = nil
        mediaReceiver?.stop()
        mediaReceiver = nil
        decoder.stop()
        mailbox.stopDiagnostics()
        decoder = makeDecoder(diagnostics)
        mailbox = LatestFrameMailbox(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        let inbox = mailbox
        let decoder = decoder
        let sampleLock = NSLock()
        var sampleCache = VideoDisplayFormatCache()
        return { [weak self] packet, acknowledged in
            decoder.decode(packet) { [weak self] result in
                switch result {
                case .success(let image):
                    let prepared = sampleLock.withLock { sampleCache.sampleBuffer(for: image) }
                    if inbox.offer(image, sampleBuffer: prepared, sequence: packet.sequence) {
                        DispatchQueue.main.async {
                            guard let self, self.mailbox === inbox else { return }
                            self.requestFramePresentation()
                        }
                    }
                    // Decode completion is independent of window visibility and display readiness.
                    acknowledged()
                case .failure(let error):
                    DispatchQueue.main.async {
                        guard let self, self.mailbox === inbox else { return }
                        self.onFailure?(error.localizedDescription)
                    }
                }
            }
        }
    }

    func makeMediaReceiver(diagnostics: PerformanceDiagnostics? = nil,
                           makeDecoder: @escaping (PerformanceDiagnostics?) -> MediaCanvasDecoding = { VideoDecoder(diagnostics: $0) }) -> MediaCanvasReceiver {
        mediaReceiver?.stop()
        self.diagnostics = diagnostics
        let token = UUID()
        mediaReceiverID = token
        let receiver = MediaCanvasReceiver(diagnostics: diagnostics, makeDecoder: makeDecoder, willDisplay: { [weak self] stream in
            guard let self, self.mediaReceiverID == token else { return }
            self.displayStream = stream
        }) { [weak self] inbox in
            guard let self, self.mediaReceiverID == token else { return }
            if self.mailbox !== inbox {
                self.decoder.stop()
                self.mailbox.stopDiagnostics()
                self.videoLayer.stopRequestingMediaData()
                self.awaitingDisplay = false
                self.videoLayer.flush()
                self.displayedFrame = nil
                self.formatCache.reset()
                self.mailbox = inbox
                self.showLatestFrame()
                return
            }
            self.requestFramePresentation()
        }
        mediaReceiver = receiver
        return receiver
    }

    private func ensureDisplayLink() -> CADisplayLink? {
        if let displayLink { return displayLink }
        guard window != nil else { return nil }
        let target = DisplayLinkTarget(self)
        let link = self.displayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        return link
    }

    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard mailbox.hasPendingFrame else {
            link.isPaused = true
            return
        }
        showLatestFrame()
    }

    private func requestFramePresentation() {
        guard let window, window.isVisible, window.occlusionState.contains(.visible), displayedFrame != nil else {
            showLatestFrame()
            return
        }
        let maxFPS = max(60, window.screen?.maximumFramesPerSecond ?? 60)
        let vsyncInterval = 1.0 / Double(maxFPS)
        if SessionClock.uptime - lastPresentedAt >= vsyncInterval * 0.75 {
            showLatestFrame()
            return
        }
        if let link = ensureDisplayLink() {
            link.isPaused = false
        } else {
            showLatestFrame()
        }
    }

    private func showLatestFrame() {
        if videoLayer.status == .failed { videoLayer.flush() }
        guard videoLayer.isReadyForMoreMediaData else {
            if !awaitingDisplay {
                awaitingDisplay = true
                videoLayer.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.videoLayer.stopRequestingMediaData()
                            self.awaitingDisplay = false
                            self.showLatestFrame()
                        }
                    }
                }
            }
            return
        }
        guard let received = mailbox.takeSampleWithTiming() else {
            displayLink?.isPaused = true
            return
        }
        if !mailbox.hasPendingFrame { displayLink?.isPaused = true }
        let image = received.frame
        let enqueueStarted = diagnostics?.start()
        guard let sample = received.sampleBuffer ?? formatCache.sampleBuffer(for: image) else { return }
        // Keep the old cursor mode while the layer is busy or sample creation fails.
        // Clear its retained image before changing modes so a burned-in old cursor
        // cannot remain visible underneath the immediate local cursor.
        let previousCursorMode = cursorState.enabled
        if let displayStream, cursorState.commit(displayStream) {
            if cursorState.enabled != previousCursorMode { videoLayer.flushAndRemoveImage() }
            refreshCursorImage(forcePublish: true)
        }
        videoLayer.enqueue(sample)
        displayedFrame = image
        lastPresentedAt = SessionClock.uptime
        // Enqueue completion does not confirm that the frame has reached the screen.
        diagnostics?.record(.decodeToDisplay, since: received.decodedAt, kind: .video, identifier: received.sequence.map(UInt64.init))
        diagnostics?.record(.displayEnqueue, since: enqueueStarted, kind: .video, identifier: received.sequence.map(UInt64.init))
    }

    func reset() {
        displayLink?.invalidate()
        displayLink = nil
        lastPresentedAt = 0
        cancelPointerMoves()
        movePacer.setInterval(PointerMovePacer.interval)
        dragPacer.setInterval(PointerMovePacer.interval)
        cursorState = CursorPresentationState(); cursorImage = nil; localCursor = .arrow
        cursorPublished = nil; localPointerInside = false
        refreshCursorImage()
        shortcutSessionActive = false
        releaseControl()
        canControl = false
        mediaReceiverID = nil
        displayStream = nil
        mediaReceiver?.stop()
        mediaReceiver = nil
        decoder.stop()
        mailbox.stopDiagnostics()
        decoder = VideoDecoder()
        mailbox = LatestFrameMailbox()
        diagnostics = nil
        videoLayer.stopRequestingMediaData()
        videoLayer.flushAndRemoveImage()
        displayedFrame = nil
        formatCache.reset()
        awaitingDisplay = false
    }

    func releaseControl() {
        cancelPointerMoves()
        activeScroll = nil
        interactionRevision &+= 1
        if window?.firstResponder === self, window?.makeFirstResponder(nil) == true { return }
        systemShortcutMonitor.stop()
        shortcutStartAttempted = false
        publishShortcutStatus("全屏控制画面获得焦点后自动转发系统快捷键", running: false)
        capsLockMonitor.reset()
        localShortcutKeys.removeAll()
        onRelease?()
        onFocus?(false)
    }

    override func becomeFirstResponder() -> Bool {
        capsLockMonitor.reset(); localShortcutKeys.removeAll(); onFocus?(true)
        // NSWindow assigns firstResponder after this callback returns.
        DispatchQueue.main.async { [weak self] in self?.reconcileSystemShortcutCapture() }
        return true
    }
    override func resignFirstResponder() -> Bool {
        cancelPointerMoves()
        activeScroll = nil
        systemShortcutMonitor.stop()
        shortcutStartAttempted = false
        publishShortcutStatus("全屏控制画面获得焦点后自动转发系统快捷键", running: false)
        capsLockMonitor.reset(); localShortcutKeys.removeAll(); onRelease?(); onFocus?(false)
        return true
    }

    func updateSystemShortcutCapture(sessionActive: Bool, accessibility: Bool, inputMonitoring: Bool, retry: Bool = false) {
        shortcutSessionActive = sessionActive
        shortcutAccessibility = accessibility
        shortcutInputMonitoring = inputMonitoring
        reconcileSystemShortcutCapture(retry: retry)
    }

    private var shortcutScope: SystemShortcutScope {
        SystemShortcutScope(sessionActive: shortcutSessionActive, canControl: canControl,
            fullScreen: window?.styleMask.contains(.fullScreen) == true,
            keyWindow: NSApp?.isActive == true && window?.isKeyWindow == true,
            canvasFocused: window?.firstResponder === self)
    }

    private func reconcileSystemShortcutCapture(retry: Bool = false) {
        guard shortcutScope.isActive else {
            let wasCapturing = systemShortcutMonitor.isRunning || (shortcutStatus?.1 == true)
            systemShortcutMonitor.stop()
            shortcutStartAttempted = false
            if wasCapturing { activeScroll = nil; onRelease?() }
            if retry || shortcutStatus?.1 != false {
                publishShortcutStatus("全屏控制画面获得焦点后自动转发系统快捷键", running: false)
            }
            return
        }
        guard shortcutAccessibility, shortcutInputMonitoring else {
            if systemShortcutMonitor.isRunning { releaseControl() }
            else { systemShortcutMonitor.stop() }
            shortcutStartAttempted = false
            publishShortcutStatus("系统快捷键转发等待本机辅助功能和输入监控生效，请重新检测", running: false)
            return
        }
        guard !SystemShortcutMonitor.secureInputActive else {
            if systemShortcutMonitor.isRunning { releaseControl() }
            else { systemShortcutMonitor.stop() }
            shortcutStartAttempted = false
            publishShortcutStatus("本机安全输入已开启，系统快捷键转发暂不可用", running: false)
            return
        }
        if systemShortcutMonitor.isRunning { publishShortcutStatus("全屏系统快捷键正在转发；⌃⌥Esc 释放，⌃⌘F 退出全屏", running: true); return }
        guard retry || !shortcutStartAttempted else {
            if shortcutStatus?.1 == true { publishShortcutStatus("系统快捷键转发已暂停，请重新检测", running: false) }
            return
        }
        if shortcutStartAttempted { activeScroll = nil; onRelease?() }
        shortcutStartAttempted = true
        do {
            try systemShortcutMonitor.start()
            publishShortcutStatus("全屏系统快捷键正在转发；⌃⌥Esc 释放，⌃⌘F 退出全屏", running: true)
        } catch {
            systemShortcutMonitor.stop()
            publishShortcutStatus(error.localizedDescription, running: false)
        }
    }

    private func publishShortcutStatus(_ message: String, running: Bool) {
        guard shortcutStatus?.0 != message || shortcutStatus?.1 != running else { return }
        shortcutStatus = (message, running)
        onSystemShortcutStatus?(message, running)
    }

    func pictureRect(for bounds: CGRect) -> CGRect {
        let fitScale = min(bounds.width / max(1, remoteSize.width), bounds.height / max(1, remoteSize.height))
        let scale = scalingMode == .original1To1 ? min(1, fitScale) : fitScale
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private var pictureRect: CGRect { pictureRect(for: bounds) }

    private func pointer(_ event: NSEvent, _ kind: RemoteInput.Kind) {
        guard canControl, !pointerInputSuspended else { return }
        if kind == .move {
            flushDragPacerOnly()
        } else if kind == .drag {
            flushMovePacerOnly()
        } else {
            flushPointerMoves()
        }
        let point = convert(event.locationInWindow, from: nil)
        let rect = pictureRect
        localPointerInside = rect.contains(point)
        updateCursorPresentation()
        if !localPointerInside { cancelScrollGesture(flags: UInt64(event.modifierFlags.rawValue)) }
        guard rect.width > 0, rect.height > 0 else { return }
        if kind != .up && kind != .drag && !rect.contains(point) { return }
        onUserActivity?()
        if kind == .down || kind == .scroll { interactionRevision &+= 1 }
        var input = RemoteInput(kind: kind)
        input.x = min(1, max(0, (point.x - rect.minX) / rect.width))
        input.y = min(1, max(0, (point.y - rect.minY) / rect.height))
        input.flags = UInt64(event.modifierFlags.rawValue)
        if localPointerInside, activeScroll != nil {
            activeScroll?.x = input.x; activeScroll?.y = input.y; activeScroll?.flags = input.flags
        }
        if kind == .down || kind == .up || kind == .drag {
            input.button = min(RemoteInput.maximumButtonNumber, max(0, event.buttonNumber))
            input.clicks = min(3, max(1, event.clickCount))
        }
        if kind == .move || kind == .drag {
            let rawDX = Double(event.deltaX)
            let rawDY = Double(event.deltaY)
            if rawDX.isFinite, rawDY.isFinite, rawDX != 0 || rawDY != 0 {
                let scaleX = Double(max(1, remoteSize.width) / rect.width)
                let scaleY = Double(max(1, remoteSize.height) / rect.height)
                let limit = RemoteInput.maximumPointerDelta
                input.pointerDeltaX = min(limit, max(-limit, rawDX * scaleX))
                input.pointerDeltaY = min(limit, max(-limit, rawDY * scaleY))
            }
        }
        if kind == .scroll {
            let multiplier: Double = event.hasPreciseScrollingDeltas ? 1 : 12
            input.deltaX = min(3000, max(-3000, event.scrollingDeltaX * multiplier))
            input.deltaY = min(3000, max(-3000, event.scrollingDeltaY * multiplier))
            // Newer hosts replay a wheel as lines and a trackpad gesture with its phases; older ones use the pixels.
            if event.hasPreciseScrollingDeltas {
                input.scrollPhase = RemoteInput.ScrollPhase(event.phase)
                input.momentumPhase = RemoteInput.MomentumPhase(event.momentumPhase)
            } else {
                let limit = RemoteInput.maximumLineDelta
                input.lineDeltaX = min(limit, max(-limit, event.scrollingDeltaX))
                input.lineDeltaY = min(limit, max(-limit, event.scrollingDeltaY))
            }
            if let phase = input.scrollPhase {
                activeScroll = phase == .ended || phase == .cancelled ? nil : input
            } else if let momentum = input.momentumPhase {
                activeScroll = momentum == .ended ? nil : input
            } else { activeScroll = nil }
        }
        if kind == .move {
            if let ready = movePacer.offer(input, now: SessionClock.now) { onInput?(ready) }
            schedulePointerMove()
        } else if kind == .drag {
            if let pendingButton = dragPacer.pendingButton, pendingButton != input.button {
                flushDragPacerOnly()
            }
            if let ready = dragPacer.offer(input, now: SessionClock.now) { onInput?(ready) }
            schedulePointerDrag()
        } else { onInput?(input) }
    }

    override func mouseDown(with event: NSEvent) {
        guard canControl, pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        pointer(event, .down)
    }
    override func mouseUp(with event: NSEvent) { pointer(event, .up) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, .down) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, .up) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, .down) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, .up) }
    override func mouseDragged(with event: NSEvent) { pointer(event, .drag) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, .drag) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, .drag) }
    override func scrollWheel(with event: NSEvent) { pointer(event, .scroll) }
    override func mouseMoved(with event: NSEvent) {
        pointer(event, .move)
    }
    override func mouseEntered(with event: NSEvent) {
        localPointerInside = pictureRect.contains(convert(event.locationInWindow, from: nil)); updateCursorPresentation()
    }
    override func mouseExited(with event: NSEvent) {
        localPointerInside = false; flushPointerMoves(); updateCursorPresentation()
        cancelScrollGesture(flags: UInt64(event.modifierFlags.rawValue))
    }

    // A quiet trackpad can still be touched. End its remote gesture only when its input target is lost;
    // zero deltas leave older hosts unchanged, while newer hosts receive an explicit phase ending.
    private func cancelScrollGesture(flags: UInt64? = nil) {
        guard var input = activeScroll else { return }
        activeScroll = nil
        flushPointerMoves()
        input.deltaX = 0; input.deltaY = 0
        if input.scrollPhase != nil { input.scrollPhase = .cancelled }
        else { input.momentumPhase = .ended }
        if let flags { input.flags = flags }
        onInput?(input)
    }

    private func keyboard(_ event: NSEvent, _ kind: RemoteInput.Kind) {
        guard canControl, window?.firstResponder === self, event.keyCode <= 127 else { return }
        flushPointerMoves()
        var input = RemoteInput(kind: kind)
        input.keyCode = event.keyCode
        input.flags = UInt64(event.modifierFlags.rawValue)
        if kind == .keyDown { input.isRepeat = event.isARepeat }
        onInput?(input)
    }

    override func keyDown(with event: NSEvent) {
        onUserActivity?()
        if !event.isARepeat { interactionRevision &+= 1 }
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        if SystemShortcutRouting.localAction(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) == .toggleFullScreen {
            localShortcutKeys.insert(event.keyCode)
            if !event.isARepeat { onToggleFullScreen?() }
            return
        }
        if SystemShortcutRouting.localAction(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) == .releaseControl {
            releaseControl()
            return
        }
        if SystemShortcutRouting.localAction(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) == .captureRemoteFrame {
            localShortcutKeys.insert(event.keyCode)
            if !event.isARepeat { onCaptureFrame?() }
            return
        }
        if synchronizesClipboard, event.keyCode == 9, modifiers.contains(.command),
           !modifiers.contains(.control), !modifiers.contains(.option), window?.firstResponder === self,
           localShortcutKeys.contains(9) || (!event.isARepeat && holdsPaste?() != false) {
            localShortcutKeys.insert(9)
            if !event.isARepeat {
                var input = RemoteInput(kind: .keyDown)
                input.keyCode = 9
                input.flags = UInt64(event.modifierFlags.rawValue)
                onPaste?(input)
            }
            return
        }
        if usesCapsLockActions && event.keyCode == 57 { return }
        keyboard(event, .keyDown)
    }
    override func keyUp(with event: NSEvent) {
        if localShortcutKeys.remove(event.keyCode) != nil { return }
        if usesCapsLockActions && event.keyCode == 57 { return }
        keyboard(event, .keyUp)
    }
    override func flagsChanged(with event: NSEvent) {
        onUserActivity?()
        if usesCapsLockActions && event.keyCode == 57 { return }
        keyboard(event, .flags)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard canControl, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    deinit {
        displayLink?.invalidate()
        moveTimer?.invalidate()
        dragTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

private extension RemoteInput.ScrollPhase {
    init?(_ phase: NSEvent.Phase) {
        if phase.contains(.mayBegin) { self = .mayBegin }
        else if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.ended) { self = .ended }
        else if phase.contains(.cancelled) { self = .cancelled }
        else { return nil }
    }
}

private extension RemoteInput.MomentumPhase {
    init?(_ phase: NSEvent.Phase) {
        if phase.contains(.began) { self = .began }
        else if phase.contains(.changed) { self = .changed }
        else if phase.contains(.ended) || phase.contains(.cancelled) { self = .ended }
        else { return nil }
    }
}

struct CanvasView: NSViewRepresentable {
    let canvas: RemoteCanvas
    func makeNSView(context: Context) -> RemoteCanvas { canvas }
    func updateNSView(_ nsView: RemoteCanvas, context: Context) {}
}
