import AppKit
import QuietDeskCore
import SwiftUI

struct RouteQualityBenchmarkView: View {
    @ObservedObject var runner: RouteQualityBenchmarkRunner
    let onConnectCandidate: (RouteBenchmarkCandidate, ConnectionRecord?) -> Void
    let onClose: () -> Void

    @State private var expandedRunIDs: Set<UUID> = []
    @State private var didSeedInitialExpansion = false
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 22)
                .padding(.vertical, 15)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let warning = runner.storageWarningMessage {
                        bannerRow(
                            icon: "exclamationmark.icloud.fill",
                            color: .orange,
                            text: warning
                        )
                    }

                    switch runner.selectedTab {
                    case .currentRun:
                        currentRunContent
                    case .history:
                        historyContent
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
        .frame(minWidth: 720, idealWidth: 780, minHeight: 580, idealHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            seedExpandedRunIfNeeded()
        }
        .onChange(of: runner.lastSavedRunID) { _, newID in
            if let newID {
                expandedRunIDs.insert(newID)
            }
        }
        .onDisappear {
            if runner.isRunning {
                runner.shutdown()
            }
        }
        .confirmationDialog(
            "清空历史测速记录",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            switch runner.historyScope {
            case .currentTarget where runner.currentTargetDescriptor.hasIdentity && !runner.otherHistoricalTargets.isEmpty:
                Button("仅清空当前目标记录（\(runner.currentTargetHistoryRuns.count) 次）", role: .destructive) {
                    runner.clearDisplayedHistory()
                }
                Button("清空全部设备记录（\(runner.allHistoryRuns.count) 次）", role: .destructive) {
                    runner.clearAllHistory()
                }
            case let .historicalTarget(target) where runner.distinctHistoricalTargets.count > 1:
                Button("仅清空「\(target.displayName)」记录（\(runner.displayedHistoryRuns.count) 次）", role: .destructive) {
                    runner.clearDisplayedHistory()
                }
                Button("清空全部设备记录（\(runner.allHistoryRuns.count) 次）", role: .destructive) {
                    runner.clearAllHistory()
                }
            default:
                Button("清空全部历史记录（\(runner.allHistoryRuns.count) 次）", role: .destructive) {
                    runner.clearAllHistory()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后历史测速记录与对应的历史总质量评估将无法恢复，但不会影响已保存的连接记录与配对码。")
        }
    }

    private func seedExpandedRunIfNeeded() {
        guard !didSeedInitialExpansion else { return }
        didSeedInitialExpansion = true
        if let latest = runner.displayedHistoryRuns.first ?? runner.allHistoryRuns.first {
            expandedRunIDs.insert(latest.id)
        }
    }

    // MARK: - Header

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
                Picker("视图", selection: $runner.selectedTab) {
                    Text("本次实测").tag(RouteQualityBenchmarkRunner.ViewTab.currentRun)
                    Text(historyTabTitle).tag(RouteQualityBenchmarkRunner.ViewTab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 8)

                if runner.selectedTab == .currentRun {
                    HStack(spacing: 8) {
                        Text("单条时长")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("每条线路测试时长", selection: $runner.duration) {
                            ForEach(RouteBenchmarkDuration.allCases) { item in
                                Text(item.shortTitle).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(runner.isRunning)

                        if runner.selectedCount > 0 {
                            Text("预计 \(estimatedTotalTimeText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } else {
                    historyHeaderControls
                }
            }
        }
    }

    private var historyTabTitle: String {
        let count = runner.badgeHistoryCount
        return count > 0 ? "历史记录与总评估（\(count)）" : "历史记录与总评估"
    }

    @ViewBuilder
    private var historyHeaderControls: some View {
        HStack(spacing: 10) {
            if showsScopePicker {
                Picker("统计范围", selection: $runner.historyScope) {
                    if runner.currentTargetDescriptor.hasIdentity {
                        Text("当前目标（\(runner.currentTargetHistoryRuns.count)）")
                            .tag(RouteQualityBenchmarkRunner.HistoryScope.currentTarget)
                    }
                    ForEach(runner.otherHistoricalTargets, id: \.self) { target in
                        let count = runner.store.archive.runs(matching: target).count
                        Text("\(target.displayName)（\(count)）")
                            .tag(RouteQualityBenchmarkRunner.HistoryScope.historicalTarget(target))
                    }
                    if runner.distinctHistoricalTargets.count > 1 {
                        Text("全部设备记录（\(runner.allHistoryRuns.count)）")
                            .tag(RouteQualityBenchmarkRunner.HistoryScope.allRecords)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            if !runner.allHistoryRuns.isEmpty {
                Button("清空记录…") {
                    showClearConfirmation = true
                }
                .controlSize(.small)
                .disabled(runner.isRunning)
            }
        }
    }

    private var showsScopePicker: Bool {
        if runner.currentTargetDescriptor.hasIdentity {
            return !runner.otherHistoricalTargets.isEmpty
        }
        return runner.distinctHistoricalTargets.count > 1
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

    // MARK: - Tab 1: Current Run

    @ViewBuilder
    private var currentRunContent: some View {
        if let errorMessage = runner.errorMessage {
            bannerRow(icon: "exclamationmark.triangle.fill", color: .orange, text: errorMessage)
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
        } else {
            if let recommendation = runner.recommendation {
                recommendationCard(winner: recommendation.winner, reason: recommendation.reason)
            } else if runner.completedOrFailedCount > 0, runner.lastSavedRunID != nil {
                savedNoticeStrip
            }

            if let assessment = runner.currentTargetAssessment, runner.completedOrFailedCount == 0 {
                historicalQuickBanner(assessment)
            }
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

    private var savedNoticeStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.secondary)
            Text("本次测速记录已保存至历史（共 \(runner.badgeHistoryCount) 次）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("查看历史总质量评估 →") {
                runner.selectedTab = .history
            }
            .buttonStyle(.link)
            .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func historicalQuickBanner(_ assessment: RouteBenchmarkOverallAssessment) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.teal)
                .frame(width: 36, height: 36)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("历史总质量评估")
                        .font(.subheadline.weight(.semibold))
                    scorePill(score: assessment.overallScore, grade: assessment.overallGrade)
                    stabilityBadge(assessment.overallStability)
                    Text("累计 \(assessment.runCount) 次实测")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let best = assessment.recommendedRoute {
                    Text("长期最优线路：\(best.candidate.title) — \(assessment.recommendationReason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(assessment.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button("总评估与记录") {
                runner.selectedTab = .history
            }
            .controlSize(.small)

            if let best = assessment.recommendedRoute {
                Button("用历史最优连接") {
                    connectWith(best.candidate, preferredTargetRecordID: assessment.target.recordID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.teal.opacity(0.24), lineWidth: 1)
        )
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("本次推荐线路：\(winner.candidate.title)")
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

            if runner.lastSavedRunID != nil {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("本次测速结果已自动记入历史档案（当前目标累计 \(runner.currentTargetHistoryRuns.count) 次）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看历史总质量评估 →") {
                        runner.selectedTab = .history
                    }
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
                }
            }
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
                            capsuleTag(text: "本次最佳", color: .green)
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

    // MARK: - Tab 2: History & Overall Assessment

    @ViewBuilder
    private var historyContent: some View {
        if runner.allHistoryRuns.isEmpty {
            emptyHistoryView
        } else if runner.displayedHistoryRuns.isEmpty {
            noRunsForCurrentTargetView
        } else {
            if let assessment = runner.displayedAssessment {
                overallAssessmentCard(assessment)
                historicalRoutesSection(assessment)
            } else {
                multiTargetScopeNotice
            }
            historicalRunsSection
        }
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("尚无保存的线路测速记录")
                .font(.headline)
            Text("每次完成直连或中继线路测速后，QuietDesk 会自动保留各线路延迟、UDP 丢包与帧率记录，并根据多次历史表现生成总质量评估与长期最优线路推荐。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            if !runner.results.isEmpty {
                Button("前往执行首次实测") {
                    runner.selectedTab = .currentRun
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var noRunsForCurrentTargetView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("当前连接目标尚无历史测速记录")
                .font(.headline)
            Text("「\(runner.targetSummary)」还未执行过线路测速。你可以立即开始首次实测，或切换查看其他已测设备的历史记录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            HStack(spacing: 10) {
                Button("返回开始实测") {
                    runner.selectedTab = .currentRun
                }
                .buttonStyle(.borderedProminent)

                if let firstOther = runner.otherHistoricalTargets.first {
                    Button("查看「\(firstOther.displayName)」的历史记录") {
                        runner.historyScope = .historicalTarget(firstOther)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }

    private var multiTargetScopeNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("正在浏览多台设备的全部历史测速记录", systemImage: "rectangle.stack")
                .font(.headline)
            Text("不同远程设备的物理网络与运营商环境不同，不合并打分。点选下方任一设备即可查看对应的历史总质量评估与长期推荐线路：")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(runner.distinctHistoricalTargets.prefix(4), id: \.self) { target in
                    Button(target.displayName) {
                        if runner.currentTargetDescriptor.hasIdentity && runner.currentTargetDescriptor.matches(target) {
                            runner.historyScope = .currentTarget
                        } else {
                            runner.historyScope = .historicalTarget(target)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }

    private func overallAssessmentCard(_ assessment: RouteBenchmarkOverallAssessment) -> some View {
        let color = gradeColor(assessment.overallGrade)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 2) {
                    Text("\(assessment.overallScore)")
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                    Text(assessment.overallGrade.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 62, height: 58)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("历史总质量评估")
                            .font(.title3.bold())
                        stabilityBadge(assessment.overallStability)
                    }
                    Text("\(assessment.target.displayName) · 累计 \(assessment.runCount) 次实测（有效采样 \(formatDurationSeconds(assessment.totalMeasuredSeconds))） · 最近测速 \(formatDateTime(assessment.latestRunAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(assessment.headline)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)
            }

            if let best = assessment.recommendedRoute {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text("长期推荐线路：\(best.candidate.title)")
                                .font(.subheadline.weight(.semibold))
                            scorePill(score: best.overallScore, grade: best.overallGrade)
                        }
                        Text(assessment.recommendationReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 8)

                    if !runner.isRunning {
                        Button("使用历史最优线路连接") {
                            connectWith(best.candidate, preferredTargetRecordID: assessment.target.recordID)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                .padding(12)
                .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.green.opacity(0.26), lineWidth: 1)
                )
            }

            if !assessment.insights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("综合质量诊断结论")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(assessment.insights, id: \.self) { insight in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.caption2)
                                .foregroundStyle(.teal)
                            Text(insight)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(color.opacity(0.32), lineWidth: 1.2)
        )
    }

    private func historicalRoutesSection(_ assessment: RouteBenchmarkOverallAssessment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("各线路历史聚合对比（\(assessment.routeSummaries.count) 条）")
                .font(.headline)

            ForEach(Array(assessment.routeSummaries.enumerated()), id: \.element.id) { index, summary in
                let isTopRecommended = index == 0 && summary.overallGrade != .unreachable
                historicalRouteCard(
                    summary,
                    isTopRecommended: isTopRecommended,
                    targetRecordID: assessment.target.recordID
                )
            }
        }
    }

    private func historicalRouteCard(
        _ summary: RouteBenchmarkHistoricalRouteSummary,
        isTopRecommended: Bool,
        targetRecordID: UUID?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(summary.candidate.title)
                            .font(.headline)
                        if isTopRecommended {
                            capsuleTag(text: "长期最佳", color: .green)
                        }
                        if summary.overallGrade == .unreachable {
                            capsuleTag(text: "历史未接通", color: .red)
                        } else {
                            scorePill(score: summary.overallScore, grade: summary.overallGrade)
                            stabilityBadge(summary.stability)
                        }
                    }
                    Text(summary.candidate.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if !runner.isRunning, summary.overallGrade != .unreachable {
                    Button("使用此线路连接") {
                        connectWith(summary.candidate, preferredTargetRecordID: targetRecordID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if summary.completedCount > 0 {
                historicalMetricsGrid(summary)
            }

            Text(summary.summary)
                .font(.caption)
                .foregroundStyle(summary.completedCount == 0 ? .red : .secondary)
                .textSelection(.enabled)
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isTopRecommended ? Color.green.opacity(0.42) : Color.primary.opacity(0.07),
                    lineWidth: isTopRecommended ? 1.4 : 1
                )
        )
    }

    private func historicalMetricsGrid(_ s: RouteBenchmarkHistoricalRouteSummary) -> some View {
        let columns = [
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading),
            GridItem(.flexible(minimum: 135), alignment: .leading)
        ]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            metricCell(
                title: "连通可用率",
                value: String(format: "%.0f%%（%d/%d 次）", s.availabilityPercent, s.completedCount, s.attemptCount),
                highlight: s.availabilityPercent < 80 ? .orange : (s.availabilityPercent >= 99.9 ? .green : nil)
            )
            metricCell(title: "历史得分 / 波动区间", value: historicalScoreRangeText(s))
            metricCell(title: "平均 / 峰值延迟", value: historicalRTTText(s))
            metricCell(
                title: "UDP 平均 / 峰值丢包",
                value: historicalLossText(s),
                highlight: historicalLossColor(s)
            )
            metricCell(
                title: "平均解码帧率",
                value: s.meanFPS.map { String(format: "%.1f fps", $0) } ?? "—"
            )
            metricCell(
                title: "平均视频吞吐",
                value: s.meanMegabits.map { String(format: "%.2f Mbps", $0) } ?? "—"
            )
            metricCell(title: "传输与打洞统计", value: historicalTransportTraitText(s))
            metricCell(title: "累计采样时长", value: formatDurationSeconds(s.totalMeasuredSeconds))
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func historicalScoreRangeText(_ s: RouteBenchmarkHistoricalRouteSummary) -> String {
        guard let minScore = s.minScore, let maxScore = s.maxScore else { return "—" }
        if s.completedCount == 1 {
            return "\(minScore) 分（单次）"
        }
        if let latest = s.latestScore {
            return "\(minScore)–\(maxScore) 分（最近 \(latest)）"
        }
        return "\(minScore)–\(maxScore) 分"
    }

    private func historicalRTTText(_ s: RouteBenchmarkHistoricalRouteSummary) -> String {
        guard let mean = s.meanRTTMilliseconds else { return "—" }
        if let worst = s.worstRTTMilliseconds, worst > mean + 1 {
            return String(format: "%.0f ms（峰值 %.0f）", mean, worst)
        }
        return String(format: "%.0f ms", mean)
    }

    private func historicalLossText(_ s: RouteBenchmarkHistoricalRouteSummary) -> String {
        if s.candidate.kind.mediaTCPOnly {
            return "无分片丢包（可靠 TCP）"
        }
        guard let mean = s.meanUDPLossPercent else {
            return s.tcpFallbackCount > 0 ? "UDP 已降级 TCP" : "0.00%"
        }
        if let worst = s.worstUDPLossPercent, worst > mean + 0.05 {
            return String(format: "%.2f%%（峰值 %.1f%%）", mean, worst)
        }
        return String(format: "%.2f%%", mean)
    }

    private func historicalLossColor(_ s: RouteBenchmarkHistoricalRouteSummary) -> Color? {
        guard !s.candidate.kind.mediaTCPOnly else { return nil }
        if let worst = s.worstUDPLossPercent, worst >= 5.0 { return .red }
        if let mean = s.meanUDPLossPercent {
            if mean >= 1.5 { return .orange }
            return .green
        }
        return nil
    }

    private func historicalTransportTraitText(_ s: RouteBenchmarkHistoricalRouteSummary) -> String {
        if s.candidate.kind == .relayAutoPunch {
            let rate = s.punchedDirectRatePercent ?? 0
            return String(format: "打洞直连 %d/%d（%.0f%%）", s.punchedDirectCount, s.completedCount, rate)
        }
        if s.candidate.kind.mediaTCPOnly {
            return "全程可靠 TCP"
        }
        if s.tcpFallbackCount > 0 {
            return "UDP 回退 TCP \(s.tcpFallbackCount) 次"
        }
        return "全程原生 UDP"
    }

    // MARK: - Historical Run List

    private var historicalRunsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("历次测试记录（\(runner.displayedHistoryRuns.count) 次）")
                    .font(.headline)
                Spacer()
                Text("点按记录行展开当次各线路详情")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(runner.displayedHistoryRuns) { run in
                historicalRunRow(run)
            }
        }
        .padding(.top, 4)
    }

    private func historicalRunRow(_ run: RouteBenchmarkRunRecord) -> some View {
        let isExpanded = expandedRunIDs.contains(run.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleExpanded(run.id)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Text(formatDateTime(run.startedAt))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.primary)

                        capsuleTag(text: "\(run.perRouteDurationSeconds) 秒/条", color: .secondary)

                        if run.stoppedEarly {
                            capsuleTag(text: "提前结束", color: .orange)
                        }

                        if runner.historyScope == .allRecords && runner.distinctHistoricalTargets.count > 1 {
                            Text(run.target.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if let best = run.bestEntry, let eval = best.evaluation {
                            HStack(spacing: 6) {
                                Text("最佳：\(best.candidate.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                scorePill(score: eval.score, grade: eval.grade)
                            }
                        } else {
                            capsuleTag(text: "全部未接通（\(run.failedCount)）", color: .red)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    expandedRunIDs.remove(run.id)
                    runner.deleteHistoryRun(run.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("删除此条测速记录")
                .accessibilityLabel("删除 \(formatDateTime(run.startedAt)) 的测速记录")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    if runner.historyScope != .allRecords {
                        Text("测试目标：\(run.target.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = run.recommendationReason, !reason.isEmpty {
                        Text("当次结论：\(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    ForEach(run.evaluatedEntries) { entry in
                        savedEntryDetailRow(
                            entry,
                            isRunWinner: entry.id == run.recommendedCandidateID,
                            targetRecordID: run.target.recordID
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    run.id == runner.lastSavedRunID ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        )
    }

    private func savedEntryDetailRow(
        _ entry: RouteBenchmarkSavedEntry,
        isRunWinner: Bool,
        targetRecordID: UUID?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(entry.candidate.title)
                        .font(.caption.weight(.semibold))
                    if isRunWinner {
                        capsuleTag(text: "当次最佳", color: .green)
                    }
                    switch entry.outcome {
                    case .completed:
                        if let eval = entry.evaluation {
                            scorePill(score: eval.score, grade: eval.grade)
                        }
                    case .failed:
                        capsuleTag(text: "不可用", color: .red)
                    case .skipped:
                        capsuleTag(text: "已跳过", color: .secondary)
                    }
                }

                switch entry.outcome {
                case .completed:
                    if let m = entry.metrics {
                        Text(compactMetricsLine(candidate: entry.candidate, metrics: m))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case let .failed(reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                case .skipped:
                    EmptyView()
                }
            }

            Spacer(minLength: 8)

            if !runner.isRunning, entry.outcome == .completed {
                Button("连接") {
                    connectWith(entry.candidate, preferredTargetRecordID: targetRecordID)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func compactMetricsLine(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> String {
        var parts: [String] = [metrics.finalRouteLabel]
        if let rtt = metrics.udpRTTMeanMilliseconds ?? metrics.controlRTTMeanMilliseconds {
            parts.append(String(format: "RTT %.0f ms", rtt))
        }
        parts.append("丢包 \(lossText(candidate: candidate, metrics: metrics))")
        if let fps = metrics.averageFPS {
            parts.append(String(format: "%.1f fps", fps))
        }
        if let mbps = metrics.averageMegabits {
            parts.append(String(format: "%.2f Mbps", mbps))
        }
        if !metrics.appliedQualitySummary.isEmpty {
            parts.append(metrics.appliedQualitySummary)
        }
        return parts.joined(separator: " · ")
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRunIDs.contains(id) {
            expandedRunIDs.remove(id)
        } else {
            expandedRunIDs.insert(id)
        }
    }

    // MARK: - Shared Subviews & Formatting

    private func bannerRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
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
            capsuleTag(text: "不可用", color: .red)
        case .skipped:
            Text("已跳过")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scoreBadge(_ eval: RouteBenchmarkEvaluation) -> some View {
        scorePill(score: eval.score, grade: eval.grade)
    }

    private func scorePill(score: Int, grade: RouteBenchmarkEvaluation.Grade) -> some View {
        let color = gradeColor(grade)
        return Text("\(score) 分 · \(grade.title)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func stabilityBadge(_ stability: RouteBenchmarkStability) -> some View {
        let color: Color = switch stability {
        case .rockSolid: .green
        case .stable: .teal
        case .singleSample: .blue
        case .fluctuating: .orange
        case .unstable, .unreachable: .red
        }
        return capsuleTag(text: stability.title, color: color)
    }

    private func capsuleTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
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

    private func formatDateTime(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    private func formatDurationSeconds(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        if rounded < 60 {
            return "\(rounded) 秒"
        }
        let minutes = rounded / 60
        let rem = rounded % 60
        return rem == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(rem) 秒"
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
            if !runner.allHistoryRuns.isEmpty {
                Button("查看过往测速历史记录（\(runner.allHistoryRuns.count) 次）") {
                    runner.selectedTab = .history
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var footerSection: some View {
        HStack {
            Text("每次测速结果自动保存在本机（不含配对码与接入凭据），并累计生成历史总质量评估。")
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

    private func connectWith(_ candidate: RouteBenchmarkCandidate, preferredTargetRecordID: UUID? = nil) {
        let record = runner.resolveConnectionRecord(for: candidate, preferredTargetRecordID: preferredTargetRecordID)
        runner.shutdown()
        onClose()
        onConnectCandidate(candidate, record)
    }
}
