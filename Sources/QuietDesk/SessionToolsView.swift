import SwiftUI

struct SessionControlPresentation: Equatable {
    enum State { case pausedReconnect, suspended, reconnecting, viewing, controlling, released }
    let state: State

    init(reconnecting: Bool, sessionPaused: Bool, inputSuspended: Bool, canControl: Bool, controlling: Bool) {
        if sessionPaused && reconnecting { state = .pausedReconnect }
        else if inputSuspended { state = .suspended }
        else if reconnecting { state = .reconnecting }
        else if !canControl { state = .viewing }
        else { state = controlling ? .controlling : .released }
    }

    var title: String {
        switch state {
        case .pausedReconnect: return "空闲暂停 · 返回窗口后继续连接"
        case .suspended: return "画面暂停或恢复中 · 暂不发送键盘鼠标"
        case .reconnecting: return "自动重连中 · 键盘鼠标暂不发送"
        case .viewing: return "仅观看 · 共享端辅助功能未生效"
        case .controlling: return "正在控制远端 · ⌃⌥Esc 释放键盘鼠标"
        case .released: return "已释放 · 点按画面开始控制"
        }
    }

    var symbol: String {
        switch state {
        case .pausedReconnect, .suspended: return "pause.circle"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .viewing: return "eye"
        case .controlling: return "cursorarrow.rays"
        case .released: return "cursorarrow"
        }
    }
}

enum SessionToolAction: CaseIterable {
    case releaseControl, fullScreen, sendText, receiveText, captureFrame, keyboard, privacy, traffic, endSession

    func title(fullScreen: Bool = false, hasSession: Bool = true) -> String {
        switch self {
        case .releaseControl: return "释放控制"
        case .fullScreen: return fullScreen ? "退出全屏" : "进入全屏"
        case .sendText: return "发送文字"
        case .receiveText: return "获取文字"
        case .captureFrame: return "截取远端画面"
        case .keyboard: return "键盘与快捷键"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if page != .main {
                    Button { perform(.releaseControl); page = .main } label: {
                        Image(systemName: "chevron.left").frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain).help("返回控制与设置").accessibilityLabel("返回控制与设置")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(title)
                    Text(presentation.connectionSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("收起控制与设置").accessibilityLabel("收起控制与设置")
            }
            Label(presentation.control.title, systemImage: presentation.control.symbol)
                .font(.system(size: 11)).foregroundStyle(presentation.control.state == .controlling ? Color.accentColor : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch page {
                    case .keyboard: keyboard
                    case .main:
                        HStack(spacing: 8) {
                            shortcutButton(.releaseControl)
                            shortcutButton(.fullScreen)
                        }
                        HStack(spacing: 6) {
                            compactButton(.sendText)
                            compactButton(.receiveText)
                            compactButton(.captureFrame)
                        }
                        desktop
                        VStack(spacing: 0) {
                            navigationButton(.keyboard, detail: presentation.keyboardSummary)
                        }
                        Divider()
                        settings
                        Divider()
                        VStack(spacing: 0) {
                            navigationButton(.privacy)
                            navigationButton(.traffic)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0)
            Divider()
            HStack {
                Text("⌃⌥Esc 释放 · ⌃⌘F 切换全屏")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(presentation.hasSession ? "断开" : "返回连接") { activate(.endSession) }
                    .foregroundStyle(presentation.hasSession ? Color.red : Color.primary)
                    .disabled(!presentation.isEnabled(.endSession))
            }.buttonStyle(.bordered).controlSize(.small)
        }
        .font(.system(size: 12)).padding(14).frame(width: 324).frame(maxHeight: 568)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: close)
    }

    private func activate(_ action: SessionToolAction) {
        guard presentation.isEnabled(action) else { return }
        perform(action)
        if action == .keyboard { page = .keyboard }
    }

    private func shortcutButton(_ action: SessionToolAction) -> some View {
        Button { activate(action) } label: {
            VStack(spacing: 3) {
                Label(action.title(fullScreen: presentation.fullScreen), systemImage: action.symbol(fullScreen: presentation.fullScreen))
                if let shortcut = action.shortcut { Text(shortcut).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).controlSize(.regular).help(action.help)
    }

    private func compactButton(_ action: SessionToolAction) -> some View {
        Button { activate(action) } label: {
            VStack(spacing: 4) {
                Image(systemName: action.symbol())
                Text(action.title()).font(.system(size: 10))
            }.frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered).controlSize(.small).help(action.help)
        .disabled(!presentation.isEnabled(action))
    }

    private func navigationButton(_ action: SessionToolAction, detail: String? = nil) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 8) {
                Label(action.title(), systemImage: action.symbol())
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.frame(minHeight: 30)
        }.buttonStyle(.plain).help(action.help)
    }
}
