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
        page == .main ? "会话设置" : SessionToolAction.keyboard.title()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                if page == .keyboard {
                    Button {
                        perform(.releaseControl)
                        page = .main
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .help("返回会话设置")
                    .accessibilityLabel("返回会话设置")
                }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 5)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(DeskButtonStyle(.quiet))
                .accessibilityLabel("收起会话设置")
                .help("收起会话设置")
            }
            .padding(.horizontal, 15)

            HStack(spacing: 6) {
                Image(systemName: presentation.control.symbol)
                    .accessibilityHidden(true)
                Text(presentation.control.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(presentation.connectionSummary)
                    .monospacedDigit()
                    .foregroundStyle(DeskPalette.muted)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(presentation.control.state == .controlling ? DeskPalette.emerald : DeskPalette.secondary)
            .padding(.horizontal, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    switch page {
                    case .keyboard:
                        keyboard
                    case .main:
                        settings

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("远端空间与快捷操作")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(DeskPalette.secondary)

                            HStack(spacing: 6) {
                                quickAction(.releaseControl)
                                quickAction(.fullScreen)
                                quickAction(.captureFrame, shortLabel: "截图")
                            }
                            HStack(spacing: 6) {
                                quickAction(.sendText)
                                quickAction(.receiveText)
                            }
                            desktop
                        }

                        VStack(spacing: 0) {
                            navigationRow(.keyboard, detail: presentation.keyboardSummary)
                            Divider().padding(.leading, 32)
                            navigationRow(.privacy)
                            Divider().padding(.leading, 32)
                            navigationRow(.portMapping)
                            Divider().padding(.leading, 32)
                            navigationRow(.traffic)
                        }
                        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DeskPalette.hairline, lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0)

            if page == .main {
                Divider()
                HStack {
                    if !presentation.remoteName.isEmpty {
                        Text(presentation.remoteName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Button(presentation.hasSession ? "断开连接" : "返回连接") { activate(.endSession) }
                        .buttonStyle(DeskButtonStyle(presentation.hasSession ? .danger : .secondary))
                        .disabled(!presentation.isEnabled(.endSession))
                        .help(SessionToolAction.endSession.help)
                }
                .padding(.horizontal, 15)
            }
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 15)
        .frame(width: 396)
        .frame(idealHeight: 704, maxHeight: 720)
        .foregroundStyle(DeskPalette.ink)
        .background(DeskPalette.cardBackground)
        .tint(DeskPalette.accent)
        .onExitCommand(perform: close)
    }

    private func activate(_ action: SessionToolAction) {
        guard presentation.isEnabled(action) else { return }
        perform(action)
        if action == .keyboard { page = .keyboard }
    }

    private func quickAction(_ action: SessionToolAction, shortLabel: String? = nil) -> some View {
        Button { activate(action) } label: {
            Label(shortLabel ?? action.title(fullScreen: presentation.fullScreen),
                  systemImage: action.symbol(fullScreen: presentation.fullScreen))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(DeskButtonStyle(.secondary, compact: true))
        .help(action.shortcut.map { action.help + " · " + $0 } ?? action.help)
        .disabled(!presentation.isEnabled(action))
    }

    private func navigationRow(_ action: SessionToolAction, detail: String? = nil) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol())
                    .font(.system(size: 12))
                    .foregroundStyle(DeskPalette.secondary)
                    .frame(width: 16)
                Text(action.title())
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.ink)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DeskPalette.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DeskPalette.muted)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.help)
    }
}
