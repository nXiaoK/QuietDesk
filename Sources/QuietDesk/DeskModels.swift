import AppKit
import Combine

/// State both role models share. The traffic history file has one writer and one observer.
@MainActor
final class DeskServices {
    let trafficHistoryStore = TrafficHistoryStore()
    let trafficHistory = TrafficHistoryFeed()
    let portMappings: PortMappingManager
    let routeBenchmarkStore = RouteQualityBenchmarkStore()

    init() {
        portMappings = PortMappingManager(localDeviceID: trafficHistoryStore.localDeviceID)
        let feed = trafficHistory
        trafficHistoryStore.observe { [weak feed] records, legacyRecords, message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { feed?.update(records: records, legacyRecords: legacyRecords, error: message) }
            }
        }
    }
}

/// Runs the viewer and the host side by side, so sharing can stay on while this Mac connects to
/// another one. Only one of them holds a control session at a time; each model enforces that
/// through its sibling.
@MainActor
final class DeskModels: ObservableObject {
    /// The role shown in the main window; it does not stop the other role.
    @Published var selected: DeskModel.Mode {
        didSet {
            if oldValue != selected {
                current.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
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
    let viewer: DeskModel
    let host: DeskModel
    var current: DeskModel { selected == .host ? host : viewer }
    var all: [DeskModel] { [viewer, host] }

    init() {
        let services = DeskServices()
        let viewer = DeskModel(mode: .viewer, services: services)
        let host = DeskModel(mode: .host, services: services)
        viewer.sibling = host
        host.sibling = viewer
        self.viewer = viewer
        self.host = host
        let initialHost = host.autoStartSharing
        selected = initialHost ? .host : .viewer
        workspaceSection = initialHost ? .sharing : .connect
    }

    var changes: AnyPublisher<Void, Never> {
        viewer.objectWillChange.merge(with: host.objectWillChange, viewer.portMappings.objectWillChange).eraseToAnyPublisher()
    }
    var mainWindow: NSWindow? { viewer.mainWindow ?? host.mainWindow }
    var updatePromptBlocked: Bool { all.contains { $0.updatePromptBlocked } }

    func attachWindow(_ window: NSWindow) { all.forEach { $0.attachWindow(window) } }
    /// The host model owns launch handling: minimizing at login and starting automatic sharing.
    func initialLaunch(atLogin: Bool) { host.initialLaunch(atLogin: atLogin) }
    func prepareShowWindow() { all.forEach { $0.prepareShowWindow() } }
    func minimizeForBackgroundLaunch() { host.minimizeForBackgroundLaunch() }
    func setPerformanceDiagnosticsEnabled(_ enabled: Bool) { all.forEach { $0.setPerformanceDiagnosticsEnabled(enabled) } }
    func flushPerformanceDiagnostics() { all.forEach { $0.flushPerformanceDiagnostics() } }
    func stopAll() {
        viewer.portMappings.stopAllMappings()
        host.setMappingHosting(false)
        all.forEach { $0.stop() }
    }
}
