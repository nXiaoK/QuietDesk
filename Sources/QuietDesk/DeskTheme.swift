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
        case .benchmark: return "网络与线路"
        case .preferences: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "square.grid.2x2"
        case .sharing: return "square.and.arrow.up"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .benchmark: return "speedometer"
        case .preferences: return "gearshape"
        }
    }
}

enum DeskPalette {
    static let accent = adaptive(0x0A74E6, 0x68B3FF, contrast: 0x0058B8)
    static let actionFill = adaptive(0x0A74E6, 0x0A68D0, contrast: 0x0056B3)
    static let ink = adaptive(0x1D232A, 0xEEF1F6, contrast: 0x0E1318)
    static let secondary = adaptive(0x525E6B, 0xAEB9C6, contrast: 0x333D47)
    static let muted = adaptive(0x6D7A87, 0x8F9CAB, contrast: 0x46505B)
    static let canvasBackground = adaptive(0xF5F6F8, 0x1E2228, contrast: 0xF0F2F5, darkContrast: 0x171A1F)
    static let cardBackground = adaptive(0xFFFFFF, 0x272C34, contrast: 0xFFFFFF, darkContrast: 0x22272F)
    static let sidebarBackground = adaptive(0xECEEF1, 0x232830, contrast: 0xE4E7EC, darkContrast: 0x1D2128)
    static let insetBackground = adaptive(0xF6F7F9, 0x22272F, contrast: 0xEDEFF3, darkContrast: 0x1B1F26)
    static let subtleFill = adaptive(0xE9EDF2, 0x313843, contrast: 0xDDE3EA, darkContrast: 0x363E4A)
    static let selection = adaptive(0xDFE5EC, 0x384250, contrast: 0xC8D6E6, darkContrast: 0x425063)
    static let hairline = adaptive(0xDFE3E8, 0x3D444F, contrast: 0x98A5B3, darkContrast: 0x768393)
    static let emerald = adaptive(0x127A50, 0x5CD6A5, contrast: 0x0B5E3C)
    static let amber = adaptive(0x94540F, 0xF3BC6E, contrast: 0x753F05)
    static let coral = adaptive(0xB82E39, 0xFF8F96, contrast: 0x941E28)

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

    func deskInputBox(focused: Bool = false, cornerRadius: CGFloat = 8, minHeight: CGFloat = 35) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(focused ? DeskPalette.accent : DeskPalette.hairline, lineWidth: focused ? 1.8 : 1)
            }
    }
}

struct DeskSearchField: View {
    let placeholder: String
    @Binding var text: String
    var accessibilityTitle: String = "搜索"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DeskPalette.muted)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .accessibilityLabel(accessibilityTitle)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.muted)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 35)
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? DeskPalette.accent : DeskPalette.hairline, lineWidth: isFocused ? 1.8 : 1)
        }
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
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 9 : 13)
                .frame(minHeight: kind == .quiet ? 28 : 31)
                .background(background, in: shape)
                .overlay {
                    shape.strokeBorder(isFocused ? DeskPalette.accent : border, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.46)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .secondary: return DeskPalette.ink
            case .danger: return DeskPalette.coral
            case .quiet: return hovering && isEnabled ? DeskPalette.ink : DeskPalette.secondary
            }
        }

        private var background: Color {
            switch kind {
            case .primary:
                if configuration.isPressed { return DeskPalette.actionFill.opacity(0.84) }
                if hovering && isEnabled { return DeskPalette.actionFill.opacity(0.93) }
                return DeskPalette.actionFill
            case .danger:
                if isEnabled && (configuration.isPressed || hovering) { return DeskPalette.coral.opacity(0.09) }
                return DeskPalette.cardBackground
            case .secondary:
                if isEnabled && (configuration.isPressed || hovering) { return DeskPalette.subtleFill }
                return DeskPalette.cardBackground
            case .quiet:
                if isEnabled && (configuration.isPressed || hovering) { return DeskPalette.subtleFill }
                return .clear
            }
        }

        private var border: Color {
            switch kind {
            case .primary, .quiet: return .clear
            case .danger: return DeskPalette.coral.opacity(0.36)
            case .secondary: return DeskPalette.hairline
            }
        }
    }
}

struct DeskSectionHeading: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DeskPalette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeskPalette.cardBackground, in: shape)
            .overlay {
                shape.strokeBorder(
                    highlightColor.map { $0.opacity(0.42) } ?? DeskPalette.hairline,
                    lineWidth: 1
                )
            }
            .shadow(
                color: reduceTransparency ? .clear : .black.opacity(0.025),
                radius: 3,
                y: 1
            )
    }
}

struct DeskCalloutBox<Actions: View>: View {
    enum Tone { case info, warning, danger, success }

    let title: String?
    let message: String
    var symbol: String? = "info.circle"
    var tone: Tone = .info
    @ViewBuilder var actions: () -> Actions

    init(
        title: String? = nil,
        message: String,
        symbol: String? = "info.circle",
        tone: Tone = .info,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tone = tone
        self.actions = actions
    }

    init(
        title: String? = nil,
        message: String,
        symbol: String? = "info.circle",
        tone: Tone = .info
    ) where Actions == EmptyView {
        self.init(title: title, message: message, symbol: symbol, tone: tone) {
            EmptyView()
        }
    }

    private var tint: Color {
        switch tone {
        case .info: return DeskPalette.secondary
        case .warning: return DeskPalette.amber
        case .danger: return DeskPalette.coral
        case .success: return DeskPalette.emerald
        }
    }

    private var backgroundFill: Color {
        switch tone {
        case .info: return DeskPalette.subtleFill.opacity(0.72)
        case .warning: return DeskPalette.amber.opacity(0.09)
        case .danger: return DeskPalette.coral.opacity(0.09)
        case .success: return DeskPalette.emerald.opacity(0.09)
        }
    }

    private var borderFill: Color {
        switch tone {
        case .info: return DeskPalette.hairline
        case .warning: return DeskPalette.amber.opacity(0.26)
        case .danger: return DeskPalette.coral.opacity(0.28)
        case .success: return DeskPalette.emerald.opacity(0.26)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(alignment: title == nil ? .center : .top, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.top, title == nil ? 0 : 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tone == .info ? DeskPalette.ink : tint)
                }
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(tone == .danger ? tint : DeskPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(backgroundFill, in: shape)
        .overlay { shape.strokeBorder(borderFill, lineWidth: 1) }
    }
}

struct DeskPillBadge: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                if symbol == "circle.fill" {
                    Circle()
                        .fill(tint)
                        .frame(width: 6.5, height: 6.5)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: monospaced ? .monospaced : .default))
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
                .padding(.horizontal, 5)
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
                    .foregroundStyle(DeskPalette.ink)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(15)
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
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DeskPalette.ink : DeskPalette.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? DeskPalette.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
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
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .foregroundStyle(DeskPalette.muted)
                    }
                }
            }
            DeskSurfaceCard(padding: 0, cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .padding(.horizontal, 16)
            }
        }
    }
}

struct DeskSettingsRow<Value: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DeskPalette.ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            value()
        }
        .padding(.vertical, 9)
        .frame(minHeight: 46)
    }
}
