import AppKit
import Charts
import QuietDeskCore
import SwiftUI

struct ConnectionDiagnosticReportView: View {
    let report: ConnectionDiagnosticReport
    @State private var showRoutes = false
    @State private var selectedTime: Double?

    private var selection: DiagnosticTimeBucket? {
        guard let selectedTime else { return nil }
        return report.timeline.first { $0.start <= selectedTime && selectedTime < $0.end }
            ?? (selectedTime == report.duration ? report.timeline.last : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 23, weight: .medium)).foregroundStyle(.teal)
                        .frame(width: 44, height: 44)
                        .background(.teal.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("连接诊断报告").font(.title2.bold())
                        Text(report.remoteName.isEmpty ? "远程连接" : report.remoteName)
                            .font(.callout).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("连接总时长").font(.caption).foregroundStyle(.secondary)
                        Text(elapsed(report.duration)).font(.title2.weight(.medium)).monospacedDigit()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Label(report.startedAt.formatted(date: .abbreviated, time: .standard), systemImage: "clock")
                        .fixedSize().help("本次连接开始时间")
                    Text(report.reason).lineLimit(3).textSelection(.enabled).help(report.reason)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)

            Picker("报告内容", selection: $showRoutes) {
                Text("质量趋势").tag(false)
                Text("路径对比").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .fixedSize().padding(.horizontal, 22).padding(.bottom, 12)
            Divider()
            ScrollView {
                if showRoutes {
                    routeComparison
                } else {
                    trends
                }
            }
            .id(showRoutes)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 600, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trends: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selection.map { "区间 " + elapsed($0.start) + " – " + elapsed($0.end) } ?? "整个连接时段")
                    .font(.headline).monospacedDigit()
                Spacer()
                if selection != nil {
                    Button("查看全程") { selectedTime = nil }.buttonStyle(.link)
                } else {
                    Text("点按图表查看区间").font(.caption).foregroundStyle(.secondary)
                }
            }

            let commonDomain = 0...max(0.001, report.duration)
            VStack(alignment: .leading, spacing: 10) {
                Text("视频路径").font(.callout.weight(.semibold))
                Chart(report.timeline, id: \.start) { bucket in
                    RectangleMark(xStart: .value("开始", bucket.start), xEnd: .value("结束", bucket.end))
                        .foregroundStyle(pathBandColor(bucket))
                        .accessibilityLabel(Text(elapsed(bucket.start) + " – " + elapsed(bucket.end)))
                        .accessibilityValue(Text(pathList(bucket)))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartXScale(domain: commonDomain, range: .plotDimension(padding: 0))
                .selectDiagnosticTime($selectedTime)
                .frame(height: 10)
                .padding(.leading, 50)
                .accessibilityLabel("视频路径时间轴")
                if let selection {
                    Text(pathList(selection)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled).help(pathList(selection))
                } else {
                    let colors = Set(report.timeline.map(pathBandColor))
                    HStack(spacing: 14) {
                        if colors.contains(.teal) { pathKey("直连", .teal) }
                        if colors.contains(.indigo) { pathKey("中继", .indigo) }
                        if colors.contains(.purple) { pathKey("UDP 试传", .purple) }
                        if colors.contains(.gray) { pathKey("等待或暂停", .gray) }
                        if colors.contains(.orange) { pathKey("区间内有切换", .orange) }
                    }
                }
            }
            .padding(.bottom, 3)

            if report.totals.hasMeasurements {
                ForEach(ReportMetric.allCases) { metric in
                    trendRow(metric, domain: commonDomain)
                }
            } else {
                ContentUnavailableView("没有质量样本", systemImage: "waveform.path.ecg",
                                       description: Text("可在「路径对比」查看本次尝试的路径和用时。"))
            }
            HStack {
                Text(elapsed(0)); Spacer(); Text(elapsed(report.duration / 2)); Spacer(); Text(elapsed(report.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .padding(.leading, 50)
            if report.totals.hasMeasurements {
                Divider().padding(.vertical, 2)
                Text("图中显示各区间的均值，空白表示没有观测。控制 RTT 来自控制通道，UDP 视频 RTT 取自已启用的 UDP 视频路径。分片丢失率含 UDP 试传期间已结算的分片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendRow(_ metric: ReportMetric, domain: ClosedRange<Double>) -> some View {
        let summary = selection?.quality ?? report.totals
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title).font(.callout.weight(.semibold))
                Spacer()
                if let peak = metric.peak(summary) {
                    Text("最高 " + metric.format(peak)).font(.caption).foregroundStyle(.secondary)
                }
                Text(metric.value(summary).map { "平均 " + metric.format($0) } ?? "无样本")
                    .font(.callout).foregroundStyle(metric.value(summary) == nil ? .secondary : .primary)
            }
            .monospacedDigit()
            if metric.value(report.totals) != nil {
                let highest = report.timeline.compactMap { metric.value($0.quality) }.max() ?? 0
                let ceiling = highest > 0 ? highest : 1
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(metric.number(ceiling))
                        Spacer()
                        Text("0")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    Chart {
                        RuleMark(y: .value("零", 0)).foregroundStyle(.secondary.opacity(0.22))
                        ForEach(report.timeline, id: \.start) { bucket in
                            if let value = metric.value(bucket.quality) {
                                RectangleMark(xStart: .value("起点", bucket.start), xEnd: .value("终点", bucket.end),
                                              yStart: .value("零", 0), yEnd: .value(metric.title, value))
                                    .foregroundStyle(metric.color.opacity(0.20))
                                    .accessibilityHidden(true)
                                RuleMark(xStart: .value("起点", bucket.start), xEnd: .value("终点", bucket.end),
                                         y: .value(metric.title, value))
                                    .foregroundStyle(metric.color).lineStyle(StrokeStyle(lineWidth: 2))
                                    .accessibilityLabel(Text(elapsed(bucket.start) + " – " + elapsed(bucket.end)))
                                    .accessibilityValue(Text(metric.format(value)))
                            }
                        }
                        if let selection {
                            RuleMark(x: .value("选中区间", (selection.start + selection.end) / 2))
                                .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartXScale(domain: domain, range: .plotDimension(padding: 0))
                    .chartYScale(domain: 0...ceiling, range: .plotDimension(padding: 3))
                    .selectDiagnosticTime($selectedTime)
                    .accessibilityLabel(metric.title + "趋势")
                }
                .frame(height: 43)
            } else {
                Divider().padding(.vertical, 6)
            }
        }
        .help(metric.help)
    }

    private var routeComparison: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text("相同控制路径、视频路径和节点的时段合并统计。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(report.routes, id: \.route) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            Text(entry.route.media.title)
                        } icon: {
                            Image(systemName: entry.route.media.symbol).foregroundStyle(entry.route.media.color)
                        }.font(.headline)
                        Spacer()
                        if entry.visits > 1 { Text("共 \(entry.visits) 段").font(.caption).foregroundStyle(.secondary) }
                        Text(elapsed(entry.duration)).font(.headline.monospacedDigit())
                    }
                    Text(entry.route.detail)
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.quality.hasMeasurements {
                        Divider()
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(ReportMetric.allCases) { metric in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(metric.shortTitle).font(.caption).foregroundStyle(.secondary)
                                    Text(metric.value(entry.quality).map(metric.format) ?? "—")
                                        .font(.callout.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(metric.help)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
            }
            Text("指标显示该路径的平均实测值。UDP 分片丢失率按已结算的分片数计算，破折号表示没有观测。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func pathKey(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.caption)
        }
    }

    private func pathBandColor(_ bucket: DiagnosticTimeBucket) -> Color {
        if bucket.routes.count > 1 { return .orange }
        return bucket.routes.keys.first?.media.color ?? .clear
    }

    private func pathList(_ bucket: DiagnosticTimeBucket) -> String {
        bucket.routes.keys.map { $0.media.title + " · " + $0.detail }.sorted().joined(separator: " / ")
    }

    private func elapsed(_ interval: TimeInterval) -> String {
        if interval > 0 && interval < 1 { return interval.formatted(.number.precision(.fractionLength(2))) + " 秒" }
        let seconds = Int(interval)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private extension View {
    func selectDiagnosticTime(_ time: Binding<Double?>) -> some View {
        chartXSelection(value: time)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
            }
    }
}

private enum ReportMetric: CaseIterable, Identifiable {
    case controlRTT, udpRTT, loss, throughput, frameRate
    var id: Self { self }

    var title: String {
        switch self {
        case .controlRTT: return "控制 RTT"
        case .udpRTT: return "UDP 视频 RTT"
        case .loss: return "UDP 分片丢失率"
        case .throughput: return "应用层吞吐"
        case .frameRate: return "解码帧率"
        }
    }

    var shortTitle: String {
        self == .loss ? "UDP 丢失率" : title
    }

    var color: Color {
        switch self {
        case .controlRTT: return .indigo
        case .udpRTT: return .teal
        case .loss: return .orange
        case .throughput: return .blue
        case .frameRate: return .green
        }
    }

    var help: String {
        switch self {
        case .controlRTT: return "控制通道的端到端往返时间"
        case .udpRTT: return "视频 UDP 通道实测的往返时间"
        case .loss: return "错过 UDP 重排窗口的分片占已结算分片的比例，含后续补回的分片"
        case .throughput: return "已连接期间控制、视频和剪贴板等应用层通道的收发总量除以采样时长"
        case .frameRate: return "采样期间本机每秒解码的画面帧数"
        }
    }

    func value(_ quality: DiagnosticQuality) -> Double? {
        switch self {
        case .controlRTT: return quality.roundTrip.mean
        case .udpRTT: return quality.udpRoundTrip.mean
        case .loss: return quality.loss.mean.map { $0 * 100 }
        case .throughput: return quality.megabitsPerSecond
        case .frameRate: return quality.framesPerSecond
        }
    }

    func peak(_ quality: DiagnosticQuality) -> Double? {
        switch self {
        case .controlRTT: return quality.roundTrip.maximum
        case .udpRTT: return quality.udpRoundTrip.maximum
        case .loss: return quality.loss.maximum.map { $0 * 100 }
        default: return nil
        }
    }

    func format(_ value: Double) -> String {
        let unit: String
        switch self {
        case .controlRTT, .udpRTT: unit = " ms"
        case .loss: unit = "%"
        case .throughput: unit = " Mbps"
        case .frameRate: unit = " fps"
        }
        return number(value) + unit
    }

    func number(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<0.01" }
        return value.formatted(.number.precision(.fractionLength(0...(value < 1 ? 2 : 1))))
    }
}

private extension DiagnosticQuality {
    var hasMeasurements: Bool { ReportMetric.allCases.contains { $0.value(self) != nil } }
}

private extension DiagnosticRoute {
    var detail: String {
        let path: String
        switch control {
        case .unavailable: path = "控制通道未建立"
        case .direct: path = "控制通道直连"
        case .relay: path = "控制通道经中继"
        }
        return node.map { path + (control == .unavailable ? " · 尝试节点 " : " · 节点 ") + $0 } ?? path
    }
}

private extension DiagnosticRoute.Media {
    var title: String {
        switch self {
        case .negotiating: return "正在建立连接"
        case .reconnecting: return "等待重连"
        case .paused: return "画面暂停"
        case .udpTrial: return "UDP 视频试传"
        case .directCompatibleTCP: return "直连 TCP · 兼容模式"
        case .relayCompatibleTCP: return "中继 TCP · 兼容模式"
        case .directTCP: return "直连 TCP 视频"
        case .relayTCP: return "中继 TCP 视频"
        case .directUDP: return "直连 UDP 视频"
        case .relayUDP: return "中继 UDP 视频"
        case .punchedUDP: return "打洞直连 UDP 视频"
        }
    }

    var symbol: String {
        switch self {
        case .negotiating, .reconnecting: return "clock"
        case .paused: return "pause.circle"
        case .udpTrial: return "waveform"
        case .relayCompatibleTCP, .relayTCP, .relayUDP: return "server.rack"
        default: return "arrow.left.arrow.right"
        }
    }

    var color: Color {
        switch self {
        case .negotiating, .reconnecting, .paused: return .gray
        case .udpTrial: return .purple
        case .relayCompatibleTCP, .relayTCP, .relayUDP: return .indigo
        default: return .teal
        }
    }
}
