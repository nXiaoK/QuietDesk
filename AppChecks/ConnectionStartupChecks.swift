import Foundation
import Darwin
import Network
@testable import QuietDeskCore

private struct CheckFailure: Error { let message: String }
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

@main
struct ConnectionStartupChecks {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--suspended-clock-helper") {
            let before = SessionClock.uptime
            var grace = LocalSchedulingGrace(now: before)
            print("ready"); fflush(stdout)
            _ = readLine()
            let after = SessionClock.uptime
            let recovered = grace.observe(now: after, interval: 0.01, allowance: 0.5)
            print(recovered && after - before >= 0.5 && grace.isActive(at: after) ? "recovered" : "failed")
            return
        }
        var passed = 0, failed = 0
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CheckFailure(message: message) }
        }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CheckFailure(message: message)
        }
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("A real suspended child proves uptime advances and recovery comes from scheduling grace") {
            let child = Process(), input = Pipe(), output = Pipe()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--suspended-clock-helper"]
            child.standardInput = input; child.standardOutput = output
            try child.run()
            defer {
                if child.isRunning { kill(child.processIdentifier, SIGCONT); kill(child.processIdentifier, SIGKILL) }
            }
            try require(String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "ready\n", "Child did not start")
            try require(kill(child.processIdentifier, SIGSTOP) == 0, "Could not suspend the isolated child")
            try await Task.sleep(for: .milliseconds(700))
            try require(kill(child.processIdentifier, SIGCONT) == 0, "Could not resume the isolated child")
            try input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
            try require(String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "recovered\n",
                        "Suspended child did not receive liveness grace")
            child.waitUntilExit()
            try require(child.terminationStatus == 0, "Child did not exit normally")
        }

        await run("Callback completion supports synchronous results, errors and duplicate callbacks") {
            let value: Int = try await CallbackOperation.run { finish in
                finish(.success(7)); finish(.success(9))
            }
            try require(value == 7, "Duplicate callback replaced the first result")
            do {
                let _: Int = try await CallbackOperation.run { $0(.failure(CheckFailure(message: "original"))) }
                throw CheckFailure(message: "Failure was swallowed")
            } catch let error as CheckFailure { try require(error.message == "original", "Error changed") }
        }
        await run("Cancellation before callback installation does not start the system operation") {
            let started = Box(false)
            let task = Task<Int, Error> {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await CallbackOperation.run { finish in started.set(true); finish(.success(1)) }
            }
            do { _ = try await task.value; throw CheckFailure(message: "Cancelled operation succeeded") }
            catch is CancellationError {}
            try require(!started.read(), "Cancelled task started the callback API")
        }
        await run("A system API that never calls back cannot retain the awaiting owner after cancellation") {
            final class Owner {}
            var owner: Owner? = Owner()
            weak var released = owner
            let callback = Box<((Result<Int, Error>) -> Void)?>(nil)
            let done = Box(false)
            var task: Task<Int, Error>? = Task { [held = owner!] in
                defer { withExtendedLifetime(held) {}; done.set(true) }
                return try await CallbackOperation.run { callback.set($0) }
            }
            owner = nil
            try await eventually("Operation did not install its callback") { callback.read() != nil }
            task?.cancel()
            try await eventually("Cancellation waited for the missing system callback") { done.read() }
            do { _ = try await task!.value; throw CheckFailure(message: "Cancelled operation succeeded") }
            catch is CancellationError {}
            task = nil
            try await eventually("Cancelled operation retained its owner") { released == nil }
            callback.read()?(.success(10))
            callback.read()?(.failure(CheckFailure(message: "late")))
        }
        await run("Concurrent callback and cancellation resolve each operation exactly once") {
            for _ in 0..<100 {
                let callback = Box<((Result<Int, Error>) -> Void)?>(nil)
                let done = Box(false)
                let task = Task<Int, Error> {
                    defer { done.set(true) }
                    return try await CallbackOperation.run { callback.set($0) }
                }
                try await eventually("Callback was not installed") { callback.read() != nil }
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    if index == 0 { task.cancel() }
                    else { callback.read()?(.success(3)) }
                }
                try await eventually("Race lost its continuation") { done.read() }
                do { try require(try await task.value == 3, "Race changed the result") }
                catch is CancellationError {}
            }
        }
        await run("Completed, replaced and released startup deadlines cannot affect a later connection") {
            var oldCalls = 0, newCalls = 0
            var deadline: ConnectionStartupDeadline? = ConnectionStartupDeadline()
            deadline?.arm(after: .milliseconds(20)) { oldCalls += 1 }
            deadline?.cancel()
            deadline?.arm(after: .milliseconds(20)) { oldCalls += 1 }
            deadline?.arm(after: .milliseconds(80)) { newCalls += 1 }
            try await Task.sleep(for: .milliseconds(150))
            try require(oldCalls == 0 && newCalls == 1 && deadline?.isArmed == false, "Old deadline escaped its generation")
            deadline?.arm(after: .milliseconds(20)) { oldCalls += 1 }
            deadline = nil
            try await Task.sleep(for: .milliseconds(60))
            try require(oldCalls == 0, "Released deadline invoked its owner")
        }
        await run("Startup timeout cancels a stalled callback operation and permits the next attempt") {
            let callback = Box<((Result<Int, Error>) -> Void)?>(nil)
            let done = Box(false)
            let first = Task<Int, Error> {
                defer { done.set(true) }
                return try await CallbackOperation.run { callback.set($0) }
            }
            try await eventually("First attempt did not start") { callback.read() != nil }
            let deadline = ConnectionStartupDeadline()
            deadline.arm(after: .milliseconds(30)) { first.cancel() }
            try await eventually("Startup timeout did not release the first attempt") { done.read() }
            do { _ = try await first.value; throw CheckFailure(message: "Timed out attempt succeeded") }
            catch is CancellationError {}
            let next: Int = try await CallbackOperation.run { finish in
                callback.read()?(.success(1))
                finish(.success(2))
            }
            try require(next == 2, "Late first result affected the new attempt")
        }
        if !CommandLine.arguments.contains("--skip-network") {
            await run("TLS heartbeats keep an unprepared host alive but cannot bypass the hello deadline") {
                let key = try PairingKey.generate()
                let listener = try NWListener(using: SecureTransport.parameters(key: key), on: .any)
                let listening = Box(false), server = Box<Peer?>(nil), ready = Box(false)
                let reason = Box<String?>(nil)
                listener.stateUpdateHandler = { if case .ready = $0 { listening.set(true) } }
                listener.newConnectionHandler = { connection in
                    let peer = Peer(connection: connection, idleTimeout: 0.2, heartbeatInterval: 0.02)
                    server.set(peer); peer.start()
                }
                listener.start(queue: DispatchQueue(label: "checks.startup-listener"))
                defer { listener.cancel(); server.read()?.close() }
                try await eventually("Loopback listener did not start") { listening.read() }
                guard let port = listener.port else { throw CheckFailure(message: "Missing listener port") }
                let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
                    using: SecureTransport.parameters(key: key)), idleTimeout: 0.2, heartbeatInterval: 0.02)
                client.onReady = { ready.set(true) }
                client.onClose = { reason.set($0) }
                client.start()
                defer { client.close() }
                try await eventually("Loopback TLS did not become ready") { ready.read() }
                let deadline = ConnectionStartupDeadline()
                deadline.arm(after: .milliseconds(500)) { client.close("hello deadline", retryable: true) }
                try await Task.sleep(for: .milliseconds(350))
                try require(reason.read() == nil, "Healthy heartbeats were treated as idle failure")
                try await eventually("Heartbeats suppressed the startup deadline") { reason.read() != nil }
                try require(reason.read() == "hello deadline" && client.closeIsRetryable, "Startup failure lost retry semantics")
            }
        }
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
