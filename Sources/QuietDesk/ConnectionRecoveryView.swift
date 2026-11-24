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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    if presentation.showsActivity {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: presentation.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(presentation.title)
                        .font(.system(size: 18, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                }

                Text(presentation.detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DeskPalette.ink)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = presentation.reason {
                    Text(reason)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if reconnecting {
                    Text("键盘鼠标暂不发送；可随时取消重连。")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.muted)
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if reconnecting || connecting {
                        Button(presentation.actionTitle, action: stop)
                            .buttonStyle(DeskButtonStyle(.secondary))
                    } else {
                        Button(presentation.actionTitle, action: returnToConnection)
                            .buttonStyle(DeskButtonStyle(retry == nil ? .primary : .secondary))
                        if let retry {
                            Button("重新连接", action: retry)
                                .buttonStyle(DeskButtonStyle(.primary))
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 430)
            .foregroundStyle(DeskPalette.ink)
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DeskPalette.hairline) }
            .shadow(color: reduceTransparency ? .clear : .black.opacity(0.09), radius: 15, y: 5)
        }
    }
}
