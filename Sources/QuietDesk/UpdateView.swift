import SwiftUI
import QuietDeskCore

struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    @State private var installationConfirmation: UpdateInstallationAction?

    private var changing: Bool {
        [.checking, .downloading, .verifying, .installing].contains(controller.state)
    }

    private var requiresInstallConfirmation: Bool {
        !controller.autoInstallPreference || controller.session.hasActiveConnection || controller.session.isControlling
    }

    private var stateHeadingTitle: String {
        if controller.needsManualInstall {
            return controller.state == .ready ? "已就绪 · 手动安装路径" : "需要手动更新"
        }
        if controller.requiredSystemVersion != nil {
            return "需要更高版本 macOS"
        }
        switch controller.state {
        case .checking: return "正在检查更新"
        case .downloading: return "正在下载更新"
        case .verifying: return "正在校验更新"
        case .installing: return "正在安装更新"
        case .ready:
            return controller.autoInstallDeferredBySession && !controller.session.hasHostConnection ? "暂缓自动安装" : "更新已就绪"
        case .available: return "QuietDesk 有可用更新"
        case .upToDate: return "已是最新版本"
        case .failed: return "更新失败"
        case .idle: return "QuietDesk 软件更新"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if controller.session.hasHostConnection {
                        HostUpdateRestartCallout()
                    }

                    if let update = controller.manifest {
                        releaseCard(update)
                    }

                    statusCard

                    if controller.enabled {
                        automaticSettingsCard
                    }

                    if controller.usesAdHocSignature {
                        DeskCalloutBox(
                            message: "当前构建为临时签名，更新重启后可能需在这台 Mac 本机重新授予屏幕录制、辅助功能与输入监控权限。",
                            symbol: "exclamationmark.shield",
                            tone: .warning
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerActions
        }
        .padding(24)
        .frame(minWidth: 530, minHeight: 430)
        .deskSurface()
        .updateInstallationConfirmation($installationConfirmation, controller: controller)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stateHeadingTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DeskPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("当前版本 \(controller.currentVersion)（Build \(controller.currentBuild)）· \(controller.usesAdHocSignature ? "临时签名" : "固定签名证书")")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.secondary)
            }
            Spacer()
            UpdateStateBadge(controller: controller)
        }
    }

    private func releaseCard(_ update: UpdateManifest) -> some View {
        DeskSurfaceCard(padding: 15, cornerRadius: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("新版本 \(update.version)")
                        .font(.system(size: 15, weight: .bold))
                    DeskPillBadge(
                        text: ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file),
                        tint: DeskPalette.accent,
                        monospaced: true
                    )
                    Spacer()
                    Button("在 GitHub 查看") { controller.openRelease() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                }
                Text("发布于 \(update.publishedAt)")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                if let notes = update.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.system(size: 13))
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
            DeskSurfaceCard(padding: 14, cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if changing && controller.state != .downloading {
                            ProgressView().controlSize(.small)
                        }
                        Text(controller.message.isEmpty ? "正在获取并验证发布清单…" : controller.message)
                            .font(.system(size: 13))
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
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 0) {
                DeskSettingsRow(title: "自动检查更新", detail: UpdateInstallationCopy.automaticCheckDetail) {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { controller.autoCheckPreference == true },
                        set: { controller.setAutomaticChecks($0) }
                    ))
                    .labelsHidden()
                }
                .padding(.horizontal, 15)

                Divider()

                DeskSettingsRow(
                    title: "非远程控制时自动更新并安装",
                    detail: "仅在未控制远端、未被远程控制且无活动映射连接时执行"
                ) {
                    Toggle("非远程控制时自动更新并安装", isOn: Binding(
                        get: { controller.autoInstallPreference },
                        set: { controller.setAutomaticInstall($0) }
                    ))
                    .labelsHidden()
                }
                .padding(.horizontal, 15)
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

            if controller.requiredSystemVersion != nil {
                Button("前往发布页") { controller.openRelease() }
            } else if controller.needsManualInstall {
                if controller.state == .ready {
                    Button("在 Finder 中显示") { controller.revealPreparedApplication() }
                        .buttonStyle(DeskButtonStyle(.primary))
                } else {
                    Button("手动安装") { controller.openRelease() }
                        .buttonStyle(DeskButtonStyle(.primary))
                }
            } else if controller.state == .ready {
                if controller.session.hasHostConnection {
                    remoteUpdateButton(.restartHost)
                } else {
                    Button("安装并重启") {
                        if requiresInstallConfirmation {
                            installationConfirmation = .restart
                        } else {
                            controller.install()
                        }
                    }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .disabled(controller.installBlocked)
                }
            } else if controller.manifest != nil && !changing {
                if controller.session.hasHostConnection {
                    Button("仅下载不重启") { controller.download() }
                    remoteUpdateButton(.downloadAndRestartHost)
                } else {
                    Button("立即下载并安装") { controller.downloadAndInstall() }
                        .buttonStyle(DeskButtonStyle(.primary))
                }
            } else if !changing {
                Button("重新检查") { controller.check() }
            }
        }
        .buttonStyle(DeskButtonStyle(.secondary))
    }

    private func remoteUpdateButton(_ action: UpdateInstallationAction) -> some View {
        Button(action.buttonTitle) { installationConfirmation = action }
            .buttonStyle(DeskButtonStyle(.primary))
    }
}

struct UpdateSettingsPanel: View {
    @ObservedObject var controller: UpdateController
    @State private var installationConfirmation: UpdateInstallationAction?

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
            if controller.session.hasHostConnection {
                HostUpdateRestartCallout()
            }
            automaticPolicyCard
            if let update = controller.manifest {
                releaseNotesCard(update)
            }
        }
        .updateInstallationConfirmation($installationConfirmation, controller: controller)
    }

    private var versionAndActionCard: some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        versionIdentity
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 10) {
                            UpdateStateBadge(controller: controller)
                            actionButtons
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        versionIdentity
                        UpdateStateBadge(controller: controller)
                        actionButtons
                    }
                }

                Text(controller.enabled
                    ? (!controller.message.isEmpty ? controller.message : "上次检查：\(formattedLastCheck)")
                    : "当前构建未配置更新源与签名公钥。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if controller.state == .downloading {
                    UpdateDownloadProgressRow(receivedBytes: controller.receivedBytes, totalBytes: controller.totalBytes)
                }
            }
        }
    }

    private var versionIdentity: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(DeskPalette.accent)
                .frame(width: 43, height: 43)
                .background(DeskPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("QuietDesk")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                Text(controller.currentVersion)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(DeskPalette.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("当前版本 \(controller.currentVersion)")
                Text("Build \(controller.currentBuild) · \(controller.usesAdHocSignature ? "临时签名" : "固定签名证书")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
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
                } else if controller.needsManualInstall {
                    Button("前往发布页…") { controller.openRelease() }
                    if controller.state == .ready {
                        Button("在 Finder 中显示") { controller.revealPreparedApplication() }
                    }
                } else if controller.state == .ready {
                    Button("取消更新") { controller.cancel() }
                    if controller.session.hasHostConnection {
                        remoteUpdateButton(.restartHost)
                    } else {
                        Button("安装并重启") {
                            if requiresInstallConfirmation {
                                installationConfirmation = .restart
                            } else {
                                controller.install()
                            }
                        }
                        .buttonStyle(DeskButtonStyle(.primary))
                        .disabled(controller.installBlocked)
                    }
                } else if controller.manifest != nil, controller.requiredSystemVersion == nil {
                    Button("跳过此版本") { controller.skip() }
                    if controller.session.hasHostConnection {
                        Button("仅下载不重启") { controller.download() }
                        remoteUpdateButton(.downloadAndRestartHost)
                    } else {
                        Button("立即下载并安装") { controller.downloadAndInstall() }
                            .buttonStyle(DeskButtonStyle(.primary))
                    }
                } else {
                    Button {
                        controller.check(manual: true, presentWindow: false)
                    } label: {
                        Label("立即检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(DeskButtonStyle(.primary))
                }
            }
            .buttonStyle(DeskButtonStyle(.secondary))
        }
    }

    private func remoteUpdateButton(_ action: UpdateInstallationAction) -> some View {
        Button(action.buttonTitle) { installationConfirmation = action }
            .buttonStyle(DeskButtonStyle(.primary))
    }

    private var automaticPolicyCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            DeskSettingsGroup(title: "更新策略") {
                DeskSettingsRow(title: "自动检查更新", detail: UpdateInstallationCopy.automaticCheckDetail) {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { controller.autoCheckPreference == true },
                        set: { controller.setAutomaticChecks($0) }
                    ))
                    .labelsHidden()
                    .disabled(!controller.enabled)
                }

                Divider()

                DeskSettingsRow(title: "非远程控制时自动更新并安装") {
                    Toggle("非远程控制时自动更新并安装", isOn: Binding(
                        get: { controller.autoInstallPreference },
                        set: { controller.setAutomaticInstall($0) }
                    ))
                    .labelsHidden()
                    .disabled(!controller.enabled)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            DeskCalloutBox(
                title: "自动安装时机",
                message: "自动安装需无远控、无被控、无活动映射连接。例行检查在启动满 2 分钟后运行，网络异常时按小时退避。"
            ) {
                DeskInfoPopoverButton(
                    title: "自动更新安全与空闲判定说明",
                    lines: [
                        "更新清单经内置 Ed25519 公钥验签，归档校验大小、SHA-256、ZIP 结构、代码签名与开发团队一致性。",
                        "本机仅开启共享等待连接（无远端接入）时，可自动更新并在重启后恢复共享。",
                        "远程连接断开后留出 10 秒空闲稳定期，避免短暂网络重连触发重启。"
                    ]
                )
            }

            if controller.isRemoteControlActive && !controller.session.hasHostConnection {
                DeskCalloutBox(
                    message: "当前有活动远控或端口映射连接，自动更新将自动延后。",
                    symbol: "clock",
                    tone: .warning
                )
            }

            if controller.usesAdHocSignature {
                Text("临时签名构建更新后，macOS 可能要求在本机重新授予屏幕录制、辅助功能与输入监控权限。")
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func releaseNotesCard(_ update: UpdateManifest) -> some View {
        DeskSurfaceCard(padding: 16, cornerRadius: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("版本 \(update.version) 更新说明")
                        .font(.system(size: 14, weight: .bold))
                    DeskPillBadge(
                        text: ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file),
                        tint: DeskPalette.accent,
                        monospaced: true
                    )
                    Spacer()
                    Text("发布于 \(update.publishedAt)")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                    Button("在 GitHub 查看") { controller.openRelease() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                }
                if let notes = update.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.system(size: 13))
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
                .foregroundStyle(controller.completionNotice != nil ? DeskPalette.emerald : DeskPalette.accent)

            Text(controller.bannerTitle)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer()

            if controller.state == .ready && !controller.installBlocked && !controller.needsManualInstall && controller.autoInstallPreference {
                Button("立即安装并重启") { controller.install() }
                    .buttonStyle(DeskButtonStyle(.primary))
            }
            Button("查看更新") { controller.present() }
                .buttonStyle(DeskButtonStyle(.secondary))
            Button { controller.dismissBanner() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DeskPalette.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭更新提示")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(DeskPalette.accent.opacity(0.08))
    }
}

private struct UpdateStateBadge: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        let deferred = controller.autoInstallDeferredBySession && !controller.session.hasHostConnection
        switch controller.state {
        case .checking:
            DeskPillBadge(text: "正在检查", tint: DeskPalette.accent)
        case .downloading:
            DeskPillBadge(text: "正在下载", tint: DeskPalette.accent)
        case .verifying:
            DeskPillBadge(text: "正在校验", tint: DeskPalette.accent)
        case .installing:
            DeskPillBadge(text: "正在安装", tint: DeskPalette.emerald)
        case .ready:
            DeskPillBadge(
                text: deferred ? "待空闲安装" : "更新已就绪",
                tint: deferred ? DeskPalette.amber : DeskPalette.emerald
            )
        case .available:
            DeskPillBadge(
                text: deferred ? "待空闲更新" : "新版本可用",
                tint: deferred ? DeskPalette.amber : DeskPalette.accent
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)) / \(totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")")
                if let total = totalBytes, total > 0 {
                    Text("· \(Int((min(1.0, Double(receivedBytes) / Double(total)) * 100).rounded()))%")
                }
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(DeskPalette.secondary)
            .monospacedDigit()

            if let total = totalBytes, total > 0 {
                ProgressView(value: min(Double(receivedBytes), Double(total)), total: Double(total))
            } else {
                ProgressView()
            }
        }
    }
}

private struct HostUpdateRestartCallout: View {
    var body: some View {
        DeskCalloutBox(
            title: "远程控制期间更新",
            message: "当前正处于远程控制会话。下载校验完成后，QuietDesk 会临时断开连接、自动安装新版本并恢复共享。支持更新重连的主控端会自动尝试连接。",
            symbol: "arrow.triangle.2.circlepath",
            tone: .info
        )
    }
}

private enum UpdateInstallationAction {
    case restart, restartHost, downloadAndRestartHost

    var buttonTitle: String {
        switch self {
        case .restart: return "安装并重启"
        case .restartHost: return "临时断开并重启更新"
        case .downloadAndRestartHost: return "下载并更新（自动重连）"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .restart: return "安装并重新启动？"
        case .restartHost: return "临时断开远控并更新？"
        case .downloadAndRestartHost: return "下载并更新被控端？"
        }
    }

    @MainActor
    func perform(controller: UpdateController) {
        switch self {
        case .restart: controller.install()
        case .restartHost: controller.installDisconnectingHost()
        case .downloadAndRestartHost: controller.downloadAndInstallDisconnectingHost()
        }
    }

    @MainActor
    func confirmationMessage(controller: UpdateController) -> String {
        if self == .restart { return UpdateInstallationCopy.confirmationMessage(controller: controller) }
        let preparation = self == .downloadAndRestartHost ? "QuietDesk 会先下载并校验更新。" : ""
        var text = preparation + "安装将临时断开远控。重启后会自动恢复共享，支持更新重连的主控端会自动尝试连接。"
        if controller.usesAdHocSignature {
            text += "\n\n此构建使用临时签名。替换应用后，macOS 可能要求在被控机本机重新授予屏幕录制与辅助功能权限。未重新授权时，重启后可能无法直接恢复画面或控制。"
        }
        return text
    }
}

private extension View {
    @MainActor
    func updateInstallationConfirmation(_ action: Binding<UpdateInstallationAction?>, controller: UpdateController) -> some View {
        alert(action.wrappedValue?.confirmationTitle ?? "安装并重新启动？", isPresented: Binding(
            get: { action.wrappedValue != nil },
            set: { if !$0 { action.wrappedValue = nil } }
        ), presenting: action.wrappedValue) { confirmed in
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button(confirmed.buttonTitle) { confirmed.perform(controller: controller) }
        } message: { confirmed in
            Text(confirmed.confirmationMessage(controller: controller))
        }
    }
}

private enum UpdateInstallationCopy {
    static let automaticCheckDetail = "例行检查间隔 24 小时，主控接入时也会检查"

    @MainActor
    static func confirmationMessage(controller: UpdateController) -> String {
        var text = "QuietDesk 将替换应用并重新启动。"
        if controller.session.hasActiveConnection {
            text += "重启会影响本次连接。"
        } else if controller.session.isSharing {
            text += "当前共享会停止。"
        }
        if controller.session.autoStartSharing {
            text += "重启后会按原有偏好尝试恢复共享。"
        }
        if controller.usesAdHocSignature {
            text += "临时签名更新后可能需要本机重新授权。"
        }
        return text
    }
}
