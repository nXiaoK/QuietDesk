import AppKit
import SwiftUI
import QuietDeskCore

/// The full-screen controls button on the trailing edge. A click toggles the session panel; a press that
/// moves drags the button along the edge, out of the way of remote content such as a scroll bar.
struct FullScreenControlsButton: View {
    static let height: CGFloat = 66
    let expanded: Bool
    /// The remote picture is being controlled: the button fades until the pointer is over it.
    let dimmed: Bool
    @Binding var position: Double?
    let containerHeight: CGFloat
    let toggle: () -> Void
    @State private var hovering = false
    @State private var dragOffset: CGFloat?

    private var restingOffset: CGFloat {
        FullScreenControlsPlacement.offset(for: position, containerHeight: containerHeight, controlHeight: Self.height)
    }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: expanded ? "chevron.right" : "slider.horizontal.3")
                .font(.system(size: 13.5, weight: .semibold))
                .frame(width: 26, height: Self.height)
                .foregroundStyle(expanded ? Color.white : DeskPalette.ink)
                .background {
                    if expanded {
                        Capsule().fill(DeskPalette.actionFill)
                    } else {
                        Capsule().fill(DeskPalette.cardBackground)
                    }
                }
                .overlay(Capsule().strokeBorder(DeskPalette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(dimmed && !hovering && !expanded ? 0.45 : 1.0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(expanded ? "收起控制与设置" : "展开控制与设置；上下拖动可移开被遮挡的远端内容")
        .accessibilityLabel(expanded ? "收起控制与设置" : "展开控制与设置")
        .offset(y: dragOffset ?? restingOffset)
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let position = FullScreenControlsPlacement.position(
                    forOffset: restingOffset + value.translation.height, containerHeight: containerHeight, controlHeight: Self.height)
                dragOffset = FullScreenControlsPlacement.offset(for: position, containerHeight: containerHeight, controlHeight: Self.height)
            }
            .onEnded { _ in
                if let dragOffset {
                    position = FullScreenControlsPlacement.position(
                        forOffset: dragOffset, containerHeight: containerHeight, controlHeight: Self.height)
                }
                dragOffset = nil
            })
        .contextMenu {
            Button("恢复居中位置") { position = nil }
                .disabled(position == nil)
        }
    }
}

/// The session toolbar full screen shows while the pointer rests at the top edge: a floating bar below the
/// place where macOS shows the menu bar. Its whole shape takes clicks, so a near miss between two items
/// does not land on the remote picture.
struct FullScreenToolbar<Content: View>: View {
    let reduceTransparency: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 6)
            .frame(height: FullScreenToolbarReveal.toolbarHeight)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(DeskPalette.cardBackground)
                    .shadow(color: reduceTransparency ? .clear : .black.opacity(0.28), radius: 14, y: 5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DeskPalette.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onTapGesture {}
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("全屏工具条")
    }
}

/// A button of the full-screen toolbar.
struct FullScreenToolbarButton: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(destructive ? DeskPalette.coral : DeskPalette.ink)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(hovering ? DeskPalette.insetBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FullScreenToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(DeskPalette.hairline)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Styles a `Menu` as an item of the full-screen toolbar.
    func fullScreenToolbarMenu() -> some View {
        menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 28)
    }
}

/// Samples the pointer while a session is in full screen and publishes whether its toolbar shows.
@MainActor
final class FullScreenToolbarController: ObservableObject {
    @Published private(set) var revealed = false
    private var reveal = FullScreenToolbarReveal()
    private var timer: Timer?
    private weak var canvas: RemoteCanvas?

    /// Samples against the picture `canvas` fills. The timer runs in the default run loop mode only, so the
    /// toolbar stays as it is while one of its menus is open.
    func start(canvas: RemoteCanvas) {
        self.canvas = canvas
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self { self.samplePointer() } else { timer.invalidate() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if reveal.hide() { revealed = false }
    }

    private func samplePointer() {
        var zone = FullScreenToolbarReveal.Zone.elsewhere
        // A captured pointer does not move, and an inactive window is not where the pointer is being used.
        if let canvas, let window = canvas.window, NSApp.isActive, window.isKeyWindow, !canvas.isRelativeMouseCaptured {
            // The canvas is flipped: y grows downwards from its top edge.
            let point = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            zone = FullScreenToolbarReveal.zone(x: point.x, fromTop: point.y, containerWidth: canvas.bounds.width)
        }
        sample(zone, buttonPressed: NSEvent.pressedMouseButtons != 0, now: SessionClock.uptime)
    }

    func sample(_ zone: FullScreenToolbarReveal.Zone, buttonPressed: Bool, now: TimeInterval) {
        if reveal.sample(zone, buttonPressed: buttonPressed, now: now) { revealed = reveal.revealed }
    }
}
