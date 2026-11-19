import AppKit
import CryptoKit
import QuietDeskCore

/// All writes stay in this in-memory dictionary. No application domain, credential, port or real UI is opened.
private final class MappingDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

@main
private enum PortMappingRuleChecks {
    @MainActor static func main() throws {
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
    }

    private static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw DeskError.invalid(message) }
        print("PASS \(message)")
    }
}
