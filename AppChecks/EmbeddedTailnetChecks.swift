import Foundation
import Network
import QuietDeskCore

@main
struct EmbeddedTailnetChecks {
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

    // Subprocess fixture: it records only operations and synthetic ports, and never creates a node.
    private static func helper(directory: String) throws {
        let logURL = URL(fileURLWithPath: directory).appendingPathComponent("requests")
        if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        var shared = 0, udp = false
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
            case "share":
                udp = req["udp"] as? Bool ?? false
                if shared != 0 { Thread.sleep(forTimeInterval: 0.08) }
                shared = port
                reply["port"] = shared
                reply["udp"] = udp
            case "open":
                try require(req["host"] as? String == "100.100.0.2" && port == 5908, "错误的对端地址")
                Thread.sleep(forTimeInterval: 0.12)
                reply["port"] = 34907
            default: break
            }
            var packet = try JSONSerialization.data(withJSONObject: reply)
            packet.append(10)
            try FileHandle.standardOutput.write(contentsOf: packet)
        }
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--state-dir" {
            try helper(directory: CommandLine.arguments[2])
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
        func log() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

        try require(EmbeddedTailnet.loginURL("https://login.tailscale.com/a/example") != nil &&
                    EmbeddedTailnet.loginURL("https://login.tailscale.com.example.invalid/a/example") == nil &&
                    EmbeddedTailnet.loginURL("https://evil@login.tailscale.com/a/example") == nil,
                    "登录浏览器地址没有限定到官方 HTTPS 域名")
        let valid = try TailnetAddress.host(in: "tailscale:100.100.0.2")
        let native = try TailnetAddress.host(in: "100.100.0.2")
        try require(valid == "100.100.0.2" && native == nil, "显式 Tailscale 线路和系统线路混淆")
        do {
            _ = try TailnetAddress.host(in: "tailscale:127.0.0.1")
            throw CocoaError(.coderInvalidValue)
        } catch is DeskError {}

        daemon.setSharing(port: 5908)
        try require(!FileManager.default.fileExists(atPath: base.path), "未启用时启动了组件")
        daemon.login()
        try await eventually("未发布正在运行的共享端口") { daemon.ip == "100.99.0.1" && daemon.shared == .init(port: 5908, udp: false) }
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

        var cancelledCompleted = false
        let cancel = daemon.bridge(host: "100.100.0.2", port: 5908, ready: { _ in cancelledCompleted = true }, failed: { _ in cancelledCompleted = true })
        try await eventually("组件未开始第二次连接") { log().components(separatedBy: "open 5908\n").count == 3 }
        cancel()
        try await eventually("取消过程中建立的端口没有释放") { log().components(separatedBy: "close 34907\n").count == 3 }
        try require(!cancelledCompleted, "已取消的连接继续启动")
        daemon.disable(logout: true)
        try await eventually("退出账号后组件依然启用") { !daemon.enabled && !daemon.changingAccount }
        try require(log().contains("logout 0\n") && !defaults.bool(forKey: "embeddedTailnetEnabled"), "退出账号未完成")
        print("PASS Embedded Tailscale opt-in, login URL, forward lifecycle, cancellation and logout (synthetic helper)")
    }
}
