import AppKit
import QuietDeskCore
import SwiftUI

struct DeskSettingsPageTabs<Tab: Hashable, Content: View>: View {
    let tabs: [(id: Tab, title: String)]
    @Binding var selection: Tab
    var badge: (Tab) -> (text: String, tint: Color)? = { _ in nil }
    var canSelect: (Tab) -> Bool = { _ in true }
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs, id: \.id) { tab in
                        let isSelected = selection == tab.id
                        let isEnabled = canSelect(tab.id)
                        Button {
                            selection = tab.id
                        } label: {
                            HStack(spacing: 6) {
                                Text(tab.title)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                                if let tag = badge(tab.id) {
                                    Circle()
                                        .fill(tag.tint)
                                        .frame(width: 6, height: 6)
                                        .accessibilityLabel(tag.text)
                                }
                            }
                            .foregroundStyle(isSelected ? DeskPalette.ink : DeskPalette.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6.5)
                            .background(
                                isSelected ? DeskPalette.cardBackground : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(DeskPalette.hairline, lineWidth: 0.8)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.52)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(DeskPalette.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.horizontal, 28)
            .frame(minHeight: 46)

            Divider()

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
                    .font(.system(size: 23, weight: .bold))
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
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
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

        DeskSurfaceCard(padding: 15, cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    if let assessment {
                        let tint = assessment.overallGrade.deskTint
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(tint.opacity(0.14))
                                .frame(width: 42, height: 42)
                            Text("\(assessment.overallScore)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(tint)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DeskPalette.subtleFill)
                                .frame(width: 42, height: 42)
                            Image(systemName: "speedometer")
                                .font(.system(size: 18))
                                .foregroundStyle(DeskPalette.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("\(ConnectionEntryPresentation.title(record)) · 线路质量档案")
                                .font(.system(size: 13.5, weight: .semibold))
                            if let assessment {
                                DeskPillBadge(
                                    text: "累计 \(assessment.runCount) 次实测 · \(assessment.overallGrade.title)",
                                    tint: assessment.overallGrade.deskTint
                                )
                            }
                        }
                        if let assessment, let best = assessment.recommendedRoute {
                            Text("长期推荐：\(best.candidate.title) — \(assessment.recommendationReason)")
                                .font(.caption)
                                .foregroundStyle(DeskPalette.secondary)
                                .lineLimit(2)
                        } else {
                            Text("尚未执行过线路质量实测；实测可对比直连与各中继节点的真实帧率、延迟与 UDP 丢包。")
                                .font(.caption)
                                .foregroundStyle(DeskPalette.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Button("前往线路实测…") {
                        openBenchmarkForRecord(record)
                    }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .disabled(viewer.active || viewer.working)
                }

                if let assessment, !assessment.routeSummaries.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(Array(assessment.routeSummaries.prefix(3).enumerated()), id: \.element.id) { idx, item in
                            let isBest = idx == 0 && item.overallGrade != .unreachable
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.candidate.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if isBest {
                                        Text("最佳")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(DeskPalette.emerald)
                                    }
                                }
                                HStack(spacing: 8) {
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
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(DeskPalette.secondary)
                                .lineLimit(1)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isBest ? DeskPalette.emerald.opacity(0.08) : DeskPalette.subtleFill,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isBest ? DeskPalette.emerald.opacity(0.35) : DeskPalette.hairline, lineWidth: 0.8)
                            }
                        }
                    }
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
                TrafficStatisticsView(model: viewer, history: history, done: {}, embedded: true)
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
                        DeskSettingsPageHeading(title: "键盘与快捷键")
                        CapsLockSettingsView(model: viewer, done: {}, embedded: true)
                    case .privacy:
                        DeskSettingsPageHeading(title: "被控端隐私与安全")
                        privacyContent
                    case .connectionDefaults:
                        DeskSettingsPageHeading(title: "连接默认项")
                        ConnectionSettingsView(
                            model: viewer,
                            openCaps: { subTab = .keyboard },
                            openTraffic: openTraffic,
                            openEffects: { subTab = .privacy },
                            openBenchmark: openBenchmark,
                            embedded: true
                        )
                    case .updates:
                        DeskSettingsPageHeading(title: "软件更新")
                        UpdateSettingsPanel(controller: updates)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 880, alignment: .leading)
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
