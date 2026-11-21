import SwiftUI

struct SessionControlPresentation: Equatable {
    enum State { case pausedReconnect, suspended, reconnecting, viewing, localViewOnly, controlling, released }
    let state: State

    init(reconnecting: Bool, sessionPaused: Bool, inputSuspended: Bool, canControl: Bool, controlling: Bool, localViewOnly: Bool = false) {
        if sessionPaused && reconnecting { state = .pausedReconnect }
        else if inputSuspended { state = .suspended }
        else if reconnecting { state = .reconnecting }
        else if !canControl { state = .viewing }
        else if localViewOnly { state = .localViewOnly }
        else { state = controlling ? .controlling : .released }
    }

    var title: String {
        switch state {
        case .pausedReconnect: return "空闲暂停 · 返回窗口后继续连接"
        case .suspended: return "画面暂停或恢复中 · 暂不发送键盘鼠标"
        case .reconnecting: return "自动重连中 · 键盘鼠标暂不发送"
        case .viewing: return "仅观看 · 共享端未允许控制或辅助功能未生效"
        case .localViewOnly: return "仅观看 · 本机已开启键鼠防误触锁定"
        case .controlling: return "正在控制远端 · ⌃⌥Esc 释放键盘鼠标"
        case .released: return "已释放 · 点按画面开始控制"
        }
    }

    var symbol: String {
        switch state {
        case .pausedReconnect, .suspended: return "pause.circle"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .viewing: return "eye"
        case .localViewOnly: return "hand.raised"
        case .controlling: return "cursorarrow.rays"
        case .released: return "cursorarrow"
        }
    }
}

enum SessionToolAction: CaseIterable {
    case releaseControl, fullScreen, sendText, receiveText, captureFrame, keyboard, portMapping, privacy, traffic, endSession

    func title(fullScreen: Bool = false, hasSession: Bool = true) -> String {
        switch self {
        case .releaseControl: return "释放控制"
        case .fullScreen: return fullScreen ? "退出全屏" : "进入全屏"
        case .sendText: return "发送文字"
        case .receiveText: return "获取文字"
        case .captureFrame: return "截取远端画面"
        case .keyboard: return "键盘与快捷键"
        case .portMapping: return "TCP 端口映射"
        case .privacy: return "被控端隐私与安全"
        case .traffic: return "设备历史流量"
        case .endSession: return hasSession ? "断开" : "返回连接"
        }
    }

    func symbol(fullScreen: Bool = false) -> String {
        switch self {
        case .releaseControl: return "cursorarrow"
        case .fullScreen: return fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        case .sendText: return "doc.badge.arrow.up"
        case .receiveText: return "arrow.down.doc"
        case .captureFrame: return "camera.viewfinder"
        case .keyboard: return "keyboard"
        case .portMapping: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "lock.shield"
        case .traffic: return "chart.bar.xaxis"
        case .endSession: return "stop.circle"
        }
    }

    var shortcut: String? {
        switch self {
        case .releaseControl: return "⌃⌥Esc"
        case .fullScreen: return "⌃⌘F"
        case .captureFrame: return "⌃⌘S"
        default: return nil
        }
    }

    var help: String {
        switch self {
        case .releaseControl: return "在本机释放键盘鼠标（⌃⌥Esc）；点按远程画面后才重新控制"
        case .fullScreen: return "切换窗口与全屏（⌃⌘F），不结束连接"
        case .sendText: return "发送本机剪贴板文字"
        case .receiveText: return "获取远端剪贴板文字"
        case .captureFrame: return "把当前远端画面复制到剪贴板（⌃⌘S），防窥遮罩不会出现在截图里"
        case .keyboard: return "系统快捷键、Caps Lock 转发与本机权限的实际生效状态"
        case .portMapping: return "在本机访问被控 Mac 允许的 TCP 服务"
        case .privacy: return "被控端防窥、静音、亮度与断开锁屏设置"
        case .traffic: return "查看本机保存的设备历史流量"
        case .endSession: return "结束本次远程连接，沿用原有停止与取消重连行为"
        }
    }
}

struct SessionToolsPresentation {
    let connected: Bool
    let reconnecting: Bool
    let hasSession: Bool
    let fullScreen: Bool
    let remoteName: String
    let latency: String
    let control: SessionControlPresentation
    let keyboardSummary: String

    var connectionSummary: String {
        if connected { return latency.isEmpty ? "已连接" : "已连接 · \(latency)" }
        return reconnecting ? "正在重连" : "未连接"
    }

    func isEnabled(_ action: SessionToolAction) -> Bool {
        switch action {
        case .sendText, .receiveText, .captureFrame: return connected
        case .endSession: return hasSession || fullScreen
        default: return true
        }
    }

    func perform(_ action: SessionToolAction, releaseControl: () -> Void, operation: () -> Void) {
        guard isEnabled(action) else { return }
        releaseControl()
        operation()
    }
}

struct SessionToolsView<Settings: View, Keyboard: View, Desktop: View>: View {
    let presentation: SessionToolsPresentation
    let settings: Settings
    let keyboard: Keyboard
    let desktop: Desktop
    let perform: (SessionToolAction) -> Void
    let close: () -> Void
    @State private var page = Page.main

    private enum Page { case main, keyboard }

    private var title: String {
        switch page {
        case .main: return presentation.remoteName.isEmpty ? "控制与设置" : presentation.remoteName
        case .keyboard: return SessionToolAction.keyboard.title()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                if page != .main {
                    Button {
                        perform(.releaseControl)
                        page = .main
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("返回控制与设置")
                    .accessibilityLabel("返回控制与设置")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .help(title)
                    Text(presentation.connectionSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                Button {
                    activate(.endSession)
                } label: {
                    Text(presentation.hasSession ? "断开" : "返回连接")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(presentation.hasSession ? Color.red : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            (presentation.hasSession ? Color.red : Color.primary).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!presentation.isEnabled(.endSession))
                .help(SessionToolAction.endSession.help)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("收起控制与设置")
                .accessibilityLabel("收起控制与设置")
            }

            // Live Control Status Pill
            HStack(spacing: 6) {
                Image(systemName: presentation.control.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(presentation.control.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(presentation.control.state == .controlling ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (presentation.control.state == .controlling ? Color.accentColor : Color.primary).opacity(0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    switch page {
                    case .keyboard:
                        keyboard
                    case .main:
                        // Top 4 Quick Action Tiles + Clipboard Row
                        HStack(spacing: 6) {
                            quickTile(.releaseControl)
                            quickTile(.fullScreen)
                            quickTile(.captureFrame)
                        }
                        HStack(spacing: 6) {
                            compactActionPill(.sendText)
                            compactActionPill(.receiveText)
                        }

                        // Inline Remote Desktop Spaces (kept inline on main page!)
                        desktop

                        Divider()

                        settings

                        Divider()

                        VStack(spacing: 2) {
                            navigationRow(.keyboard, detail: presentation.keyboardSummary)
                            navigationRow(.privacy)
                            navigationRow(.portMapping)
                            navigationRow(.traffic)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 348)
        .frame(maxHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: close)
    }

    private func activate(_ action: SessionToolAction) {
        guard presentation.isEnabled(action) else { return }
        perform(action)
        if action == .keyboard { page = .keyboard }
    }

    private func quickTile(_ action: SessionToolAction) -> some View {
        Button { activate(action) } label: {
            VStack(spacing: 3.5) {
                Image(systemName: action.symbol(fullScreen: presentation.fullScreen))
                    .font(.system(size: 13.5, weight: .semibold))
                Text(action.title(fullScreen: presentation.fullScreen))
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(action.help)
        .disabled(!presentation.isEnabled(action))
    }

    private func compactActionPill(_ action: SessionToolAction) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 5) {
                Image(systemName: action.symbol())
                    .font(.system(size: 11, weight: .medium))
                Text(action.title())
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(action.help)
        .disabled(!presentation.isEnabled(action))
    }

    private func navigationRow(_ action: SessionToolAction, detail: String? = nil) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol())
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(action.title())
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(action.help)
    }
}
