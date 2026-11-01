import Foundation
import QuietDeskCore

private struct CheckFailure: Error { let message: String }

private final class SyntheticCapture: CaptureStreamControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var startCallback: ((Error?) -> Void)?
    private var stopCallbacks: [((Error?) -> Void)] = []
    private var starts = 0
    private var stops = 0
    let repliesToStop: Bool
    let synchronousStart: Bool

    init(repliesToStop: Bool = true, synchronousStart: Bool = false) {
        self.repliesToStop = repliesToStop; self.synchronousStart = synchronousStart
    }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    func startCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock { starts += 1; startCallback = completionHandler }
        if synchronousStart { completionHandler?(nil) }
    }
    func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.withLock {
            stops += 1
            if let completionHandler { stopCallbacks.append(completionHandler) }
        }
        if repliesToStop { completionHandler?(nil) }
    }
    func completeStart(_ error: Error? = nil) { lock.withLock { startCallback }?(error) }
    func completeStops() { lock.withLock { stopCallbacks }.forEach { $0(nil) } }
}

@MainActor
private final class CaptureOwner {
    let lifecycle: CaptureLifecycle
    var task: Task<Void, Error>?
    init(_ lifecycle: CaptureLifecycle) { self.lifecycle = lifecycle }
    func start() {
        task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer { withExtendedLifetime(self) {} }
            try await lifecycle.start()
        }
    }
}

@main
struct CaptureLifecycleChecks {
    @MainActor
    static func main() async {
        var passed = 0, failed = 0
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw CheckFailure(message: message) }
        }
        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CheckFailure(message: "Timed out waiting for a synthetic callback")
        }
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("Normal synchronous start and concurrent stops finish exactly once") {
            let stream = SyntheticCapture(synchronousStart: true)
            let lifecycle = CaptureLifecycle(stream: stream)
            try await lifecycle.start()
            async let first: Void = lifecycle.stop()
            async let second: Void = lifecycle.stop()
            _ = await (first, second)
            stream.completeStart(); stream.completeStops()
            await lifecycle.stop()
            try require(stream.startCount == 1 && stream.stopCount == 1, "Duplicate callback or stop restarted cleanup")
        }
        await run("A cancelled task never starts the underlying capture") {
            let stream = SyntheticCapture()
            let own = CaptureLifecycle(stream: stream)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await own.start()
            }
            do { try await task.value; throw CheckFailure(message: "Cancellation was lost") }
            catch is CancellationError {}
            await own.stop()
            try require(stream.startCount == 0 && stream.stopCount == 0, "Cancelled start touched the system stream")
        }
        await run("Cancellation releases an owner even when neither system callback ever arrives") {
            let stream = SyntheticCapture(repliesToStop: false)
            var owner: CaptureOwner? = CaptureOwner(CaptureLifecycle(stream: stream, shutdownTimeout: 0.05))
            weak var released = owner
            owner?.start()
            var task = owner?.task
            try await eventually { stream.startCount == 1 }
            owner = nil
            task?.cancel()
            do { try await task?.value; throw CheckFailure(message: "Cancellation was lost") }
            catch is CancellationError {}
            task = nil
            try await eventually { released == nil && stream.stopCount == 1 }
            stream.completeStart()
            try await eventually { stream.stopCount == 2 }
        }
        await run("Repeated abandoned starts release every owner instead of accumulating across retries") {
            var streams: [SyntheticCapture] = []
            for _ in 0..<25 {
                let stream = SyntheticCapture(repliesToStop: false)
                streams.append(stream)
                var owner: CaptureOwner? = CaptureOwner(CaptureLifecycle(stream: stream, shutdownTimeout: 0.01))
                weak var released = owner
                owner?.start()
                var task = owner?.task
                try await eventually { stream.startCount == 1 }
                owner = nil
                task?.cancel()
                do { try await task?.value; throw CheckFailure(message: "Cancelled retry succeeded") }
                catch is CancellationError {}
                task = nil
                try await eventually { released == nil }
            }
            streams.forEach { $0.completeStart() }
            try await eventually { streams.allSatisfy { $0.stopCount == 2 } }
        }
        await run("Startup timeout completes without a callback and a replacement can start") {
            let old = SyntheticCapture(repliesToStop: false)
            let lifecycle = CaptureLifecycle(stream: old, startupTimeout: 0.04, shutdownTimeout: 0.04)
            do { try await lifecycle.start(); throw CheckFailure(message: "Missing callback succeeded") }
            catch let error as DeskError {
                try require(error.localizedDescription.contains("屏幕采集启动"), "Startup error changed")
            }
            await lifecycle.stop()
            let replacement = SyntheticCapture(synchronousStart: true)
            let next = CaptureLifecycle(stream: replacement)
            try await next.start()
            old.completeStart()
            try await eventually { old.stopCount == 2 }
            try require(replacement.stopCount == 0, "Late old callback stopped the replacement")
            await next.stop()
        }
        await run("Successful start followed by missing stop callback has bounded concurrent cleanup") {
            let stream = SyntheticCapture(repliesToStop: false, synchronousStart: true)
            let lifecycle = CaptureLifecycle(stream: stream, shutdownTimeout: 0.05)
            try await lifecycle.start()
            let began = ContinuousClock.now
            async let first: Void = lifecycle.stop()
            async let second: Void = lifecycle.stop()
            _ = await (first, second)
            try require(began.duration(to: .now) < .seconds(1) && stream.stopCount == 1, "Stop remained unbounded")
            stream.completeStops(); stream.completeStops()
            await lifecycle.stop()
        }
        await run("Stopping an in-flight start cancels it and stops a later successful activation again") {
            let stream = SyntheticCapture()
            let active = CaptureLifecycle(stream: stream)
            let task = Task { try await active.start() }
            try await eventually { stream.startCount == 1 }
            await active.stop()
            do { try await task.value; throw CheckFailure(message: "Stopped start succeeded") }
            catch is CancellationError {}
            stream.completeStart()
            try await eventually { stream.stopCount == 2 }
            stream.completeStart()
            try await Task.sleep(for: .milliseconds(20))
            try require(stream.stopCount == 2, "Duplicate start callback repeated cleanup")
        }
        await run("System start errors retain their original result") {
            let stream = SyntheticCapture()
            let active = CaptureLifecycle(stream: stream)
            let task = Task { try await active.start() }
            try await eventually { stream.startCount == 1 }
            stream.completeStart(CheckFailure(message: "original"))
            do { try await task.value; throw CheckFailure(message: "Error swallowed") }
            catch let error as CheckFailure { try require(error.message == "original", "System error changed") }
            await active.stop()
        }
        await run("Concurrent cancellation and successful callbacks cannot strand the continuation") {
            for _ in 0..<100 {
                let stream = SyntheticCapture()
                let lifecycle = CaptureLifecycle(stream: stream)
                let task = Task { try await lifecycle.start() }
                try await eventually { stream.startCount == 1 }
                DispatchQueue.concurrentPerform(iterations: 2) { index in
                    if index == 0 { task.cancel() } else { stream.completeStart() }
                }
                do { try await task.value } catch is CancellationError {}
                await lifecycle.stop()
                try require(stream.stopCount >= 1 && stream.stopCount <= 2, "Race lost or duplicated cleanup")
            }
        }
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
