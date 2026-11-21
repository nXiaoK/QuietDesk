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

struct TrustedRemoteMappingDevice: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var lastConnected: Date
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
        var remoteDevices: [TrustedRemoteMappingDevice]?
    }

    private struct PendingDecision {
        let deviceID: UUID?
        let reply: (Bool) -> Void
    }

    @Published private(set) var rules: [PortMappingRule] = []
    @Published private(set) var states: [UUID: PortMappingState] = [:]
    @Published private(set) var pendingTargets: [PortMappingTarget] = []
    @Published private(set) var allowedTargets: Set<PortMappingTarget> = []
    @Published private(set) var trustedRemoteDevices: [TrustedRemoteMappingDevice] = []
    @Published private(set) var hasIncomingMappings = false
    @Published private(set) var storageError: String?
    var onApprovalVisibilityChanged: ((Bool) -> Void)?
    var hostApprovalPending: Bool { !pendingTargets.isEmpty }
    var hasRunningMappings: Bool { !running.isEmpty }

    private let defaults: UserDefaults
    private let localDeviceID: UUID?
    private let showsApprovalPanel: Bool
    private static let rulesKey = "tcpMappingRules.v1"
    private static let grantsKey = "tcpMappingGrants.v1"
    static let maximumTrustedRemoteDevices = 64
    private var running: [UUID: RunningRule] = [:]
    private var loadFailed = false
    private let traffic = PortMappingTraffic()
    private var host: PortMappingHost?
    private var hostGeneration: UUID?
    private var grants: Grants?
    private var decisions: [PortMappingTarget: [PendingDecision]] = [:]
    private var requestedAt: [PortMappingTarget: TimeInterval] = [:]
    private var prompt: PortMappingApprovalPanel?
    private var approvalVisible = false

    init(defaults: UserDefaults = .standard, localDeviceID: UUID? = nil, showsApprovalPanel: Bool = true) {
        self.defaults = defaults
        self.localDeviceID = localDeviceID
        self.showsApprovalPanel = showsApprovalPanel
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
                                                       localPort: rule.localPort, traffic: self.traffic, deviceID: self.localDeviceID)
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
        if sample.showsPathStress { traffic.noteVideoPressure() }
        else if let delay = sample.deliveryMilliseconds { traffic.noteVideoDeliveryDelay(delay) }
    }

    func selectHostPairingKey(_ key: PairingKey) {
        let identity = Data(SHA256.hash(data: key.data))
        if grants?.pairingIdentity != identity {
            if grants != nil, !loadFailed { defaults.removeObject(forKey: Self.grantsKey) }
            grants = Grants(pairingIdentity: identity, targets: [], remoteDevices: [])
        }
        allowedTargets = grants?.targets ?? []
        trustedRemoteDevices = Self.normalizedRemoteDevices(grants?.remoteDevices ?? [])
    }

    func makeHost(pairingKey: PairingKey) -> PortMappingHost {
        shutdownHost()
        let generation = UUID()
        hostGeneration = generation
        selectHostPairingKey(pairingKey)
        let server = PortMappingHost(traffic: traffic) { [weak self] target, deviceID, reply in
            DispatchQueue.main.async {
                self?.handleHostAuthorization(target: target, deviceID: deviceID, generation: generation, reply: reply)
            }
        }
        server.onAuthorizationWithdrawn = { [weak self] target in
            DispatchQueue.main.async {
                guard let self, self.hostGeneration == generation else { return }
                self.removeRequest(target)
            }
        }
        server.onActiveSessionsChanged = { [weak self] active in
            DispatchQueue.main.async {
                guard let self, self.hostGeneration == generation else { return }
                if self.hasIncomingMappings != active {
                    self.hasIncomingMappings = active
                }
            }
        }
        host = server
        return server
    }

    func handleHostAuthorization(target: PortMappingTarget, deviceID: UUID?, generation: UUID, reply: @escaping (Bool) -> Void) {
        guard hostGeneration == generation, !loadFailed else { reply(false); return }
        if let deviceID, trustedRemoteDevices.contains(where: { $0.id == deviceID }) { reply(true); return }
        if allowedTargets.contains(target) { reply(true); return }
        decisions[target, default: []].append(PendingDecision(deviceID: deviceID, reply: reply))
        if !pendingTargets.contains(target) {
            requestedAt[target] = ProcessInfo.processInfo.systemUptime
            pendingTargets.append(target)
            syncApprovalPanel()
        }
    }

    func authorizeHostRequest(target: PortMappingTarget, deviceID: UUID?, reply: @escaping (Bool) -> Void) {
        guard let generation = hostGeneration else { reply(false); return }
        handleHostAuthorization(target: target, deviceID: deviceID, generation: generation, reply: reply)
    }

    /// Record a viewer device that completed an authenticated desktop session under the current pairing key.
    func recordRemoteDevice(_ identity: DeviceIdentity, at date: Date = Date()) {
        do {
            var next = trustedRemoteDevices
            let name = Self.sanitizedDeviceName(identity)
            if let index = next.firstIndex(where: { $0.id == identity.id }) {
                next[index].name = name
                next[index].lastConnected = max(next[index].lastConnected, date)
            } else {
                next.append(TrustedRemoteMappingDevice(id: identity.id, name: name, lastConnected: date))
            }
            try setTrustedRemoteDevices(Self.normalizedRemoteDevices(next))
            approvePendingRequests(for: identity.id)
        } catch { storageError = error.localizedDescription }
    }

    func revokeRemoteDevice(_ deviceID: UUID) {
        do {
            let next = trustedRemoteDevices.filter { $0.id != deviceID }
            try setTrustedRemoteDevices(next)
            host?.revokeDevice(deviceID)
        } catch { storageError = error.localizedDescription }
    }

    func presentPendingRequest() { prompt?.present() }

    func decide(_ target: PortMappingTarget, allow: Bool) {
        guard let pending = decisions[target] else { return }
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
        pending.forEach { $0.reply(allow) }
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

    private func setTrustedRemoteDevices(_ devices: [TrustedRemoteMappingDevice]) throws {
        guard var next = grants else { throw DeskError.invalid("当前配对身份未就绪") }
        next.remoteDevices = devices
        try save(next, key: Self.grantsKey)
        grants = next
        trustedRemoteDevices = devices
    }

    private func approvePendingRequests(for deviceID: UUID) {
        var granted: [(Bool) -> Void] = []
        for target in pendingTargets {
            guard let entries = decisions[target] else { continue }
            var remaining: [PendingDecision] = []
            for entry in entries {
                if entry.deviceID == deviceID { granted.append(entry.reply) }
                else { remaining.append(entry) }
            }
            if remaining.isEmpty { removeRequest(target) }
            else { decisions[target] = remaining }
        }
        granted.forEach { $0(true) }
    }

    private static func sanitizedDeviceName(_ identity: DeviceIdentity) -> String {
        String(identity.displayName.prefix(80))
    }

    private static func normalizedRemoteDevices(_ devices: [TrustedRemoteMappingDevice]) -> [TrustedRemoteMappingDevice] {
        var unique: [UUID: TrustedRemoteMappingDevice] = [:]
        for device in devices {
            let name = sanitizedDeviceName(DeviceIdentity(id: device.id, name: device.name))
            if let existing = unique[device.id] {
                if device.lastConnected >= existing.lastConnected {
                    unique[device.id] = TrustedRemoteMappingDevice(id: device.id, name: name, lastConnected: device.lastConnected)
                }
            } else {
                unique[device.id] = TrustedRemoteMappingDevice(id: device.id, name: name, lastConnected: device.lastConnected)
            }
        }
        let sorted = unique.values.sorted {
            if $0.lastConnected != $1.lastConnected { return $0.lastConnected > $1.lastConnected }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Array(sorted.prefix(maximumTrustedRemoteDevices))
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
        if hasIncomingMappings { hasIncomingMappings = false }
        let pending = decisions.values.flatMap { $0 }
        decisions.removeAll()
        requestedAt.removeAll()
        pendingTargets.removeAll()
        syncApprovalPanel()
        pending.forEach { $0.reply(false) }
    }

    private func removeRequest(_ target: PortMappingTarget) {
        decisions.removeValue(forKey: target)
        requestedAt.removeValue(forKey: target)
        pendingTargets.removeAll { $0 == target }
        syncApprovalPanel()
    }

    private func syncApprovalPanel() {
        if hostApprovalPending {
            guard !approvalVisible else { return }
            approvalVisible = true
            onApprovalVisibilityChanged?(true)
            guard showsApprovalPanel else { return }
            let panel = PortMappingApprovalPanel(manager: self)
            prompt = panel
            panel.present()
        } else {
            if let panel = prompt {
                prompt = nil
                panel.close()
            }
            if approvalVisible {
                approvalVisible = false
                onApprovalVisibilityChanged?(false)
            }
        }
    }
}
