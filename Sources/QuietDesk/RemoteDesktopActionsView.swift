import SwiftUI
import QuietDeskCore

extension RemoteDesktopAction {
    static let inlineOrder: [RemoteDesktopAction] = [.previousSpace, .missionControl, .nextSpace]

    var title: String {
        switch self {
        case .previousSpace: return "上一空间"
        case .nextSpace: return "下一空间"
        case .missionControl: return "调度中心，选择桌面…"
        }
    }

    var compactTitle: String {
        switch self {
        case .previousSpace: return "上一空间"
        case .missionControl: return "调度中心"
        case .nextSpace: return "下一空间"
        }
    }

    /// Shown in the window toolbar and the inline session tools row.
    var toolbarSymbol: String {
        switch self {
        case .previousSpace: return "arrow.left.square"
        case .nextSpace: return "arrow.right.square"
        case .missionControl: return "rectangle.3.group"
        }
    }

    var toolbarHelp: String {
        switch self {
        case .previousSpace: return "切换到远端上一空间，也会经过全屏应用（远端默认 ⌃←）"
        case .nextSpace: return "切换到远端下一空间，也会经过全屏应用（远端默认 ⌃→）"
        case .missionControl: return "在远端打开调度中心，再点按画面选择桌面（远端默认 ⌃↑）"
        }
    }

    func helpText(unavailableReason: String?, privacyEnabled: Bool) -> String {
        if let unavailableReason { return unavailableReason }
        return privacyEnabled ? toolbarHelp + "\n黑屏遮罩不保证覆盖调度中心和空间切换动画。" : toolbarHelp
    }
}

struct RemoteDesktopActionsView: View {
    let unavailableReason: String?
    let status: String
    let privacyEnabled: Bool
    let perform: (RemoteDesktopAction) -> Void

    static func detailText(unavailableReason: String?, status: String, privacyEnabled: Bool) -> String? {
        var lines: [String] = []
        if let unavailableReason {
            lines.append(unavailableReason)
        } else if !status.isEmpty {
            lines.append(status)
        }
        if privacyEnabled {
            lines.append("黑屏遮罩不保证覆盖调度中心和空间切换动画。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(RemoteDesktopAction.inlineOrder, id: \.self) { action in
                    Button { perform(action) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.toolbarSymbol)
                            Text(action.compactTitle).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .help(action.helpText(unavailableReason: unavailableReason, privacyEnabled: privacyEnabled))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(unavailableReason != nil)
            if let detail = Self.detailText(unavailableReason: unavailableReason, status: status, privacyEnabled: privacyEnabled) {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
