import AppKit
import QuietDeskCore

/// Keeps a session window in the shape of the remote picture, so that the picture fills it without bars:
/// when the shape becomes known or changes, the width stays and the height follows; after the viewer has
/// dragged an edge, the other edge follows the drag. Full screen, a zoomed window and 1:1 scaling are left
/// alone, and a window sized by anything but a drag (tiling, zooming) keeps the size it was given.
@MainActor
final class SessionWindowFit {
    private weak var window: NSWindow?
    private weak var canvas: RemoteCanvas?
    private var observers: [NSObjectProtocol] = []
    private var dragStart: (frame: CGRect, area: CGSize)?
    private var pending = false
    private var retryScheduled = false
    /// Whether the viewer wants this at all, and the session shows a picture in a window.
    var enabled: () -> Bool = { true }
    /// The screen area the window may use; injected by checks.
    var visibleFrame: (NSWindow) -> CGRect = { window in
        (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
    }

    func attach(window: NSWindow, canvas: RemoteCanvas) {
        guard self.window !== window || self.canvas !== canvas else { return }
        detach()
        self.window = window
        self.canvas = canvas
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeStarted() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeEnded() }
            }
        ]
        if pending { fitIfReady() }
    }

    func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        dragStart = nil
        window = nil
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// The picture's shape may have changed, or fitting was just switched on: fit once the window can be.
    func pictureChanged() {
        pending = true
        fitIfReady()
    }

    /// The canvas was laid out: a fit that waited for the window, a size or the first picture is tried again,
    /// after the layout pass, so that the window is not resized while its views are being laid out.
    func canvasLaidOut() {
        guard pending, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if self.pending { self.fitIfReady() }
        }
    }

    private func fitIfReady() {
        guard let window, let canvas, canvas.window === window, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        // A drag in progress decides when it ends. Full screen, a zoomed window and a session that shows no
        // picture yet wait: the layout pass that follows their end tries again.
        guard !window.inLiveResize, dragStart == nil, enabled(),
              !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        pending = false
        apply(.keepingWidth, before: nil)
    }

    private func liveResizeStarted() {
        guard let window, let canvas, canvas.window === window else { return }
        dragStart = (window.frame, canvas.bounds.size)
    }

    private func liveResizeEnded() {
        guard let start = dragStart else { return }
        dragStart = nil
        pending = false
        // The canvas takes its new size with the next layout pass.
        window?.layoutIfNeeded()
        apply(.dragged(from: start.area), before: start.frame)
    }

    private func apply(_ change: WindowAspectFit.Change, before: CGRect?) {
        guard let window, let canvas, canvas.window === window, enabled(),
              !window.styleMask.contains(.fullScreen), !window.isZoomed, canvas.scalingMode == .fitWindow,
              canvas.remoteSize.width > 0, canvas.remoteSize.height > 0 else { return }
        let area = canvas.bounds.size, aspect = canvas.remoteSize.width / canvas.remoteSize.height
        guard area.width > 0, area.height > 0, !WindowAspectFit.fills(area, aspect: aspect) else { return }
        // Everything around the picture (title bar, toolbar, status bar) keeps its size when the window changes.
        let frame = window.frame, chrome = CGSize(width: frame.width - area.width, height: frame.height - area.height)
        guard chrome.width >= 0, chrome.height >= 0 else { return }
        let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let smallest = CGSize(width: max(window.minSize.width, contentMinimum.width), height: max(window.minSize.height, contentMinimum.height))
        let screen = visibleFrame(window)
        let target = WindowAspectFit.area(
            area, aspect: aspect, change: change,
            minimum: CGSize(width: smallest.width - chrome.width, height: smallest.height - chrome.height),
            maximum: CGSize(width: screen.width - chrome.width, height: screen.height - chrome.height))
        guard target != area else { return }
        window.setFrame(WindowAspectFit.frame(frame, before: before, area: area, target: target, screen: screen), display: true)
    }
}
