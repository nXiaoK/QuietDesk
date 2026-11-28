import AppKit
import QuietDeskCore
import SwiftUI

struct TrafficStatisticsView: View {
    private enum Tab { case reports, addresses }
    private enum HistoryAction {
        case delete(UUID)
        case clear

        var title: String {
            switch self {
            case .delete: return "删除这条诊断报告？"
            case .clear: return "清空连接诊断报告？"
            }
        }

        var buttonLabel: String {
            switch self {
            case .delete: return "删除"
            case .clear: return "清空"
            }
        }
    }

    @ObservedObject var model: DeskModel
    @ObservedObject var history: TrafficHistoryFeed
    @ObservedObject var reportHistory: ConnectionReportHistoryFeed
    let reportHistoryStore: ConnectionReportHistoryStore
    let done: () -> Void
    var embedded: Bool = false
    @State private var tab: Tab = .reports
    @State private var selectedEndpoint: TrafficEndpoint?
    @State private var selectedReportID: UUID?
    @State private var presentedReport: ConnectionDiagnosticReport?
    @State private var pendingHistoryAction: HistoryAction?
    @State private var confirmingHistoryAction = false

    private var selectedRecord: EndpointTrafficRecord? {
        if let selectedEndpoint, let found = history.records.first(where: { $0.id == selectedEndpoint }) {
            return found
        }
        return history.records.first
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

    private var selectedReport: ConnectionDiagnosticReport? {
        reportHistory.reports.first { $0.id == selectedReportID }
    }

    var body: some View {
        Group {
            if embedded {
                ScrollView {
                    content
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView { content }
                    Divider()
                    HStack {
                        Spacer()
                        Button("完成", action: done)
                            .buttonStyle(DeskButtonStyle(.primary))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(width: 760, height: 560)
            }
        }
        .background(DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
        .onAppear {
            model.flushTrafficHistory()
            if selectedEndpoint == nil {
                selectedEndpoint = history.records.first?.id
            }
            updateSelectedReport()
        }
        .onChange(of: history.records.first?.id) { _, firstID in
            if selectedEndpoint == nil {
                selectedEndpoint = firstID
            }
        }
        .onChange(of: reportHistory.reports.map(\.id)) { _, _ in updateSelectedReport() }
        .onDisappear { model.flushTrafficHistory() }
        .onExitCommand {
            if !embedded { done() }
        }
        .sheet(item: $presentedReport) { report in
            VStack(spacing: 0) {
                ConnectionDiagnosticReportView(report: report, relayNodeNames: model.relayNodeNames)
                Divider()
                HStack {
                    Spacer()
                    Button("关闭") { presentedReport = nil }
                        .buttonStyle(DeskButtonStyle(.quiet))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(DeskPalette.canvasBackground)
            }
            .frame(width: 800, height: 640)
        }
        .alert(pendingHistoryAction?.title ?? "", isPresented: $confirmingHistoryAction, presenting: pendingHistoryAction) { action in
            Button("取消", role: .cancel) { pendingHistoryAction = nil }
            Button(action.buttonLabel, role: .destructive) {
                switch action {
                case .delete(let id): reportHistoryStore.delete(id: id)
                case .clear: reportHistoryStore.clearAll()
                }
                pendingHistoryAction = nil
            }
        } message: { _ in
            Text("此操作会永久删除所选的连接诊断记录。")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeskSegmentedTabs(
                tabs: [(.reports, "连接记录与诊断报告"), (.addresses, "地址累计流量")], selection: $tab
            )
            .frame(maxWidth: 345)
            switch tab {
            case .reports: connectionReports
            case .addresses: addressTraffic
            }
        }
    }

    private var connectionReports: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                DeskSettingsPageHeading(title: "连接记录", detail: "在本机保留最近 100 次连接的诊断报告。")
                Spacer()
                if !reportHistory.reports.isEmpty {
                    Button("清空记录…") { confirm(.clear) }
                        .buttonStyle(DeskButtonStyle(.quiet))
                }
            }

            if let error = reportHistory.error {
                DeskCalloutBox(message: error, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }

            reportSummary

            if reportHistory.reports.isEmpty {
                DeskSurfaceCard(padding: 24, cornerRadius: 10) {
                    Text(reportHistory.error == nil ? "连接结束后，诊断报告会出现在这里。" : "暂无可显示的连接诊断报告。")
                        .font(.system(size: 13))
                        .foregroundStyle(DeskPalette.secondary)
                        .frame(maxWidth: .infinity)
                }
            } else {
                reportTable
                if let selectedReport { reportDetails(selectedReport) }
            }
        }
    }

    private var reportSummary: some View {
        let reports = reportHistory.reports
        let metrics = [
            ("记录数", "\(reports.count) 次"),
            ("累计连接时长", DiagnosticReportFormat.elapsed(reports.reduce(0) { $0 + $1.duration })),
            ("累计总流量", DiagnosticReportFormat.bytes(reports.reduce(Decimal.zero) { $0 + Decimal($1.traffic.totalBytes) })),
            ("累计中转流量", DiagnosticReportFormat.bytes(reports.reduce(Decimal.zero) { $0 + Decimal($1.traffic.relayedBytes) })),
            ("累计打洞直连流量", DiagnosticReportFormat.bytes(reports.reduce(Decimal.zero) { $0 + Decimal($1.traffic.punchedBytes) }))
        ]
        return ViewThatFits(in: .horizontal) {
            trafficSummaryGrid(metrics, columns: 5).frame(minWidth: 640)
            trafficSummaryGrid(metrics, columns: 3).frame(minWidth: 410)
            trafficSummaryGrid(metrics, columns: 2)
        }
    }

    private var reportTable: some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            Table(reportHistory.reports, selection: $selectedReportID) {
                TableColumn("开始时间") { report in
                    Text(DiagnosticReportFormat.date(report.startedAt)).monospacedDigit()
                }
                .width(min: 92, ideal: 110)
                TableColumn("设备 / 地址") { report in
                    let title = report.diagnosticDisplayName(relayNodeNames: model.relayNodeNames)
                    Text(title).lineLimit(1).help(title)
                }
                .width(min: 105, ideal: 150)
                TableColumn("连接时长") { report in
                    Text(DiagnosticReportFormat.elapsed(report.duration)).monospacedDigit()
                }
                .width(min: 54, ideal: 66)
                TableColumn("总流量") { report in reportAmount(report.traffic.totalBytes) }
                    .width(min: 52, ideal: 67)
                TableColumn("中转流量") { report in reportAmount(report.traffic.relayedBytes) }
                    .width(min: 57, ideal: 68)
                TableColumn("打洞直连") { report in reportAmount(report.traffic.punchedBytes) }
                    .width(min: 57, ideal: 68)
                TableColumn("活跃帧率与稳定度") { report in
                    HStack(spacing: 5) {
                        Text(DiagnosticReportFormat.fps(report.frameRate.activeMeanFPS))
                            .monospacedDigit()
                        DiagnosticStabilityBadge(stats: report.frameRate)
                    }
                }
                .width(min: 119, ideal: 127)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: min(305, max(88, 30 + CGFloat(reportHistory.reports.count) * 27)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func reportAmount(_ bytes: UInt64) -> some View {
        Text(DiagnosticReportFormat.bytes(bytes))
            .monospacedDigit()
            .help(bytes.formatted() + " 字节")
    }

    private func reportDetails(_ report: ConnectionDiagnosticReport) -> some View {
        let traffic = report.traffic
        return DeskSettingsGroup(title: "连接摘要") {
            DeskSettingsRow(title: report.diagnosticDisplayName(relayNodeNames: model.relayNodeNames), detail: report.reason) {
                DiagnosticStabilityBadge(stats: report.frameRate)
            }
            Divider()
            DeskSettingsRow(title: "本机收发", detail: "发 \(DiagnosticReportFormat.bytes(traffic.totalSentBytes)) / 收 \(DiagnosticReportFormat.bytes(traffic.totalReceivedBytes))") {
                Text("TCP \(DiagnosticReportFormat.bytes(traffic.tcpBytes)) · UDP \(DiagnosticReportFormat.bytes(traffic.udpBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DeskPalette.secondary)
            }
            Divider()
            DeskSettingsRow(title: "活跃平均帧率", detail: DiagnosticReportFormat.fpsRange(report.frameRate)) {
                Text(DiagnosticReportFormat.fps(report.frameRate.activeMeanFPS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DeskPalette.secondary)
            }
            Divider()
            HStack {
                Button("查看完整诊断报告") { presentedReport = report }
                    .buttonStyle(DeskButtonStyle(.primary))
                Spacer()
                Button("删除记录…") { confirm(.delete(report.id)) }
                    .buttonStyle(DeskButtonStyle(.quiet))
            }
            .padding(.vertical, 9)
        }
    }

    private func updateSelectedReport() {
        if selectedReport == nil {
            selectedReportID = reportHistory.reports.first?.id
        }
    }

    private func confirm(_ action: HistoryAction) {
        pendingHistoryAction = action
        confirmingHistoryAction = true
    }

    private var addressTraffic: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                DeskSettingsPageHeading(
                    title: "地址历史流量",
                    detail: "累计应用层收发，以本机视角统计。\(model.trafficHistoryStatus)"
                )
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
                .padding(.top, 4)
            }

            if let error = history.error {
                DeskCalloutBox(message: error, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }

            if history.records.isEmpty {
                DeskSurfaceCard(padding: 36, cornerRadius: 11) {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(DeskPalette.muted)
                            .accessibilityHidden(true)
                        Text("暂无地址流量记录")
                            .font(.system(size: 17, weight: .semibold))
                        Text(history.error == nil
                             ? "建立连接后，收发流量会在本机按地址累计。"
                             : "当前没有可显示的统计，详细原因见上方提示。")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                trafficSummary
                trafficTableCard

                if let selectedRecord {
                    recordDetails(selectedRecord)
                }
            }

            if !history.legacyRecords.isEmpty {
                DisclosureGroup("查看旧版按设备统计归档（\(history.legacyRecords.count) 项）") {
                    DeskSurfaceCard(padding: 12, cornerRadius: 9) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("设备").frame(maxWidth: .infinity, alignment: .leading)
                                Text("本机发送")
                                Text("本机接收")
                                Text("合计")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DeskPalette.secondary)

                            ForEach(history.legacyRecords) { record in
                                GridRow {
                                    Text(record.name)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(trafficAmount(Decimal(record.sentBytes))).monospacedDigit()
                                    Text(trafficAmount(Decimal(record.receivedBytes))).monospacedDigit()
                                    Text(trafficAmount(record.totalBytes)).monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
            }

            Text("以上是本机收发视角，不代表运营商账单。未保存地址的旧文件不混入地址汇总。")
                .font(.system(size: 12))
                .foregroundStyle(DeskPalette.secondary)
        }
    }

    private var trafficSummary: some View {
        let metrics = [
            ("统计地址数", "\(history.records.count) 个"),
            ("累计本机发送", trafficAmount(totalSent)),
            ("累计本机接收", trafficAmount(totalReceived)),
            ("应用层总计", trafficAmount(totalCombined))
        ]
        return ViewThatFits(in: .horizontal) {
            trafficSummaryGrid(metrics, columns: 4)
                .frame(minWidth: 478)
            trafficSummaryGrid(metrics, columns: 2)
        }
    }

    private func trafficSummaryGrid(_ metrics: [(String, String)], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                summaryValue(title: metric.0, value: metric.1, highlighted: index == metrics.count - 1)
            }
        }
    }

    private var trafficTableCard: some View {
        ViewThatFits(in: .horizontal) {
            trafficTable(amountWidth: 96)
                .frame(minWidth: 524)
            trafficTable(amountWidth: 75)
        }
    }

    private func trafficTable(amountWidth: CGFloat) -> some View {
        DeskSurfaceCard(padding: 0, cornerRadius: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("地址 / 设备").frame(maxWidth: .infinity, alignment: .leading)
                    Text("本机发送").frame(width: amountWidth, alignment: .trailing)
                    Text("本机接收").frame(width: amountWidth, alignment: .trailing)
                    Text("合计").frame(width: amountWidth, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DeskPalette.secondary)
                .padding(.horizontal, 16)
                .frame(height: 35)
                .background(DeskPalette.insetBackground)

                ForEach(history.records) { record in
                    let isSelected = selectedRecord?.id == record.id
                    let deviceTitle = matchedDeviceName(for: record)
                    Divider()
                    Button {
                        selectedEndpoint = record.id
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Text(record.endpoint.label)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(DeskPalette.ink)
                                    .lineLimit(1)
                                if let deviceTitle {
                                    Text("· \(deviceTitle)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(DeskPalette.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(record.endpoint.label)

                            Text(trafficAmount(Decimal(record.sentBytes)))
                                .monospacedDigit()
                                .frame(width: amountWidth, alignment: .trailing)
                                .help("精确发送：\(record.sentBytes) 字节")

                            Text(trafficAmount(Decimal(record.receivedBytes)))
                                .monospacedDigit()
                                .frame(width: amountWidth, alignment: .trailing)
                                .help("精确接收：\(record.receivedBytes) 字节")

                            Text(trafficAmount(record.totalBytes))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .frame(width: amountWidth, alignment: .trailing)
                                .help("精确合计：\(NSDecimalNumber(decimal: record.totalBytes).stringValue) 字节")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(DeskPalette.ink)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 32)
                        .background(isSelected ? DeskPalette.accent.opacity(0.08) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func matchedDeviceName(for traffic: EndpointTrafficRecord) -> String? {
        let label = traffic.endpoint.label
        guard let matched = model.connections.first(where: { ConnectionEntryPresentation.endpoint($0) == label }) else {
            return nil
        }
        let name = matched.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func summaryValue(title: String, value: String, highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlighted ? DeskPalette.accent : DeskPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
        .background(highlighted ? DeskPalette.selection : DeskPalette.cardBackground, in: shape)
        .overlay { shape.strokeBorder(DeskPalette.hairline) }
        .accessibilityElement(children: .combine)
    }

    private func recordDetails(_ record: EndpointTrafficRecord) -> some View {
        let titlePrefix = matchedDeviceName(for: record) ?? record.endpoint.label
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(titlePrefix) · 统计详情")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)

            DeskSettingsGroup(title: "流量边界") {
                detailRow("首次统计", value: record.firstSeen.formatted(date: .abbreviated, time: .shortened))
                Divider()
                detailRow("最近连接", value: record.lastSeen.formatted(date: .abbreviated, time: .shortened))
                Divider()
                detailRow("旧记录", value: "未保存地址的文件独立保留")
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        DeskSettingsRow(title: title) {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(DeskPalette.secondary)
                .monospacedDigit()
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
