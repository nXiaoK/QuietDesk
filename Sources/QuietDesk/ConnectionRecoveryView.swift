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
    let actionTitle: String

    init(
        reconnecting: Bool,
        paused: Bool,
        wait: ReconnectWait?,
        status: String,
        now: TimeInterval,
        connecting: Bool = false,
        failure: String? = nil,
        disconnectedActionTitle: String = "返回连接"
    ) {
        if reconnecting && paused {
            state = .paused
            title = "空闲暂停，等待返回窗口"
            detail = status
            reason = nil
            actionTitle = "停止重连"
        } else if reconnecting, let wait {
            state = .waiting
            title = "连接中断，等待自动重连"
            detail = wait.countdown(at: now)
            reason = wait.reason
            actionTitle = "停止重连"
        } else if reconnecting {
            state = .connecting
            title = "连接中断，正在自动重连…"
            detail = status
            reason = nil
            actionTitle = "停止重连"
        } else if connecting {
            state = .connecting
            title = "正在建立加密连接…"
            detail = status
            reason = nil
            actionTitle = "取消连接"
        } else if let failure, !failure.isEmpty {
            state = .disconnected
            title = "连接未建立或已断开"
            detail = failure
            reason = nil
            actionTitle = disconnectedActionTitle
        } else {
            state = .disconnected
            title = "尚未连接"
            detail = "退出全屏后输入地址和配对码"
            reason = nil
            actionTitle = disconnectedActionTitle
        }
    }

    var showsActivity: Bool { state == .connecting }
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
    var connecting: Bool = false
    var failure: String? = nil
    var disconnectedActionTitle: String = "返回连接"
    var retry: (() -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let presentation = ConnectionRecoveryPresentation(
                reconnecting: reconnecting,
                paused: paused,
                wait: wait,
                status: status,
                now: now(),
                connecting: connecting,
                failure: failure,
                disconnectedActionTitle: disconnectedActionTitle
            )
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
                } else if connecting {
                    Button(presentation.actionTitle, action: stop)
                } else if let retry {
                    HStack(spacing: 10) {
                        Button("重新连接", action: retry)
                            .buttonStyle(.borderedProminent)
                        Button(presentation.actionTitle, action: returnToConnection)
                    }
                } else {
                    Button(presentation.actionTitle, action: returnToConnection)
                }
            }
            .padding(24).frame(maxWidth: 420)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
