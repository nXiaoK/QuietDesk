import AppKit
import SwiftUI
import QuietDeskCore

/// One value per line in white on a rounded black background; the viewer sets how transparent the background is.
struct FullScreenStatusOverlay<Content: View>: View {
    @Binding var position: CGPoint?
    let backgroundOpacity: Double?
    let beginDrag: () -> Void
    @ViewBuilder let content: Content
    @State private var statusSize: CGSize = .zero
    @State private var dragOrigin: CGPoint?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let automatic = FullScreenStatusPlacement.automaticOrigin(container: geometry.size, status: statusSize)
            let saved = position.map { FullScreenStatusPlacement.origin(for: $0, container: geometry.size, status: statusSize) } ?? automatic
            let proposed = dragOrigin.map { CGPoint(x: $0.x + translation.width, y: $0.y + translation.height) } ?? saved
            let normalized = FullScreenStatusPlacement.position(for: proposed, container: geometry.size, status: statusSize)
            let origin = FullScreenStatusPlacement.origin(for: normalized, container: geometry.size, status: statusSize)
            let background = backgroundOpacity.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                ?? FullScreenStatusPlacement.defaultBackgroundOpacity
            VStack(alignment: .leading, spacing: 1) { content }
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white)
                // Fades in as the background clears, so the text stays readable over a bright picture.
                .shadow(color: .black.opacity(0.6 * (1 - background)), radius: 1)
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(background))
                    if dragOrigin != nil { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.5)) }
                }
                // Measured directly: a size preference would be reset by the drag target, a sibling that reports
                // the key's default, which left every position computed for a zero-sized status.
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { statusSize = $0 }
                .allowsHitTesting(false)
                .overlay {
                    StatusDragTarget(begin: {
                        dragOrigin = origin
                        translation = .zero
                        beginDrag()
                    }, move: { translation = $0 }, cancel: {
                        dragOrigin = nil
                        translation = .zero
                    }, end: { final in
                        if let dragOrigin, abs(final.width) + abs(final.height) >= 3 {
                            position = FullScreenStatusPlacement.position(
                                for: CGPoint(x: dragOrigin.x + final.width, y: dragOrigin.y + final.height),
                                container: geometry.size, status: statusSize)
                        }
                        dragOrigin = nil
                        translation = .zero
                    })
                }
                // The corner position needs the measured size; stay hidden for the first pass instead of flashing off-screen.
                .opacity(statusSize == .zero ? 0 : 1)
                .offset(x: origin.x, y: origin.y)
        }
    }
}

private struct StatusDragTarget: NSViewRepresentable {
    let begin: () -> Void
    let move: (CGSize) -> Void
    let cancel: () -> Void
    let end: (CGSize) -> Void

    func makeNSView(context: Context) -> StatusDragView { StatusDragView() }
    func updateNSView(_ view: StatusDragView, context: Context) {
        view.begin = begin; view.move = move; view.cancel = cancel; view.end = end
    }
}

/// Only the status rectangle consumes pointer events; the rest of the canvas keeps its input routing.
final class StatusDragView: NSView {
    var begin: (() -> Void)?
    var move: ((CGSize) -> Void)?
    var cancel: (() -> Void)?
    var end: ((CGSize) -> Void)?
    private var start: CGPoint?
    private var resignObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func viewDidMoveToWindow() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { start = nil; return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.start != nil else { return }
                    self.start = nil
                    self.cancel?()
                }
            }
    }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        begin?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        move?(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        end?(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y))
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动连接状态可调整位置；在控制与设置中调整背景透明度或恢复自动位置"
        setAccessibilityLabel("连接状态，可拖动调整位置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
}
