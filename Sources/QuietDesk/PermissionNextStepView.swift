import SwiftUI

struct PermissionNextStep: Equatable {
    enum Action { case screenRecording, accessibility, inputMonitoring, recheck }
    let title: String
    let detail: String
    let action: Action?

    var actionTitle: String? {
        switch action {
        case .screenRecording: return "打开本机屏幕录制设置…"
        case .accessibility: return "打开本机辅助功能设置…"
        case .inputMonitoring: return "打开本机输入监控设置…"
        case .recheck: return "重新检测并重试监听"
        case nil: return nil
        }
    }

    static func sharing(screenRecording: Bool, accessibility: Bool, started: Bool) -> Self {
        if !screenRecording {
            return Self(title: "下一步：允许这台 Mac 录制屏幕",
                detail: "屏幕录制未生效，无法开始传送画面。请在本机系统设置允许当前应用，返回后点“重新检测”；"
                    + (started ? "若共享已停止，生效后需重新点“开启共享”。" : "生效后仍需点“开启共享”，不会自动开始。"),
                action: .screenRecording)
        }
        if !accessibility {
            return Self(title: "画面权限已生效，辅助功能尚未生效",
                detail: (started ? "当前权限仅允许观看。" : "如只需观看，可点“开启共享”。") + "若需键盘鼠标控制，请在这台被控 Mac 开启辅助功能，再重新检测；本机未授权不影响只观看共享。",
                action: .accessibility)
        }
        return Self(title: started ? "共享所需权限已生效" : "权限已生效，按需开启共享",
            detail: started ? "屏幕录制用于传送画面，辅助功能用于接受键盘鼠标控制。控制端仍需连接并通过验证。"
                : "请返回上方点“开启共享”；配对码、端口与画面准备仍会按原流程检查。授权不会自动开启共享。",
            action: nil)
    }

    static func localKeyboard(accessibility: Bool, inputMonitoring: Bool, capsEnabled: Bool, capsRunning: Bool) -> Self {
        if !accessibility || !inputMonitoring {
            return Self(title: "下一步：处理这台控制 Mac 的权限",
                detail: "本机辅助功能和输入监控用于 Caps Lock 与全屏系统快捷键监听，不代替被控 Mac 的控制授权。开启缺少的权限后点“重新检测”；已开启但未生效时，请完全退出后重开。",
                action: accessibility ? .inputMonitoring : .accessibility)
        }
        if capsEnabled && !capsRunning {
            return Self(title: "本机权限已生效，Caps Lock 监听尚未就绪",
                detail: "点“重新检测并重试监听”；若仍失败，可完全退出后重开。权限勾选或生效不等于监听已运行，以实际状态为准。",
                action: .recheck)
        }
        return Self(title: capsEnabled ? "本机 Caps Lock 监听已就绪" : "本机权限已生效，Caps Lock 转发未开启",
            detail: "监听状态只代表本机准备情况。实际转发还需对端支持并允许控制；全屏系统快捷键仅在画面聚焦且监听生效时捕获，安全输入开启时暂停。",
            action: nil)
    }

    static func remoteKeyboard(connected: Bool, reconnecting: Bool, canControl: Bool,
                               livePermissionUpdates: Bool, supportsInputActions: Bool, inputSuspended: Bool) -> Self {
        guard connected else {
            return Self(title: reconnecting ? "等待连接恢复后确认被控端" : "连接后确认被控端控制状态",
                detail: "以下权限按钮只处理这台控制 Mac，不会替另一台 Mac 授权。被控端是否允许控制，以本次连接收到的状态为准。",
                action: nil)
        }
        if !canControl {
            return Self(title: "本次连接仅观看：请在被控 Mac 上处理",
                detail: "请在被控 Mac 的系统设置开启 QuietDesk 辅助功能，再在被控端重新检测。"
                    + (livePermissionUpdates ? "当前连接支持接收权限变化；请以实际控制状态更新为准。"
                       : "当前连接未协商权限更新；在被控端生效后，需断开再连接才能获取新状态。")
                    + "在这台控制 Mac 授权不能解除被控端限制。",
                action: nil)
        }
        if !supportsInputActions {
            return Self(title: "被控端已允许控制，但不支持 Caps Lock 动作",
                detail: "请更新被控 Mac 后重新连接，再使用 Caps Lock 切换输入法。普通键盘鼠标仍按原能力工作，不要为此反复修改本机权限。",
                action: nil)
        }
        return Self(title: inputSuspended ? "被控端已允许控制，等待画面恢复" : "被控端已允许控制",
            detail: inputSuspended ? "暂停或等待新画面期间不发送输入；恢复后仍需按原焦点规则控制。"
                : "本机监听就绪后，点按远程画面开始控制；关闭设置不会自动捕获键盘鼠标。",
            action: nil)
    }
}

struct PermissionNextStepView: View {
    let step: PermissionNextStep
    let compact: Bool
    let perform: (PermissionNextStep.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title).font(.system(size: compact ? 11 : 12, weight: .semibold))
            Text(step.detail).font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = step.action, let title = step.actionTitle {
                Button(title) { perform(action) }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 9 : 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
