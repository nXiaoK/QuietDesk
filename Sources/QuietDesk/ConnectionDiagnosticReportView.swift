import AppKit
import Charts
import QuietDeskCore
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionDiagnosticReportView: View {
    private enum Tab { case overview, trends, routes }
    private struct TrafficRow {
        let title: String
        let bucket: DiagnosticTrafficBucket
        var color: Color? = nil
    }

    let report: ConnectionDiagnosticReport
    @State private var tab: Tab = .overview
    @State private var selectedTime: Double?
    @State private var actionFeedback: String?
    @State private var exporting = false

    private var selection: DiagnosticTimeBucket? {
        guard let selectedTime else { return nil }
        return report.timeline.first { $0.start <= selectedTime && selectedTime < $0.end }
            ?? (selectedTime == report.duration ? report.timeline.last : nil)
    }

    private var pausedSeconds: TimeInterval {
        report.routes.filter { $0.route.media == .paused }.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .overview: overview
                    case .trends: trends
                    case .routes: routeComparison
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(tab)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tab == .trends, let selection {
                    intervalSummary(selection)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(DeskPalette.canvasBackground)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .background(DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接诊断报告")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(DeskPalette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(report.diagnosticDisplayName)
                        .font(.system(size: 13))
                        .foregroundStyle(DeskPalette.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("连接总时长")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                    Text(DiagnosticReportFormat.elapsed(report.duration))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                }
            }

            HStack(spacing: 10) {
                DeskSegmentedTabs(
                    tabs: [(.overview, "总览与流量"), (.trends, "帧率与趋势"), (.routes, "路径对比")],
                    selection: $tab
                )
                .frame(maxWidth: 335)

                Spacer(minLength: 4)

                Button("复制报告摘要", action: copySummary)
                    .buttonStyle(DeskButtonStyle(.quiet))
                Button("导出 JSON…", action: exportJSON)
                    .buttonStyle(DeskButtonStyle(.quiet))
                    .disabled(exporting)
            }
            if let actionFeedback {
                Text(actionFeedback)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                overviewMetrics(columns: 5).frame(minWidth: 860)
                overviewMetrics(columns: 3)
            }
            trafficComposition
            frameAnalysis
        }
    }

    private func overviewMetrics(columns: Int) -> some View {
        let traffic = report.traffic
        let frames = report.frameRate
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            overviewMetric("连接总时长", DiagnosticReportFormat.elapsed(report.duration)) {
                Text("开始 " + DiagnosticReportFormat.date(report.startedAt))
                Text("结束 " + DiagnosticReportFormat.date(report.endedAt))
                Text(report.reason)
                    .help(report.reason)
            }
            overviewMetric("本次总流量", DiagnosticReportFormat.bytes(traffic.totalBytes)) {
                Text(trafficDirections(traffic.totalSentBytes, traffic.totalReceivedBytes))
            }
            overviewMetric("中转消耗流量", DiagnosticReportFormat.bytes(traffic.relayedBytes), tint: .indigo) {
                Text("占总流量 " + DiagnosticReportFormat.share(traffic.relayShareFraction))
            }
            overviewMetric("打洞直连流量", DiagnosticReportFormat.bytes(traffic.punchedBytes), tint: ReportPathColor.punched) {
                if let saved = traffic.punchedSavedRelayFraction {
                    Text("为中转省流 " + DiagnosticReportFormat.share(saved))
                }
            }
            .help("含自托管中继打洞直连及 Tailscale P2P 直连。")
            overviewMetric("活跃帧率与波动", DiagnosticReportFormat.fps(frames.activeMeanFPS)) {
                Text(DiagnosticReportFormat.fpsRange(frames))
                DiagnosticStabilityBadge(stats: frames)
            }
        }
    }

    private func overviewMetric<Detail: View>(
        _ title: String, _ value: String, tint: Color = DeskPalette.ink, @ViewBuilder detail: () -> Detail
    ) -> some View {
        let detailContent = detail()
        return DeskSurfaceCard(padding: 12, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DeskPalette.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                VStack(alignment: .leading, spacing: 4) { detailContent }
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        }
    }

    private var trafficComposition: some View {
        let traffic = report.traffic
        let pathRows = trafficRows(traffic)
        return DeskSurfaceCard(padding: 16, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionTitle("流量构成")
                    Spacer()
                    DeskInfoPopoverButton(
                        title: "流量统计口径",
                        lines: [
                            "TCP、原生直连 UDP 和 Tailscale UDP 均记录应用层实际收发。",
                            "自托管中继与打洞直连 UDP 记录对应路径上的 DTLS 数据报载荷。",
                            "Tailscale 底层路径按定期探测结果归类，未获得结果时计入未知路径。"
                        ],
                        label: "统计口径"
                    )
                }
                if traffic.totalBytes > 0 {
                    trafficPathBar(pathRows)
                }
                trafficTable("按传输路径", rows: pathRows)
                Divider()
                trafficTable("按传输协议", rows: [
                    TrafficRow(title: "TCP", bucket: traffic.tcp),
                    TrafficRow(title: "UDP", bucket: traffic.udp)
                ])
                Divider()
                trafficTable("按业务通道", rows: [
                    TrafficRow(title: "视频与媒体", bucket: traffic.videoChannel),
                    TrafficRow(title: "控制与交互", bucket: traffic.controlChannel),
                    TrafficRow(title: "文件与剪贴板", bucket: traffic.bulkChannel)
                ])
            }
        }
    }

    private func trafficRows(_ traffic: DiagnosticTrafficBreakdown) -> [TrafficRow] {
        [
            TrafficRow(title: "原生直连 TCP", bucket: traffic.directTCP, color: ReportPathColor.direct),
            TrafficRow(title: "原生直连 UDP", bucket: traffic.directUDP, color: ReportPathColor.direct),
            TrafficRow(title: "打洞直连 UDP", bucket: traffic.punchedUDP, color: ReportPathColor.punched),
            TrafficRow(title: "自托管中继 TCP", bucket: traffic.relayTCP, color: ReportPathColor.relay),
            TrafficRow(title: "自托管中继 UDP", bucket: traffic.relayUDP, color: ReportPathColor.relay),
            TrafficRow(title: "Tailscale P2P 直连 TCP", bucket: traffic.tailnetDirectTCP, color: ReportPathColor.tailnetDirect),
            TrafficRow(title: "Tailscale P2P 直连 UDP", bucket: traffic.tailnetDirectUDP, color: ReportPathColor.tailnetDirect),
            TrafficRow(title: "Tailscale DERP 中转 TCP", bucket: traffic.tailnetDERPTCP, color: ReportPathColor.tailnetRelay),
            TrafficRow(title: "Tailscale DERP 中转 UDP", bucket: traffic.tailnetDERPUDP, color: ReportPathColor.tailnetRelay),
            TrafficRow(title: "Tailscale 未知路径 TCP", bucket: traffic.tailnetUnknownTCP, color: ReportPathColor.tailnetUnknown),
            TrafficRow(title: "Tailscale 未知路径 UDP", bucket: traffic.tailnetUnknownUDP, color: ReportPathColor.tailnetUnknown)
        ]
        .filter { $0.bucket.totalBytes > 0 }
    }

    private func trafficPathBar(_ rows: [TrafficRow]) -> some View {
        let total = rows.reduce(0.0) { $0 + Double($1.bucket.totalBytes) }
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(rows, id: \.title) { row in
                    Rectangle()
                        .fill(row.color ?? DeskPalette.secondary)
                        .frame(width: geometry.size.width * (Double(row.bucket.totalBytes) / total))
                        .help(row.title + " · " + DiagnosticReportFormat.bytes(row.bucket.totalBytes))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func trafficTable(_ title: String, rows: [TrafficRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("暂无路径流量")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("分类").frame(maxWidth: .infinity, alignment: .leading)
                        Text("本机发送")
                        Text("本机接收")
                        Text("合计")
                        Text("占比")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DeskPalette.secondary)

                    ForEach(rows, id: \.title) { row in
                        GridRow {
                            HStack(spacing: 6) {
                                if let color = row.color {
                                    Circle().fill(color).frame(width: 7, height: 7)
                                        .accessibilityHidden(true)
                                }
                                Text(row.title)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            tableAmount(row.bucket.sentBytes)
                            tableAmount(row.bucket.receivedBytes)
                            tableAmount(row.bucket.totalBytes).fontWeight(.semibold)
                            Text(DiagnosticReportFormat.share(
                                report.traffic.totalBytes > 0
                                    ? Double(row.bucket.totalBytes) / Double(report.traffic.totalBytes) : nil
                            ))
                        }
                        .font(.system(size: 12))
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    private func tableAmount(_ amount: UInt64) -> some View {
        Text(DiagnosticReportFormat.bytes(amount))
            .help(amount.formatted() + " 字节")
    }

    private var frameAnalysis: some View {
        let frames = report.frameRate
        let stats = [
            ("活跃平均帧率", DiagnosticReportFormat.fps(frames.activeMeanFPS)),
            ("最高帧率", DiagnosticReportFormat.fps(frames.maximumFPS)),
            ("活跃最低帧率", DiagnosticReportFormat.fps(frames.minimumActiveFPS)),
            ("P10 低帧率", DiagnosticReportFormat.fps(frames.p10LowFPS)),
            ("帧率标准差", DiagnosticReportFormat.fps(frames.standardDeviationFPS)),
            ("明显掉帧事件", "\(frames.dropEvents) 次"),
            ("活跃出帧", DiagnosticReportFormat.elapsed(frames.activeSeconds)),
            ("静止 / 暂停",
             DiagnosticReportFormat.elapsed(frames.idleSeconds) + " / " + DiagnosticReportFormat.elapsed(pausedSeconds))
        ]
        return DeskSurfaceCard(padding: 16, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionTitle("帧率波动分析")
                    Spacer(minLength: 0)
                    DiagnosticStabilityBadge(stats: frames)
                }
                valuesGrid(stats)
                Text("帧率波动计入至少半秒且有新解码帧的采样。P10 按活跃样本的帧率分档计算。")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
            }
        }
    }

    private var trends: some View {
        let domain = 0...max(0.001, report.duration)
        return VStack(alignment: .leading, spacing: 14) {
            DeskSurfaceCard(padding: 16, cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 14) {
                    pathTimeline(domain)
                    if report.totals.hasMeasurements {
                        ForEach(ReportMetric.allCases) { metric in
                            trendRow(metric, domain: domain)
                        }
                    } else {
                        Text("暂无帧率或链路质量样本")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                    HStack {
                        Text(DiagnosticReportFormat.elapsed(0))
                        Spacer()
                        Text(DiagnosticReportFormat.elapsed(report.duration / 2))
                        Spacer()
                        Text(DiagnosticReportFormat.elapsed(report.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DeskPalette.secondary)
                    .padding(.leading, 50)
                }
            }

            if report.totals.hasMeasurements {
                Text("帧率带表示区间内活跃最低到最高帧率，虚线表示全程活跃平均。RTT 和分片丢失率按各自通道的实测样本汇总。")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
            }
        }
    }

    private func pathTimeline(_ domain: ClosedRange<Double>) -> some View {
        let colors = Set(report.timeline.map(pathBandColor))
        let legend = [
            ("原生直连", ReportPathColor.direct), ("打洞直连", ReportPathColor.punched),
            ("自托管中继", ReportPathColor.relay), ("Tailscale P2P", ReportPathColor.tailnetDirect),
            ("Tailscale DERP", ReportPathColor.tailnetRelay), ("Tailscale 未知", ReportPathColor.tailnetUnknown),
            ("UDP 试传", Color.purple), ("等待或暂停", Color.gray), ("区间内切换", Color.orange)
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("视频路径时间轴").font(.system(size: 13, weight: .semibold))
                Spacer()
                if selection == nil {
                    Text("点按时间轴或图表查看区间")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                }
            }
            Chart {
                ForEach(report.timeline, id: \.start) { bucket in
                    RectangleMark(xStart: .value("开始", bucket.start), xEnd: .value("结束", bucket.end))
                        .foregroundStyle(pathBandColor(bucket))
                        .accessibilityLabel(Text(intervalLabel(bucket)))
                        .accessibilityValue(Text(pathList(bucket)))
                }
                if let selection {
                    RuleMark(x: .value("选中区间", (selection.start + selection.end) / 2))
                        .foregroundStyle(DeskPalette.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .accessibilityHidden(true)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartXScale(domain: domain, range: .plotDimension(padding: 0))
            .selectDiagnosticTime($selectedTime)
            .frame(height: 12)
            .padding(.leading, 50)
            .accessibilityLabel("视频路径时间轴")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 5, alignment: .leading)], spacing: 6) {
                ForEach(legend.filter { colors.contains($0.1) }, id: \.0) { label, color in
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(label).font(.caption).foregroundStyle(DeskPalette.secondary)
                    }
                }
            }
        }
    }

    private func intervalSummary(_ bucket: DiagnosticTimeBucket) -> some View {
        let traffic = bucket.quality.traffic
        let frames = bucket.quality.frameRate
        return DeskSurfaceCard(padding: 14, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("区间 " + intervalLabel(bucket))
                    Spacer()
                    Button("查看全程") { selectedTime = nil }
                        .buttonStyle(DeskButtonStyle(.quiet))
                }
                Text(pathList(bucket))
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(pathList(bucket))
                valuesGrid([
                    ("TCP 用量", DiagnosticReportFormat.bytes(traffic.tcpBytes)),
                    ("UDP 用量", DiagnosticReportFormat.bytes(traffic.udpBytes)),
                    ("中转用量", DiagnosticReportFormat.bytes(traffic.relayedBytes)),
                    ("打洞直连用量", DiagnosticReportFormat.bytes(traffic.punchedBytes)),
                    ("最低帧率", DiagnosticReportFormat.fps(frames.minimumActiveFPS)),
                    ("活跃平均帧率", DiagnosticReportFormat.fps(frames.activeMeanFPS)),
                    ("最高帧率", DiagnosticReportFormat.fps(frames.maximumFPS))
                ])
            }
        }
    }

    private func trendRow(_ metric: ReportMetric, domain: ClosedRange<Double>) -> some View {
        let summary = selection?.quality ?? report.totals
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let peak = metric.peak(summary) {
                    Text("最高 " + metric.format(peak)).font(.caption).foregroundStyle(DeskPalette.secondary)
                }
                Text(metric.value(summary).map { "平均 " + metric.format($0) } ?? "无样本")
                    .font(.system(size: 13))
                    .foregroundStyle(metric.value(summary) == nil ? DeskPalette.secondary : DeskPalette.ink)
            }
            .monospacedDigit()
            if metric.value(report.totals) != nil {
                let ceiling = max(1, report.timeline.compactMap { bucket in
                    metric == .frameRate ? bucket.quality.frameRate.maximumFPS : metric.value(bucket.quality)
                }.max() ?? 0)
                HStack(spacing: 6) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(metric.number(ceiling))
                        Spacer()
                        Text("0")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(DeskPalette.secondary)
                    .frame(width: 44, alignment: .trailing)
                    Chart {
                        RuleMark(y: .value("零", 0)).foregroundStyle(.secondary.opacity(0.22))
                        ForEach(report.timeline, id: \.start) { bucket in
                            trendMarks(metric, bucket: bucket)
                        }
                        if metric == .frameRate, let mean = report.frameRate.activeMeanFPS {
                            RuleMark(y: .value("全程活跃平均", mean))
                                .foregroundStyle(metric.color.opacity(0.75))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
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
                .frame(height: metric == .frameRate ? 98 : 46)
            }
        }
        .help(metric.help)
    }

    @ChartContentBuilder
    private func trendMarks(_ metric: ReportMetric, bucket: DiagnosticTimeBucket) -> some ChartContent {
        if let value = metric.value(bucket.quality) {
            let minimum = metric == .frameRate ? bucket.quality.frameRate.minimumActiveFPS ?? value : 0
            let maximum = metric == .frameRate ? bucket.quality.frameRate.maximumFPS ?? value : value
            RectangleMark(xStart: .value("起点", bucket.start), xEnd: .value("终点", bucket.end),
                          yStart: .value("最低", minimum), yEnd: .value("最高", maximum))
                .foregroundStyle(metric.color.opacity(metric == .frameRate ? 0.23 : 0.12))
                .accessibilityHidden(true)
            RuleMark(xStart: .value("起点", bucket.start), xEnd: .value("终点", bucket.end),
                     y: .value(metric.title, value))
                .foregroundStyle(metric.color).lineStyle(StrokeStyle(lineWidth: 1.4))
                .accessibilityLabel(Text(intervalLabel(bucket)))
                .accessibilityValue(Text(metric == .frameRate
                    ? metric.format(value) + " · " + DiagnosticReportFormat.fpsRange(bucket.quality.frameRate)
                    : metric.format(value)))
        }
    }

    private var routeComparison: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(report.routes, id: \.route) { entry in
                DeskSurfaceCard(padding: 16, cornerRadius: 10) {
                    routeDetail(entry)
                }
            }
        }
    }

    private func routeDetail(_ entry: DiagnosticRouteSummary) -> some View {
        let traffic = entry.quality.traffic
        let frames = entry.quality.frameRate
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(entry.route.media.title)
                } icon: {
                    Image(systemName: entry.route.media.symbol).foregroundStyle(entry.route.pathColor)
                }
                .font(.system(size: 15, weight: .semibold))
                Spacer()
                if entry.visits > 1 {
                    Text("共 \(entry.visits) 段").font(.caption).foregroundStyle(DeskPalette.secondary)
                }
                Text(DiagnosticReportFormat.elapsed(entry.duration))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            Text(entry.route.detail)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
                .textSelection(.enabled)
            if entry.quality.hasMeasurements {
                valuesGrid(ReportMetric.allCases.map { metric in
                    (metric.shortTitle, metric.value(entry.quality).map(metric.format) ?? "—")
                })
            }
            Divider()
            valuesGrid([
                ("总流量", DiagnosticReportFormat.bytes(traffic.totalBytes)),
                ("本机收发", trafficDirections(traffic.totalSentBytes, traffic.totalReceivedBytes)),
                ("中转用量", DiagnosticReportFormat.bytes(traffic.relayedBytes)),
                ("打洞直连用量", DiagnosticReportFormat.bytes(traffic.punchedBytes)),
                ("活跃帧率区间", DiagnosticReportFormat.fpsRange(frames)),
                ("帧率标准差", DiagnosticReportFormat.fps(frames.standardDeviationFPS))
            ])
        }
    }

    private func valuesGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 9) {
            ForEach(values, id: \.0) { title, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(DeskPalette.secondary)
                    Text(value).font(.system(size: 12, design: .monospaced)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DeskPalette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func trafficDirections(_ sent: UInt64, _ received: UInt64) -> String {
        "发 " + DiagnosticReportFormat.bytes(sent) + " / 收 " + DiagnosticReportFormat.bytes(received)
    }

    private func intervalLabel(_ bucket: DiagnosticTimeBucket) -> String {
        DiagnosticReportFormat.elapsed(bucket.start) + " – " + DiagnosticReportFormat.elapsed(bucket.end)
    }

    private func pathBandColor(_ bucket: DiagnosticTimeBucket) -> Color {
        if bucket.routes.count > 1 { return .orange }
        return bucket.routes.keys.first?.pathColor ?? .gray
    }

    private func pathList(_ bucket: DiagnosticTimeBucket) -> String {
        let paths = bucket.routes.keys.map { $0.media.title + " · " + $0.detail }.sorted()
        return paths.isEmpty ? "暂无路径观测" : paths.joined(separator: " / ")
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        actionFeedback = pasteboard.setString(report.plainTextSummary(), forType: .string)
            ? "报告摘要已复制" : "未能复制报告摘要"
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.title = "导出连接诊断报告"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "QuietDesk-connection-\(report.id.uuidString).json"
        actionFeedback = nil
        exporting = true
        panel.begin { response in
            exporting = false
            guard response == .OK, let destination = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: destination, options: .atomic)
                actionFeedback = "诊断报告已导出"
            } catch {
                actionFeedback = "导出失败，请检查保存位置和访问权限。"
            }
        }
    }
}

enum DiagnosticReportFormat {
    static func bytes(_ count: UInt64) -> String { bytes(Decimal(count)) }

    static func bytes(_ count: Decimal) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = count
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        return amount.formatted(.number.precision(.fractionLength(0...(unit == 0 ? 0 : 2)))) + " " + units[unit]
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "—" }
        if interval > 0, interval < 1 {
            return interval.formatted(.number.precision(.fractionLength(2))) + " 秒"
        }
        let seconds = Int(interval)
        if seconds >= 3600 {
            return String(format: "%lld:%02d:%02d", Int64(seconds / 3600), seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }

    static func fps(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " fps" } ?? "—"
    }

    static func fpsRange(_ stats: DiagnosticFrameRateStats) -> String {
        guard let minimum = stats.minimumActiveFPS, let maximum = stats.maximumFPS else { return "—" }
        return minimum.formatted(.number.precision(.fractionLength(0...1))) + " – " + fps(maximum)
    }

    static func share(_ fraction: Double?) -> String {
        fraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—"
    }
}

struct DiagnosticStabilityBadge: View {
    let stats: DiagnosticFrameRateStats

    var body: some View {
        DeskPillBadge(text: stats.stabilityLabel, tint: tint)
    }

    private var tint: Color {
        switch stats.stabilityLabel {
        case "稳定": return .teal
        case "轻微波动": return .blue
        case "明显波动": return .orange
        default: return DeskPalette.secondary
        }
    }
}

extension ConnectionDiagnosticReport {
    var diagnosticDisplayName: String {
        if remoteName.isEmpty { return endpointLabel.isEmpty ? "远程连接" : endpointLabel }
        return endpointLabel.isEmpty || endpointLabel == remoteName ? remoteName : remoteName + " · " + endpointLabel
    }
}

private enum ReportPathColor {
    static let direct = Color.teal
    static let punched = Color(red: 0, green: 0.58, blue: 0.72)
    static let relay = Color.indigo
    static let tailnetDirect = Color.blue
    static let tailnetRelay = Color(red: 0.72, green: 0.46, blue: 0.06)
    static let tailnetUnknown = Color(red: 0.32, green: 0.37, blue: 0.47)
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
    case frameRate, controlRTT, udpRTT, loss, throughput
    var id: Self { self }

    var title: String {
        switch self {
        case .controlRTT: return "控制 RTT"
        case .udpRTT: return "UDP 视频 RTT"
        case .loss: return "UDP 分片丢失率"
        case .throughput: return "应用层吞吐"
        case .frameRate: return "活跃解码帧率"
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
        case .frameRate: return "有新画面时，本机每秒解码的帧数"
        }
    }

    func value(_ quality: DiagnosticQuality) -> Double? {
        switch self {
        case .controlRTT: return quality.roundTrip.mean
        case .udpRTT: return quality.udpRoundTrip.mean
        case .loss: return quality.loss.mean.map { $0 * 100 }
        case .throughput: return quality.megabitsPerSecond
        case .frameRate: return quality.frameRate.activeMeanFPS
        }
    }

    func peak(_ quality: DiagnosticQuality) -> Double? {
        switch self {
        case .controlRTT: return quality.roundTrip.maximum
        case .udpRTT: return quality.udpRoundTrip.maximum
        case .loss: return quality.loss.maximum.map { $0 * 100 }
        case .frameRate: return quality.frameRate.maximumFPS
        case .throughput: return nil
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
    var pathColor: Color {
        switch media {
        case .negotiating, .reconnecting, .paused: return .gray
        case .udpTrial: return .purple
        case .relayCompatibleTCP, .relayTCP, .relayUDP: return ReportPathColor.relay
        case .punchedUDP: return ReportPathColor.punched
        case .directCompatibleTCP, .directTCP, .directUDP: return ReportPathColor.direct
        case .tailnetTCP, .tailnetCompatibleTCP, .tailnetUDP:
            switch tailnetPath {
            case "direct": return ReportPathColor.tailnetDirect
            case "derp": return ReportPathColor.tailnetRelay
            default: return ReportPathColor.tailnetUnknown
            }
        }
    }

    var detail: String {
        let path: String
        switch control {
        case .unavailable: path = "控制通道未建立"
        case .direct: path = "控制通道直连"
        case .relay: path = "控制通道经中继"
        case .tailnet:
            switch tailnetPath {
            case "direct": path = "控制通道经 Tailscale P2P 直连"
            case "derp": path = "控制通道经 Tailscale DERP 中转"
            default: path = "控制通道经 Tailscale · 底层路径未知"
            }
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
        case .tailnetUDP: return "Tailscale UDP 视频"
        case .tailnetTCP: return "Tailscale TCP 视频"
        case .tailnetCompatibleTCP: return "Tailscale TCP · 兼容模式"
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

}
