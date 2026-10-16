import AppKit
import AVFoundation
import QuietDeskCore
import SwiftUI

@MainActor
final class RemoteCanvas: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var decoder = VideoDecoder()
    private var mailbox = LatestFrameMailbox()
    private var awaitingDisplay = false
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var lastMove: TimeInterval = 0
    private var localShortcutKeys = Set<UInt16>()
    let capsLockMonitor = CapsLockMonitor()
    var onInput: ((RemoteInput) -> Void)?
    var onPaste: ((RemoteInput) -> Void)?
    var synchronizesClipboard = false
    private(set) var interactionRevision: UInt64 = 0
    var onRelease: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFullScreen: ((Bool) -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var remoteSize = CGSize(width: 16, height: 10)
    var canControl = false
    var usesCapsLockActions = false

    override var acceptsFirstResponder: Bool { canControl }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        capsLockMonitor.isActive = { [weak self] in
            guard let self else { return false }
            return self.usesCapsLockActions && self.canControl && self.window?.isKeyWindow == true
                && self.window?.firstResponder === self
        }
        capsLockMonitor.onAction = { [weak self] kind in self?.onInput?(RemoteInput(kind: kind)) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        showLatestFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseControl() }
            })
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onFullScreen?(self.window?.styleMask.contains(.fullScreen) == true)
                }
            })
        }
        onFullScreen?(window.styleMask.contains(.fullScreen))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    func present(_ packet: VideoPacket, acknowledged: @escaping () -> Void) throws {
        let inbox = mailbox
        decoder.decode(packet) { [weak self] result in
            switch result {
            case .success(let image):
                if inbox.offer(image) {
                    DispatchQueue.main.async {
                        guard let self, self.mailbox === inbox else { return }
                        self.showLatestFrame()
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

    private func showLatestFrame() {
        if videoLayer.status == .failed { videoLayer.flush() }
        guard videoLayer.isReadyForMoreMediaData else {
            if !awaitingDisplay {
                awaitingDisplay = true
                videoLayer.requestMediaDataWhenReady(on: .main) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.videoLayer.stopRequestingMediaData()
                        self.awaitingDisplay = false
                        self.showLatestFrame()
                    }
                }
            }
            return
        }
        guard let image = mailbox.take() else { return }
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &format) == noErr, let format,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        videoLayer.enqueue(sample)
    }

    func reset() {
        releaseControl()
        canControl = false
        decoder.stop()
        decoder = VideoDecoder()
        mailbox = LatestFrameMailbox()
        videoLayer.stopRequestingMediaData()
        videoLayer.flushAndRemoveImage()
        awaitingDisplay = false
    }

    func releaseControl() {
        interactionRevision &+= 1
        capsLockMonitor.reset()
        localShortcutKeys.removeAll()
        onRelease?()
        onFocus?(false)
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func becomeFirstResponder() -> Bool { capsLockMonitor.reset(); localShortcutKeys.removeAll(); onFocus?(true); return true }
    override func resignFirstResponder() -> Bool { capsLockMonitor.reset(); localShortcutKeys.removeAll(); onRelease?(); onFocus?(false); return true }

    private var pictureRect: CGRect {
        let scale = min(bounds.width / max(1, remoteSize.width), bounds.height / max(1, remoteSize.height))
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func pointer(_ event: NSEvent, _ kind: RemoteInput.Kind) {
        guard canControl else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = pictureRect
        guard rect.width > 0, rect.height > 0 else { return }
        if kind != .up && kind != .drag && !rect.contains(point) { return }
        if kind == .down || kind == .scroll { interactionRevision &+= 1 }
        var input = RemoteInput(kind: kind)
        input.x = min(1, max(0, (point.x - rect.minX) / rect.width))
        input.y = min(1, max(0, (point.y - rect.minY) / rect.height))
        input.button = min(2, max(0, event.buttonNumber))
        input.flags = UInt64(event.modifierFlags.rawValue)
        input.clicks = min(3, max(1, event.clickCount))
        if kind == .scroll {
            let multiplier: Double = event.hasPreciseScrollingDeltas ? 1 : 12
            input.deltaX = min(3000, max(-3000, event.scrollingDeltaX * multiplier))
            input.deltaY = min(3000, max(-3000, event.scrollingDeltaY * multiplier))
        }
        onInput?(input)
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
        guard event.timestamp - lastMove >= 1.0 / 60 else { return }
        lastMove = event.timestamp
        pointer(event, .move)
    }

    private func keyboard(_ event: NSEvent, _ kind: RemoteInput.Kind) {
        guard canControl, window?.firstResponder === self, event.keyCode <= 127 else { return }
        var input = RemoteInput(kind: kind)
        input.keyCode = event.keyCode
        input.flags = UInt64(event.modifierFlags.rawValue)
        if kind == .keyDown { input.isRepeat = event.isARepeat }
        onInput?(input)
    }

    override func keyDown(with event: NSEvent) {
        if !event.isARepeat { interactionRevision &+= 1 }
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        if event.keyCode == 3, modifiers == [.control, .command] {
            localShortcutKeys.insert(event.keyCode)
            if !event.isARepeat { onToggleFullScreen?() }
            return
        }
        if event.keyCode == 53, event.modifierFlags.contains([.control, .option]) {
            localShortcutKeys.insert(event.keyCode)
            releaseControl()
            return
        }
        if synchronizesClipboard, event.keyCode == 9, modifiers.contains(.command),
           !modifiers.contains(.control), !modifiers.contains(.option), window?.firstResponder === self {
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

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

struct CanvasView: NSViewRepresentable {
    let canvas: RemoteCanvas
    func makeNSView(context: Context) -> RemoteCanvas { canvas }
    func updateNSView(_ nsView: RemoteCanvas, context: Context) {}
}
