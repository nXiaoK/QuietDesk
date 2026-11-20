import AppKit
import SwiftUI

enum DeskWorkspaceGroup: String, CaseIterable {
    case workspace = "工作台"
    case network = "网络与诊断"
    case system = "系统与安全"
}

enum DeskWorkspaceSection: String, CaseIterable, Identifiable {
    case connect
    case sharing
    case network
    case benchmark
    case preferences

    var id: String { rawValue }

    var group: DeskWorkspaceGroup {
        switch self {
        case .connect, .sharing: return .workspace
        case .network, .benchmark: return .network
        case .preferences: return .system
        }
    }

    var title: String {
        switch self {
        case .connect: return "远程桌面"
        case .sharing: return "本机共享"
        case .network: return "端口映射与中继"
        case .benchmark: return "线路实测与流量"
        case .preferences: return "键盘、防窥与偏好"
        }
    }

    var pageTitle: String {
        switch self {
        case .connect: return "远程桌面"
        case .sharing: return "本机共享控制台"
        case .network: return "端口映射与自托管中继"
        case .benchmark: return "线路实测与历史流量"
        case .preferences: return "键盘、防窥与连接偏好"
        }
    }

    var subtitle: String {
        switch self {
        case .connect: return "从已保存的书桌一键继续工作，或发起新的加密连接"
        case .sharing: return "管理被控状态、配对凭据、macOS 实际生效权限与默认编码档位"
        case .network: return "统一管理 TCP 端口映射隧道、自托管中继节点与本机被控映射授权"
        case .benchmark: return "执行实际视频流质量对比，查看历史总评估与按地址累计收发流量"
        case .preferences: return "Caps Lock 远端输入法切换、系统快捷键实效权限、被控端防窥记忆、连接默认项与自动更新"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "desktopcomputer"
        case .sharing: return "dot.radiowaves.left.and.right"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .benchmark: return "speedometer"
        case .preferences: return "keyboard.badge.eye"
        }
    }
}

enum DeskPalette {
    static let emerald = Color(red: 0.07, green: 0.64, blue: 0.44)
    static let amber = Color(red: 0.88, green: 0.52, blue: 0.08)
    static let coral = Color(red: 0.86, green: 0.22, blue: 0.24)

    static var canvasBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var subtleFill: Color {
        Color.primary.opacity(0.045)
    }

    static var hairline: Color {
        Color(nsColor: .separatorColor).opacity(0.65)
    }
}

struct DeskSurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 13
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
                        lineWidth: highlightColor == nil ? 0.8 : 1.3
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
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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
                .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
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
            }
        }
        .padding(3)
        .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct DeskPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
