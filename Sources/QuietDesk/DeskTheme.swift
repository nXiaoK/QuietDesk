import AppKit
import SwiftUI

enum DeskWorkspaceSection: String, CaseIterable, Identifiable {
    case connect
    case sharing
    case network
    case benchmark
    case preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "全部设备"
        case .sharing: return "本机共享"
        case .network: return "网络与线路"
        case .benchmark: return "线路实测与流量"
        case .preferences: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "square.grid.2x2"
        case .sharing: return "square.and.arrow.up"
        case .network: return "point.3.filled.connected.trianglepath.dotted"
        case .benchmark: return "speedometer"
        case .preferences: return "gearshape"
        }
    }
}

enum DeskPalette {
    static let accent = adaptive(0x0875E1, 0x72B6FF, contrast: 0x005DBB)
    static let actionFill = adaptive(0x0875E1, 0x0865CC, contrast: 0x005AB6)
    static let ink = adaptive(0x222830, 0xEBEEF3, contrast: 0x11161B)
    static let secondary = adaptive(0x515E6A, 0xB2BEC9, contrast: 0x36404A)
    static let muted = adaptive(0x65717D, 0x9DAABA, contrast: 0x48525D)
    static let canvasBackground = adaptive(0xF4F5F7, 0x21252B)
    static let cardBackground = adaptive(0xFFFFFF, 0x2B3038)
    static let sidebarBackground = adaptive(0xEFF0F2, 0x262B32)
    static let insetBackground = adaptive(0xF6F7F9, 0x242932)
    static let subtleFill = adaptive(0xECEFF3, 0x363D47)
    static let selection = adaptive(0xE1E5EA, 0x3C4653, contrast: 0xC9D7E8)
    static let hairline = adaptive(0xDCE1E7, 0x484F59, contrast: 0x9BA8B6, darkContrast: 0x778494)
    static let emerald = adaptive(0x137A51, 0x6DDAB0)
    static let amber = adaptive(0x925511, 0xF3BC70)
    static let coral = adaptive(0xB6303B, 0xFF9298)

    private static func adaptive(
        _ light: UInt32, _ dark: UInt32, contrast: UInt32? = nil, darkContrast: UInt32? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua
            ])
            let hex: UInt32
            switch match {
            case .accessibilityHighContrastDarkAqua: hex = darkContrast ?? dark
            case .accessibilityHighContrastAqua: hex = contrast ?? light
            case .darkAqua: hex = dark
            default: hex = light
            }
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    func deskSurface() -> some View {
        background(DeskPalette.canvasBackground)
            .foregroundStyle(DeskPalette.ink)
            .tint(DeskPalette.accent)
    }
}

struct DeskButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, quiet }

    var kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7)
            configuration.label
                .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 11)
                .frame(minHeight: 29)
                .background(background, in: shape)
                .overlay {
                    shape.strokeBorder(isFocused ? DeskPalette.accent : border, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.48)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .secondary: return DeskPalette.ink
            case .danger: return DeskPalette.coral
            case .quiet: return DeskPalette.secondary
            }
        }

        private var background: Color {
            if kind == .primary { return DeskPalette.actionFill.opacity(configuration.isPressed ? 0.82 : 1) }
            if isEnabled && (configuration.isPressed || hovering) { return DeskPalette.subtleFill }
            return kind == .quiet ? .clear : DeskPalette.cardBackground
        }

        private var border: Color {
            kind == .primary || kind == .quiet ? .clear : DeskPalette.hairline
        }
    }
}

struct DeskSectionHeading: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DeskPalette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DeskSurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 10
    var highlightColor: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlightColor.map { $0.opacity(0.42) } ?? DeskPalette.hairline,
                        lineWidth: 1
                    )
            }
    }
}

struct DeskPillBadge: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: monospaced ? .monospaced : .default))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct DeskInfoPopoverButton: View {
    let title: String
    let lines: [String]
    var label: String? = nil
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if let label {
                HStack(spacing: 4) {
                    Text(label)
                    Image(systemName: "info.circle")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(DeskPalette.accent)
                .padding(.horizontal, 4)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(label ?? title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(DeskPalette.cardBackground)
        }
    }
}

struct DeskSegmentedTabs<Tab: Hashable>: View {
    let tabs: [(id: Tab, title: String)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.id) { item in
                let isSelected = selection == item.id
                Button {
                    selection = item.id
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DeskPalette.ink : DeskPalette.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? DeskPalette.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(DeskPalette.hairline, lineWidth: 0.7)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct DeskSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .accessibilityAddTraits(.isHeader)
            DeskSurfaceCard(padding: 0, cornerRadius: 9) {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .padding(.horizontal, 15)
            }
        }
    }
}

struct DeskSettingsRow<Value: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(DeskPalette.ink)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            value()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 43)
    }
}
