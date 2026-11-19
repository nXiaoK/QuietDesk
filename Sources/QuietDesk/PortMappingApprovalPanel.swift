import AppKit
import SwiftUI
import QuietDeskCore

@MainActor
final class PortMappingApprovalPanel {
    private let panel: NSPanel

    init(manager: PortMappingManager) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 200),
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
                Text("允许访问这个 TCP 服务？").font(.title3.bold())
                Text(target.mappingAddress).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Text("允许后，持有当前配对码的设备都可通过这台 Mac 访问此地址和端口。可在「共享 → TCP 端口映射」中撤回。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if manager.pendingTargets.count > 1 {
                        Text("共 \(manager.pendingTargets.count) 个待确认目标").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("拒绝") { manager.decide(target, allow: false) }.keyboardShortcut(.cancelAction)
                    Button("允许此目标") { manager.decide(target, allow: true) }
                }
            }
        }
        .padding(20).frame(width: 430)
    }
}
