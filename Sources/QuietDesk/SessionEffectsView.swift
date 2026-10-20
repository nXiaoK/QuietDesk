import SwiftUI

struct SessionEffectsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("被控端设置").font(.title3.weight(.semibold))
            Text("开启成功后会记住，之后每次连接自动开启；关闭开关即不再自动开启。断开时被控端恢复原状。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("被控端静音", isOn: Binding(get: { model.sessionEffects.muted }, set: model.setRemoteMuted))
                .disabled(!model.connected || !model.supportsSessionEffects || model.sessionEffectsWorking)
            Toggle("防窥 · 本地显示黑屏遮罩", isOn: Binding(get: { model.sessionEffects.privacy }, set: model.setRemotePrivacy))
                .disabled(!model.connected || !model.supportsSessionEffects || model.sessionEffectsWorking)
            Text("黑屏期间远端仍可观看和操作。被控 Mac 可按 ⌃⌥Esc 退出遮罩；系统安全界面、Mission Control 等不在遮罩保证范围内。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("防窥会从远端画面排除 QuietDesk 自身窗口，处理被控端的文件确认或权限设置前请先关闭。静音恢复原输出设备状态；设备不支持系统静音时会说明原因。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let remembered = model.sessionEffectsMemory.connectionState {
                Text("新连接将自动开启：" + [remembered.muted ? "被控端静音" : nil, remembered.privacy ? "防窥" : nil]
                    .compactMap { $0 }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.connected {
                Text("连接后可使用。").font(.caption).foregroundStyle(.secondary)
            } else if !model.supportsSessionEffects {
                Text("共享端需更新后才能使用这两个开关。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.sessionEffectsStatus.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if model.sessionEffectsWorking { ProgressView().controlSize(.small) }
                    Text(model.sessionEffectsStatus).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack { Spacer(); Button("完成", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .toggleStyle(.switch)
        .padding(22).frame(width: 450)
        .onExitCommand(perform: done)
    }
}
