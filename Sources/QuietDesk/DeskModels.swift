import AppKit
import Combine
import QuietDeskCore

/// State all role and viewer session models share. The traffic history file has one writer and one observer.
@MainActor
final class DeskServices {
    private struct WeakModel {
        weak var value: DeskModel?
    }

    let trafficHistoryStore = TrafficHistoryStore()
    let trafficHistory = TrafficHistoryFeed()
    let portMappings: PortMappingManager
    let routeBenchmarkStore = RouteQualityBenchmarkStore()
    private var registeredModels: [WeakModel] = []

    init() {
        portMappings = PortMappingManager(localDeviceID: trafficHistoryStore.localDeviceID)
        let feed = trafficHistory
        trafficHistoryStore.observe { [weak feed] records, legacyRecords, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { feed?.update(records: records, legacyRecords: legacyRecords, error: message) }
            }
        }
    }

    func register(_ model: DeskModel) {
        registeredModels.removeAll { $0.value == nil || $0.value === model }
        registeredModels.append(WeakModel(value: model))
    }

    func unregister(_ model: DeskModel) {
        registeredModels.removeAll { $0.value == nil || $0.value === model }
        refreshDesktopActiveOnPortMappings()
    }

    var allModels: [DeskModel] {
        registeredModels.compactMap(\.value)
    }

    func otherModels(excluding model: DeskModel) -> [DeskModel] {
        allModels.filter { $0 !== model }
    }

    func refreshDesktopActiveOnPortMappings() {
        let hostActive = allModels.contains { $0.mode == .host && $0.hasActivePeerConnection }
        let viewerCount = allModels.filter { $0.mode == .viewer && $0.hasActivePeerConnection }.count
        portMappings.setDesktopActive(
            MultiSessionPolicy.isDesktopTrafficActive(
                hostPeerActive: hostActive,
                viewerPeersActiveCount: viewerCount
            )
        )
    }

    func connectedViewerSession(forRecordID recordID: UUID) -> DeskModel? {
        allModels.first { $0.mode == .viewer && $0.connected && $0.currentRecordID == recordID }
    }

    func connectedViewerRecordIDs(excluding model: DeskModel) -> Set<UUID> {
        Set(otherModels(excluding: model).compactMap {
            $0.mode == .viewer && $0.connected ? $0.currentRecordID : nil
        })
    }

    var anyModelBlocksRelaySettings: Bool {
        allModels.contains { $0.active || $0.working || $0.mappingHosting || $0.isRunningRouteBenchmark }
    }

    func notifyConnectionsChanged(excluding sender: DeskModel) {
        for item in otherModels(excluding: sender) {
            item.reloadSavedConnections()
        }
    }
}

/// Coordinates the workspace hub viewer model, the local host sharing model, and any number of
/// concurrent outgoing remote desktop viewer sessions (`A -> {B, C}` and `A -> B -> D`).
@MainActor
final class DeskModels: ObservableObject {
    /// The role shown in the main workspace hub window; it never stops host sharing or remote sessions.
    @Published var selected: DeskModel.Mode {
        didSet {
            if oldValue != selected {
                current.refreshPermissions(checkScreenCapture: selected == .host, retryCapsLock: true)
                if selected == .host, workspaceSection != .sharing {
                    workspaceSection = .sharing
                } else if selected == .viewer, workspaceSection == .sharing {
                    workspaceSection = .connect
                }
            }
        }
    }

    @Published var workspaceSection: DeskWorkspaceSection {
        didSet {
            guard oldValue != workspaceSection else { return }
            switch workspaceSection {
            case .sharing:
                if selected != .host { selected = .host }
            case .connect, .benchmark:
                if selected != .viewer { selected = .viewer }
            case .network, .preferences:
                for item in all {
                    item.refreshPermissions(checkScreenCapture: item.mode == .host, retryCapsLock: item.mode == .viewer)
                }
            }
        }
    }

    let services: DeskServices
    let viewer: DeskModel
    let host: DeskModel
    @Published private(set) var viewerSessions: [DeskModel] = []

    var openSessionWindow: ((UUID) -> Void)?
    var onConnectionDiagnosticReport: ((ConnectionDiagnosticReport) -> Void)? {
        didSet {
            viewer.onConnectionDiagnosticReport = onConnectionDiagnosticReport
            for session in viewerSessions {
                session.onConnectionDiagnosticReport = onConnectionDiagnosticReport
            }
        }
    }

    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    private let sessionChangeRelay = PassthroughSubject<Void, Never>()
    private var fullScreenCloseObservers: [UUID: NSObjectProtocol] = [:]

    var current: DeskModel { selected == .host ? host : viewer }
    var all: [DeskModel] { [viewer, host] + viewerSessions }

    init(services: DeskServices? = nil) {
        let services = services ?? DeskServices()
        self.services = services
        let viewer = DeskModel(mode: .viewer, services: services)
        let host = DeskModel(mode: .host, services: services)
        self.viewer = viewer
        self.host = host
        let initialHost = host.autoStartSharing
        selected = initialHost ? .host : .viewer
        workspaceSection = initialHost ? .sharing : .connect
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge4(
            viewer.objectWillChange,
            host.objectWillChange,
            viewer.portMappings.objectWillChange,
            sessionChangeRelay
        )
        .eraseToAnyPublisher()
    }

    var mainWindow: NSWindow? { viewer.mainWindow ?? host.mainWindow }
    var keyViewerSession: DeskModel? { viewerSessions.first { $0.mainWindow?.isKeyWindow == true } }
    var preferredCommandViewer: DeskModel { keyViewerSession ?? viewerSessions.first ?? viewer }
    var preferredAlertWindow: NSWindow? { keyViewerSession?.mainWindow ?? mainWindow ?? viewerSessions.compactMap(\.mainWindow).first }
    var updatePromptBlocked: Bool { all.contains { $0.updatePromptBlocked } }
    var hasActiveViewerSession: Bool { viewer.isControllingAnotherMac || viewerSessions.contains(where: \.isControllingAnotherMac) }
    var hasConnectedViewerSession: Bool { viewer.connected || viewerSessions.contains(where: \.connected) }
    var anyViewerFullScreen: Bool { viewer.isFullScreen || viewerSessions.contains(where: \.isFullScreen) }
    var activeSessionSummaries: [ActiveRemoteSessionSummary] { viewerSessions.map(\.activeSessionSummary) }

    func session(for id: UUID) -> DeskModel? {
        viewerSessions.first { $0.sessionID == id }
    }

    func existingSession(matching identity: RemoteSessionTargetIdentity) -> DeskModel? {
        let candidates = viewerSessions.map { (id: $0.sessionID, target: $0.sessionTargetIdentity) }
        guard let matchedID = MultiSessionPolicy.existingSessionID(matching: identity, in: candidates) else {
            return nil
        }
        return session(for: matchedID)
    }

    func existingSession(for record: ConnectionRecord) -> DeskModel? {
        let identity = RemoteSessionTargetIdentity(
            recordID: record.id,
            address: record.address,
            port: record.port,
            relayDeviceID: record.relay?.deviceID
        )
        return existingSession(matching: identity)
    }

    func focusViewerSession(id: UUID) {
        guard let session = session(for: id) else { return }
        focusViewerSession(session)
    }

    func focusViewerSession(_ session: DeskModel) {
        if let window = session.mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            openSessionWindow?(session.sessionID)
        }
    }

    @discardableResult
    func connectFromHub() -> DeskModel? {
        guard let launch = viewer.prepareSessionLaunch(savedRelayRoute: nil) else { return nil }
        return activateOrSpawnViewerSession(with: launch)
    }

    @discardableResult
    func quickConnect(_ record: ConnectionRecord) -> DeskModel? {
        if let existing = existingSession(for: record),
           existing.active || existing.working || existing.reconnecting {
            viewer.clearConnectionError()
            focusViewerSession(existing)
            return existing
        }
        guard let launch = viewer.prepareQuickConnectLaunch(record) else { return nil }
        return activateOrSpawnViewerSession(with: launch)
    }

    @discardableResult
    func connectOrFillDiscoveredHost(_ discovered: DiscoveredLANHost) -> DeskModel? {
        let candidateIdentity = RemoteSessionTargetIdentity(
            recordID: BonjourDiscovery.matchingRecord(for: discovered, in: viewer.connections)?.id,
            address: discovered.host,
            port: discovered.port,
            relayDeviceID: nil
        )
        if let existing = existingSession(matching: candidateIdentity),
           existing.active || existing.working || existing.reconnecting {
            viewer.clearConnectionError()
            focusViewerSession(existing)
            return existing
        }
        guard let launch = viewer.prepareDiscoveredHostLaunch(discovered) else { return nil }
        return activateOrSpawnViewerSession(with: launch)
    }

    @discardableResult
    func connectUsingBenchmarkCandidate(_ candidate: RouteBenchmarkCandidate, record: ConnectionRecord?) -> DeskModel? {
        guard let launch = viewer.prepareBenchmarkCandidateLaunch(candidate, record: record) else { return nil }
        return activateOrSpawnViewerSession(with: launch)
    }

    private func activateOrSpawnViewerSession(with launch: DeskModel.SessionLaunch) -> DeskModel {
        if let existing = existingSession(matching: launch.identity) {
            if !existing.active && !existing.working && !existing.reconnecting {
                existing.startLaunchedSession(launch)
            }
            focusViewerSession(existing)
            return existing
        }
        let session = DeskModel(mode: .viewer, services: services)
        session.onConnectionDiagnosticReport = onConnectionDiagnosticReport
        registerViewerSession(session)
        session.startLaunchedSession(launch)
        openSessionWindow?(session.sessionID)
        return session
    }

    private func registerViewerSession(_ session: DeskModel) {
        guard !viewerSessions.contains(where: { $0.sessionID == session.sessionID }) else { return }
        sessionCancellables[session.sessionID] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.sessionChangeRelay.send(())
        }
        viewerSessions.append(session)
        sessionChangeRelay.send(())
    }

    func disconnectViewerSession(id: UUID) {
        guard let session = session(for: id) else { return }
        disconnectViewerSession(session)
    }

    func disconnectViewerSession(_ session: DeskModel) {
        let id = session.sessionID
        let window = session.mainWindow
        let wasFullScreen = window?.styleMask.contains(.fullScreen) == true
        session.stop()
        unregisterViewerSession(id: id)
        guard let window else { return }
        if wasFullScreen {
            if let prior = fullScreenCloseObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(prior)
            }
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let removed = self?.fullScreenCloseObservers.removeValue(forKey: id) {
                        NotificationCenter.default.removeObserver(removed)
                    }
                    window?.close()
                }
            }
            fullScreenCloseObservers[id] = observer
        } else {
            window.close()
        }
    }

    func disconnectAllViewerSessions() {
        for session in viewerSessions {
            disconnectViewerSession(session)
        }
        if viewer.active || viewer.working || viewer.reconnecting {
            viewer.stop()
        }
    }

    func windowDidCloseForSession(id: UUID) {
        if let observer = fullScreenCloseObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let session = session(for: id) {
            if session.active || session.working || session.reconnecting || session.connected {
                session.stop()
            }
            unregisterViewerSession(id: id)
        }
    }

    private func unregisterViewerSession(id: UUID) {
        sessionCancellables.removeValue(forKey: id)
        if let removed = viewerSessions.first(where: { $0.sessionID == id }) {
            services.unregister(removed)
        }
        viewerSessions.removeAll { $0.sessionID == id }
        sessionChangeRelay.send(())
    }

    func releaseAllViewerControls() {
        viewer.canvas.releaseControl()
        for session in viewerSessions {
            session.canvas.releaseControl()
        }
    }

    func attachWindow(_ window: NSWindow) {
        viewer.attachWindow(window)
        host.attachWindow(window)
    }

    /// The host model owns launch handling: minimizing at login and starting automatic sharing.
    func initialLaunch(atLogin: Bool) { host.initialLaunch(atLogin: atLogin) }
    func prepareShowWindow() { all.forEach { $0.prepareShowWindow() } }
    func minimizeForBackgroundLaunch() { host.minimizeForBackgroundLaunch() }
    func setPerformanceDiagnosticsEnabled(_ enabled: Bool) { all.forEach { $0.setPerformanceDiagnosticsEnabled(enabled) } }
    func flushPerformanceDiagnostics() { all.forEach { $0.flushPerformanceDiagnostics() } }

    func stopAll() {
        viewer.portMappings.stopAllMappings()
        host.setMappingHosting(false)
        for session in viewerSessions {
            session.stop()
            services.unregister(session)
        }
        sessionCancellables.removeAll()
        viewerSessions.removeAll()
        viewer.stop()
        host.stop()
    }
}
