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

    private var connectionAddress: String? {
        guard tailnet.state == "Running", let ip = tailnet.ip else { return nil }
        return TailnetAddress.prefix + ip
    }

    private var statusTint: Color {
        guard tailnet.enabled else { return DeskPalette.secondary }
        switch tailnet.state {
        case "Running": return DeskPalette.emerald
        case "NeedsLogin", "NeedsMachineAuth", "Starting": return DeskPalette.amber
        default: return DeskPalette.secondary
        }
    }

    var body: some View {
        DeskSettingsPageHeading(
            title: "Tailscale",
            detail: "两端的 QuietDesk 登录同一 Tailscale 网络后，即可跨网使用地址和配对码连接。"
        )

        deviceCard

        if connectionAddress != nil {
            DeskSettingsGroup(title: "共享状态") {
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

            Text("在控制端的新建连接填入此地址。端口和配对码可在「本机共享」查看。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        accountActions
    }

    private var deviceCard: some View {
        DeskSurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DeskPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(DeskPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("本机设备")
                            .font(.system(size: 13.5, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        DeskPillBadge(text: status, symbol: "circle.fill", tint: statusTint)
                        if let message = tailnet.message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(DeskPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }

                if let connectionAddress {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("QuietDesk 连接地址")
                            .font(.system(size: 12))
                            .foregroundStyle(DeskPalette.secondary)
                        Text(connectionAddress)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var accountActions: some View {
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
        .disabled(tailnet.changingAccount)
    }
}
