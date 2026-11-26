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
