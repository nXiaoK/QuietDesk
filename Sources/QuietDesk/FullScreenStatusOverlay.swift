import AppKit
import SwiftUI
import QuietDeskCore

struct FullScreenStatusOverlay<Content: View>: View {
    let picture: CGSize
    @Binding var position: CGPoint?
    let opacity: Double?
    let beginDrag: () -> Void
    @ViewBuilder let content: Content
    @State private var statusSize: CGSize = .zero
    @State private var dragOrigin: CGPoint?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let placement = FullScreenStatusPlacement.choose(container: geometry.size, picture: picture)
            let automatic: CGPoint = switch placement {
            case .topBand(let height): CGPoint(x: 0, y: max(0, (height - statusSize.height) / 2))
            case .leadingBand: CGPoint(x: 0, y: 16)
            case .overlay: CGPoint(x: 10, y: 10)
            }
            let saved = position.map { FullScreenStatusPlacement.origin(for: $0, container: geometry.size, status: statusSize) } ?? automatic
            let proposed = dragOrigin.map { CGPoint(x: $0.x + translation.width, y: $0.y + translation.height) } ?? saved
            let normalized = FullScreenStatusPlacement.position(for: proposed, container: geometry.size, status: statusSize)
            let origin = FullScreenStatusPlacement.origin(for: normalized, container: geometry.size, status: statusSize)
            status(placement)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    if placement == .overlay || position != nil || dragOrigin != nil {
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
                    }
                }
                .background(GeometryReader { status in Color.clear.preference(key: StatusSizeKey.self, value: status.size) })
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
                .opacity(opacity.flatMap { $0.isFinite ? min(1, max(0.1, $0)) : nil } ?? placement.defaultOpacity)
                .offset(x: origin.x, y: origin.y)
        }
        .onPreferenceChange(StatusSizeKey.self) { statusSize = $0 }
    }

    @ViewBuilder private func status(_ placement: FullScreenStatusPlacement) -> some View {
        switch placement {
        case .topBand:
            HStack(spacing: 10) { content }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                .padding(.horizontal, 16).padding(.vertical, 4)
        case .leadingBand(let width):
            VStack(alignment: .leading, spacing: 6) { content }
                .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).minimumScaleFactor(0.85)
                .padding(.horizontal, 12).padding(.vertical, 4).frame(width: min(width, 220), alignment: .leading)
        case .overlay:
            HStack(spacing: 8) { content }
                .font(.caption2).monospacedDigit().foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
        }
    }
}

private struct StatusSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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
        toolTip = "拖动连接状态可调整位置；在控制与设置中调整透明度或恢复自动位置"
        setAccessibilityLabel("连接状态，可拖动调整位置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
}
