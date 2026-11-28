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
    var deviceID: UUID
    var hostDeviceID: UUID?
    var routeMode: PortMappingRouteMode
    var name: String
    var localPort: UInt16
    var target: PortMappingTarget
    var scope: PortMappingScope

    init(id: UUID, deviceID: UUID, name: String, localPort: UInt16, target: PortMappingTarget,
         scope: PortMappingScope, hostDeviceID: UUID? = nil, routeMode: PortMappingRouteMode = .pinned) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.localPort = localPort
        self.target = target
        self.scope = scope
        self.hostDeviceID = hostDeviceID
        self.routeMode = routeMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        deviceID = try values.decode(UUID.self, forKey: .deviceID)
        name = try values.decode(String.self, forKey: .name)
        localPort = try values.decode(UInt16.self, forKey: .localPort)
        target = try values.decode(PortMappingTarget.self, forKey: .target)
        scope = try values.decode(PortMappingScope.self, forKey: .scope)
        hostDeviceID = try values.decodeIfPresent(UUID.self, forKey: .hostDeviceID)
        routeMode = (try? values.decodeIfPresent(PortMappingRouteMode.self, forKey: .routeMode)) ?? .pinned
    }
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
    typealias ClassifiedRoute = (_ ready: @escaping @MainActor (String, UInt16, PairingKey) -> Void,
                                 _ failed: @escaping @MainActor (RouteOpenFailure) -> Void) throws -> (() -> Void)

    enum RouteOpenFailure: LocalizedError {
        case network(String)
        case terminal(String)

        var errorDescription: String? {
            switch self {
            case .network(let message), .terminal(let message): message
            }
        }

        var mayTryAlternateRoute: Bool {
            if case .network = self { return true }
            return false
        }
    }

    struct RouteCandidate {
        let label: String
        let open: ClassifiedRoute
        let viewerNetworkFailure: @MainActor (String) -> RouteOpenFailure

        /// Use this initializer for openers whose string callbacks and unclassified throws are network failures.
        init(label: String, open: @escaping Route) {
            self.init(label: label, classifiedOpen: { ready, failed in
                do { return try open(ready) { failed(.network($0)) } }
                catch { throw (error as? RouteOpenFailure) ?? RouteOpenFailure.network(error.localizedDescription) }
            })
        }

        init(label: String, viewerNetworkFailure: @escaping @MainActor (String) -> RouteOpenFailure = { .network($0) },
             classifiedOpen: @escaping ClassifiedRoute) {
            self.label = label
            self.open = classifiedOpen
            self.viewerNetworkFailure = viewerNetworkFailure
        }
    }

    private final class RouteAttempt {
        let label: String
        let viewerNetworkFailure: @MainActor (String) -> RouteOpenFailure
        var viewer: PortMappingViewer?
        var closeRoute: (() -> Void)?
        var opening = true
        var openingFailure: RouteOpenFailure?

        init(_ candidate: RouteCandidate) {
            label = candidate.label
            viewerNetworkFailure = candidate.viewerNetworkFailure
        }
    }

    private final class RunningRule {
        var rule: PortMappingRule
        var remainingCandidates: [RouteCandidate]
        var attempt: RouteAttempt?

        init(_ rule: PortMappingRule, candidates: [RouteCandidate]) {
            self.rule = rule
            remainingCandidates = candidates
        }
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
    @Published private(set) var activeRouteLabels: [UUID: String] = [:]
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

    func updateRuleRoute(id: UUID, recordID: UUID, hostDeviceID: UUID?, routeMode: PortMappingRouteMode) throws
        -> (updated: PortMappingRule, wasRunning: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { throw DeskError.invalid("找不到此映射规则") }
        var next = rules
        next[index].deviceID = recordID
        next[index].hostDeviceID = hostDeviceID
        next[index].routeMode = routeMode
        try save(next, key: Self.rulesKey)
        let wasRunning = isEnabled(id)
        if wasRunning { stop(id) }
        rules = next
        return (next[index], wasRunning)
    }

    func synchronizeHostDeviceID(forRecordID recordID: UUID, hostDeviceID: UUID) {
        var next = rules
        let indices = next.indices.filter { next[$0].deviceID == recordID && next[$0].hostDeviceID == nil }
        guard !indices.isEmpty else { return }
        for index in indices { next[index].hostDeviceID = hostDeviceID }
        do {
            try save(next, key: Self.rulesKey)
            for index in indices { running[next[index].id]?.rule.hostDeviceID = hostDeviceID }
            rules = next
        } catch { storageError = error.localizedDescription }
    }

    func migrateOrRemoveRecord(_ removedRecordID: UUID, replacementRecordID: UUID?, hostDeviceID: UUID?) {
        guard let replacementRecordID else { removeDevice(removedRecordID); return }
        guard replacementRecordID != removedRecordID else { return }
        var next = rules
        let indices = next.indices.filter { next[$0].deviceID == removedRecordID }
        guard !indices.isEmpty else { return }
        for index in indices {
            next[index].deviceID = replacementRecordID
            if next[index].hostDeviceID == nil { next[index].hostDeviceID = hostDeviceID }
        }
        do {
            try save(next, key: Self.rulesKey)
            for index in indices { stop(next[index].id) }
            rules = next
        } catch { storageError = error.localizedDescription }
    }

    func isEnabled(_ id: UUID) -> Bool { running[id] != nil }

    func start(_ rule: PortMappingRule, fallback: Route? = nil, route: Route) throws {
        // The first opener is consumed synchronously. Only its callbacks and cleanup escape.
        try withoutActuallyEscaping(route) { initial in
            let candidates = ([initial] + (fallback.map { [$0] } ?? [])).map { legacy in
                RouteCandidate(label: "", classifiedOpen: { ready, failed in
                    try legacy(ready) { failed(.terminal($0)) }
                })
            }
            try start(rule, candidates: candidates)
        }
    }

    func start(_ rule: PortMappingRule, candidates: [RouteCandidate]) throws {
        guard running[rule.id] == nil else { return }
        guard !candidates.isEmpty else { throw DeskError.invalid("此设备没有可用的端口映射线路") }
        if running.values.contains(where: { $0.rule.localPort == rule.localPort }) {
            let reason = "本地端口 \(rule.localPort) 已用于另一条映射，请修改本地端口。"
            states[rule.id] = .failed(reason)
            throw DeskError.invalid(reason)
        }
        let run = RunningRule(rule, candidates: candidates)
        running[rule.id] = run
        try startNextRoute(run)
    }

    private func startNextRoute(_ run: RunningRule) throws {
        let id = run.rule.id
        while running[id] === run, !run.remainingCandidates.isEmpty {
            let candidate = run.remainingCandidates.removeFirst()
            let attempt = RouteAttempt(candidate)
            run.attempt = attempt
            states[id] = .authorizing
            do {
                let cleanup = try candidate.open({ [weak self, weak run, weak attempt] address, port, key in
                    guard let self, let run, let attempt, self.isCurrent(attempt, in: run),
                          attempt.viewer == nil, attempt.openingFailure == nil else { return }
                    self.startViewer(for: run, attempt: attempt, address: address, port: port, key: key)
                }, { [weak self, weak run, weak attempt] failure in
                    guard let self, let run, let attempt, self.isCurrent(attempt, in: run) else { return }
                    let effectiveFailure = attempt.viewer?.hasAuthenticatedRoute == true
                        ? .terminal(failure.localizedDescription) : failure
                    self.reportAttemptFailure(effectiveFailure, in: run, attempt: attempt)
                })
                guard isCurrent(attempt, in: run) else { cleanup(); return }
                attempt.closeRoute = cleanup
                attempt.opening = false
                guard let failure = attempt.openingFailure else { return }
                if !prepareAlternate(after: failure, in: run) { return }
            } catch {
                guard isCurrent(attempt, in: run) else { return }
                let failure = (error as? RouteOpenFailure) ?? .terminal(error.localizedDescription)
                if let pending = attempt.openingFailure, !pending.mayTryAlternateRoute {
                    _ = prepareAlternate(after: pending, in: run)
                    throw pending
                }
                if !prepareAlternate(after: failure, in: run) { throw error }
            }
        }
    }

    private func startViewer(for run: RunningRule, attempt: RouteAttempt, address: String, port: UInt16, key: PairingKey) {
        let rule = run.rule
        do {
            let viewer = try PortMappingViewer(host: address, port: port, key: key, target: rule.target,
                                               localPort: rule.localPort, traffic: traffic, deviceID: localDeviceID)
            attempt.viewer = viewer
            viewer.onState = { [weak self, weak run, weak attempt, weak viewer] state in
                DispatchQueue.main.async {
                    guard let self, let run, let attempt, let viewer, self.isCurrent(attempt, in: run) else { return }
                    switch state {
                    case .failed(let message):
                        let failure = viewer.mayTryAlternateRoute
                            ? attempt.viewerNetworkFailure(message) : .terminal(message)
                        self.reportAttemptFailure(failure, in: run, attempt: attempt)
                    case .stopped:
                        self.finish(rule.id, state: state)
                    case .authorizing, .listening:
                        if case .listening = state { run.remainingCandidates.removeAll() }
                        if !attempt.label.isEmpty { self.activeRouteLabels[rule.id] = attempt.label }
                        self.states[rule.id] = state
                    case .targetFailed:
                        self.states[rule.id] = state
                    }
                }
            }
            viewer.start()
        } catch { reportAttemptFailure(.terminal(error.localizedDescription), in: run, attempt: attempt) }
    }

    private func isCurrent(_ attempt: RouteAttempt, in run: RunningRule) -> Bool {
        running[run.rule.id] === run && run.attempt === attempt
    }

    private func reportAttemptFailure(_ failure: RouteOpenFailure, in run: RunningRule, attempt: RouteAttempt) {
        if attempt.opening {
            // An opener may fail synchronously and still return resources that must be closed before retry.
            if attempt.openingFailure?.mayTryAlternateRoute != false { attempt.openingFailure = failure }
        } else if prepareAlternate(after: failure, in: run) {
            try? startNextRoute(run)
        }
    }

    private func prepareAlternate(after failure: RouteOpenFailure, in run: RunningRule) -> Bool {
        guard failure.mayTryAlternateRoute, !run.remainingCandidates.isEmpty else {
            finish(run.rule.id, state: .failed(failure.localizedDescription))
            return false
        }
        closeAttempt(in: run)
        return true
    }

    private func closeAttempt(in run: RunningRule) {
        let attempt = run.attempt
        run.attempt = nil
        activeRouteLabels[run.rule.id] = nil
        attempt?.viewer?.stop()
        attempt?.closeRoute?()
    }

    private func finish(_ id: UUID, state: PortMappingState?) {
        let run = running.removeValue(forKey: id)
        states[id] = state
        if let run { closeAttempt(in: run) }
    }

    func stop(_ id: UUID) { finish(id, state: nil) }

    func stopSessionMappings() {
        for run in Array(running.values) where run.rule.scope == .session { stop(run.rule.id) }
    }

    func stopSessionMappings(forDeviceID deviceID: UUID) {
        stopSessionMappings(forRecordIDs: [deviceID])
    }

    func stopSessionMappings(forRecordIDs recordIDs: Set<UUID>, hostDeviceID: UUID? = nil) {
        for run in Array(running.values) where run.rule.scope == .session
            && (recordIDs.contains(run.rule.deviceID) || (hostDeviceID != nil && run.rule.hostDeviceID == hostDeviceID)) {
            stop(run.rule.id)
        }
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
