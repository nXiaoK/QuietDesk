import AppKit
import Network
import QuietDeskCore

/// One private tsnet process shared by all the application's desktop sessions.
@MainActor
final class EmbeddedTailnet: ObservableObject {
    private struct Reply: Decodable {
        private enum CodingKeys: String, CodingKey { case id, state, ip, authURL, port, udp, error }
        var source: Process?
        let id: Int
        let state: String?
        let ip: String?
        let authURL: String?
        let port: UInt16?
        let udp: Bool?
        let error: String?
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

    private let defaults: UserDefaults
    private let executable: URL
    private let directory: URL
    private var process: Process?
    private var input: FileHandle?
    private let writes = DispatchQueue(label: "quietdesk.tailnet.stdin")
    private var nextID = 0
    private var lastExposureReply = 0
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
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
        if enabled { startPolling() }
    }

    private func launch() throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["--state-dir", directory.path]
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
    }

    private func received(_ reply: Reply, from child: Process) {
        guard process === child, let continuation = pending.removeValue(forKey: reply.id) else { return }
        var completed = reply
        completed.source = child
        continuation.resume(returning: completed)
    }

    private func request(_ op: String, host: String? = nil, port: UInt16? = nil, udp: Bool? = nil) async throws -> Reply {
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

    static func loginURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), ["login.tailscale.com", "controlplane.tailscale.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
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
        updateExposure(reply)
        if message == lastStatusError { message = nil }
        lastStatusError = nil
        if backendState == "Running" {
            browserRequested = false
            synchronizeSharing()
        } else if browserRequested, let address = reply.authURL, !address.isEmpty {
            browserRequested = false
            guard let url = Self.loginURL(address), NSWorkspace.shared.open(url) else {
                message = "无法打开 Tailscale 登录页，请重新登录"
                return
            }
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
                    if !Task.isCancelled { self.lastStatusError = error.localizedDescription; self.message = self.lastStatusError }
                }
                do { try await Task.sleep(for: .seconds(self.state == "Running" ? 10 : 2)) }
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
        var localPort: UInt16?
        weak var owner: Process?
        let opening = Task {
            do {
                guard !Task.isCancelled else { return }
                let reply = try await request("open", host: host, port: port)
                owner = reply.source
                guard let port = reply.port, port != 0 else { throw DeskError.invalid("Tailscale 没有返回可用端口") }
                if Task.isCancelled { self.closeBridge(port, on: owner); return }
                localPort = port
                ready(port)
            } catch {
                if !Task.isCancelled { failed(error.localizedDescription) }
            }
        }
        return {
            opening.cancel()
            if let port = localPort { localPort = nil; self.closeBridge(port, on: owner) }
        }
    }

    private func closeBridge(_ port: UInt16, on child: Process?) {
        Task {
            guard let child, process === child else { return }
            _ = try? await request("close", port: port)
        }
    }
}
