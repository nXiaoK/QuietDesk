import AppKit
import Network
import QuietDeskCore

/// One private tsnet process shared by all the application's desktop sessions.
@MainActor
final class EmbeddedTailnet: ObservableObject {
    private struct Reply: Decodable {
        private enum CodingKeys: String, CodingKey {
            case id, state, ip, authURL, port, udp, error, peerPath, peerRelay, bridgeRoutes
        }
        var source: Process?
        let id: Int
        let state: String?
        let ip: String?
        let authURL: String?
        let port: UInt16?
        let udp: Bool?
        let error: String?
        let peerPath: String?
        let peerRelay: String?
        let bridgeRoutes: [String: BridgeRoute]?
    }

    private struct BridgeRoute: Decodable, Equatable {
        let path: String
        let relay: String?
    }

    private struct BridgeObservation {
        let openedWith: Int
        let onChange: (String?, String?) -> Void
        var route: BridgeRoute?
    }

    private struct Request: Encodable {
        let id: Int
        let op: String
        let host: String?
        let port: UInt16?
        let udp: Bool?
    }

    struct Exposure: Equatable {
        var port: UInt16 = 0
        var udp = false
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var state = ""
    @Published private(set) var ip: String?
    @Published private(set) var shared = Exposure()
    @Published private(set) var message: String?
    @Published private(set) var changingAccount = false
    @Published private(set) var peerPath: String?
    @Published private(set) var peerRelay: String?
    @Published private(set) var controlURL: String

    private let defaults: UserDefaults
    private let executable: URL
    private let directory: URL
    private var process: Process?
    private var input: FileHandle?
    private let writes = DispatchQueue(label: "quietdesk.tailnet.stdin")
    private var nextID = 0
    private var lastExposureReply = 0
    private var lastBridgeStatusReply = 0
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var bridgeObservations: [UInt16: BridgeObservation] = [:]
    private var pollTask: Task<Void, Never>?
    private var requestedShare: UInt16 = 0
    private var datagramListener: NWListener?
    private var planned: Exposure?
    private var sharingRevision = 0
    private var processExit: Task<Void, Never>?
    private var exitedRevision = 0
    private var shareTask: Task<Void, Never>?
    private var browserRequested = false
    private var lastStatusError: String?

    init(defaults: UserDefaults = .standard, executable: URL? = nil, directory: URL? = nil) {
        self.defaults = defaults
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/QuietDeskTailnet")
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.folderName()).appendingPathComponent("Tailscale", isDirectory: true)
        enabled = defaults.bool(forKey: "embeddedTailnetEnabled")
        controlURL = defaults.string(forKey: "embeddedTailnetControlURL") ?? ""
        if enabled { startPolling() }
    }

    private func launch() throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["--state-dir", directory.path]
        if !controlURL.isEmpty { child.arguments?.append(contentsOf: ["--control-url", controlURL]) }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        let reader = stdout.fileHandleForReading
        try child.run()
        try? stdout.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        process = child
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    guard line.count <= 65536, let reply = try? JSONDecoder().decode(Reply.self, from: line) else {
                        DispatchQueue.main.async { [weak self] in self?.disconnected(child) }
                        return
                    }
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { [weak self] in self?.received(reply, from: child) }
                }
                if buffer.count > 65536 { break }
            }
            DispatchQueue.main.async { [weak self] in self?.disconnected(child) }
        }
    }

    private func disconnected(_ child: Process) {
        guard process === child else { return }
        shutdown()
        if enabled { lastStatusError = "Tailscale 组件已断开"; message = lastStatusError }
    }

    private func shutdown() {
        let child = process
        process = nil
        try? input?.close()
        input = nil
        if let child {
            if child.isRunning { child.terminate() }
            let previousExit = processExit
            exitedRevision += 1
            let revision = exitedRevision
            processExit = Task {
                await Task.detached { child.waitUntilExit() }.value
                await previousExit?.value
                if exitedRevision == revision { processExit = nil }
            }
        }
        for reply in pending.values { reply.resume(throwing: DeskError.invalid("Tailscale 组件已断开")) }
        pending.removeAll()
        state = ""
        ip = nil
        shared = Exposure()
        peerPath = nil
        peerRelay = nil
        let observations = bridgeObservations.values
        bridgeObservations.removeAll()
        for observation in observations where observation.route != nil { observation.onChange(nil, nil) }
    }

    private func received(_ reply: Reply, from child: Process) {
        guard process === child, let continuation = pending.removeValue(forKey: reply.id) else { return }
        var completed = reply
        completed.source = child
        continuation.resume(returning: completed)
    }

    private func request(_ op: String, host: String? = nil, port: UInt16? = nil, udp: Bool? = nil) async throws -> Reply {
        // The replacement helper reuses the private state directory and the WireGuard port.
        if process == nil, let processExit {
            await processExit.value
            try Task.checkCancellation()
        }
        guard enabled else { throw DeskError.invalid("请先在「网络与线路 → Tailscale」登录") }
        try launch()
        guard let child = process, let input else { throw DeskError.invalid("无法启动 Tailscale 组件") }
        nextID += 1
        let id = nextID
        var packet = try JSONEncoder().encode(Request(id: id, op: op, host: host, port: port, udp: udp))
        packet.append(10)
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            writes.async { [weak self, packet] in
                do { try input.write(contentsOf: packet) }
                catch { DispatchQueue.main.async { [weak self] in self?.disconnected(child) } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self, weak child] in
                guard let self, let child, self.pending[id] != nil else { return }
                self.disconnected(child)
            }
        }
        if op != "share", let error = reply.error, !error.isEmpty { throw DeskError.invalid("Tailscale：\(error)") }
        return reply
    }

    static func normalizedControlURL(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        let invalid = DeskError.invalid("Tailscale 控制服务地址需为 https://域名或IP[:端口]，且不含账号密码或查询参数")
        guard text.prefix(8).lowercased() == "https://",
              let url = URL(string: text, encodingInvalidCharacters: false),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.rangeOfPort == nil || parts.port != nil, (1...65_535).contains(parts.port ?? 443) else { throw invalid }
        let authority = text.dropFirst(8).prefix { $0 != "/" }
        guard !authority.hasSuffix(":"), !authority.contains("%") else { throw invalid }
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]"),
                  closing == authority.index(before: authority.endIndex) || (parts.port != nil && authority[authority.index(after: closing)] == ":"),
                  IPv6Address(String(authority[authority.index(after: authority.startIndex)..<closing])) != nil else { throw invalid }
        } else {
            let hostname = authority.prefix { $0 != ":" }
            let domain = hostname.hasSuffix(".") ? hostname.dropLast() : hostname
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let numericHost = domain.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
            guard !domain.isEmpty, domain.utf8.count <= 253,
                  !numericHost || IPv4Address(String(domain)) != nil,
                  labels.allSatisfy({ label in
                      (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                          label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                  }) else { throw invalid }
        }
        return text
    }

    func setControlURL(_ value: String) throws {
        let normalized = try Self.normalizedControlURL(value)
        guard normalized != controlURL else { return }
        controlURL = normalized
        defaults.set(normalized, forKey: "embeddedTailnetControlURL")
        browserRequested = false
        if process != nil { shutdown() }
        if enabled { startPolling() }
    }

    static func loginURL(_ value: String, controlURL: String? = nil) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.rangeOfPort == nil || url.port != nil,
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        let port = url.port ?? 443
        if ["login.tailscale.com", "controlplane.tailscale.com"].contains(host), port == 443 { return url }
        guard let controlURL, let normalized = try? normalizedControlURL(controlURL), !normalized.isEmpty,
              let control = URL(string: normalized), host == control.host?.lowercased(), port == (control.port ?? 443) else { return nil }
        return url
    }

    private func updateExposure(_ reply: Reply) {
        guard reply.source === process, reply.id > lastExposureReply else { return }
        lastExposureReply = reply.id
        shared = Exposure(port: reply.port ?? 0, udp: reply.udp ?? false)
    }

    private func update(_ reply: Reply) {
        guard reply.source === process, let backendState = reply.state else { return }
        state = backendState
        ip = reply.ip
        peerPath = reply.peerPath
        peerRelay = reply.peerRelay
        if reply.id > lastBridgeStatusReply {
            lastBridgeStatusReply = reply.id
            updateBridgeRoutes(backendState == "Running" ? reply.bridgeRoutes : nil, replyID: reply.id)
        }
        updateExposure(reply)
        if message == lastStatusError { message = nil }
        lastStatusError = nil
        if backendState == "Running" {
            browserRequested = false
            synchronizeSharing()
        } else if browserRequested, let address = reply.authURL, !address.isEmpty {
            browserRequested = false
            guard let url = Self.loginURL(address, controlURL: controlURL), NSWorkspace.shared.open(url) else {
                message = "无法打开 Tailscale 登录页，请重新登录"
                return
            }
        }
    }

    private func updateBridgeRoutes(_ routes: [String: BridgeRoute]?, replyID: Int? = nil) {
        for (port, var observation) in bridgeObservations {
            // A status requested before the open cannot describe a reused loopback port.
            if let replyID, replyID <= observation.openedWith { continue }
            let reported = routes?[String(port)]
            let route = reported.flatMap { $0.path == "direct" || $0.path == "derp" ? $0 : nil }
            guard route != observation.route else { continue }
            observation.route = route
            bridgeObservations[port] = observation
            observation.onChange(route?.path, route?.path == "derp" ? route?.relay : nil)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, self.enabled, !Task.isCancelled {
                do {
                    let reply = try await self.request("status")
                    guard !Task.isCancelled else { return }
                    self.update(reply)
                } catch {
                    if !Task.isCancelled {
                        self.updateBridgeRoutes(nil)
                        self.lastStatusError = error.localizedDescription
                        self.message = self.lastStatusError
                    }
                }
                let interval = self.bridgeObservations.isEmpty ? (self.state == "Running" ? 10 : 2) : 1
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }

    func login() {
        guard !changingAccount else { return }
        enabled = true
        defaults.set(true, forKey: "embeddedTailnetEnabled")
        browserRequested = true
        message = nil
        changingAccount = true
        Task {
            defer { changingAccount = false }
            do { update(try await request("login")) }
            catch { browserRequested = false; message = error.localizedDescription }
            if enabled { startPolling() }
        }
    }

    func disable(logout: Bool) {
        guard !changingAccount else { return }
        changingAccount = true
        browserRequested = false
        pollTask?.cancel()
        Task {
            defer { changingAccount = false }
            if logout {
                do { _ = try await request("logout") }
                catch { message = error.localizedDescription; startPolling(); return }
            }
            enabled = false
            defaults.set(false, forKey: "embeddedTailnetEnabled")
            shutdown()
            message = nil
        }
    }

    @discardableResult
    func setSharing(port: UInt16, afterChange: (() -> Void)? = nil) -> Task<Void, Never>? {
        requestedShare = port
        return synchronizeSharing(afterChange: afterChange)
    }

    func datagramReadiness(_ listener: NWListener, ready: Bool) {
        if ready { datagramListener = listener }
        else if datagramListener === listener { datagramListener = nil }
        synchronizeSharing()
    }

    func retireDatagram(_ listener: NWListener) {
        if datagramListener === listener { datagramListener = nil }
        synchronizeSharing { listener.cancel() }
    }

    func waitForSharingChanges() async { await shareTask?.value }

    func afterSharingChanges(_ body: @escaping () -> Void) {
        guard let task = shareTask else { body(); return }
        Task { await task.value; body() }
    }

    @discardableResult
    private func synchronizeSharing(afterChange: (() -> Void)? = nil) -> Task<Void, Never>? {
        let desired = Exposure(port: requestedShare, udp: requestedShare != 0 && datagramListener?.port?.rawValue == requestedShare)
        if afterChange == nil, planned == desired { return shareTask }
        let previous = shareTask
        guard previous != nil || (enabled && process != nil && desired != shared) || processExit != nil else {
            afterChange?()
            return nil
        }
        sharingRevision += 1
        let revision = sharingRevision
        planned = desired
        let task = Task {
            await previous?.value
            defer {
                afterChange?()
                if revision == sharingRevision { planned = nil; shareTask = nil }
            }
            if let child = process, enabled, desired != shared,
               state == "Running" || shared.port != 0 {
                do {
                    let reply = try await request("share", port: desired.port, udp: desired.udp)
                    updateExposure(reply)
                    if let error = reply.error { message = "Tailscale 共享失败：\(error)" }
                    else if message?.hasPrefix("Tailscale 共享") == true { message = nil }
                    // Keep the local socket bound if the node could still forward to it.
                    if shared.port != 0 && (shared.port != desired.port || shared.udp && !desired.udp) { shutdown() }
                } catch {
                    if process === child { shutdown() }
                    message = "Tailscale 共享失败：\(error.localizedDescription)"
                }
            }
            await processExit?.value
        }
        shareTask = task
        return task
    }

    /// The owner releases the returned lease when its desktop or mapping session ends.
    func bridge(host: String, port: UInt16, ready: @escaping (UInt16) -> Void,
                failed: @escaping (String) -> Void) -> () -> Void {
        openBridge(host: host, port: port, ready: ready, failed: failed, peerRouteChanged: nil)
    }

    func bridge(host: String, port: UInt16, ready: @escaping (UInt16) -> Void,
                failed: @escaping (String) -> Void,
                peerRouteChanged: @escaping (String?, String?) -> Void) -> () -> Void {
        openBridge(host: host, port: port, ready: ready, failed: failed, peerRouteChanged: peerRouteChanged)
    }

    private func openBridge(host: String, port: UInt16, ready: @escaping (UInt16) -> Void,
                            failed: @escaping (String) -> Void,
                            peerRouteChanged: ((String?, String?) -> Void)?) -> () -> Void {
        var localPort: UInt16?
        var openedWith: Int?
        weak var owner: Process?
        let opening = Task {
            do {
                guard !Task.isCancelled else { return }
                let reply = try await request("open", host: host, port: port)
                guard let source = reply.source, process === source else { throw DeskError.invalid("Tailscale 组件已断开") }
                owner = source
                guard let port = reply.port, port != 0 else { throw DeskError.invalid("Tailscale 没有返回可用端口") }
                if Task.isCancelled { self.closeBridge(port, on: owner); return }
                localPort = port
                openedWith = reply.id
                if let peerRouteChanged {
                    let startsRoutePolling = bridgeObservations.isEmpty
                    bridgeObservations[port] = BridgeObservation(openedWith: reply.id, onChange: peerRouteChanged)
                    if startsRoutePolling { startPolling() }
                }
                ready(port)
            } catch {
                if !Task.isCancelled { failed(error.localizedDescription) }
            }
        }
        return {
            opening.cancel()
            if let port = localPort {
                localPort = nil
                if self.bridgeObservations[port]?.openedWith == openedWith {
                    self.bridgeObservations.removeValue(forKey: port)
                }
                self.closeBridge(port, on: owner)
            }
        }
    }

    private func closeBridge(_ port: UInt16, on child: Process?) {
        Task {
            guard let child, process === child else { return }
            _ = try? await request("close", port: port)
        }
    }
}
