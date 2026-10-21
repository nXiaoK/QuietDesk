import AppKit
import Combine

/// State both role models share. The traffic history file has one writer and one observer.
@MainActor
final class DeskServices {
    let trafficHistoryStore = TrafficHistoryStore()
    let trafficHistory = TrafficHistoryFeed()

    init() {
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
        didSet { if oldValue != selected { current.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) } }
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
        selected = host.autoStartSharing ? .host : .viewer
    }

    var changes: AnyPublisher<Void, Never> {
        viewer.objectWillChange.merge(with: host.objectWillChange).eraseToAnyPublisher()
    }
    var mainWindow: NSWindow? { viewer.mainWindow ?? host.mainWindow }
    var updatePromptBlocked: Bool { all.contains { $0.updatePromptBlocked } }

    func attachWindow(_ window: NSWindow) { all.forEach { $0.attachWindow(window) } }
    /// The host model owns launch handling: minimizing at login and starting automatic sharing.
    func initialLaunch(atLogin: Bool) { host.initialLaunch(atLogin: atLogin) }
    func prepareShowWindow() { all.forEach { $0.prepareShowWindow() } }
    func setPerformanceDiagnosticsEnabled(_ enabled: Bool) { all.forEach { $0.setPerformanceDiagnosticsEnabled(enabled) } }
    func flushPerformanceDiagnostics() { all.forEach { $0.flushPerformanceDiagnostics() } }
    func stopAll() { all.forEach { $0.stop() } }
}
