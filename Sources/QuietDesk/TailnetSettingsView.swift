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
            }
            if let ip = tailnet.ip, tailnet.state == "Running" {
                Divider()
                DeskSettingsRow(title: "QuietDesk 连接地址", detail: "将此地址填入控制端的新建连接，端口与配对码使用本机共享页显示的值。") {
                    Text(TailnetAddress.prefix + ip).monospaced().textSelection(.enabled)
                }
                Divider()
                DeskSettingsRow(title: "本机共享") {
                    Text(tailnet.shared.port == 0 ? "未通过 Tailscale 共享" : "\(tailnet.shared.udp ? "TCP / UDP" : "TCP") \(tailnet.shared.port)")
                }
            }
            Divider()
            HStack {
                if !tailnet.enabled || tailnet.state != "Running" {
                    Button("登录 Tailscale…") { tailnet.login() }
                        .buttonStyle(DeskButtonStyle(.primary))
                }
                if tailnet.enabled {
                    Button("停用") { tailnet.disable(logout: false) }
                    Button("退出账号") { tailnet.disable(logout: true) }
                }
            }
            .disabled(tailnet.changingAccount)
        }
    }
}
