import Foundation
import Network
import QuietDeskCore

@main
struct EmbeddedTailnetChecks {
    private static let bridgeReplyGate = "hold-bridge-reply"

    private static func require(_ condition: Bool, _ description: String) throws {
        if !condition { throw DeskError.invalid(description) }
    }

    private static func eventually(_ description: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DeskError.invalid(description)
    }

    // The fixture records arguments and operations and returns synthetic status without creating a node.
    private static func helper(directory: String, controlURL: String?) throws {
        let base = URL(fileURLWithPath: directory)
        let logURL = base.appendingPathComponent("requests")
        let pathFixture = base.appendingPathComponent("peer-path")
        let bridgeFixture = base.appendingPathComponent("bridge-routes")
        let replyGate = base.appendingPathComponent(bridgeReplyGate)
        if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        try log.write(contentsOf: Data("launch \(controlURL ?? "official")\n".utf8))
        var shared = 0, udp = false
        var bridges = Set<Int>()
        while let text = readLine(), let req = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = req["op"] as? String, let id = req["id"] as? Int {
            let port = req["port"] as? Int ?? 0
            try log.write(contentsOf: Data("\(op) \(port)\n".utf8))
            var reply: [String: Any] = ["id": id]
            switch op {
            case "login", "status":
                reply["state"] = "Running"
                reply["ip"] = "100.99.0.1"
                reply["port"] = shared
                reply["udp"] = udp
                if controlURL != nil,
                   let path = try? String(contentsOf: pathFixture, encoding: .utf8),
                   ["direct", "derp"].contains(path) {
                    reply["peerPath"] = path
                    if path == "derp" { reply["peerRelay"] = "hkg" }
                }
                if let data = try? Data(contentsOf: bridgeFixture),
                   let routes = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    reply["bridgeRoutes"] = routes.filter { (Int($0.key).map { bridges.contains($0) }) == true }
                }
            case "share":
                udp = req["udp"] as? Bool ?? false
                if shared != 0 { Thread.sleep(forTimeInterval: 0.08) }
                shared = port
                reply["port"] = shared
                reply["udp"] = udp
            case "open":
                let host = req["host"] as? String
                try require((host == "100.100.0.2" || host == "100.100.0.3") && port == 5908, "错误的对端地址")
                if FileManager.default.fileExists(atPath: replyGate.path) {
                    let deadline = DispatchTime.now() + .seconds(5)
                    while FileManager.default.fileExists(atPath: replyGate.path) {
                        try require(DispatchTime.now() < deadline, "测试未释放延迟的连接回复")
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.12)
                }
                let localPort = host == "100.100.0.2" ? 34907 : 34908
                bridges.insert(localPort)
                reply["port"] = localPort
            case "close":
                bridges.remove(port)
            default: break
            }
            var packet = try JSONSerialization.data(withJSONObject: reply)
            packet.append(10)
            try FileHandle.standardOutput.write(contentsOf: packet)
        }
    }

    @MainActor
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--state-dir" {
            try require(args.count == 2 || (args.count == 4 && args[2] == "--control-url"), "组件收到了非预期启动参数")
            try helper(directory: args[1], controlURL: args.count == 4 ? args[3] : nil)
            return
        }
        let identifier = "QuietDesk.Test.Tailnet." + UUID().uuidString
        let defaults = UserDefaults(suiteName: identifier)!
        defer { defaults.removePersistentDomain(forName: identifier) }
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/tailscale/mac/test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let daemon = EmbeddedTailnet(defaults: defaults, executable: URL(fileURLWithPath: CommandLine.arguments[0]), directory: base)
        let logURL = base.appendingPathComponent("requests")
        let pathFixture = base.appendingPathComponent("peer-path")
        let bridgeFixture = base.appendingPathComponent("bridge-routes")
        func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

        try require(EmbeddedTailnet.loginURL("https://login.tailscale.com/a/example") != nil &&
                    EmbeddedTailnet.loginURL("https://controlplane.tailscale.com:443/a/example") != nil &&
                    EmbeddedTailnet.loginURL("https://login.tailscale.com:8443/a/example") == nil &&
                    EmbeddedTailnet.loginURL("https://login.tailscale.com.example.invalid/a/example") == nil &&
                    EmbeddedTailnet.loginURL("https://evil@login.tailscale.com/a/example") == nil,
                    "登录浏览器地址没有限定到官方 HTTPS 域名")
        let control = "https://headscale.example:8443"
        let normalized = try EmbeddedTailnet.normalizedControlURL(" \n\(control) \t")
        let official = try EmbeddedTailnet.normalizedControlURL(" \n\t")
        try require(normalized == control && official.isEmpty && daemon.controlURL.isEmpty, "控制服务地址未去除外侧空白或丢失官方默认设置")
        for value in ["http://headscale.example", "http://localhost", "https:///headscale.example", "https://user:pass@headscale.example",
                      "https://headscale.example?token=example", "https://headscale.example#login", "https://headscale.example:0",
                      "https://headscale.example:65536"] {
            do {
                _ = try EmbeddedTailnet.normalizedControlURL(value)
                throw CocoaError(.coderInvalidValue)
            } catch is DeskError {}
        }
        try require(EmbeddedTailnet.loginURL("https://HEADSCALE.example:8443/register?key=sample", controlURL: control) != nil &&
                    EmbeddedTailnet.loginURL("https://headscale.example/a/example", controlURL: "https://headscale.example:443") != nil &&
                    EmbeddedTailnet.loginURL("https://login.tailscale.com/a/example", controlURL: control) != nil &&
                    EmbeddedTailnet.loginURL("https://headscale.example:8443/a/example") == nil,
                    "登录浏览器未按自定义控制服务来源验证")
        for value in ["http://headscale.example:8443/register", "https://headscale.example/register",
                      "https://headscale.example:8444/register", "https://headscale.example.other.invalid:8443/register",
                      "https://user:pass@headscale.example:8443/register"] {
            try require(EmbeddedTailnet.loginURL(value, controlURL: control) == nil, "登录浏览器接受了不同来源或含凭据的地址")
        }
        try require(EmbeddedTailnet.loginURL("https://headscale.example/register", controlURL: "https://headscale.example#invalid") == nil,
                    "无效的控制服务配置扩大了允许的登录地址范围")
        let valid = try TailnetAddress.host(in: "tailscale:100.100.0.2")
        let native = try TailnetAddress.host(in: "100.100.0.2")
        try require(valid == "100.100.0.2" && native == nil, "显式 Tailscale 线路和系统线路混淆")
        do {
            _ = try TailnetAddress.host(in: "tailscale:127.0.0.1")
            throw CocoaError(.coderInvalidValue)
        } catch is DeskError {}

        try daemon.setControlURL(control)
        try require(daemon.controlURL == control && defaults.string(forKey: "embeddedTailnetControlURL") == control,
                    "禁用时未保存控制服务配置")
        try daemon.setControlURL("")
        daemon.setSharing(port: 5908)
        try require(!FileManager.default.fileExists(atPath: base.path), "未启用时启动了组件")
        daemon.login()
        try await eventually("未发布正在运行的共享端口") {
            !daemon.changingAccount && daemon.ip == "100.99.0.1" && daemon.shared == .init(port: 5908, udp: false)
        }
        try require(log().contains("launch official\n") && daemon.peerPath == nil && daemon.peerRelay == nil,
                    "默认启动传入了控制服务或旧版状态被误判为已有传输路径")
        let mode = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o700, "节点状态目录权限错误")
        let loopback = NWParameters.udp
        loopback.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let udp = try NWListener(using: loopback)
        udp.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            udp.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.resume()
                case .failed(let error): ready.resume(throwing: error)
                default: break
                }
            }
            udp.start(queue: DispatchQueue(label: "tailnet-fixture.udp"))
        }
        let bound = udp.port!.rawValue
        daemon.setSharing(port: bound)
        daemon.datagramReadiness(udp, ready: true)
        try await eventually("未发布已实际绑定的 UDP 端口") { daemon.shared == .init(port: bound, udp: true) }
        daemon.retireDatagram(udp)
        try await eventually("撤销 UDP 时影响了 TCP 或未释放 UDP") { daemon.shared == .init(port: bound, udp: false) }
        var released = false
        daemon.setSharing(port: 0) { released = true }
        try require(!released, "撤回通知尚未到达就释放了本机端口")
        try await eventually("停止共享后端口仍然可用") { released && daemon.shared.port == 0 && log().contains("share 0\n") }
        var bridged: UInt16?, error: String?
        let close = daemon.bridge(host: "100.100.0.2", port: 5908, ready: { bridged = $0 }, failed: { error = $0 })
        try await eventually("连接未映射到组件端口") { bridged == 34907 || error != nil }
        try require(error == nil, error ?? "")
        close()
        try await eventually("断开后仍然保留转发端口") { log().contains("close 34907\n") }

        let replyGate = base.appendingPathComponent(bridgeReplyGate)
        try Data().write(to: replyGate, options: .atomic)
        var cancelledCompleted = false
        let cancel = daemon.bridge(host: "100.100.0.2", port: 5908, ready: { _ in cancelledCompleted = true }, failed: { _ in cancelledCompleted = true })
        try await eventually("组件未开始第二次连接") { log().components(separatedBy: "open 5908\n").count == 3 }
        cancel()
        try FileManager.default.removeItem(at: replyGate)
        try await eventually("取消过程中建立的端口没有释放") { log().components(separatedBy: "close 34907\n").count == 3 }
        try require(!cancelledCompleted, "已取消的连接继续启动")

        try Data("derp".utf8).write(to: pathFixture, options: .atomic)
        try daemon.setControlURL(" \(control) ")
        try await eventually("组件未携带控制服务参数重启或未发布 DERP 路径") {
            log().contains("launch \(control)\n") && daemon.state == "Running" && daemon.peerPath == "derp" && daemon.peerRelay == "hkg"
        }
        try require(defaults.string(forKey: "embeddedTailnetControlURL") == control, "启用后未保存规范化的控制服务配置")

        try Data(#"{"34907":{"path":"direct"},"34908":{"path":"derp","relay":"test"}}"#.utf8).write(to: bridgeFixture, options: .atomic)
        var firstRoutes: [(String?, String?)] = []
        var secondRoutes: [(String?, String?)] = []
        let closeFirst = daemon.bridge(host: "100.100.0.2", port: 5908, ready: { _ in }, failed: { error = $0 },
                                       peerRouteChanged: { firstRoutes.append(($0, $1)) })
        let closeSecond = daemon.bridge(host: "100.100.0.3", port: 5908, ready: { _ in }, failed: { error = $0 },
                                        peerRouteChanged: { secondRoutes.append(($0, $1)) })
        try await eventually("并发连接没有各自收到真实的对端路径") {
            firstRoutes.last?.0 == "direct" && secondRoutes.last?.0 == "derp" && secondRoutes.last?.1 == "test"
        }
        closeFirst()
        try await eventually("关闭连接后未撤销旧路径观察") {
            log().components(separatedBy: "close 34907\n").count == 4
        }
        let firstEvents = firstRoutes.count
        try Data(#"{"34907":{"path":"derp","relay":"other"}}"#.utf8).write(to: bridgeFixture, options: .atomic)
        var reusedRoutes: [(String?, String?)] = []
        let closeReused = daemon.bridge(host: "100.100.0.2", port: 5908, ready: { _ in }, failed: { error = $0 },
                                        peerRouteChanged: { reusedRoutes.append(($0, $1)) })
        try await eventually("复用端口沿用了旧路径，或缺省路径仍被报告为中继") {
            reusedRoutes.last?.0 == "derp" && reusedRoutes.last?.1 == "other" &&
            secondRoutes.count == 2 && secondRoutes.last?.0 == nil
        }
        try require(firstRoutes.count == firstEvents && error == nil, "已关闭的连接收到复用端口的路径事件")
        closeSecond()

        try Data("direct".utf8).write(to: pathFixture, options: .atomic)
        daemon.login()
        try await eventually("未发布 P2P 路径或沿用了上一条 DERP 区域") {
            !daemon.changingAccount && daemon.peerPath == "direct" && daemon.peerRelay == nil
        }
        try FileManager.default.removeItem(at: pathFixture)
        daemon.login()
        try await eventually("较旧的状态回复省略路径字段后没有清除 P2P 路径") {
            !daemon.changingAccount && daemon.peerPath == nil && daemon.peerRelay == nil
        }

        try Data("derp".utf8).write(to: pathFixture, options: .atomic)
        daemon.login()
        try await eventually("未恢复模拟的 DERP 路径") { !daemon.changingAccount && daemon.peerPath == "derp" }
        try daemon.setControlURL("")
        try require(daemon.controlURL.isEmpty && daemon.peerPath == nil && daemon.peerRelay == nil,
                    "恢复默认设置时没有同步清除旧组件的路径状态")
        try require(reusedRoutes.count == 2 && reusedRoutes.last?.0 == nil, "组件替换后没有同步清除连接的旧路径")
        closeReused()
        try await eventually("恢复默认设置后没有用官方默认参数重启") {
            log().components(separatedBy: "launch official\n").count == 3 && daemon.state == "Running"
        }
        try require((defaults.string(forKey: "embeddedTailnetControlURL") ?? "").isEmpty && daemon.peerPath == nil && daemon.peerRelay == nil,
                    "恢复默认设置后仍保留自定义控制服务或旧路径")
        daemon.disable(logout: true)
        try await eventually("退出账号后组件依然启用") { !daemon.enabled && !daemon.changingAccount }
        try require(log().contains("logout 0\n") && !defaults.bool(forKey: "embeddedTailnetEnabled"), "退出账号未完成")
        print("PASS Embedded Tailscale opt-in, control server restart and login URL, P2P/DERP status, forward lifecycle, cancellation and logout (synthetic helper)")
    }
}
