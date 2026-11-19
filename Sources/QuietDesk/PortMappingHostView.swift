import SwiftUI
import QuietDeskCore

struct PortMappingHostView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var manager: PortMappingManager
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本机 TCP 端口映射").font(.title2.bold())
                Spacer()
                Button("完成", action: done).keyboardShortcut(.cancelAction)
            }
            Toggle("关闭桌面共享时也接受映射", isOn: Binding(get: { model.mappingHosting }, set: { model.setMappingHosting($0) }))
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.mappingHostingStatus).textSelection(.enabled)
                Text("桌面共享开启时可直接接受映射。独立映射使用相同的配对码和监听端口，无需开启远程桌面。")
            }
            .font(.callout).foregroundStyle(.secondary)
            if manager.hostApprovalPending {
                Button("查看待确认请求（\(manager.pendingTargets.count)）") { manager.presentPendingRequest() }
            }
            Divider()
            Text("已允许的目标").font(.headline)
            Text("持有当前配对码的设备可访问下列 TCP 服务。撤回会断开该目标现有的映射。")
                .font(.callout).foregroundStyle(.secondary)
            if manager.allowedTargets.isEmpty {
                ContentUnavailableView("尚无授权目标", systemImage: "lock",
                    description: Text("控制端首次请求具体地址和端口时，请在此 Mac 上确认。"))
            } else {
                List(manager.allowedTargets.sorted { $0.mappingAddress < $1.mappingAddress }, id: \.self) { target in
                    HStack {
                        Text(target.mappingAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("撤回", role: .destructive) { manager.revoke(target) }
                    }
                    .padding(.vertical, 3)
                }
            }
            if let error = manager.storageError { Text(error).font(.callout).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }
        .padding(22).frame(width: 510, height: 420)
    }
}
