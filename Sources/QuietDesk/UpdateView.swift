import SwiftUI
import QuietDeskCore

struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    @State private var confirmInstallation = false

    private var changing: Bool {
        [.checking, .downloading, .verifying, .installing].contains(controller.state)
    }

    private var requiresInstallConfirmation: Bool {
        !controller.autoInstallPreference || controller.session.hasActiveConnection || controller.session.isControlling
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let update = controller.manifest {
                        releaseCard(update)
                    }

                    statusCard

                    if controller.enabled {
                        automaticSettingsCard
                    }

                    if controller.usesAdHocSignature {
                        Label("当前构建为临时签名，更新重启后可能需在这台 Mac 本机重新授予屏幕录制、辅助功能与输入监控权限。", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if controller.installBlocked {
                        Label("这台 Mac 正被远程控制。为防止更新重启导致远端失联，请先停止共享或等待远程会话结束后自动安装。", systemImage: "hand.raised.fill")
                            .font(.callout)
                            .foregroundStyle(DeskPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerActions
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
        .background(DeskPalette.canvasBackground)
        .alert("安装更新并重新启动？", isPresented: $confirmInstallation) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("安装并重新启动") { controller.install() }
        } message: {
            Text(UpdateInstallationCopy.confirmationMessage(controller: controller))
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("QuietDesk 更新")
                        .font(.system(size: 17, weight: .bold))
                    UpdateStateBadge(controller: controller)
                }
                Text("当前版本 \(controller.currentVersion)（Build \(controller.currentBuild)）· \(controller.usesAdHocSignature ? "临时签名" : "固定签名证书")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    private func releaseCard(_ update: UpdateManifest) -> some View {
        DeskSurfaceCard(padding: 14, cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("新版本 \(update.version)")
                        .font(.system(size: 14.5, weight: .bold))
                    DeskPillBadge(
                        text: ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file),
                        tint: .accentColor,
                        monospaced: true
                    )
                    Spacer()
                    Button("在 GitHub 查看") { controller.openRelease() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text("发布于 \(update.publishedAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = update.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if !controller.message.isEmpty || changing {
            DeskSurfaceCard(padding: 13, cornerRadius: 11) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if changing && controller.state != .downloading {
                            ProgressView().controlSize(.small)
                        }
                        Text(controller.message.isEmpty ? "准备就绪" : controller.message)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if controller.state == .downloading {
                        UpdateDownloadProgressRow(receivedBytes: controller.receivedBytes, totalBytes: controller.totalBytes)
                    }
                }
            }
        }
    }

    private var automaticSettingsCard: some View {
        DeskSurfaceCard(padding: 13, cornerRadius: 11) {
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(
                    get: { controller.autoCheckPreference == true },
                    set: { controller.setAutomaticChecks($0) }
                )) {
                    Text("自动检查更新（每 24 小时最多一次）")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(isOn: Binding(
                    get: { controller.autoInstallPreference },
                    set: { controller.setAutomaticInstall($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("非远程控制时自动更新并安装")
                            .font(.callout.weight(.medium))
                        Text("发现新版本后自动下载校验；仅在未控制远端、未被远程控制且无活动映射连接时自动安装重启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            if changing {
                Button("取消") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("稍后") { controller.later() }
                    .keyboardShortcut(.cancelAction)
                if controller.state == .ready {
                    Button("取消更新") { controller.cancel() }
                } else if controller.manifest != nil {
                    Button("跳过此版本") { controller.skip() }
                }
            }

            Spacer()

            if controller.needsManualInstall {
                Button("手动安装") { controller.openRelease() }
                Button("在 Finder 中显示") { controller.revealPreparedApplication() }
                    .disabled(controller.state != .ready)
            } else if controller.state == .ready {
                Button("安装并重新启动") {
                    if requiresInstallConfirmation {
                        confirmInstallation = true
                    } else {
                        controller.install()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.installBlocked)
            } else if controller.manifest != nil && !changing && controller.requiredSystemVersion == nil {
                if controller.installBlocked {
                    Button("先下载更新") { controller.download() }
                } else {
                    Button("立即下载并安装") { controller.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                }
            } else if !changing && controller.requiredSystemVersion == nil {
                Button("重新检查") { controller.check() }
            }
        }
    }
}

struct UpdateSettingsPanel: View {
    @ObservedObject var controller: UpdateController
    @State private var confirmInstallation = false

    private var changing: Bool {
        [.checking, .downloading, .verifying, .installing].contains(controller.state)
    }

    private var requiresInstallConfirmation: Bool {
        !controller.autoInstallPreference || controller.session.hasActiveConnection || controller.session.isControlling
    }

    private var formattedLastCheck: String {
        guard let date = controller.lastCheckedAt else { return "尚未自动检查" }
        let now = Date()
        if now.timeIntervalSince(date) < 10 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            versionAndActionCard
            automaticPolicyCard
            if let update = controller.manifest {
                releaseNotesCard(update)
            }
        }
        .alert("安装更新并重新启动？", isPresented: $confirmInstallation) {
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("安装并重新启动") { controller.install() }
        } message: {
            Text(UpdateInstallationCopy.confirmationMessage(controller: controller))
        }
    }

    private var versionAndActionCard: some View {
        DeskSurfaceCard(padding: 18, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 46, height: 46)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("QuietDesk \(controller.currentVersion)")
                                .font(.system(size: 16.5, weight: .bold))
                            DeskPillBadge(text: "Build \(controller.currentBuild)", tint: .secondary, monospaced: true)
                            DeskPillBadge(
                                text: controller.usesAdHocSignature ? "临时签名" : "固定签名证书",
                                tint: controller.usesAdHocSignature ? DeskPalette.amber : DeskPalette.emerald
                            )
                            UpdateStateBadge(controller: controller)
                        }
                        Text(controller.enabled
                             ? "上次自动检查：\(formattedLastCheck)\(controller.message.isEmpty ? "" : " · \(controller.message)")"
                             : "当前构建未配置更新源与签名公钥，应用内更新已关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    actionButtons
                }

                if controller.state == .downloading {
                    UpdateDownloadProgressRow(receivedBytes: controller.receivedBytes, totalBytes: controller.totalBytes)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if controller.enabled {
            HStack(spacing: 8) {
                if changing {
                    if controller.state != .downloading {
                        ProgressView().controlSize(.small)
                    }
                    Button("取消") { controller.cancel() }
                        .controlSize(.regular)
                } else if controller.needsManualInstall {
                    Button("前往 GitHub 下载…") { controller.openRelease() }
                    if controller.state == .ready {
                        Button("在 Finder 中显示") { controller.revealPreparedApplication() }
                    }
                } else if controller.state == .ready {
                    Button("取消暂存") { controller.cancel() }
                    Button("安装并重新启动") {
                        if requiresInstallConfirmation {
                            confirmInstallation = true
                        } else {
                            controller.install()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.installBlocked)
                } else if controller.manifest != nil, controller.requiredSystemVersion == nil {
                    Button("跳过此版本") { controller.skip() }
                    if controller.installBlocked {
                        Button("先下载更新") { controller.download() }
                    } else {
                        Button("立即下载并安装") { controller.downloadAndInstall() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("检查更新") { controller.check(manual: true, presentWindow: false) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var automaticPolicyCard: some View {
        DeskSurfaceCard(padding: 18, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("自动检查与自动更新策略", systemImage: "sparkles")
                        .font(.system(size: 13.5, weight: .bold))
                    Spacer()
                    DeskInfoPopoverButton(
                        title: "自动更新安全与空闲判定说明",
                        lines: [
                            "所有更新清单均经内置 Ed25519 公钥验签，归档严格校验大小、SHA-256、ZIP 结构、代码签名与开发团队一致性。",
                            "当本机正在远程控制其他 Mac、正被其他 Mac 远程控制，或存在活动 TCP 端口映射连接时，不会启动后台下载或自动重启。",
                            "本机仅开启「本机共享」等待连接（当前无远端接入）不视为处于远程控制中，可正常自动完成更新并在重启后恢复共享。",
                            "远程连接刚断开时会留出 10 秒空闲稳定期，避免短暂网络重连期间误触发重启。"
                        ],
                        label: "安全规则"
                    )
                }

                Toggle(isOn: Binding(
                    get: { controller.autoCheckPreference == true },
                    set: { controller.setAutomaticChecks($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动检查更新")
                            .fontWeight(.medium)
                        Text("启动满 2 分钟后，每 24 小时最多访问一次 GitHub Release 获取最新签名清单；网络异常时按小时退避重试。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!controller.enabled)

                Divider()

                Toggle(isOn: Binding(
                    get: { controller.autoInstallPreference },
                    set: { controller.setAutomaticInstall($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动更新（非远程控制情况下自动下载并安装）")
                            .fontWeight(.medium)
                        Text("开启后自动启用更新检查；发现新版本且不处于远程控制或活动连接时，自动在后台下载、校验、替换应用并静默重启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!controller.enabled)

                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isRemoteControlActive ? DeskPalette.amber : DeskPalette.emerald)
                        .frame(width: 7.5, height: 7.5)
                    Text(controller.isRemoteControlActive
                         ? "当前检测：处于远程控制或活动连接中 · 自动更新将推迟至连接空闲后执行"
                         : "当前检测：未处于远程控制状态 · 满足自动更新安装条件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if controller.usesAdHocSignature {
                    Label("当前应用使用临时签名（ad-hoc），自动更新替换后 macOS 可能要求在本机重新确认屏幕录制、辅助功能与输入监控权限。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func releaseNotesCard(_ update: UpdateManifest) -> some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("版本 \(update.version) 更新说明")
                        .font(.system(size: 13.5, weight: .bold))
                    DeskPillBadge(
                        text: ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file),
                        tint: .accentColor,
                        monospaced: true
                    )
                    Spacer()
                    Text("发布于 \(update.publishedAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("GitHub Release…") { controller.openRelease() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if let notes = update.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct UpdateBanner: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.completionNotice != nil ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                .foregroundStyle(controller.completionNotice != nil ? DeskPalette.emerald : Color.accentColor)

            Text(controller.bannerTitle)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer()

            if controller.state == .ready && !controller.installBlocked && !controller.needsManualInstall && controller.autoInstallPreference {
                Button("立即安装并重启") { controller.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("查看更新") { controller.present() }
                .controlSize(.small)
            Button { controller.dismissBanner() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭更新提示")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct UpdateStateBadge: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        switch controller.state {
        case .checking:
            DeskPillBadge(text: "正在检查", tint: .accentColor)
        case .downloading:
            DeskPillBadge(text: "正在下载", tint: .accentColor)
        case .verifying:
            DeskPillBadge(text: "正在校验", tint: .accentColor)
        case .installing:
            DeskPillBadge(text: "正在安装", tint: DeskPalette.emerald)
        case .ready:
            DeskPillBadge(
                text: controller.autoInstallDeferredBySession ? "待空闲安装" : "已就绪",
                tint: controller.autoInstallDeferredBySession ? DeskPalette.amber : DeskPalette.emerald
            )
        case .available:
            DeskPillBadge(
                text: controller.autoInstallDeferredBySession ? "待空闲更新" : "新版本可用",
                tint: controller.autoInstallDeferredBySession ? DeskPalette.amber : .accentColor
            )
        case .upToDate:
            DeskPillBadge(text: "已是最新", tint: DeskPalette.emerald)
        case .failed:
            DeskPillBadge(text: "更新受阻", tint: DeskPalette.coral)
        case .idle:
            if controller.autoInstallPreference {
                DeskPillBadge(text: "自动更新已开", tint: DeskPalette.emerald)
            }
        }
    }
}

private struct UpdateDownloadProgressRow: View {
    let receivedBytes: Int64
    let totalBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let total = totalBytes, total > 0 {
                ProgressView(value: min(Double(receivedBytes), Double(total)), total: Double(total))
            } else {
                ProgressView()
            }
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) / \(totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")")
                Spacer()
                if let total = totalBytes, total > 0 {
                    Text("\(Int((min(1.0, Double(receivedBytes) / Double(total)) * 100).rounded()))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

private enum UpdateInstallationCopy {
    @MainActor
    static func confirmationMessage(controller: UpdateController) -> String {
        var text = "QuietDesk 将退出、替换应用并重新启动。"
        if controller.session.hasActiveConnection {
            text += "当前连接会断开。"
        } else if controller.session.isSharing {
            text += "当前共享会停止。"
        }
        if controller.session.autoStartSharing {
            text += "重启后会按原有偏好尝试恢复共享。"
            if controller.usesAdHocSignature {
                text += "临时签名版本需要先在本机重新授予权限。"
            }
        }
        return text
    }
}
