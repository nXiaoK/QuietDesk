import SwiftUI
import QuietDeskCore

struct TailnetSettingsView: View {
    @ObservedObject var tailnet: EmbeddedTailnet

    private var status: String {
        guard tailnet.enabled else { return "未启用" }
        switch tailnet.state {
        case "Running": return "已连接"
        case "NeedsLogin": return "需要登录"
        case "NeedsMachineAuth": return "等待 Tailscale 管理员批准设备"
        case "Starting": return "正在连接"
        case "Stopped": return "已停止"
        case "": return "等待组件响应"
        default: return tailnet.state
        }
    }

    var body: some View {
        DeskSettingsPageHeading(title: "Tailscale", detail: "两端的 QuietDesk 登录同一 Tailscale 网络后，即可跨网使用地址和配对码连接。")
        DeskSettingsGroup(title: "本机设备") {
            DeskSettingsRow(title: "连接状态", detail: tailnet.message) {
                Text(status)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ip = tailnet.ip, tailnet.state == "Running" {
                Divider()
                DeskSettingsRow(title: "QuietDesk 连接地址", detail: "将此地址填入控制端的新建连接，端口与配对码使用本机共享页显示的值。") {
                    Text(TailnetAddress.prefix + ip)
                        .monospaced()
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
                Divider()
                DeskSettingsRow(title: "本机共享") {
                    if tailnet.shared.port == 0 {
                        Text("未通过 Tailscale 共享")
                    } else {
                        let transport = tailnet.shared.udp ? "TCP / UDP" : "TCP"
                        Text(verbatim: "\(transport) \(tailnet.shared.port)")
                            .monospaced()
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                if !tailnet.enabled || tailnet.state != "Running" {
                    Button("登录 Tailscale…") { tailnet.login() }
                        .buttonStyle(DeskButtonStyle(.primary))
                }
                if tailnet.enabled {
                    Button("停用") { tailnet.disable(logout: false) }
                        .buttonStyle(DeskButtonStyle(.secondary))
                    Button("退出账号", role: .destructive) { tailnet.disable(logout: true) }
                        .buttonStyle(DeskButtonStyle(.danger))
                }
            }
            .padding(.vertical, 10)
            .disabled(tailnet.changingAccount)
        }
    }
}
