import Foundation
import QuietDeskCore

private struct HistoryCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw HistoryCheckFailure(message) }
}

@main
private struct TrafficHistoryChecks {
    static func main() {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: (URL) throws -> Void) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-traffic-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                try body(folder)
                passed += 1; print("PASS \(name)")
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Device identity and traffic survive reload, address changes and separate connections") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            let id = DeviceIdentity(id: UUID(), name: "Home Mac")
            for _ in 0..<2 {
                let meter = TrafficMeter()
                let session = TrafficSession(connectionID: meter.connectionID, onDelta: { store.record($0, delta: $1) })
                meter.onUpdate = session.receive
                meter.record(sentBytes: 15, receivedBytes: 100)
                try session.bind(id)
                session.receive(meter.snapshot())
            }
            store.record(DeviceIdentity(id: UUID(), name: id.name), delta: .init(sentBytes: 3))
            store.flush()
            let records = store.snapshot().records
            try require(records.count == 2, "Names were used to merge different devices")
            try require(records.first(where: { $0.id == id.id })?.totals == TrafficTotals(sentBytes: 30, receivedBytes: 200),
                        "Connections for one device were not combined exactly once")
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(store.localDeviceID != nil && reloaded.localDeviceID == store.localDeviceID, "Local identity changed across reload")
            try require(reloaded.snapshot().records == records && reloaded.snapshot().error == nil, "Persisted totals changed after reload")
        }

        run("Checkpoint saves active and late-completing traffic without ending the session") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 0.05)
            let identity = DeviceIdentity(id: UUID(), name: "Remote")
            var owner: TrafficMeter? = TrafficMeter()
            let session = TrafficSession(connectionID: owner!.connectionID, onDelta: { store.record($0, delta: $1) })
            owner!.onUpdate = session.receive
            try session.bind(identity)
            owner!.record(receivedBytes: 7)
            let completion = { [meter = owner!] in meter.record(sentBytes: 11) }
            owner = nil
            completion()
            Thread.sleep(forTimeInterval: 0.2)
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(reloaded.snapshot().records.first?.totals == TrafficTotals(sentBytes: 11, receivedBytes: 7),
                        "Active checkpoint or late send completion was not saved")
        }

        run("Malformed and future history files are preserved instead of being overwritten") { folder in
            for (index, bytes) in [Data("broken-json".utf8), Data("{\"version\":99,\"records\":[]}".utf8)].enumerated() {
                let directory = folder.appendingPathComponent("case-\(index)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("traffic-history.json")
                try bytes.write(to: file)
                let store = TrafficHistoryStore(directory: directory, checkpointInterval: 60)
                store.record(DeviceIdentity(id: UUID(), name: "new"), delta: .init(receivedBytes: 9))
                store.flush()
                try require(store.snapshot().error != nil, "Unreadable history was silently accepted")
                try require(try Data(contentsOf: file) == bytes, "Unreadable history was destroyed")
                try require(store.snapshot().records.first?.receivedBytes == 9, "New in-memory traffic disappeared after load failure")
            }
        }

        run("Write errors retain pending counters and a later successful flush saves them once") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            let file = folder.appendingPathComponent("traffic-history.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            store.record(DeviceIdentity(id: UUID(), name: "Mac"), delta: .init(sentBytes: 15, receivedBytes: 25))
            store.flush()
            try require(store.snapshot().error != nil && store.snapshot().records.first?.sentBytes == 15,
                        "A write failure lost counters or hid the error")
            try FileManager.default.removeItem(at: file)
            store.flush()
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(store.snapshot().error == nil && reloaded.snapshot().records.first?.totals == TrafficTotals(sentBytes: 15, receivedBytes: 25),
                        "A retry duplicated or lost pending counters")
        }

        run("Protected unreadable history publishes a traffic change only once across checkpoints") { folder in
            let file = folder.appendingPathComponent("traffic-history.json")
            let bytes = Data("unreadable-history".utf8)
            try bytes.write(to: file)
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 0.05)
            let initial = DispatchSemaphore(value: 0), updated = DispatchSemaphore(value: 0)
            var updates = 0
            store.observe { records, _ in
                if records.isEmpty { initial.signal() }
                else { updates += 1; updated.signal() }
            }
            try require(initial.wait(timeout: .now() + 3) == .success, "Initial history was not published")
            store.record(DeviceIdentity(id: UUID(), name: "new"), delta: .init(receivedBytes: 9))
            try require(updated.wait(timeout: .now() + 3) == .success, "New in-memory traffic was not published")
            try require(updated.wait(timeout: .now() + 0.2) == .timedOut, "Unchanged protected history was republished")
            let snapshot = store.snapshot()
            try require(updates == 1 && snapshot.records.first?.receivedBytes == 9 && snapshot.error != nil,
                        "Protected history changed its notification or retained state")
            try require(try Data(contentsOf: file) == bytes, "Protected history was overwritten")
        }

        run("Checkpoint write failures and recovery each publish their changed error state once") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 0.05)
            let file = folder.appendingPathComponent("traffic-history.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let updated = DispatchSemaphore(value: 0)
            var errors: [String?] = []
            store.observe { _, error in errors.append(error); updated.signal() }
            try require(updated.wait(timeout: .now() + 3) == .success, "Initial history was not published")
            store.record(DeviceIdentity(id: UUID(), name: "Mac"), delta: .init(sentBytes: 15))
            try require(updated.wait(timeout: .now() + 3) == .success, "Write failure was not published")
            try require(store.snapshot().error != nil && errors.count == 2 && errors[0] == nil && errors[1] != nil,
                        "First write failure was hidden")
            try require(updated.wait(timeout: .now() + 0.2) == .timedOut, "Unchanged write failure was republished")
            try FileManager.default.removeItem(at: file)
            try require(updated.wait(timeout: .now() + 3) == .success, "Write recovery was not published")
            try require(store.snapshot().error == nil && errors.count == 3 && errors[2] == nil,
                        "Write recovery left a stale error")
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(reloaded.snapshot().records.first?.sentBytes == 15, "Automatic write retry lost pending counters")
        }

        run("Counting errors remain immediately observable between checkpoints") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            let updated = DispatchSemaphore(value: 0)
            store.observe { _, _ in updated.signal() }
            try require(updated.wait(timeout: .now() + 3) == .success, "Initial history was not published")
            store.reportCountingError("counting failed")
            try require(updated.wait(timeout: .now() + 3) == .success, "Reported counting error waited for a checkpoint")
            try require(store.snapshot().error == "counting failed", "Reported counting error disappeared")
            let identity = DeviceIdentity(id: UUID(), name: "Mac")
            store.record(identity, delta: .init(sentBytes: UInt64.max))
            store.record(identity, delta: .init(sentBytes: 1))
            try require(updated.wait(timeout: .now() + 3) == .success, "Overflow error waited for a checkpoint")
            let snapshot = store.snapshot()
            try require(snapshot.error != nil && snapshot.error != "counting failed" && snapshot.records.first?.sentBytes == UInt64.max,
                        "Overflow lost counters or its changed error")
        }

        run("A damaged local identity is preserved and disables identity exchange") { folder in
            let file = folder.appendingPathComponent("device-identity.json")
            let bytes = Data("damaged identity".utf8)
            try bytes.write(to: file)
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(store.localDeviceID == nil && store.snapshot().error != nil, "A damaged identity was silently replaced")
            try require(try Data(contentsOf: file) == bytes, "The original identity file was overwritten")
        }

        run("History persists safe single-line labels without changing device identity") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            let id = UUID()
            store.record(DeviceIdentity(id: id, name: "\n\t "), delta: .init(sentBytes: 1))
            store.flush()
            try require(store.snapshot().records.first?.name == "未命名 Mac", "Empty name was stored as a blank label")
            store.record(DeviceIdentity(id: id, name: " Mac\n\u{0} 👨‍👩‍👧‍👦 "), delta: .init(receivedBytes: 2))
            store.flush()
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(reloaded.snapshot().records.first?.name == "Mac 👨‍👩‍👧‍👦" && reloaded.snapshot().records.first?.id == id,
                        "Label normalization changed identity or was not persisted")
        }

        run("An unreadable parent directory cannot be mistaken for missing history and overwritten after recovery") { folder in
            let directory = folder.appendingPathComponent("private")
            let original = TrafficHistoryStore(directory: directory, checkpointInterval: 60)
            original.record(DeviceIdentity(id: UUID(), name: "original"), delta: .init(sentBytes: 123))
            original.flush()
            let historyFile = directory.appendingPathComponent("traffic-history.json")
            let identityFile = directory.appendingPathComponent("device-identity.json")
            let historyBytes = try Data(contentsOf: historyFile)
            let identityBytes = try Data(contentsOf: identityFile)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            let inaccessible = TrafficHistoryStore(directory: directory, checkpointInterval: 60)
            try require(inaccessible.localDeviceID == nil && inaccessible.snapshot().error != nil,
                        "An unreadable directory did not report protected loading failure")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            inaccessible.record(DeviceIdentity(id: UUID(), name: "pending"), delta: .init(receivedBytes: 9))
            inaccessible.flush()
            try require(try Data(contentsOf: historyFile) == historyBytes, "Restored directory access overwrote existing history")
            try require(try Data(contentsOf: identityFile) == identityBytes, "Restored directory access replaced device identity")
        }

        run("Closing snapshot and flush wait for an in-progress delta to enter persistence") { folder in
            let store = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            let meter = TrafficMeter()
            let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
            let flushed = DispatchSemaphore(value: 0), counted = DispatchSemaphore(value: 0)
            defer { proceed.signal() }
            let session = TrafficSession(connectionID: meter.connectionID, onDelta: { identity, delta in
                if delta.sentBytes == 10 { entered.signal(); proceed.wait() }
                store.record(identity, delta: delta)
            })
            try session.bind(DeviceIdentity(id: UUID(), name: "Mac"))
            meter.onUpdate = session.receive
            DispatchQueue.global().async { meter.record(sentBytes: 10); counted.signal() }
            try require(entered.wait(timeout: .now() + 3) == .success, "No in-progress delta")
            DispatchQueue.global().async {
                session.receive(meter.snapshot())
                store.flush()
                flushed.signal()
            }
            let escaped = flushed.wait(timeout: .now() + 0.05) == .success
            proceed.signal()
            try require(counted.wait(timeout: .now() + 3) == .success, "Pending delta did not finish")
            if !escaped { try require(flushed.wait(timeout: .now() + 3) == .success, "Closing flush did not finish") }
            try require(!escaped, "Flush passed a delta before it was queued for storage")
            let reloaded = TrafficHistoryStore(directory: folder, checkpointInterval: 60)
            try require(reloaded.snapshot().records.first?.sentBytes == 10, "Closing lost the final in-progress delta")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
