import AppKit
import QuietDeskCore
import SwiftUI

struct TrafficStatisticsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    @State private var selectedEndpoint: TrafficEndpoint?

    private var selectedRecord: EndpointTrafficRecord? {
        model.trafficHistory.first { $0.id == selectedEndpoint }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 21)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("地址历史流量").font(.title3.weight(.semibold))
                    Text("本机视角 · 包含当前连接 · 1 KB = 1000 字节")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(model.trafficHistoryStatus)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.trafficHistoryError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ScrollView {
                        Text(error).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 34)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }

            if model.trafficHistory.isEmpty {
                ContentUnavailableView {
                    Label("暂无地址流量", systemImage: "desktopcomputer")
                } description: {
                    Text(model.trafficHistoryError == nil
                         ? "按网址/IP＋端口累计，建立连接后开始记录。"
                         : "当前没有可显示的统计，详细原因见上方提示。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.trafficHistory, selection: $selectedEndpoint) {
                    TableColumn("网址/IP＋端口") { record in
                        Label {
                            Text(record.endpoint.label).textSelection(.enabled).lineLimit(1)
                        } icon: {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        }
                        .help(record.endpoint.label)
                    }
                    .width(min: 200, ideal: 260, max: 360)
                    TableColumn("本机发送") { record in
                        Text(trafficAmount(Decimal(record.sentBytes)))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确发送：" + String(record.sentBytes) + " 字节")
                    }
                    .width(100)
                    TableColumn("本机接收") { record in
                        Text(trafficAmount(Decimal(record.receivedBytes)))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确接收：" + String(record.receivedBytes) + " 字节")
                    }
                    .width(100)
                    TableColumn("合计") { record in
                        Text(trafficAmount(record.totalBytes))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确合计：\(NSDecimalNumber(decimal: record.totalBytes).stringValue) 字节")
                    }
                    .width(100)
                }
                .tableStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !model.legacyTrafficHistory.isEmpty {
                DisclosureGroup("旧版按设备统计（\(model.legacyTrafficHistory.count) 项）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("旧记录未保存连接地址，无法拆分到网址/IP＋端口；原文件保留，以下数值不混入新增地址统计。")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                GridRow {
                                    Text("设备").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("本机发送"); Text("本机接收"); Text("合计")
                                }.font(.caption.weight(.medium))
                                ForEach(model.legacyTrafficHistory) { record in
                                    GridRow {
                                        Text(record.name).lineLimit(1)
                                            .help("\(record.name)\n首次统计：\(record.firstSeen.formatted(date: .abbreviated, time: .shortened))\n最近连接：\(record.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(trafficAmount(Decimal(record.sentBytes))).monospacedDigit()
                                        Text(trafficAmount(Decimal(record.receivedBytes))).monospacedDigit()
                                        Text(trafficAmount(record.totalBytes)).monospacedDigit()
                                    }.font(.caption)
                                }
                            }
                        }.frame(maxHeight: 130)
                    }.padding(.top, 6)
                }
            }

            Group {
                if let selectedRecord {
                    HStack(spacing: 16) {
                        Text("首次统计：\(selectedRecord.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        Spacer(minLength: 0)
                        Text("最近连接：\(selectedRecord.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    }
                } else {
                    Text(model.trafficHistory.isEmpty ? "从建立连接开始记录。" : "选择地址查看首次统计和最近连接时间。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(height: 18, alignment: .topLeading)

            Divider()
            Text("控制端按填写的地址＋目标端口累计；被控端按控制端来源 IP＋本机监听端口累计。不同端口分别统计，域名与 IP 不自动合并。仅含应用层收发，不含 TCP/TLS 开销；移除连接记录不删除历史。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("完成", action: done)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.flushTrafficHistory() }
        .onDisappear { model.flushTrafficHistory() }
        .onExitCommand(perform: done)
    }

    private func trafficAmount(_ bytes: Decimal) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = NSDecimalNumber(decimal: bytes).doubleValue
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        return amount.formatted(.number.precision(.fractionLength(0...(unit == 0 ? 0 : 2)))) + " " + units[unit]
    }
}
