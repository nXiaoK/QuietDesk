import AppKit
import CryptoKit
import Network
import QuietDeskCore

/// All configuration writes stay in this in-memory dictionary.
private final class MappingDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

private final class MappingRouteFixture: @unchecked Sendable {
    private let listener: NWListener
    private let host: PortMappingHost
    private let lock = NSLock()
    private var peers: [Peer] = []

    init(key: PairingKey, allowed: PortMappingTarget) throws {
        host = PortMappingHost { target, reply in reply(target == allowed) }
        let parameters = try MediaSecureTransport.tlsParameters(key: key, roles: [.portMapping])
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer = Peer(connection: connection)
            self.lock.withLock { self.peers.append(peer) }
            peer.onReady = { [weak self, weak peer] in
                if let self, let peer { self.host.accept(peer) }
            }
            peer.start()
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    if let port = listener?.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: DeskError.invalid("回环端口未就绪")) }
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "checks.mapping-rule.fixture"))
        }
    }

    func stop() {
        listener.cancel()
        host.stop()
        lock.withLock { peers.forEach { $0.close() }; peers.removeAll() }
    }
}

@main
private enum PortMappingRuleChecks {
    @MainActor static func main() async throws {
        let defaults = MappingDefaults()
        let manager = PortMappingManager(defaults: defaults)
        let target = try PortMappingTarget(host: "127.0.0.1", port: 8080)
        let session = PortMappingRule(id: UUID(), deviceID: UUID(), name: "同名服务", localPort: 18081, target: target, scope: .session)
        let standalone = PortMappingRule(id: UUID(), deviceID: UUID(), name: session.name, localPort: 18082, target: target, scope: .independent)
        try manager.saveRule(session)
        try manager.saveRule(standalone)
        let reloaded = PortMappingManager(defaults: defaults)
        try check(reloaded.rules == [session, standalone] && !reloaded.hasRunningMappings, "重启后按设备区分规则且均停用")
        var closed: [UUID] = []
        var delayedFailure: (@MainActor (String) -> Void)?
        try manager.start(session) { _, fail in delayedFailure = fail; return { closed.append(session.id) } }
        try manager.start(standalone) { _, _ in { closed.append(standalone.id) } }
        let collision = PortMappingRule(id: UUID(), deviceID: standalone.deviceID, name: "冲突", localPort: session.localPort,
                                        target: target, scope: .independent)
        var conflict = false
        do { try manager.start(collision) { _, _ in throw DeskError.invalid("不应进入路由") } }
        catch { conflict = error.localizedDescription.contains("本地端口") }
        try check(conflict && !manager.isEnabled(collision.id), "跨设备本地端口冲突保留原监听")
        manager.stopSessionMappings()
        try check(closed == [session.id] && manager.isEnabled(standalone.id), "断开桌面只清理随会话映射")
        try manager.start(session) { _, _ in { closed.append(session.id) } }
        delayedFailure?("已过期")
        try check(manager.isEnabled(session.id) && manager.states[session.id] == .authorizing, "旧路由回调不能终止同一规则的新尝试")
        manager.removeDevice(session.deviceID)
        try check(manager.rules == [standalone] && manager.isEnabled(standalone.id), "删除一个设备不会移除另一个设备的同名规则")
        manager.stopAllMappings()
        try check(closed == [session.id, session.id, standalone.id] && !manager.hasRunningMappings, "休眠或退出清理所有映射和路由")
        try manager.start(standalone) { _, failed in failed("路由失败"); return { closed.append(standalone.id) } }
        try check(manager.states[standalone.id] == .failed("路由失败") && closed.count == 4, "同步失败也归还路由并报告真实结果")
        try manager.deleteRule(standalone.id)
        try check(PortMappingManager(defaults: defaults).rules.isEmpty, "删除后的规则不会重新载入")

        try check(!PortMappingManager.acceptsApproval(type: .leftMouseUp, sourcePID: Int64(getpid()), timestamp: 30, requestedAt: 20)
            && !PortMappingManager.acceptsApproval(type: .keyDown, sourcePID: 0, timestamp: 15, requestedAt: 20)
            && !PortMappingManager.acceptsApproval(type: .mouseMoved, sourcePID: 0, timestamp: 30, requestedAt: 20)
            && PortMappingManager.acceptsApproval(type: .leftMouseUp, sourcePID: 0, timestamp: 30, requestedAt: 20),
            "批准按钮仅接受申请后真实的本机操作，排除 QuietDesk 发布的输入")
        let key = try PairingKey.generate()
        let identity = Data(SHA256.hash(data: key.data))
        let grant = try JSONSerialization.data(withJSONObject: ["pairingIdentity": identity.base64EncodedString(),
                                                                 "targets": [["host": target.host, "port": target.port]]])
        defaults.values["tcpMappingGrants.v1"] = grant
        let permissions = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        try check(permissions.allowedTargets.isEmpty && permissions.trustedRemoteDevices.isEmpty,
                  "显示授权前须先匹配本机配对身份")
        permissions.selectHostPairingKey(key)
        try check(permissions.allowedTargets == [target] && permissions.trustedRemoteDevices.isEmpty,
                  "相同身份恢复旧版已批准目标并兼容缺少远控设备字段")
        permissions.revoke(target)
        let revoked = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        revoked.selectHostPairingKey(key)
        try check(revoked.allowedTargets.isEmpty, "撤回授权在重启后仍生效")

        // Trusted remote-controlled devices skip host confirmation while unrecorded and legacy devices still require it.
        var visibilityEvents: [Bool] = []
        let hostManager = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        hostManager.onApprovalVisibilityChanged = { visibilityEvents.append($0) }
        _ = hostManager.makeHost(pairingKey: key)
        let knownDevice = UUID(), pendingDevice = UUID(), unknownDevice = UUID()
        let unapprovedTarget = try PortMappingTarget(host: "192.168.10.113", port: 3000)

        var unknownReply: Bool?
        hostManager.authorizeHostRequest(target: unapprovedTarget, deviceID: unknownDevice) { unknownReply = $0 }
        var legacyReply: Bool?
        hostManager.authorizeHostRequest(target: unapprovedTarget, deviceID: nil) { legacyReply = $0 }
        var pendingDeviceReply: Bool?
        hostManager.authorizeHostRequest(target: unapprovedTarget, deviceID: pendingDevice) { pendingDeviceReply = $0 }
        try check(unknownReply == nil && legacyReply == nil && pendingDeviceReply == nil
            && hostManager.hostApprovalPending && visibilityEvents == [true],
            "未曾远控的设备与旧版控制端仍进入本机确认流程")

        let noisyName = "Office\n\tMac " + String(repeating: "A", count: 100)
        hostManager.recordRemoteDevice(DeviceIdentity(id: knownDevice, name: noisyName), at: Date(timeIntervalSince1970: 1_000))
        try check(hostManager.trustedRemoteDevices.count == 1
            && hostManager.trustedRemoteDevices[0].id == knownDevice
            && hostManager.trustedRemoteDevices[0].name.count == 80
            && !hostManager.trustedRemoteDevices[0].name.contains("\n"),
            "记录远控设备时清理控制字符并限制名称长度")

        var knownReply: Bool?
        hostManager.authorizeHostRequest(target: unapprovedTarget, deviceID: knownDevice) { knownReply = $0 }
        try check(knownReply == true && hostManager.hostApprovalPending,
                  "曾远控过本机的设备直接放行且不影响其他待确认请求")

        // Recording a device with an in-flight request resolves only that device's request.
        hostManager.recordRemoteDevice(DeviceIdentity(id: pendingDevice, name: "Studio Mac"), at: Date(timeIntervalSince1970: 2_000))
        try check(pendingDeviceReply == true && unknownReply == nil && legacyReply == nil && hostManager.hostApprovalPending,
                  "补录远控设备后立即放行该设备待确认请求，保留其他未远控设备的确认")

        // Denying the remaining unapproved requests clears the approval prompt.
        hostManager.decide(unapprovedTarget, allow: false)
        try check(unknownReply == false && legacyReply == false && !hostManager.hostApprovalPending
            && visibilityEvents == [true, false],
            "拒绝剩余未远控设备请求后关闭待确认状态")

        // Persistence across restart requires matching the host pairing key.
        let reloadedHost = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        try check(reloadedHost.trustedRemoteDevices.isEmpty, "重启后匹配配对身份前不暴露远控设备记录")
        reloadedHost.selectHostPairingKey(key)
        try check(reloadedHost.trustedRemoteDevices.map(\.id) == [pendingDevice, knownDevice],
                  "重启后按最近远控时间恢复免确认设备列表")

        // Updating an existing device updates metadata without duplicating IDs, and caps total entries.
        reloadedHost.recordRemoteDevice(DeviceIdentity(id: knownDevice, name: "Renamed Mac"), at: Date(timeIntervalSince1970: 3_000))
        try check(reloadedHost.trustedRemoteDevices.count == 2
            && reloadedHost.trustedRemoteDevices.first?.id == knownDevice
            && reloadedHost.trustedRemoteDevices.first?.name == "Renamed Mac",
            "同一设备再次远控更新名称和时间且不重复")
        for index in 0..<(PortMappingManager.maximumTrustedRemoteDevices + 5) {
            reloadedHost.recordRemoteDevice(DeviceIdentity(id: UUID(), name: "Mac \(index)"),
                                            at: Date(timeIntervalSince1970: Double(4_000 + index)))
        }
        try check(reloadedHost.trustedRemoteDevices.count == PortMappingManager.maximumTrustedRemoteDevices,
                  "远控设备记录数量受上限保护")

        // Revoking a remote device persists across restart and requires confirmation again.
        let retainedID = reloadedHost.trustedRemoteDevices[0].id
        _ = reloadedHost.makeHost(pairingKey: key)
        var allowedBeforeRevoke: Bool?
        reloadedHost.authorizeHostRequest(target: unapprovedTarget, deviceID: retainedID) { allowedBeforeRevoke = $0 }
        try check(allowedBeforeRevoke == true && !reloadedHost.hostApprovalPending, "重启恢复的远控设备仍可直接放行")
        reloadedHost.revokeRemoteDevice(retainedID)
        let afterDeviceRevoke = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        _ = afterDeviceRevoke.makeHost(pairingKey: key)
        var afterRevokeReply: Bool?
        afterDeviceRevoke.authorizeHostRequest(target: unapprovedTarget, deviceID: retainedID) { afterRevokeReply = $0 }
        try check(!afterDeviceRevoke.trustedRemoteDevices.contains(where: { $0.id == retainedID })
            && afterRevokeReply == nil && afterDeviceRevoke.hostApprovalPending,
            "撤回远控设备在重启后生效且再次请求需本机确认")
        afterDeviceRevoke.shutdownHost()

        defaults.values["tcpMappingGrants.v1"] = grant
        let rotated = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        rotated.selectHostPairingKey(key)
        rotated.recordRemoteDevice(DeviceIdentity(id: knownDevice, name: "Old Pair"))
        rotated.selectHostPairingKey(try PairingKey.generate())
        let restored = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        restored.selectHostPairingKey(key)
        try check(rotated.allowedTargets.isEmpty && rotated.trustedRemoteDevices.isEmpty
            && restored.allowedTargets.isEmpty && restored.trustedRemoteDevices.isEmpty,
            "更换配对码会清空旧身份目标授权与远控设备免确认记录")

        let original = Data("broken".utf8)
        defaults.values["tcpMappingRules.v1"] = original
        let corrupted = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
        var refused = false
        do { try corrupted.saveRule(session) } catch { refused = true }
        _ = corrupted.makeHost(pairingKey: key)
        corrupted.recordRemoteDevice(DeviceIdentity(id: knownDevice, name: "Blocked"))
        var corruptAuthReply: Bool?
        corrupted.authorizeHostRequest(target: unapprovedTarget, deviceID: knownDevice) { corruptAuthReply = $0 }
        try check(refused && corrupted.storageError != nil && defaults.values["tcpMappingRules.v1"] == original
            && corrupted.trustedRemoteDevices.isEmpty && corruptAuthReply == false,
            "损坏的已有配置保留原值、拒绝写入且不自动放行")
        corrupted.shutdownHost()

        try legacyRulesAndMigration(template: session)
        try await candidateFailoverAndDenial(target: target, key: key)
    }

    @MainActor
    private static func legacyRulesAndMigration(template: PortMappingRule) throws {
        let defaults = MappingDefaults()
        let encoded = try JSONEncoder().encode([template])
        let rows = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        guard var legacy = rows?.first else { throw DeskError.invalid("无法构建旧版规则夹具") }
        legacy.removeValue(forKey: "hostDeviceID")
        legacy.removeValue(forKey: "routeMode")
        defaults.values["tcpMappingRules.v1"] = try JSONSerialization.data(withJSONObject: [legacy])
        let manager = PortMappingManager(defaults: defaults)
        try check(manager.rules == [template] && manager.rules.first?.routeMode == .pinned
            && manager.rules.first?.hostDeviceID == nil, "旧版规则默认指定线路，保留原字段")

        let machine = UUID(), replacement = UUID()
        var closed = 0
        try manager.start(template) { _, _ in { closed += 1 } }
        manager.synchronizeHostDeviceID(forRecordID: template.deviceID, hostDeviceID: machine)
        manager.synchronizeHostDeviceID(forRecordID: template.deviceID, hostDeviceID: UUID())
        try check(manager.rules.first?.hostDeviceID == machine && manager.isEnabled(template.id),
                  "认证后静默补齐机器 ID，不覆盖已保存的认证身份或中断映射")
        manager.stopSessionMappings(forRecordIDs: [replacement], hostDeviceID: machine)
        try check(closed == 1 && !manager.isEnabled(template.id), "可按已认证的同机身份停止随会话映射")

        try manager.start(template) { _, _ in { closed += 1 } }
        manager.migrateOrRemoveRecord(template.deviceID, replacementRecordID: replacement, hostDeviceID: machine)
        var migrated = template
        migrated.deviceID = replacement
        migrated.hostDeviceID = machine
        try check(closed == 2 && !manager.isEnabled(template.id)
            && PortMappingManager(defaults: defaults).rules == [migrated], "删除旧线路时停用旧连接并无损迁移规则")

        try manager.start(migrated) { _, _ in { closed += 1 } }
        let switched = try manager.updateRuleRoute(id: migrated.id, recordID: replacement,
                                                   hostDeviceID: machine, routeMode: .automatic)
        migrated.routeMode = .automatic
        try check(switched.wasRunning && switched.updated == migrated && closed == 3
            && PortMappingManager(defaults: defaults).rules == [migrated], "切换线路保存新模式并返回可热重连的运行标记")
        manager.migrateOrRemoveRecord(replacement, replacementRecordID: nil, hostDeviceID: machine)
        try check(PortMappingManager(defaults: defaults).rules.isEmpty, "删除同机最后一条线路才清除规则")
    }

    @MainActor
    private static func candidateFailoverAndDenial(target: PortMappingTarget, key: PairingKey) async throws {
        let manager = PortMappingManager(defaults: MappingDefaults(), showsApprovalPanel: false)
        let fixture = try MappingRouteFixture(key: key, allowed: target)
        let port = try await fixture.start()
        defer { manager.stopAllMappings(); fixture.stop() }
        let rule = PortMappingRule(id: UUID(), deviceID: UUID(), name: "线路切换", localPort: 0,
                                   target: target, scope: .independent)
        var attempts: [String] = []
        var previousFailure: (@MainActor (PortMappingManager.RouteOpenFailure) -> Void)?
        let first = PortMappingManager.RouteCandidate(label: "直连", classifiedOpen: { _, failed in
            attempts.append("开始直连")
            previousFailure = failed
            failed(.network("模拟网络不可达"))
            return { attempts.append("清理直连") }
        })
        let second = PortMappingManager.RouteCandidate(label: "Tailscale · 合成回环", open: { ready, _ in
            attempts.append("开始备用")
            ready("127.0.0.1", port, key)
            return { attempts.append("清理备用") }
        })
        try manager.start(rule, candidates: [first, second])
        previousFailure?(.terminal("上次尝试的回调"))
        try await waitUntil("备用线路未能进入监听") {
            if case .listening = manager.states[rule.id] { return true }
            return false
        }
        try check(attempts == ["开始直连", "清理直连", "开始备用"]
            && manager.activeRouteLabels[rule.id] == second.label, "网络失败先清理旧线路，再走通并显示备用线路")
        guard case .listening(let localPort, _) = manager.states[rule.id] else {
            throw DeskError.invalid("备用线路没有监听端口")
        }
        manager.stop(rule.id)
        try check(attempts.last == "清理备用" && manager.activeRouteLabels[rule.id] == nil, "停用映射清除当前线路")

        let unavailable = PortMappingManager.RouteCandidate(label: "不可达", open: { _, _ in
            throw DeskError.invalid("首条线路超时")
        })
        let stillUnavailable = PortMappingManager.RouteCandidate(label: "也不可达", classifiedOpen: { _, failed in
            failed(.network("最后线路超时"))
            return {}
        })
        try manager.start(rule, candidates: [unavailable, stillUnavailable])
        try check(manager.states[rule.id] == .failed("最后线路超时") && !manager.isEnabled(rule.id),
                  "同步抛错可网络回退，候选耗尽时保留最后真实错误")

        var forbiddenFallback = false
        let never = PortMappingManager.RouteCandidate(label: "不应尝试", open: { _, _ in
            forbiddenFallback = true
            return {}
        })
        let deniedRelay = PortMappingManager.RouteCandidate(label: "中继", classifiedOpen: { _, failed in
            failed(.terminal("中继拒绝接入"))
            return {}
        })
        try manager.start(rule, candidates: [deniedRelay, never])
        try check(!forbiddenFallback && manager.states[rule.id] == .failed("中继拒绝接入"),
                  "外层线路拒绝授权时立即结束，不尝试备用线路")

        var denied = rule
        denied.target = try PortMappingTarget(host: target.host, port: target.port + 1)
        try manager.start(denied, candidates: [second, never])
        try await waitUntil("远端授权拒绝未结束") {
            if case .failed = manager.states[denied.id] { return true }
            return false
        }
        try check(!forbiddenFallback && manager.activeRouteLabels[denied.id] == nil, "远端目标拒绝不触发备用线路")

        let wrongKey = try PairingKey.generate()
        let unauthenticated = PortMappingManager.RouteCandidate(label: "错误配对码", open: { ready, _ in
            ready("127.0.0.1", port, wrongKey)
            return {}
        })
        try manager.start(rule, candidates: [unauthenticated, never])
        try await waitUntil("错误配对码未结束", timeout: 24) {
            if case .failed = manager.states[rule.id] { return true }
            return false
        }
        try check(!forbiddenFallback && manager.activeRouteLabels[rule.id] == nil, "错误配对码不触发备用线路")

        var fixed = rule
        fixed.localPort = localPort
        try manager.saveRule(fixed)
        let firstRoute = PortMappingManager.RouteCandidate(label: "直连 · 合成回环", open: { ready, _ in
            ready("127.0.0.1", port, key)
            return {}
        })
        try manager.start(fixed, candidates: [firstRoute])
        for index in 0..<6 {
            try await waitUntil("热切换前本地固定端口尚未监听") {
                if case .listening(let port, _) = manager.states[fixed.id] { return port == localPort }
                return false
            }
            let nextRoute = index.isMultiple(of: 2) ? second : firstRoute
            let changed = try manager.updateRuleRoute(id: fixed.id, recordID: UUID(), hostDeviceID: nil, routeMode: .pinned)
            try check(changed.wasRunning, "第 \(index + 1) 次切换识别原规则正在运行")
            try manager.start(changed.updated, candidates: [nextRoute])
        }
        try await waitUntil("热切换后本地固定端口未重新监听") {
            if case .listening(let port, _) = manager.states[fixed.id] { return port == localPort }
            return false
        }
        try check(manager.activeRouteLabels[fixed.id] == firstRoute.label, "连续热切换保留固定本地端口并更新实际线路")
    }

    @MainActor
    private static func waitUntil(_ message: String, timeout: TimeInterval = 12, condition: () -> Bool) async throws {
        let deadline = SessionClock.now + timeout
        while !condition() {
            guard SessionClock.now < deadline else { throw DeskError.invalid(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw DeskError.invalid(message) }
        print("PASS \(message)")
    }
}
