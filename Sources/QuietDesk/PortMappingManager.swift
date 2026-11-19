import AppKit
import CryptoKit
import QuietDeskCore

extension PortMappingTarget {
    var mappingAddress: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

enum PortMappingScope: String, Codable, CaseIterable {
    case session, independent

    var title: String { self == .session ? "随远控会话" : "独立运行" }
}

struct PortMappingRule: Identifiable, Codable, Equatable {
    let id: UUID
    let deviceID: UUID
    var name: String
    var localPort: UInt16
    var target: PortMappingTarget
    var scope: PortMappingScope
}

@MainActor
final class PortMappingManager: ObservableObject {
    typealias Route = (_ ready: @escaping @MainActor (String, UInt16, PairingKey) -> Void,
                       _ failed: @escaping @MainActor (String) -> Void) throws -> (() -> Void)

    private final class RunningRule {
        let rule: PortMappingRule
        var viewer: PortMappingViewer?
        var closeRoute: (() -> Void)?
        init(_ rule: PortMappingRule) { self.rule = rule }
    }

    private struct Grants: Codable {
        var pairingIdentity: Data
        var targets: Set<PortMappingTarget>
    }

    @Published private(set) var rules: [PortMappingRule] = []
    @Published private(set) var states: [UUID: PortMappingState] = [:]
    @Published private(set) var pendingTargets: [PortMappingTarget] = []
    @Published private(set) var allowedTargets: Set<PortMappingTarget> = []
    @Published private(set) var storageError: String?
    var onApprovalVisibilityChanged: ((Bool) -> Void)?
    var hostApprovalPending: Bool { !pendingTargets.isEmpty }
    var hasRunningMappings: Bool { !running.isEmpty }

    private let defaults: UserDefaults
    private static let rulesKey = "tcpMappingRules.v1"
    private static let grantsKey = "tcpMappingGrants.v1"
    private var running: [UUID: RunningRule] = [:]
    private var loadFailed = false
    private let traffic = PortMappingTraffic()
    private var host: PortMappingHost?
    private var hostGeneration: UUID?
    private var grants: Grants?
    private var decisions: [PortMappingTarget: [(Bool) -> Void]] = [:]
    private var requestedAt: [PortMappingTarget: TimeInterval] = [:]
    private var prompt: PortMappingApprovalPanel?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults.data(forKey: Self.rulesKey) { rules = try JSONDecoder().decode([PortMappingRule].self, from: data) }
            if let data = defaults.data(forKey: Self.grantsKey) { grants = try JSONDecoder().decode(Grants.self, from: data) }
        } catch {
            loadFailed = true
            storageError = "读取端口映射配置失败，已保留原记录：\(error.localizedDescription)"
        }
    }

    private func save<Value: Encodable>(_ value: Value, key: String) throws {
        if loadFailed { throw DeskError.invalid(storageError ?? "无法读取映射配置") }
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    func saveRule(_ rule: PortMappingRule) throws {
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule } else { next.append(rule) }
        try save(next, key: Self.rulesKey)
        rules = next
        stop(rule.id)
    }

    func deleteRule(_ id: UUID) throws {
        let next = rules.filter { $0.id != id }
        try save(next, key: Self.rulesKey)
        stop(id)
        rules = next
    }

    func removeDevice(_ id: UUID) {
        let removed = rules.filter { $0.deviceID == id }
        guard !removed.isEmpty else { return }
        removed.forEach { stop($0.id) }
        let next = rules.filter { $0.deviceID != id }
        do { try save(next, key: Self.rulesKey); rules = next }
        catch { storageError = error.localizedDescription }
    }

    func isEnabled(_ id: UUID) -> Bool { running[id] != nil }

    func start(_ rule: PortMappingRule, fallback: Route? = nil, route: Route) throws {
        guard running[rule.id] == nil else { return }
        if running.values.contains(where: { $0.rule.localPort == rule.localPort }) {
            let reason = "本地端口 \(rule.localPort) 已用于另一条映射，请修改本地端口。"
            states[rule.id] = .failed(reason)
            throw DeskError.invalid(reason)
        }
        let run = RunningRule(rule)
        running[rule.id] = run
        try startRoute(run, fallback: fallback, route: route)
    }

    private func startRoute(_ run: RunningRule, fallback: Route?, route: Route) throws {
        let rule = run.rule
        states[rule.id] = .authorizing
        do {
            let cleanup = try route({ [weak self, weak run] address, port, key in
                guard let self, let run, self.running[rule.id] === run else { return }
                do {
                    let viewer = try PortMappingViewer(host: address, port: port, key: key, target: rule.target,
                                                       localPort: rule.localPort, traffic: self.traffic)
                    run.viewer = viewer
                    viewer.onState = { [weak self, weak run, weak viewer] state in
                        DispatchQueue.main.async {
                            guard let self, let run, let viewer, self.running[rule.id] === run, run.viewer === viewer else { return }
                            if case .failed = state, let fallback, viewer.mayTryAlternateRoute {
                                self.finish(rule.id, state: nil)
                                do { try self.start(rule, route: fallback) }
                                catch { self.states[rule.id] = .failed(error.localizedDescription) }
                                return
                            }
                            switch state {
                            case .failed, .stopped: self.finish(rule.id, state: state)
                            default: self.states[rule.id] = state
                            }
                        }
                    }
                    viewer.start()
                } catch { self.finish(rule.id, state: .failed(error.localizedDescription)) }
            }, { [weak self, weak run] message in
                guard let self, let run, self.running[rule.id] === run else { return }
                self.finish(rule.id, state: .failed(message))
            })
            if running[rule.id] === run { run.closeRoute = cleanup } else { cleanup() }
        } catch {
            finish(rule.id, state: .failed(error.localizedDescription))
            throw error
        }
    }

    private func finish(_ id: UUID, state: PortMappingState?) {
        let run = running.removeValue(forKey: id)
        states[id] = state
        run?.viewer?.stop()
        run?.closeRoute?()
    }

    func stop(_ id: UUID) { finish(id, state: nil) }

    func stopSessionMappings() {
        for run in Array(running.values) where run.rule.scope == .session { stop(run.rule.id) }
    }

    func stopAllMappings() {
        for id in Array(running.keys) { stop(id) }
    }

    func setDesktopActive(_ active: Bool) {
        traffic.setDesktopActive(active)
    }

    func noteVideoPressure() { traffic.noteVideoPressure() }

    func observeVideo(_ sample: MediaPathSample) {
        if sample.networkCondition == .congested || sample.networkCondition == .severe { traffic.noteVideoPressure() }
        else if let delay = sample.deliveryMilliseconds { traffic.noteVideoDeliveryDelay(delay) }
    }

    func selectHostPairingKey(_ key: PairingKey) {
        let identity = Data(SHA256.hash(data: key.data))
        if grants?.pairingIdentity != identity {
            if grants != nil, !loadFailed { defaults.removeObject(forKey: Self.grantsKey) }
            grants = Grants(pairingIdentity: identity, targets: [])
        }
        allowedTargets = grants?.targets ?? []
    }

    func makeHost(pairingKey: PairingKey) -> PortMappingHost {
        shutdownHost()
        let generation = UUID()
        hostGeneration = generation
        selectHostPairingKey(pairingKey)
        let server = PortMappingHost(traffic: traffic) { [weak self] target, reply in
            DispatchQueue.main.async {
                guard let self, self.hostGeneration == generation, !self.loadFailed else { reply(false); return }
                if self.allowedTargets.contains(target) { reply(true); return }
                self.decisions[target, default: []].append(reply)
                if !self.pendingTargets.contains(target) {
                    self.requestedAt[target] = ProcessInfo.processInfo.systemUptime
                    self.pendingTargets.append(target)
                    self.syncApprovalPanel()
                }
            }
        }
        server.onAuthorizationWithdrawn = { [weak self] target in
            DispatchQueue.main.async {
                guard let self, self.hostGeneration == generation else { return }
                self.removeRequest(target)
            }
        }
        host = server
        return server
    }

    func presentPendingRequest() { prompt?.present() }

    func decide(_ target: PortMappingTarget, allow: Bool) {
        guard let replies = decisions[target] else { return }
        if allow {
            // A synthetic click already posted before remote input was suspended may still be in AppKit's queue.
            guard let since = requestedAt[target], let event = NSApp.currentEvent, let source = event.cgEvent,
                  Self.acceptsApproval(type: event.type, sourcePID: source.getIntegerValueField(.eventSourceUnixProcessID),
                                       timestamp: event.timestamp, requestedAt: since) else { return }
            do {
                var next = allowedTargets
                next.insert(target)
                try setAllowed(next)
            } catch { storageError = error.localizedDescription; return }
        }
        removeRequest(target)
        replies.forEach { $0(allow) }
    }

    static func acceptsApproval(type: NSEvent.EventType, sourcePID: Int64, timestamp: TimeInterval, requestedAt: TimeInterval) -> Bool {
        let userAction = [.leftMouseUp, .leftMouseDown, .keyDown, .keyUp].contains(type)
        return userAction && sourcePID != Int64(getpid()) && timestamp >= requestedAt
    }

    private func setAllowed(_ targets: Set<PortMappingTarget>) throws {
        guard var next = grants else { throw DeskError.invalid("当前配对身份未就绪") }
        next.targets = targets
        try save(next, key: Self.grantsKey)
        grants = next
        allowedTargets = targets
    }

    func revoke(_ target: PortMappingTarget) {
        do {
            var next = allowedTargets
            next.remove(target)
            try setAllowed(next)
            host?.revoke(target)
        } catch { storageError = error.localizedDescription }
    }

    func shutdownHost() {
        hostGeneration = nil
        host?.stop()
        host = nil
        let replies = decisions.values.flatMap { $0 }
        decisions.removeAll()
        requestedAt.removeAll()
        pendingTargets.removeAll()
        syncApprovalPanel()
        replies.forEach { $0(false) }
    }

    private func removeRequest(_ target: PortMappingTarget) {
        decisions.removeValue(forKey: target)
        requestedAt.removeValue(forKey: target)
        pendingTargets.removeAll { $0 == target }
        syncApprovalPanel()
    }

    private func syncApprovalPanel() {
        if hostApprovalPending {
            guard prompt == nil else { return }
            onApprovalVisibilityChanged?(true)
            let panel = PortMappingApprovalPanel(manager: self)
            prompt = panel
            panel.present()
        } else if let panel = prompt {
            prompt = nil
            panel.close()
            onApprovalVisibilityChanged?(false)
        }
    }
}
