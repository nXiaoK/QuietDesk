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
        let permissions = PortMappingManager(defaults: defaults)
        try check(permissions.allowedTargets.isEmpty, "显示授权前须先匹配本机配对身份")
        permissions.selectHostPairingKey(key)
        try check(permissions.allowedTargets == [target], "相同身份恢复已批准的确切地址和端口")
        permissions.revoke(target)
        let revoked = PortMappingManager(defaults: defaults)
        revoked.selectHostPairingKey(key)
        try check(revoked.allowedTargets.isEmpty, "撤回授权在重启后仍生效")
        defaults.values["tcpMappingGrants.v1"] = grant
        let rotated = PortMappingManager(defaults: defaults)
        rotated.selectHostPairingKey(try PairingKey.generate())
        let restored = PortMappingManager(defaults: defaults)
        restored.selectHostPairingKey(key)
        try check(rotated.allowedTargets.isEmpty && restored.allowedTargets.isEmpty, "更换配对码会清空旧身份授权")

        let original = Data("broken".utf8)
        defaults.values["tcpMappingRules.v1"] = original
        let corrupted = PortMappingManager(defaults: defaults)
        var refused = false
        do { try corrupted.saveRule(session) } catch { refused = true }
        try check(refused && corrupted.storageError != nil && defaults.values["tcpMappingRules.v1"] == original,
                  "损坏的已有配置保留原值并提示错误")
    }

    private static func check(_ ok: Bool, _ message: String) throws {
        guard ok else { throw DeskError.invalid(message) }
        print("PASS \(message)")
    }
}
