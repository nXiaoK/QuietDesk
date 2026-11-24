import AppKit
import SwiftUI
import QuietDeskCore

@MainActor
final class PortMappingApprovalPanel {
    private let panel: NSPanel

    init(manager: PortMappingManager) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 245),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "QuietDesk · 端口映射请求"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: MappingApprovalRequest(manager: manager))
        panel.center()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel.close() }
}

private struct MappingApprovalRequest: View {
    @ObservedObject var manager: PortMappingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let target = manager.pendingTargets.first {
                Text("允许访问这个 TCP 服务？")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DeskPalette.ink)
                    .accessibilityAddTraits(.isHeader)

                Text("目标 \(target.mappingAddress)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(DeskPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("允许后，持有当前配对码的设备都可通过这台 Mac 访问此地址和端口。可在「本机映射授权」撤回。")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("共 \(manager.pendingTargets.count) 个待确认目标")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.muted)
                    .padding(.top, 2)

                HStack(spacing: 10) {
                    Spacer()
                    Button("拒绝") { manager.decide(target, allow: false) }
                        .buttonStyle(DeskButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("允许此目标") { manager.decide(target, allow: true) }
                        .buttonStyle(DeskButtonStyle(.primary))
                }
                .padding(.top, 8)
            }
        }
        .padding(26)
        .frame(width: 500, alignment: .leading)
        .frame(minHeight: 245, alignment: .topLeading)
        .deskSurface()
    }
}
