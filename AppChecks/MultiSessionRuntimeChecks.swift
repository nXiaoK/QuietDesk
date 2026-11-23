import AppKit
import Foundation
import QuietDeskCore

private struct MultiSessionCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class IsolatedDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey defaultName: String) -> Data? { values[defaultName] }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Message] = []
    func append(_ message: Message) { lock.withLock { items.append(message) } }
    func snapshot() -> [Message] { lock.withLock { items } }
    func clear() { lock.withLock { items.removeAll() } }
}

@MainActor
private final class SharedMemoryPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 1
    private var currentKind: ClipboardManifestKind?
    private var currentPayload: ClipboardPayload?
    private var lazyFetch: (@MainActor () -> ClipboardPayload?)?
    private(set) var contentMarker: String?
    var hasContentMarker: Bool { contentMarker != nil }

    func copyLocalText(_ value: String) {
        changeCount += 1
        currentKind = .text
        currentPayload = .text(Data(value.utf8))
        lazyFetch = nil
        contentMarker = nil
    }

    var fileURLs: [URL]? {
        if currentPayload == nil, let fetch = lazyFetch {
            currentPayload = fetch()
            lazyFetch = nil
        }
        if case .files(let urls) = currentPayload { return urls }
        return nil
    }

    var pngData: Data? {
        if currentPayload == nil, let fetch = lazyFetch {
            currentPayload = fetch()
            lazyFetch = nil
        }
        if case .png(let data) = currentPayload { return data }
        return nil
    }

    var text: String? {
        if currentPayload == nil, let fetch = lazyFetch {
            currentPayload = fetch()
            lazyFetch = nil
        }
        if case .text(let data) = currentPayload { return String(data: data, encoding: .utf8) }
        return nil
    }

    func inspectCurrentKind() -> ClipboardManifestKind? {
        currentKind
    }

    func write(_ payload: ClipboardPayload, marker: String) -> Bool {
        changeCount += 1
        switch payload {
        case .text: currentKind = .text
        case .png: currentKind = .png
        case .files: currentKind = .files
        }
        currentPayload = payload
        lazyFetch = nil
        contentMarker = marker
        return true
    }

    func writeLazy(
        _ kind: ClipboardManifestKind,
        marker: String,
        fetch: @escaping @MainActor () -> ClipboardPayload?,
        asyncFetch: @escaping @MainActor (@escaping (ClipboardPayload?) -> Void) -> Void
    ) -> Bool {
        _ = asyncFetch
        changeCount += 1
        currentKind = kind
        currentPayload = nil
        lazyFetch = fetch
        contentMarker = marker
        return true
    }
}

@main
private struct MultiSessionRuntimeChecks {
    @MainActor
    static func main() throws {
        var passed = 0
        var failed = 0

        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw MultiSessionCheckError(message) }
        }

        func pump(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        func run(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                passed += 1
                print("PASS \(name)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }

        run("Device-scoped stopSessionMappings(forDeviceID:) stops only disconnected Mac B while keeping Mac C active") {
            let defaults = IsolatedDefaults()
            let manager = PortMappingManager(defaults: defaults, showsApprovalPanel: false)
            let targetB = try PortMappingTarget(host: "127.0.0.1", port: 8081)
            let targetC = try PortMappingTarget(host: "127.0.0.1", port: 8082)
            let deviceB = UUID()
            let deviceC = UUID()

            let sessionRuleB = PortMappingRule(id: UUID(), deviceID: deviceB, name: "B-Web", localPort: 28081, target: targetB, scope: .session)
            let independentRuleB = PortMappingRule(id: UUID(), deviceID: deviceB, name: "B-DB", localPort: 28082, target: targetB, scope: .independent)
            let sessionRuleC = PortMappingRule(id: UUID(), deviceID: deviceC, name: "C-Web", localPort: 28083, target: targetC, scope: .session)

            try manager.saveRule(sessionRuleB)
            try manager.saveRule(independentRuleB)
            try manager.saveRule(sessionRuleC)

            var stoppedIDs: [UUID] = []
            try manager.start(sessionRuleB) { _, _ in { stoppedIDs.append(sessionRuleB.id) } }
            try manager.start(independentRuleB) { _, _ in { stoppedIDs.append(independentRuleB.id) } }
            try manager.start(sessionRuleC) { _, _ in { stoppedIDs.append(sessionRuleC.id) } }

            manager.stopSessionMappings(forDeviceID: deviceB)
            try require(stoppedIDs == [sessionRuleB.id], "Disconnecting B stopped unexpected port mapping rules: \(stoppedIDs)")
            try require(!manager.isEnabled(sessionRuleB.id), "B's session rule should have stopped")
            try require(manager.isEnabled(independentRuleB.id), "B's independent rule must remain active")
            try require(manager.isEnabled(sessionRuleC.id), "C's session rule must remain active while C stays connected")

            manager.stopAllMappings()
            try require(!manager.hasRunningMappings, "stopAllMappings should stop remaining rules cleanly")
        }

        run("CapsLockMonitor consumes hardware Caps Lock when active and passes through synthetic local InputInjector events (A -> B -> D)") {
            let pid = Int64(getpid())
            try require(
                CapsLockMonitor.shouldConsumeKeyboardEvent(keyCode: 57, sourcePID: 0, localPID: pid, isActive: true),
                "Hardware Caps Lock (sourcePID != localPID) must be consumed when viewer canvas is active"
            )
            try require(
                !CapsLockMonitor.shouldConsumeKeyboardEvent(keyCode: 57, sourcePID: pid, localPID: pid, isActive: true),
                "Synthetic Caps Lock from local InputInjector (sourcePID == localPID) must pass through for A -> B -> D"
            )
            try require(
                !CapsLockMonitor.shouldConsumeKeyboardEvent(keyCode: 57, sourcePID: 0, localPID: pid, isActive: false),
                "Inactive viewer canvas must not consume Caps Lock"
            )
            try require(
                !CapsLockMonitor.shouldConsumeKeyboardEvent(keyCode: 49, sourcePID: 0, localPID: pid, isActive: true),
                "Non-Caps-Lock keys must pass through"
            )
        }

        run("Concurrent ClipboardSync instances on a shared pasteboard do not trigger each other's lazy pulls or echo loops") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-multisession-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let sharedPasteboard = SharedMemoryPasteboard()
            let remoteBPasteboard = SharedMemoryPasteboard()

            let sentToB = MessageBox()
            let sentToC = MessageBox()
            let sentToEager = MessageBox()

            var syncB: ClipboardSync!
            let remotePeerB = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: remoteBPasteboard,
                storage: tempRoot.appendingPathComponent("remoteB")
            ) { message in
                DispatchQueue.main.async { syncB?.receiveMessage(message) }
            }
            defer { remotePeerB.stop() }

            syncB = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: sharedPasteboard,
                storage: tempRoot.appendingPathComponent("syncB")
            ) { message in
                sentToB.append(message)
                DispatchQueue.main.async { remotePeerB.receiveMessage(message) }
            }
            let syncC = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: true,
                pasteboard: sharedPasteboard,
                storage: tempRoot.appendingPathComponent("syncC")
            ) { message in
                sentToC.append(message)
            }
            let syncEager = ClipboardSync(
                session: UUID(),
                allowsFileSending: true,
                allowsAutomaticSending: true,
                allowsChunkWindow: true,
                allowsDecoupledFileTransfer: true,
                allowsOnDemandClipboard: false,
                pasteboard: sharedPasteboard,
                storage: tempRoot.appendingPathComponent("syncEager")
            ) { message in
                sentToEager.append(message)
            }
            defer {
                syncB.stop()
                syncC.stop()
                syncEager.stop()
            }

            pump(0.1)
            sentToB.clear()
            sentToC.clear()
            sentToEager.clear()

            // 1) Simulate session B installing a lazy remote text item onto the shared pasteboard:
            // verify neither modern syncC nor legacy syncEager forces lazy materialization in background!
            var lazyPullCount = 0
            let otherLazyMarker = "\(UUID().uuidString):lazy:text:\(UUID().uuidString):1"
            try require(
                sharedPasteboard.writeLazy(
                    .text,
                    marker: otherLazyMarker,
                    fetch: {
                        lazyPullCount += 1
                        return .text(Data("from-remote-B".utf8))
                    },
                    asyncFetch: { done in
                        lazyPullCount += 1
                        done(.text(Data("from-remote-B".utf8)))
                    }
                ),
                "Failed to install lazy item on shared pasteboard"
            )

            pump(0.75)
            try require(lazyPullCount == 0, "Sibling ClipboardSync background poll eagerly pulled session B's lazy item (\(lazyPullCount) pulls)")
            try require(sentToC.snapshot().isEmpty, "Modern sibling session C echoed another session's unmaterialized lazy item")
            try require(sentToEager.snapshot().isEmpty, "Eager sibling session sent another session's unmaterialized lazy item")

            // 2) Simulate a genuine local user copy on Mac A (no QuietDesk session marker):
            // all outgoing sessions (B, C, and Eager) must observe and sync/announce it!
            sharedPasteboard.copyLocalText("copied-on-mac-A")

            pump(0.75)
            try require(sentToB.snapshot().contains { $0.kind == .clipboardManifest }, "Session B did not announce local Mac A copy")
            try require(sentToC.snapshot().contains { $0.kind == .clipboardManifest }, "Session C did not announce local Mac A copy")
            try require(sentToEager.snapshot().contains { $0.kind == .clipboardBegin || $0.kind == .clipboard }, "Eager session did not send local Mac A copy")
        }

        print("\(passed) passed, \(failed) failed")
        if failed != 0 { Foundation.exit(1) }
    }
}
