import AppKit
import QuietDeskCore
import SwiftUI

struct TrafficStatisticsView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var history: TrafficHistoryFeed
    let done: () -> Void
    var embedded: Bool = false
    @State private var selectedEndpoint: TrafficEndpoint?

    private var selectedRecord: EndpointTrafficRecord? {
        history.records.first { $0.id == selectedEndpoint }
    }

    private var totalSent: Decimal {
        history.records.reduce(Decimal.zero) { $0 + Decimal($1.sentBytes) }
    }

    private var totalReceived: Decimal {
        history.records.reduce(Decimal.zero) { $0 + Decimal($1.receivedBytes) }
    }

    private var totalCombined: Decimal {
        history.records.reduce(Decimal.zero) { $0 + $1.totalBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if !embedded {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("地址历史流量")
                        .font(embedded ? .system(size: 15, weight: .bold) : .title3.weight(.semibold))
                    Text("\(model.trafficHistoryStatus) · 本机视角（1 KB = 1000 字节）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DeskInfoPopoverButton(
                    title: "流量统计口径说明",
                    lines: [
                        "控制端按填写的目标地址＋端口累计；被控端按控制端来源 IP＋本机监听端口累计。",
                        "不同端口分别统计，域名与 IP 不自动合并；仅含应用层收发，不含 TCP/TLS 包头开销。",
                        "移除连接记录不会删除对应的历史流量记录。"
                    ],
                    label: "统计说明"
                )
            }

            if !history.records.isEmpty {
                HStack(spacing: 12) {
                    summaryCard(title: "统计地址数", value: "\(history.records.count) 个", tint: .secondary)
                    summaryCard(title: "累计本机发送", value: trafficAmount(totalSent), tint: .accentColor)
                    summaryCard(title: "累计本机接收", value: trafficAmount(totalReceived), tint: DeskPalette.emerald)
                    summaryCard(title: "应用层总计", value: trafficAmount(totalCombined), tint: .primary)
                }
            }

            if let error = history.error {
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
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if history.records.isEmpty {
                ContentUnavailableView {
                    Label("暂无地址流量记录", systemImage: "chart.bar.xaxis")
                } description: {
                    Text(history.error == nil
                         ? "按网址/IP＋端口自动累计，首次建立连接后开始记录。"
                         : "当前没有可显示的统计，详细原因见上方提示。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                }
            } else {
                Table(history.records, selection: $selectedEndpoint) {
                    TableColumn("网址/IP＋端口") { record in
                        Label {
                            Text(record.endpoint.label)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "network").foregroundStyle(.secondary)
                        }
                        .help(record.endpoint.label)
                    }
                    .width(min: 220, ideal: 290, max: 440)
                    TableColumn("本机发送") { record in
                        Text(trafficAmount(Decimal(record.sentBytes)))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确发送：" + String(record.sentBytes) + " 字节")
                    }
                    .width(110)
                    TableColumn("本机接收") { record in
                        Text(trafficAmount(Decimal(record.receivedBytes)))
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确接收：" + String(record.receivedBytes) + " 字节")
                    }
                    .width(110)
                    TableColumn("合计") { record in
                        Text(trafficAmount(record.totalBytes))
                            .fontWeight(.medium)
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .help("精确合计：\(NSDecimalNumber(decimal: record.totalBytes).stringValue) 字节")
                    }
                    .width(110)
                }
                .tableStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !history.legacyRecords.isEmpty {
                DisclosureGroup("旧版按设备统计归档（\(history.legacyRecords.count) 项）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("旧记录未保存连接地址，原文件独立保留，不混入上方地址统计。")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                                GridRow {
                                    Text("设备").frame(maxWidth: .infinity, alignment: .leading)
                                    Text("本机发送"); Text("本机接收"); Text("合计")
                                }.font(.caption.weight(.medium))
                                ForEach(history.legacyRecords) { record in
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
                        }.frame(maxHeight: 120)
                    }.padding(.top, 6)
                }
                .font(.caption)
            }

            HStack {
                if let selectedRecord {
                    Text("首次统计：\(selectedRecord.firstSeen.formatted(date: .abbreviated, time: .shortened)) · 最近连接：\(selectedRecord.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(history.records.isEmpty ? "从建立连接开始自动记录。" : "点选任意地址行可查看首次统计与最近连接时间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !embedded {
                    Button("完成", action: done)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, embedded ? 26 : 20)
        .padding(.vertical, embedded ? 16 : 20)
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.flushTrafficHistory() }
        .onDisappear { model.flushTrafficHistory() }
        .onExitCommand {
            if !embedded { done() }
        }
    }

    private func summaryCard(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
        }
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
