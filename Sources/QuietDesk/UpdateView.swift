import SwiftUI
import QuietDeskCore

struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    @State private var confirmInstallation = false
    private var changing: Bool {
        [.checking, .downloading, .verifying, .installing].contains(controller.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("QuietDesk 更新").font(.title2.weight(.semibold))
            Text("当前版本 \(controller.currentVersion)（\(controller.currentBuild)）")
                .font(.callout).foregroundStyle(.secondary)
            if let update = controller.manifest {
                HStack {
                    Text("新版本 \(update.version)").font(.headline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file))
                }
                Text("发布于 \(update.publishedAt)").font(.caption).foregroundStyle(.secondary)
                if let notes = update.notes, !notes.isEmpty {
                    ScrollView { Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(minHeight: 60, maxHeight: 170)
                }
                Button("在 GitHub 查看") { controller.openRelease() }.buttonStyle(.link)
            }
            Text(controller.message).textSelection(.enabled)
            if controller.state == .downloading {
                if let total = controller.totalBytes, total > 0 {
                    ProgressView(value: Double(controller.receivedBytes), total: Double(total))
                } else { ProgressView() }
                Text("\(ByteCountFormatter.string(fromByteCount: controller.receivedBytes, countStyle: .file)) / \(controller.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")")
                    .font(.caption).monospacedDigit()
            } else if changing { ProgressView().controlSize(.small) }
            if controller.usesAdHocSignature {
                Text("临时签名版本更新后，需要在这台 Mac 上重新授予屏幕录制、辅助功能和输入监控权限。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if controller.installBlocked {
                Text("这台 Mac 正被远程控制。更新后需要在本机重新授权，远程将无法连回。请先停止共享，或在本机操作时更新。")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                if changing && controller.state != .installing {
                    Button("取消") { controller.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("稍后") { controller.later() }.keyboardShortcut(.cancelAction)
                    if controller.manifest != nil && controller.state != .ready {
                        Button("跳过此版本") { controller.skip() }
                    }
                }
                Spacer()
                if controller.needsManualInstall {
                    Button("手动安装") { controller.openRelease() }
                    Button("在 Finder 中显示") { controller.revealPreparedApplication() }
                        .disabled(controller.state != .ready)
                } else if controller.state == .ready {
                    Button("安装并重新启动") { confirmInstallation = true }.disabled(controller.installBlocked)
                } else if controller.manifest != nil && !changing {
                    Button("下载并安装") { controller.download() }.buttonStyle(.borderedProminent)
                } else if !changing {
                    Button("重新检查") { controller.check() }
                }
            }
        }
        .padding(24).frame(width: 520).frame(minHeight: 370)
        .alert("安装更新并重新启动？", isPresented: $confirmInstallation) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("安装并重新启动") { controller.install() }
        } message: {
            Text(installationMessage)
        }
    }

    private var installationMessage: String {
        var text = "QuietDesk 将退出、替换应用并重新启动。"
        if controller.session.hasActiveConnection { text += "当前连接会断开。" }
        else if controller.session.isSharing { text += "当前共享会停止。" }
        if controller.session.autoStartSharing {
            text += "重启后会按原有偏好尝试恢复共享；临时签名版本需要先在本机重新授予权限。"
        }
        return text
    }
}

struct UpdateBanner: View {
    @ObservedObject var controller: UpdateController
    var body: some View {
        HStack {
            Text(controller.menuTitle.replacingOccurrences(of: "…", with: ""))
            Spacer()
            Button("查看更新") { controller.present() }
            Button { controller.dismissBanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("关闭更新提示")
        }
        .font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }
}
