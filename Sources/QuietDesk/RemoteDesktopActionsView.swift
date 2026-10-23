import SwiftUI
import QuietDeskCore

extension RemoteDesktopAction {
    var title: String {
        switch self {
        case .previousSpace: return "上一空间"
        case .nextSpace: return "下一空间"
        case .missionControl: return "调度中心，选择桌面…"
        }
    }
}

struct RemoteDesktopActionsView: View {
    let unavailableReason: String?
    let status: String
    let privacyEnabled: Bool
    let perform: (RemoteDesktopAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("远端桌面", systemImage: "rectangle.3.group").font(.headline)
            HStack(spacing: 8) {
                Button { perform(.previousSpace) } label: {
                    Label("上一空间", systemImage: "chevron.left").frame(maxWidth: .infinity)
                }
                Button { perform(.nextSpace) } label: {
                    Label("下一空间", systemImage: "chevron.right").frame(maxWidth: .infinity)
                }
            }
            .disabled(unavailableReason != nil)
            Button { perform(.missionControl) } label: {
                Label("调度中心，选择桌面…", systemImage: "rectangle.3.group").frame(maxWidth: .infinity)
            }
            .disabled(unavailableReason != nil)
            Text(unavailableReason ?? (status.isEmpty ? "在远端调度中心点击要使用的桌面；上一／下一空间也会经过全屏应用。" : status))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("使用远端默认快捷键 ⌃←、⌃→、⌃↑；若被修改或关闭，请在被控 Mac 的系统设置中核对。多屏时作用于远端当前活动屏幕。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if privacyEnabled {
                Text("黑屏遮罩不保证覆盖调度中心和空间切换动画。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
}
