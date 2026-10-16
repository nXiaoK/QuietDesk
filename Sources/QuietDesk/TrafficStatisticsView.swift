import AppKit
import QuietDeskCore
import SwiftUI

struct TrafficStatisticsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void
    @State private var selectedDeviceID: UUID?

    private var selectedDevice: DeviceTrafficRecord? {
        model.trafficHistory.first { $0.id == selectedDeviceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 21)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("设备历史流量").font(.title3.weight(.semibold))
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
                    Label("暂无设备流量", systemImage: "desktopcomputer")
                } description: {
                    Text(model.trafficHistoryError == nil
                         ? "与新版 QuietDesk 设备建立连接后，会在这里持续累计。"
                         : "当前没有可显示的统计，详细原因见上方提示。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.trafficHistory, selection: $selectedDeviceID) {
                    TableColumn("设备") { record in
                        Label {
                            Text(record.name).lineLimit(1)
                        } icon: {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        }
                        .help("\(record.name)\n设备标识：\(record.id.uuidString)")
                    }
                    .width(min: 140, ideal: 180, max: 220)
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

            Group {
                if let selectedDevice {
                    HStack(spacing: 16) {
                        Text("首次统计：\(selectedDevice.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        Spacer(minLength: 0)
                        Text("最近连接：\(selectedDevice.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    }
                } else {
                    Text(model.trafficHistory.isEmpty ? "从建立可识别的连接开始记录。" : "选择设备查看首次统计和最近连接时间。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(height: 18, alignment: .topLeading)

            Divider()
            Text("累计本机与该设备已识别连接的应用层收发，不含 TCP、TLS 等开销。旧版未记录的流量无法追溯，双方新版才能识别；同一设备更换地址仍持续累计，移除连接记录不影响此历史。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("完成", action: done)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 500)
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
