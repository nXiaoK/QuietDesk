import AppKit
import QuietDeskCore
import SwiftUI

extension RouteBenchmarkEvaluation.Grade {
    var deskTint: Color {
        switch self {
        case .excellent: return DeskPalette.emerald
        case .good: return .teal
        case .fair: return DeskPalette.amber
        case .poor, .unreachable: return DeskPalette.coral
        }
    }
}

struct RouteQualityBenchmarkView: View {
    @ObservedObject var runner: RouteQualityBenchmarkRunner
    let onConnectCandidate: (RouteBenchmarkCandidate, ConnectionRecord?) -> Void
    let onClose: () -> Void
    var embedded: Bool = false
    var availableRecords: [ConnectionRecord] = []
    var selectedTargetRecord: ConnectionRecord? = nil
    var onSelectTargetRecord: ((ConnectionRecord?) -> Void)? = nil
    var relayNodeNames: [String: String] = [:]

    @Namespace private var assessmentAnchor
    @Namespace private var runsAnchor
    @State private var expandedRunIDs: Set<UUID> = []
    @State private var expandedRouteIDs: Set<String> = []
    @State private var didSeedInitialExpansion = false
    @State private var showClearConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            mainContent(scrollToAssessment: {
                withAnimation { proxy.scrollTo(assessmentAnchor, anchor: .top) }
            }, scrollToRuns: {
                withAnimation { proxy.scrollTo(runsAnchor, anchor: .top) }
            })
        }
        .frame(
            minWidth: embedded ? nil : 720,
            idealWidth: embedded ? nil : 780,
            maxWidth: embedded ? .infinity : nil,
            minHeight: embedded ? nil : 580,
            idealHeight: embedded ? nil : 660,
            maxHeight: embedded ? .infinity : nil
        )
        .background(DeskPalette.canvasBackground)
        .tint(DeskPalette.accent)
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

    private func mainContent(scrollToAssessment: @escaping () -> Void, scrollToRuns: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if embedded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerSection

                        if let warning = runner.storageWarningMessage {
                            bannerRow(
                                icon: "exclamationmark.icloud.fill",
                                color: DeskPalette.amber,
                                text: warning
                            )
                        }

                        switch runner.selectedTab {
                        case .currentRun:
                            currentRunContent
                        case .history:
                            historyContent(scrollToAssessment: scrollToAssessment, scrollToRuns: scrollToRuns)
                        }

                        if runner.isRunning, runner.selectedTab == .currentRun {
                            DeskSurfaceCard(padding: 16, cornerRadius: 10) {
                                liveProgressCard
                            }
                        }

                        footerSection
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                headerSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let warning = runner.storageWarningMessage {
                            bannerRow(
                                icon: "exclamationmark.icloud.fill",
                                color: DeskPalette.amber,
                                text: warning
                            )
                        }

                        switch runner.selectedTab {
                        case .currentRun:
                            currentRunContent
                        case .history:
                            historyContent(scrollToAssessment: scrollToAssessment, scrollToRuns: scrollToRuns)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }

                if runner.isRunning, runner.selectedTab == .currentRun {
                    Divider()
                    liveProgressCard
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }

                Divider()

                footerSection
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    benchmarkHeading.frame(minWidth: 200, alignment: .leading)
                    Spacer(minLength: 8)
                    benchmarkActions.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    benchmarkHeading
                    benchmarkActions
                }
            }

            if runner.selectedTab == .history {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        benchmarkTabs.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        historyHeaderControls.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        benchmarkTabs
                        historyHeaderControls
                    }
                }
            } else {
                benchmarkTabs
                HStack(spacing: 10) {
                    Text("单条时长")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .accessibilityHidden(true)

                    DeskSegmentedTabs(
                        tabs: RouteBenchmarkDuration.allCases.map { ($0, $0.shortTitle) },
                        selection: $runner.duration
                    )
                    .frame(maxWidth: 210, alignment: .leading)
                    .disabled(runner.isRunning)

                    if runner.selectedCount > 0 {
                        Text("预计 \(estimatedTotalTimeText)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DeskPalette.secondary)
                    }
                }
            }
        }
    }

    private var benchmarkHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pageTitle)
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(DeskPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(runner.targetSummary)
                .font(.callout)
                .foregroundStyle(DeskPalette.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private var benchmarkActions: some View {
        HStack(spacing: 8) {
            if let onSelectTargetRecord, !availableRecords.isEmpty {
                Menu {
                    Button("使用连接页当前填写目标") {
                        onSelectTargetRecord(nil)
                    }
                    Divider()
                    ForEach(availableRecords) { record in
                        Button("\(ConnectionEntryPresentation.title(record)) · \(ConnectionEntryPresentation.endpoint(record, relayNodeNames: relayNodeNames))") {
                            onSelectTargetRecord(record)
                        }
                    }
                } label: {
                    Label("切换测速目标", systemImage: "desktopcomputer")
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .accessibilityValue(selectedTargetRecord.map(ConnectionEntryPresentation.title) ?? "当前连接草稿")
                .disabled(runner.isRunning)
            }
            if !runner.isRunning {
                Button {
                    runner.start()
                } label: {
                    Label(runner.completedOrFailedCount > 0 ? "重新实测" : "开始实测", systemImage: "play")
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .disabled(runner.selectedCount == 0)
            }
        }
    }

    private var benchmarkTabs: some View {
        HStack(spacing: 0) {
            ForEach([RouteQualityBenchmarkRunner.ViewTab.currentRun, .history], id: \.self) { tab in
                let selected = runner.selectedTab == tab
                Button {
                    runner.selectedTab = tab
                } label: {
                    Text(tab == .currentRun ? "本次实测" : historyTabTitle)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? DeskPalette.accent : DeskPalette.secondary)
                        .frame(minHeight: 32)
                        .padding(.horizontal, 11)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule()
                                    .fill(DeskPalette.accent)
                                    .frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DeskPalette.hairline)
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var pageTitle: String {
        if runner.selectedTab == .history { return "线路历史与长期评估" }
        return !runner.isRunning && runner.completedOrFailedCount > 0 ? "线路实测结果" : "线路实测"
    }

    private var historyTabTitle: String {
        let count = runner.badgeHistoryCount
        return count > 0 ? "历史记录与评估（\(count)）" : "历史记录与评估"
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
                .buttonStyle(DeskButtonStyle(.secondary))
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
            bannerRow(icon: "exclamationmark.triangle.fill", color: DeskPalette.amber, text: errorMessage)
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
            .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        }

        if !runner.isRunning {
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
            benchmarkTable {
                benchmarkTableHeader {
                    Text("候选线路 / 节点").frame(maxWidth: .infinity, alignment: .leading)
                    Text("状态").frame(width: 98, alignment: .leading)
                    Text("操作").frame(width: 132, alignment: .leading)
                }
                ForEach(runner.results) { item in
                    Divider().padding(.horizontal, 13)
                    routeRow(item)
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
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func historicalQuickBanner(_ assessment: RouteBenchmarkOverallAssessment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("历史总质量评估")
                    .font(.headline)
                scorePill(score: assessment.overallScore, grade: assessment.overallGrade)
                stabilityBadge(assessment.overallStability)
                Text("累计 \(assessment.runCount) 次实测")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
            }

            if let best = assessment.recommendedRoute {
                Text("长期最优线路：\(routeTitle(best.candidate)) — \(assessment.recommendationReason)")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(2)
            } else {
                Text(assessment.headline)
                    .font(.caption)
                    .foregroundStyle(DeskPalette.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("总评估与记录") {
                    runner.selectedTab = .history
                }
                .buttonStyle(DeskButtonStyle(.secondary))

                if let best = assessment.recommendedRoute {
                    Button("用历史最优连接") {
                        connectWith(best.candidate, preferredTargetRecordID: assessment.target.recordID)
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                }
            }
        }
        .padding(12)
        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DeskPalette.hairline, lineWidth: 1) }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Text("候选线路（\(runner.results.count)）")
                .font(.headline)

            Spacer()

            if !runner.isRunning {
                if runner.results.count > 1 {
                    Button("全选") { runner.selectAll() }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                }
                if runner.hasDirectCandidates && runner.hasRelayCandidates {
                    Button("仅测直连") { runner.selectDirectOnly() }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                    Button("仅测中继") { runner.selectRelayOnly() }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                }
                Button("刷新线路") { runner.reloadPlan() }
                    .buttonStyle(DeskButtonStyle(.secondary))
            }
        }
    }

    private var liveProgressCard: some View {
        let activeItem = runner.results.first { $0.id == runner.activeCandidateID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(activeItem.map { "正在测试：\(routeTitle($0.candidate))" } ?? "正在准备下一条线路…")
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
                .buttonStyle(DeskButtonStyle(.secondary))

                Button("停止并查看结果") {
                    runner.stopAll()
                }
                .buttonStyle(DeskButtonStyle(.primary))
            }
        }
        .padding(.vertical, 5)
    }

    private func recommendationCard(winner: RouteBenchmarkResult, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(DeskPalette.emerald)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("本次推荐线路：\(routeTitle(winner.candidate))")
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
                .buttonStyle(DeskButtonStyle(.primary))
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
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DeskPalette.hairline, lineWidth: 1) }
    }

    private func routeRow(_ item: RouteBenchmarkResult) -> some View {
        let isWinner = !runner.isRunning && runner.recommendation?.winner.id == item.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                Button {
                    runner.toggleSelection(item.id)
                } label: {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(item.isSelected ? DeskPalette.accent : DeskPalette.secondary)
                        .frame(width: 19, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(runner.isRunning)
                .accessibilityLabel(item.isSelected ? "取消勾选 \(routeTitle(item.candidate))" : "勾选 \(routeTitle(item.candidate))")
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        candidateTitle(item.candidate, isWinner: isWinner)
                            .frame(minWidth: 128, alignment: .leading)
                        candidateAddress(item.candidate)
                            .frame(minWidth: 135, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        candidateTitle(item.candidate, isWinner: isWinner)
                        candidateAddress(item.candidate)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                statusBadge(for: item)
                    .frame(width: 98, alignment: .leading)

                Group {
                    if !runner.isRunning, canConnect(item) {
                        Button {
                            connectWith(item.candidate)
                        } label: {
                            Text("使用此线路连接")
                                .lineLimit(1)
                        }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                        .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Color.clear.frame(height: 0).accessibilityHidden(true)
                    }
                }
                .frame(width: 132, alignment: .leading)
            }

            if case let .failed(reason) = item.status {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.coral)
                    .textSelection(.enabled)
            } else if let metrics = item.metrics {
                metricsGrid(candidate: item.candidate, metrics: metrics)
                if let summary = item.evaluation?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 4)
        .background(runner.activeCandidateID == item.id ? DeskPalette.accent.opacity(0.06) : Color.clear)
    }

    private func candidateTitle(_ candidate: RouteBenchmarkCandidate, isWinner: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(candidateRowTitle(candidate))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .help(routeTitle(candidate))
            if isWinner {
                capsuleTag(text: "本次最佳", color: DeskPalette.emerald)
            }
        }
    }

    private func routeTitle(_ candidate: RouteBenchmarkCandidate) -> String {
        candidate.displayTitle(relayNodeNames: relayNodeNames)
    }

    private func candidateRowTitle(_ candidate: RouteBenchmarkCandidate) -> String {
        if candidate.kind.usesRelay, let endpoint = candidate.relayEndpoint,
           RelayNodeNaming.sanitize(relayNodeNames[endpoint.address]) == nil {
            return candidate.kind.modeTitle
        }
        return routeTitle(candidate)
    }

    private func candidateAddress(_ candidate: RouteBenchmarkCandidate) -> some View {
        Text(candidate.subtitle.components(separatedBy: " · ").first ?? candidate.subtitle)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DeskPalette.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(candidate.subtitle)
    }

    private func benchmarkTable(@ViewBuilder content: () -> some View) -> some View {
        let rows = content()
        return DeskSurfaceCard(padding: 0, cornerRadius: 9) {
            VStack(alignment: .leading, spacing: 0) { rows }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func benchmarkTableHeader(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 9, content: content)
            .font(.caption)
            .foregroundStyle(DeskPalette.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(DeskPalette.insetBackground)
            .accessibilityHidden(true)
    }

    // MARK: - Tab 2: History & Overall Assessment

    @ViewBuilder
    private func historyContent(
        scrollToAssessment: @escaping () -> Void,
        scrollToRuns: @escaping () -> Void
    ) -> some View {
        if runner.allHistoryRuns.isEmpty {
            emptyHistoryView
        } else if runner.displayedHistoryRuns.isEmpty {
            noRunsForCurrentTargetView
        } else {
            if let assessment = runner.displayedAssessment {
                overallAssessmentCard(assessment)
                    .id(assessmentAnchor)
                historicalRoutesSection(assessment, scrollToRuns: scrollToRuns)
            } else {
                multiTargetScopeNotice
            }
            historicalRunsSection(scrollToAssessment: runner.displayedAssessment == nil ? nil : scrollToAssessment)
                .id(runsAnchor)
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
                .buttonStyle(DeskButtonStyle(.primary))
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
                .buttonStyle(DeskButtonStyle(.primary))

                if let firstOther = runner.otherHistoricalTargets.first {
                    Button("查看「\(firstOther.displayName)」的历史记录") {
                        runner.historyScope = .historicalTarget(firstOther)
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
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
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskPalette.cardBackground, in: RoundedRectangle(cornerRadius: 11))
    }

    private func overallAssessmentCard(_ assessment: RouteBenchmarkOverallAssessment) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 3) {
                    Text("\(assessment.overallScore)")
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                    Text("综合评分")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(DeskPalette.accent)
                .frame(width: 72, height: 76)
                .background(DeskPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("综合评分 \(assessment.overallScore) 分，\(assessment.overallGrade.title)")

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("历史总质量评估")
                            .font(.subheadline.weight(.semibold))
                        stabilityBadge(assessment.overallStability)
                    }
                    Text("\(assessment.target.displayName) · 累计 \(assessment.runCount) 次实测 · 最近测速 \(formatDateTime(assessment.latestRunAt))")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .textSelection(.enabled)
                    if let best = assessment.recommendedRoute {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .bottom, spacing: 10) {
                                recommendedHistoryRoute(best)
                                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                                if !runner.isRunning {
                                    connectHistoricalRoute(best, targetRecordID: assessment.target.recordID)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                recommendedHistoryRoute(best)
                                if !runner.isRunning {
                                    connectHistoricalRoute(best, targetRecordID: assessment.target.recordID)
                                }
                            }
                        }
                    } else {
                        Text(assessment.headline)
                            .font(.caption)
                            .foregroundStyle(DeskPalette.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup("综合质量诊断结论") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("有效采样 \(formatDurationSeconds(assessment.totalMeasuredSeconds))")
                    if assessment.recommendedRoute != nil {
                        Text(assessment.headline)
                        Text(assessment.recommendationReason)
                    }
                    ForEach(assessment.insights, id: \.self) { insight in
                        Label(insight, systemImage: "waveform.path.ecg")
                    }
                }
                .foregroundStyle(DeskPalette.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(13)
        .background(DeskPalette.insetBackground, in: shape)
        .overlay { shape.strokeBorder(DeskPalette.hairline, lineWidth: 1) }
    }

    private func recommendedHistoryRoute(_ best: RouteBenchmarkHistoricalRouteSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("长期推荐 · \(candidateRowTitle(best.candidate))")
                .font(.system(size: 13, weight: .semibold))
            candidateAddress(best.candidate)
        }
        .help("\(routeTitle(best.candidate))，\(best.overallScore) 分 · \(best.overallGrade.title)")
    }

    private func connectHistoricalRoute(_ best: RouteBenchmarkHistoricalRouteSummary, targetRecordID: UUID?) -> some View {
        Button {
            connectWith(best.candidate, preferredTargetRecordID: targetRecordID)
        } label: {
            Label("使用历史最优线路连接", systemImage: "arrow.right")
        }
        .buttonStyle(DeskButtonStyle(.secondary, compact: true))
    }

    private func historicalRoutesSection(
        _ assessment: RouteBenchmarkOverallAssessment,
        scrollToRuns: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("各线路历史聚合对比（\(assessment.routeSummaries.count) 条）")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: scrollToRuns) {
                    Label("查看历次记录", systemImage: "list.bullet")
                }
                .buttonStyle(DeskButtonStyle(.quiet, compact: true))
            }
            comparisonTable {
                ForEach(assessment.routeSummaries) { summary in
                    Divider()
                    historicalRouteRow(summary, targetRecordID: assessment.target.recordID)
                }
            }

            Text("TCP 的 UDP 丢包不适用，以 — 显示。")
                .font(.caption)
                .foregroundStyle(DeskPalette.secondary)
        }
    }

    private func comparisonTable(@ViewBuilder _ rows: () -> some View) -> some View {
        let content = rows()
        return benchmarkTable {
            ViewThatFits(in: .horizontal) {
                comparisonTableContent(content)
                    .frame(minWidth: 568)
                ScrollView(.horizontal) {
                    comparisonTableContent(content)
                        .frame(minWidth: 568)
                }
            }
        }
    }

    private func comparisonTableContent<Rows: View>(_ rows: Rows) -> some View {
        VStack(spacing: 0) {
            benchmarkTableHeader {
                Text("候选线路")
                    .frame(maxWidth: .infinity, alignment: .leading)
                comparisonCells(["评分", "RTT", "UDP 丢包", "平均帧率", "视频吞吐"], isHeading: true)
                Text("操作").frame(width: 45, alignment: .leading)
            }
            rows
        }
    }

    private func comparisonCells(_ values: [String], isHeading: Bool = false) -> some View {
        let widths: [CGFloat] = [42, 60, 65, 62, 77]
        return ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            Text(value)
                .font(.system(size: 11, weight: index == 0 ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(isHeading ? DeskPalette.secondary : index == 0 ? DeskPalette.accent : DeskPalette.ink)
                .frame(width: widths[index], alignment: .leading)
                .accessibilityLabel(isHeading ? value : "\(comparisonMetricLabel(index)) \(value)")
        }
    }

    private func comparisonMetricLabel(_ index: Int) -> String {
        ["评分", "RTT", "UDP 丢包", "平均帧率", "视频吞吐"][index]
    }

    private func formattedMetric(_ value: Double?, _ pattern: String) -> String {
        value.map { String(format: pattern, $0) } ?? "—"
    }

    private func historicalRouteRow(
        _ summary: RouteBenchmarkHistoricalRouteSummary,
        targetRecordID: UUID?
    ) -> some View {
        let expanded = expandedRouteIDs.contains(summary.id)
        let values = [
            summary.completedCount > 0 ? String(summary.overallScore) : "—",
            formattedMetric(summary.meanRTTMilliseconds, "%.0f ms"),
            formattedMetric(summary.candidate.kind.mediaTCPOnly ? nil : summary.meanUDPLossPercent, "%.2f%%"),
            formattedMetric(summary.meanFPS, "%.1f"),
            formattedMetric(summary.meanMegabits, "%.2f Mbps")
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    if expanded { expandedRouteIDs.remove(summary.id) }
                    else { expandedRouteIDs.insert(summary.id) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DeskPalette.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            candidateTitle(summary.candidate)
                            candidateAddress(summary.candidate)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(routeTitle(summary.candidate))
                .accessibilityHint(expanded ? "收起线路评估详情" : "展开线路评估详情")
                .frame(maxWidth: .infinity, alignment: .leading)

                comparisonCells(values)
                Group {
                    if !runner.isRunning, summary.overallGrade != .unreachable {
                        Button("连接") {
                            connectWith(summary.candidate, preferredTargetRecordID: targetRecordID)
                        }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                        .accessibilityLabel("使用 \(routeTitle(summary.candidate)) 连接")
                    }
                }
                .frame(width: 45, alignment: .leading)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        scorePill(score: summary.overallScore, grade: summary.overallGrade)
                        stabilityBadge(summary.stability)
                    }
                    if summary.completedCount > 0 {
                        historicalMetricsGrid(summary)
                    }
                    Text(summary.summary)
                        .font(.caption)
                        .foregroundStyle(summary.completedCount == 0 ? DeskPalette.coral : DeskPalette.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
            }
        }
    }

    private func historicalMetricsGrid(_ s: RouteBenchmarkHistoricalRouteSummary) -> some View {
        let columns = [GridItem(.adaptive(minimum: 112), alignment: .leading)]
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
        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 8))
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
            return s.tcpFallbackCount > 0 ? "UDP 已降级 TCP" : "—"
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

    private func historicalRunsSection(scrollToAssessment: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("历次测试记录（\(runner.displayedHistoryRuns.count) 次）")
                    .font(.headline)
                Spacer()
                if let scrollToAssessment {
                    Button(action: scrollToAssessment) {
                        Label("返回长期评估", systemImage: "arrow.left")
                    }
                    .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                } else {
                    Text("点按记录行展开当次各线路详情")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            benchmarkTable {
                ForEach(runner.displayedHistoryRuns) { run in
                    if run.id != runner.displayedHistoryRuns.first?.id { Divider().padding(.horizontal, 12) }
                    historicalRunRow(run)
                }
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
                            capsuleTag(text: "提前结束", color: DeskPalette.amber)
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
                                Text("最佳：\(routeTitle(best.candidate))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                scorePill(score: eval.score, grade: eval.grade)
                            }
                        } else {
                            capsuleTag(text: "全部未接通（\(run.failedCount)）", color: DeskPalette.coral)
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

                    comparisonTable {
                        ForEach(run.evaluatedEntries) { entry in
                            Divider()
                            savedEntryDetailRow(
                                entry,
                                isRunWinner: entry.id == run.recommendedCandidateID,
                                targetRecordID: run.target.recordID
                            )
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(run.id == runner.lastSavedRunID ? DeskPalette.accent.opacity(0.045) : Color.clear)
    }

    private func savedEntryDetailRow(
        _ entry: RouteBenchmarkSavedEntry,
        isRunWinner: Bool,
        targetRecordID: UUID?
    ) -> some View {
        let metrics = entry.metrics
        let values = [
            entry.evaluation.map { String($0.score) } ?? "—",
            formattedMetric(metrics?.udpRTTMeanMilliseconds ?? metrics?.controlRTTMeanMilliseconds, "%.0f ms"),
            formattedMetric(entry.candidate.kind.mediaTCPOnly ? nil : metrics?.udpLossMeanPercent, "%.2f%%"),
            formattedMetric(metrics?.averageFPS, "%.1f"),
            formattedMetric(metrics?.averageMegabits, "%.2f Mbps")
        ]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    candidateTitle(entry.candidate, isWinner: isRunWinner)
                    candidateAddress(entry.candidate)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                comparisonCells(values)
                Group {
                    if !runner.isRunning, entry.outcome == .completed {
                        Button("连接") {
                            connectWith(entry.candidate, preferredTargetRecordID: targetRecordID)
                        }
                        .buttonStyle(DeskButtonStyle(.quiet, compact: true))
                        .accessibilityLabel("使用 \(routeTitle(entry.candidate)) 连接")
                    }
                }
                .frame(width: 45, alignment: .leading)
            }

            switch entry.outcome {
            case .completed:
                if let metrics {
                    Text(compactMetricsLine(candidate: entry.candidate, metrics: metrics))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DeskPalette.secondary)
                        .textSelection(.enabled)
                }
            case let .failed(reason):
                Label(reason.isEmpty ? "不可用" : reason, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(DeskPalette.coral)
                    .textSelection(.enabled)
            case .skipped:
                Text("已跳过").font(.caption2).foregroundStyle(DeskPalette.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
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
            Text(item.isSelected ? "未测试" : "未勾选")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            Text("正在连接…")
                .font(.caption.weight(.medium))
                .foregroundStyle(DeskPalette.accent)
        case let .measuring(elapsed, duration):
            Text(String(format: "采样 %.0f/%.0fs", elapsed, duration))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(DeskPalette.accent)
        case .completed:
            if let eval = item.evaluation {
                scoreBadge(eval)
            }
        case .failed:
            capsuleTag(text: "不可用", color: DeskPalette.coral)
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
        let color = grade.deskTint
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

    private func metricsGrid(candidate: RouteBenchmarkCandidate, metrics: RouteBenchmarkMetrics) -> some View {
        let columns = [GridItem(.adaptive(minimum: 112), alignment: .leading)]
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
        .background(DeskPalette.insetBackground, in: RoundedRectangle(cornerRadius: 8))
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
        return "—"
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

            if !embedded {
                Button("关闭") {
                    runner.shutdown()
                    onClose()
                }
                .buttonStyle(DeskButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func connectWith(_ candidate: RouteBenchmarkCandidate, preferredTargetRecordID: UUID? = nil) {
        let record = runner.resolveConnectionRecord(for: candidate, preferredTargetRecordID: preferredTargetRecordID)
        runner.shutdown()
        onClose()
        onConnectCandidate(candidate, record)
    }
}
