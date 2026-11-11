import AppKit
import QuietDeskCore
import SwiftUI

struct RouteQualityBenchmarkView: View {
    @ObservedObject var runner: RouteQualityBenchmarkRunner
    let onConnectCandidate: (RouteBenchmarkCandidate, ConnectionRecord?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage = runner.errorMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !runner.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(runner.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if runner.isRunning {
                        liveProgressCard
                    } else if let recommendation = runner.recommendation {
                        recommendationCard(winner: recommendation.winner, reason: recommendation.reason)
                    }

                    if !runner.results.isEmpty {
                        selectionToolbar
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(runner.results) { item in
                                routeCard(item)
                            }
                        }
                    } else {
                        emptyStateView
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }

            Divider()

            footerSection
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "speedometer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("连接与中继线路质量实测")
                        .font(.title2.bold())
                    Text(runner.targetSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                Spacer()

                if !runner.isRunning {
                    Button(runner.completedOrFailedCount > 0 ? "重新实测" : "开始实测") {
                        runner.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(runner.selectedCount == 0)
                }
            }

            HStack(spacing: 12) {
                Text("每条线路测试时长")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("每条线路测试时长", selection: $runner.duration) {
                    ForEach(RouteBenchmarkDuration.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(runner.isRunning)

                Spacer()

                if runner.selectedCount > 0 {
                    Text("已选 \(runner.selectedCount) 条 · 预计约 \(estimatedTotalTimeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var estimatedTotalTimeText: String {
        let totalSeconds = runner.selectedCount * (runner.duration.rawValue + 2)
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Text("候选线路（\(runner.results.count)）")
                .font(.headline)

            Spacer()

            if !runner.isRunning {
                if runner.results.count > 1 {
                    Button("全选") { runner.selectAll() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if runner.hasDirectCandidates && runner.hasRelayCandidates {
                    Button("仅测直连") { runner.selectDirectOnly() }
                        .buttonStyle(.link)
                        .font(.caption)
                    Button("仅测中继") { runner.selectRelayOnly() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button("刷新线路") { runner.reloadPlan() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var liveProgressCard: some View {
        let activeItem = runner.results.first { $0.id == runner.activeCandidateID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(activeItem.map { "正在测试：\($0.candidate.title)" } ?? "正在准备下一条线路…")
                    .font(.headline)
                Spacer()
                if let activeItem, case let .measuring(elapsed, duration) = activeItem.status {
                    Text(String(format: "%.0f / %.0f 秒", elapsed, duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("握手中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let activeItem, case let .measuring(elapsed, duration) = activeItem.status, duration > 0 {
                ProgressView(value: min(max(0, elapsed), duration), total: duration)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if !runner.liveTelemetrySummary.isEmpty {
                Text(runner.liveTelemetrySummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("跳过当前线路") {
                    runner.skipCurrentRoute()
                }
                .controlSize(.small)

                Button("停止并查看结果") {
                    runner.stopAll()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.blue.opacity(0.22), lineWidth: 1)
        )
    }

    private func recommendationCard(winner: RouteBenchmarkResult, reason: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("推荐线路：\(winner.candidate.title)")
                        .font(.headline)
                    if let eval = winner.evaluation {
                        scoreBadge(eval)
                    }
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button("使用推荐线路连接") {
                connectWith(winner.candidate)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(14)
        .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.green.opacity(0.28), lineWidth: 1)
        )
    }

    private func routeCard(_ item: RouteBenchmarkResult) -> some View {
        let isWinner = !runner.isRunning && runner.recommendation?.winner.id == item.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    runner.toggleSelection(item.id)
                } label: {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(runner.isRunning)
                .padding(.top, 2)
                .accessibilityLabel(item.isSelected ? "取消勾选 \(item.candidate.title)" : "勾选 \(item.candidate.title)")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(item.candidate.title)
                            .font(.headline)
                        if isWinner {
                            Text("最佳")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        statusBadge(for: item)
                    }
                    Text(item.candidate.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if !runner.isRunning, canConnect(item) {
                    Button("使用此线路连接") {
                        connectWith(item.candidate)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if case let .failed(reason) = item.status {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, 25)
            } else if let metrics = item.metrics {
                metricsGrid(candidate: item.candidate, metrics: metrics)
                    .padding(.leading, 25)
                if let summary = item.evaluation?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 25)
                }
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isWinner ? Color.green.opacity(0.45)
                        : (runner.activeCandidateID == item.id ? Color.blue.opacity(0.45) : Color.primary.opacity(0.07)),
                    lineWidth: isWinner || runner.activeCandidateID == item.id ? 1.5 : 1
                )
        )
    }

    private func canConnect(_ item: RouteBenchmarkResult) -> Bool {
        if case .failed = item.status { return false }
        return true
    }

    @ViewBuilder
    private func statusBadge(for item: RouteBenchmarkResult) -> some View {
        switch item.status {
        case .pending:
            Text(item.isSelected ? "待测试" : "未勾选")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Text("正在连接…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        case let .measuring(elapsed, duration):
            Text(String(format: "采样 %.0f/%.0fs", elapsed, duration))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.blue)
        case .completed:
            if let eval = item.evaluation {
                scoreBadge(eval)
            }
        case .failed:
            Text("不可用")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.red.opacity(0.14), in: Capsule())
                .foregroundStyle(.red)
        case .skipped:
            Text("已跳过")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scoreBadge(_ eval: RouteBenchmarkEvaluation) -> some View {
        let color = gradeColor(eval.grade)
        return Text("\(eval.score) 分 · \(eval.grade.title)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func gradeColor(_ grade: RouteBenchmarkEvaluation.Grade) -> Color {
        switch grade {
        case .excellent: return .green
        case .good: return .teal
        case .fair: return .orange
        case .poor, .unreachable: return .red
        }
    }

    private func metricsGrid(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> some View {
        let columns = [
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            metricCell(title: "建连 / 首帧", value: startupText(metrics))
            metricCell(title: "实际媒体路径", value: metrics.finalRouteLabel)
            metricCell(title: "往返延迟 (RTT)", value: rttText(metrics))
            metricCell(
                title: "UDP 分片丢包",
                value: lossText(candidate: candidate, metrics: metrics),
                highlight: lossHighlightColor(candidate: candidate, metrics: metrics)
            )
            metricCell(title: "实测解码帧率", value: fpsText(metrics))
            metricCell(title: "实测视频吞吐", value: throughputText(metrics))
            metricCell(
                title: "生效画质上限",
                value: metrics.appliedQualitySummary.isEmpty ? "默认画质" : metrics.appliedQualitySummary
            )
            metricCell(title: "有效采样时长", value: String(format: "%.1f 秒（%d 帧）", metrics.measuredSeconds, metrics.decodedFrames))
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metricCell(title: String, value: String, highlight: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(highlight ?? .primary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func startupText(_ m: RouteBenchmarkMetrics) -> String {
        let conn = m.connectMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        let first = m.firstFrameMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        return "\(conn) / \(first)"
    }

    private func rttText(_ m: RouteBenchmarkMetrics) -> String {
        if let udp = m.udpRTTMeanMilliseconds {
            if let peak = m.udpRTTMaxMilliseconds {
                return String(format: "%.0f ms（峰值 %.0f）", udp, peak)
            }
            return String(format: "%.0f ms（视频）", udp)
        }
        if let ctl = m.controlRTTMeanMilliseconds {
            if let peak = m.controlRTTMaxMilliseconds {
                return String(format: "%.0f ms（峰值 %.0f）", ctl, peak)
            }
            return String(format: "%.0f ms（控制）", ctl)
        }
        return "—"
    }

    private func lossText(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> String {
        if candidate.kind.mediaTCPOnly {
            return "无分片丢包（可靠 TCP）"
        }
        if metrics.fellBackToTCP {
            return "UDP 不通，已回退 TCP"
        }
        if let loss = metrics.udpLossMeanPercent {
            if metrics.settledFragments > 0 {
                return String(format: "%.2f%%（%d/%d）", loss, metrics.lostFragments, metrics.settledFragments)
            }
            return String(format: "%.2f%%", loss)
        }
        return "0.00%（未检出丢包）"
    }

    private func lossHighlightColor(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> Color? {
        if metrics.fellBackToTCP { return .orange }
        guard !candidate.kind.mediaTCPOnly, let loss = metrics.udpLossMeanPercent else { return nil }
        if loss >= 5.0 { return .red }
        if loss >= 1.5 { return .orange }
        return .green
    }

    private func fpsText(_ m: RouteBenchmarkMetrics) -> String {
        guard let avg = m.averageFPS else { return "—" }
        if let peak = m.peakFPS, peak > avg + 1 {
            return String(format: "%.1f fps（峰值 %.0f）", avg, peak)
        }
        return String(format: "%.1f fps", avg)
    }

    private func throughputText(_ m: RouteBenchmarkMetrics) -> String {
        guard let avg = m.averageMegabits else { return "—" }
        if let peak = m.peakMegabits, peak > avg + 0.5 {
            return String(format: "%.2f Mbps（峰值 %.1f）", avg, peak)
        }
        return String(format: "%.2f Mbps", avg)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("暂无可测试的候选线路")
                .font(.headline)
            Text("请先在连接界面填写目标域名/IP，或在中继设置中启用服务并填写目标中继设备标识。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var footerSection: some View {
        HStack {
            Text("测速过程自动发送真实编码视频流以检测实际帧率、自适应画质与 UDP 分片丢包，不会修改连接记录或同步剪贴板。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("关闭") {
                runner.shutdown()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private func connectWith(_ candidate: RouteBenchmarkCandidate) {
        let record = runner.sourceRecord
        runner.shutdown()
        onClose()
        onConnectCandidate(candidate, record)
    }
}
