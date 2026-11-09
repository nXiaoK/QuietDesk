import SwiftUI

struct ReconnectWait: Equatable {
    let attempt: Int
    let delay: TimeInterval
    let reason: String
    let deadline: TimeInterval

    init(attempt: Int, delay: TimeInterval, reason: String, now: TimeInterval) {
        self.attempt = attempt
        self.delay = delay
        self.reason = reason
        deadline = now + delay
    }

    func remainingSeconds(at now: TimeInterval) -> Int {
        Int(min(delay, max(0, deadline - now)).rounded(.up))
    }

    func countdown(at now: TimeInterval) -> String {
        let seconds = remainingSeconds(at: now)
        return seconds > 0 ? "\(seconds) 秒后第 \(attempt) 次重连" : "即将开始第 \(attempt) 次重连"
    }

    var status: String { "等待第 \(attempt) 次重连 · \(reason)" }
}

struct ConnectionRecoveryPresentation {
    enum State { case paused, waiting, connecting, disconnected }
    let state: State
    let title: String
    let detail: String
    let reason: String?

    init(reconnecting: Bool, paused: Bool, wait: ReconnectWait?, status: String, now: TimeInterval) {
        if reconnecting && paused {
            state = .paused
            title = "空闲暂停，等待返回窗口"
            detail = status
            reason = nil
        } else if reconnecting, let wait {
            state = .waiting
            title = "连接中断，等待自动重连"
            detail = wait.countdown(at: now)
            reason = wait.reason
        } else if reconnecting {
            state = .connecting
            title = "连接中断，正在自动重连…"
            detail = status
            reason = nil
        } else {
            state = .disconnected
            title = "尚未连接"
            detail = "退出全屏后输入地址和配对码"
            reason = nil
        }
    }

    var showsActivity: Bool { state == .connecting }
    var actionTitle: String { state == .disconnected ? "返回连接" : "停止重连" }
    var symbol: String {
        switch state {
        case .paused: return "pause.circle"
        case .waiting: return "clock.arrow.circlepath"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "desktopcomputer"
        }
    }
}

struct ConnectionRecoveryView: View {
    let reconnecting: Bool
    let paused: Bool
    let wait: ReconnectWait?
    let status: String
    let now: () -> TimeInterval
    let stop: () -> Void
    let returnToConnection: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let presentation = ConnectionRecoveryPresentation(reconnecting: reconnecting, paused: paused,
                wait: wait, status: status, now: now())
            VStack(spacing: 14) {
                if presentation.showsActivity { ProgressView().controlSize(.small) }
                else { Image(systemName: presentation.symbol).font(.system(size: 28)).foregroundStyle(.secondary) }
                Text(presentation.title).font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(presentation.detail).font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit().multilineTextAlignment(.center)
                if let reason = presentation.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                }
                if reconnecting {
                    Text("重连期间不发送键盘鼠标").font(.caption).foregroundStyle(.secondary)
                    Button(presentation.actionTitle, action: stop)
                } else { Button(presentation.actionTitle, action: returnToConnection) }
            }
            .padding(24).frame(maxWidth: 420)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
