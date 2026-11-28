import AppKit
import QuietDeskCore
import SwiftUI

struct DeskUnderlineTabs<Tab: Hashable>: View {
    let tabs: [(id: Tab, title: String)]
    @Binding var selection: Tab
    var badge: (Tab) -> (text: String, tint: Color)? = { _ in nil }
    var canSelect: (Tab) -> Bool = { _ in true }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabStrip(distributed: true)
            ScrollView(.horizontal, showsIndicators: false) {
                tabStrip(distributed: false)
            }
        }
        .background(alignment: .bottom) {
            Rectangle()
                .fill(DeskPalette.hairline)
                .frame(height: 1)
        }
    }

    private func tabStrip(distributed: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.id) { tab in
                let isSelected = selection == tab.id
                let isEnabled = canSelect(tab.id)
                Button {
                    selection = tab.id
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .fixedSize(horizontal: true, vertical: false)
                        if let tag = badge(tab.id) {
                            Circle()
                                .fill(tag.tint)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(tag.text)
                        }
                    }
                    .foregroundStyle(isSelected ? DeskPalette.accent : DeskPalette.secondary)
                    .frame(height: 36)
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(DeskPalette.accent)
                                .frame(height: 2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: distributed ? .infinity : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.52)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Places settings groups side by side when their controls have room and stacks at narrow window widths.
struct DeskSettingsColumns<Leading: View, Trailing: View>: View {
    var minimumColumnWidth: CGFloat = 300
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        DeskSettingsColumnLayout(minimumColumnWidth: minimumColumnWidth) {
            leading().frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DeskSettingsColumnLayout: Layout {
    let minimumColumnWidth: CGFloat
    private let gap: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = proposedWidth
        } else {
            let idealColumnWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = max(minimumColumnWidth, idealColumnWidth) * CGFloat(subviews.count) + gaps(subviews.count)
        }

        let arrangement = arrange(width: width, count: subviews.count)
        let sizes = subviews.map { $0.sizeThatFits(arrangement.proposal) }
        let height = arrangement.sideBySide
            ? sizes.map(\.height).max() ?? 0
            : sizes.map(\.height).reduce(0, +) + gaps(subviews.count)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let arrangement = arrange(width: bounds.width, count: subviews.count)
        var origin = bounds.origin
        for subview in subviews {
            subview.place(at: origin, anchor: .topLeading, proposal: arrangement.proposal)
            if arrangement.sideBySide {
                origin.x += arrangement.columnWidth + gap
            } else {
                origin.y += subview.sizeThatFits(arrangement.proposal).height + gap
            }
        }
    }

    private func gaps(_ count: Int) -> CGFloat {
        CGFloat(max(0, count - 1)) * gap
    }

    private func arrange(width: CGFloat, count: Int) -> (sideBySide: Bool, columnWidth: CGFloat, proposal: ProposedViewSize) {
        let columnWidth = (width - gaps(count)) / CGFloat(count)
        let sideBySide = columnWidth >= minimumColumnWidth
        return (sideBySide, columnWidth, ProposedViewSize(width: sideBySide ? columnWidth : width, height: nil))
    }
}

struct DeskSettingsPageTabs<Tab: Hashable, Content: View>: View {
    let tabs: [(id: Tab, title: String)]
    @Binding var selection: Tab
    var badge: (Tab) -> (text: String, tint: Color)? = { _ in nil }
    var canSelect: (Tab) -> Bool = { _ in true }
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskUnderlineTabs(tabs: tabs, selection: $selection, badge: badge, canSelect: canSelect)
                .padding(.horizontal, 22)
                .padding(.top, 4)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DeskPalette.canvasBackground)
    }
}

struct DeskSettingsPageHeading: View {
    let title: String
    var detail: String? = nil
    var badgeText: String? = nil
    var badgeTint: Color = DeskPalette.emerald

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(DeskPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let badgeText {
                    DeskPillBadge(text: badgeText, symbol: "circle.fill", tint: badgeTint)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum NetworkWorkspaceSubTab: String, CaseIterable, Hashable {
    case viewerMappings
    case tailnet
    case relayNodes
    case hostApprovals
}

enum DiagnosticsWorkspaceSubTab: String, CaseIterable, Hashable {
    case benchmark
    case traffic
}

enum PreferencesWorkspaceSubTab: String, CaseIterable, Hashable {
    case keyboard
    case privacy
    case connectionDefaults
    case updates
}

private enum NetworkWorkspacePage: Hashable {
    case network(NetworkWorkspaceSubTab)
    case diagnostics(DiagnosticsWorkspaceSubTab)

    static let tabs: [(id: Self, title: String)] = [
        (.network(.viewerMappings), "端口映射"),
        (.network(.relayNodes), "自托管中继"),
        (.network(.tailnet), "Tailscale"),
        (.network(.hostApprovals), "本机映射授权"),
        (.diagnostics(.benchmark), "线路实测"),
        (.diagnostics(.traffic), "地址流量")
    ]
}

struct NetworkWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var host: DeskModel
    @ObservedObject var portMappings: PortMappingManager
    @ObservedObject private var benchmarkStore: RouteQualityBenchmarkStore
    @Binding var subTab: NetworkWorkspaceSubTab
    @Binding var preferredDeviceID: UUID?
    let openBenchmarkForRecord: (ConnectionRecord?) -> Void
    let openDiagnostics: (DiagnosticsWorkspaceSubTab) -> Void

    init(
        viewer: DeskModel,
        host: DeskModel,
        portMappings: PortMappingManager,
        subTab: Binding<NetworkWorkspaceSubTab>,
        preferredDeviceID: Binding<UUID?>,
        openBenchmarkForRecord: @escaping (ConnectionRecord?) -> Void,
        openDiagnostics: @escaping (DiagnosticsWorkspaceSubTab) -> Void
    ) {
        self.viewer = viewer
        self.host = host
        self.portMappings = portMappings
        self._benchmarkStore = ObservedObject(wrappedValue: viewer.routeBenchmarkStore)
        self._subTab = subTab
        self._preferredDeviceID = preferredDeviceID
        self.openBenchmarkForRecord = openBenchmarkForRecord
        self.openDiagnostics = openDiagnostics
    }

    var body: some View {
        DeskSettingsPageTabs(
            tabs: NetworkWorkspacePage.tabs,
            selection: Binding(
                get: { .network(subTab) },
                set: { page in
                    switch page {
                    case .network(let tab): subTab = tab
                    case .diagnostics(let tab): openDiagnostics(tab)
                    }
                }
            ),
            badge: { page in
                if page == .network(.hostApprovals) && host.portMappings.hostApprovalPending {
                    return ("待确认请求", DeskPalette.amber)
                }
                return nil
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch subTab {
                    case .viewerMappings:
                        PortMappingView(
                            model: viewer,
                            manager: portMappings,
                            done: {},
                            embedded: true,
                            workspaceDeviceID: $preferredDeviceID
                        ) { record in
                            deviceRouteSummaryCard(for: record)
                        }
                    case .relayNodes:
                        DeskSettingsPageHeading(
                            title: "自托管中继",
                            detail: "两端主动连接同一自建节点；配置在下次共享或连接时生效"
                        )
                        RelaySettingsView(
                            enabled: viewer.relayEnabled,
                            nodes: viewer.relayNodes,
                            deviceID: viewer.relayDeviceID,
                            locked: viewer.relaySettingsLocked,
                            measurements: viewer.relayNodeMeasurements,
                            embedded: true,
                            loadTrust: viewer.relayCertificate,
                            saveNode: viewer.saveRelayNode,
                            save: viewer.saveRelayConfiguration
                        )
                    case .tailnet:
                        TailnetSettingsView(tailnet: viewer.services.tailnet)
                    case .hostApprovals:
                        DeskSettingsPageHeading(title: "本机映射授权")
                        PortMappingHostView(
                            model: host,
                            manager: host.portMappings,
                            done: {},
                            embedded: true
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(DeskPalette.canvasBackground)
    }

    @ViewBuilder
    private func deviceRouteSummaryCard(for record: ConnectionRecord) -> some View {
        let descriptor = viewer.buildRouteBenchmarkTargetDescriptor(for: record)
        let runs = descriptor.hasIdentity ? benchmarkStore.archive.runs(matching: descriptor) : []
        let assessment = RouteBenchmarkHistoryEvaluator.assess(runs: runs, targetOverride: descriptor)

        DeskSurfaceCard(padding: 14, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("线路质量档案")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DeskPalette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let assessment {
                        DeskPillBadge(
                            text: "综合 \(assessment.overallScore) 分",
                            tint: assessment.overallGrade.deskTint
                        )
                    }
                }

                if let assessment {
                    if let best = assessment.recommendedRoute {
                        Text("长期推荐 · \(best.candidate.title)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DeskPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(assessment.recommendationReason)
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("尚未执行过线路质量实测。实测可对比直连与各中继节点的帧率、延迟和 UDP 丢包。")
                        .font(.caption)
                        .foregroundStyle(DeskPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if let assessment {
                        Text("累计 \(assessment.runCount) 次实测 · \(assessment.overallGrade.title)")
                            .font(.caption)
                            .foregroundStyle(DeskPalette.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        openBenchmarkForRecord(record)
                    } label: {
                        Label("前往线路实测…", systemImage: "speedometer")
                    }
                    .buttonStyle(DeskButtonStyle(.secondary, compact: true))
                    .disabled(viewer.active || viewer.working)
                }

                if let assessment, !assessment.routeSummaries.isEmpty {
                    DisclosureGroup("候选线路概览") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(assessment.routeSummaries.prefix(3))) { item in
                                HStack {
                                    Text(item.candidate.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 6)
                                    if let rtt = item.meanRTTMilliseconds {
                                        Text(String(format: "延迟 %.1f ms", rtt))
                                    }
                                    if let loss = item.meanUDPLossPercent {
                                        Text(String(format: "丢包 %.1f%%", loss))
                                    }
                                    if let fps = item.meanFPS {
                                        Text(String(format: "%.0f fps", fps))
                                    }
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DeskPalette.secondary)
                            }
                        }
                        .padding(.top, 7)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}

struct DiagnosticsWorkspaceView: View {
    @ObservedObject var models: DeskModels
    @ObservedObject var viewer: DeskModel
    @ObservedObject var history: TrafficHistoryFeed
    @Binding var subTab: DiagnosticsWorkspaceSubTab
    @Binding var benchmarkTargetRecord: ConnectionRecord?
    let openNetwork: (NetworkWorkspaceSubTab) -> Void
    @State private var inlineRunner: RouteQualityBenchmarkRunner?

    var body: some View {
        DeskSettingsPageTabs(
            tabs: NetworkWorkspacePage.tabs,
            selection: Binding(
                get: { .diagnostics(subTab) },
                set: { page in
                    switch page {
                    case .network(let tab): openNetwork(tab)
                    case .diagnostics(let tab): subTab = tab
                    }
                }
            ),
            badge: { page in
                if page == .network(.hostApprovals) && models.host.portMappings.hostApprovalPending {
                    return ("待确认请求", DeskPalette.amber)
                }
                return nil
            },
            canSelect: { !viewer.isRunningRouteBenchmark || $0 == .diagnostics(subTab) }
        ) {
            switch subTab {
            case .benchmark:
                if let runner = inlineRunner {
                    RouteQualityBenchmarkView(
                        runner: runner,
                        onConnectCandidate: { candidate, record in
                            runner.shutdown()
                            DispatchQueue.main.async {
                                _ = models.connectUsingBenchmarkCandidate(candidate, record: record)
                            }
                        },
                        onClose: {
                            runner.shutdown()
                        },
                        embedded: true,
                        availableRecords: viewer.connections,
                        selectedTargetRecord: benchmarkTargetRecord,
                        onSelectTargetRecord: { rebuildRunner(for: $0) }
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .traffic:
                TrafficStatisticsView(model: viewer, history: history, reportHistory: viewer.connectionReportHistory,
                                      reportHistoryStore: viewer.connectionReportHistoryStore, done: {}, embedded: true)
            }
        }
        .background(DeskPalette.canvasBackground)
        .onAppear {
            if inlineRunner == nil {
                if benchmarkTargetRecord == nil, viewer.address.trimmingCharacters(in: .whitespaces).isEmpty {
                    benchmarkTargetRecord = viewer.connections.first
                }
                inlineRunner = RouteQualityBenchmarkRunner(model: viewer, record: benchmarkTargetRecord)
            }
        }
        .onChange(of: benchmarkTargetRecord?.id) { _, _ in
            rebuildRunner(for: benchmarkTargetRecord)
        }
        .onDisappear {
            inlineRunner?.shutdown()
        }
    }

    private func rebuildRunner(for record: ConnectionRecord?) {
        inlineRunner?.shutdown()
        benchmarkTargetRecord = record
        inlineRunner = RouteQualityBenchmarkRunner(model: viewer, record: record)
    }
}

struct PreferencesWorkspaceView: View {
    @ObservedObject var viewer: DeskModel
    @ObservedObject var updates: UpdateController
    @Binding var subTab: PreferencesWorkspaceSubTab
    let activeSessions: [ActiveRemoteSessionSummary]
    let openSession: (UUID) -> Void
    let openBenchmark: () -> Void
    let openTraffic: () -> Void

    private var connectedSessions: [ActiveRemoteSessionSummary] {
        activeSessions.filter(\.connected)
    }

    var body: some View {
        DeskSettingsPageTabs(
            tabs: [
                (.keyboard, "键盘与快捷键"),
                (.connectionDefaults, "连接默认项"),
                (.privacy, "隐私偏好"),
                (.updates, "软件更新")
            ],
            selection: $subTab,
            badge: { tab in
                if tab == .updates && (updates.manifest != nil || updates.manualReleaseURL != nil) {
                    return ("有新版本", DeskPalette.accent)
                }
                return nil
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch subTab {
                    case .keyboard:
                        DeskSettingsPageHeading(title: "键盘与快捷键", detail: "设置系统快捷键与 Caps Lock 转发。")
                        CapsLockSettingsView(model: viewer, done: {}, embedded: true)
                    case .privacy:
                        DeskSettingsPageHeading(title: "被控端隐私与安全", detail: "管理会话期间的隐私策略和本机保存的凭据。")
                        privacyContent
                    case .connectionDefaults:
                        DeskSettingsPageHeading(
                            title: "连接默认项",
                            detail: "用于新建连接的显示和传输设置。即时调整请在对应会话窗口进行。"
                        )
                        ConnectionSettingsView(
                            model: viewer,
                            openCaps: { subTab = .keyboard },
                            openTraffic: openTraffic,
                            openEffects: { subTab = .privacy },
                            openBenchmark: openBenchmark,
                            embedded: true
                        )
                    case .updates:
                        DeskSettingsPageHeading(title: "软件更新", detail: "查看版本与更新策略。")
                        UpdateSettingsPanel(controller: updates)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(DeskPalette.canvasBackground)
    }

    @ViewBuilder
    private var privacyContent: some View {
        if !viewer.connected && !connectedSessions.isEmpty {
            DeskSettingsGroup(title: "当前已连接会话（可在对应会话窗口即时调整）") {
                ForEach(connectedSessions) { session in
                    if session.id != connectedSessions.first?.id { Divider() }
                    DeskSettingsRow(title: session.title, detail: session.endpointLabel) {
                        Button("切到会话窗口") { openSession(session.id) }
                            .buttonStyle(DeskButtonStyle(.secondary))
                            .accessibilityLabel("切到 \(session.title) 的会话窗口")
                    }
                }
            }
        }
        SessionEffectsView(model: viewer, done: {}, embedded: true)
    }
}
