import Foundation

private struct LogCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw LogCheckFailure(message) }
}

private func entries(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        guard let object = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
            throw LogCheckFailure("Invalid JSON log record")
        }
        return object
    }
}

@main
private struct DiagnosticLogChecks {
    static func main() async {
        var passed = 0, failed = 0
        func run(_ name: String, _ body: (URL) async throws -> Void) async {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-log-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                try await body(folder)
                passed += 1; print("PASS \(name)")
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        await run("Auto logs include environment and retain complete structured entries") { folder in
            let log = DiagnosticLog(directory: folder.appendingPathComponent("logs"))
            log.record(.applicationStarted)
            log.record(.streamConfigured, role: .host, state: .succeeded,
                       values: [.width: 3024, .height: 1964, .fps: 60, .targetBitrate: 100_000_000])
            try require(log.flush() == nil, "Initial log write failed")
            let output = folder.appendingPathComponent("export.txt")
            try await log.export(to: output)
            let lines = try entries(at: output)
            let started = lines.first { $0["event"] as? String == "applicationStarted" }
            let environment = started?["environment"] as? [String: Any]
            try require(environment?["macOS"] is String && environment?["architecture"] is String
                        && environment?["appVersion"] is String && environment?["appBuild"] is String,
                        "Environment metadata is incomplete")
            let configured = lines.first { $0["event"] as? String == "streamConfigured" }
            try require(configured?["role"] as? String == "host" && configured?["state"] as? String == "succeeded",
                        "Session direction or outcome disappeared")
            try require((configured?["values"] as? [String: Int])?["width"] == 3024, "Negotiated dimensions disappeared")
        }

        await run("Rotation is bounded and export orders retained records oldest to newest") { folder in
            let directory = folder.appendingPathComponent("logs")
            let log = DiagnosticLog(directory: directory, maximumFileBytes: 512, retainedFileCount: 3)
            for index in 0..<50 {
                log.record(.streamConfigured, values: [.eventCount: index])
                try require(log.flush() == nil, "Rotation write failed")
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            try require(files.count == 3, "Rotation retained too many or too few files")
            for file in files {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try require(size <= 512, "A rolling file exceeded its cap")
                _ = try entries(at: file)
            }
            let output = folder.appendingPathComponent("ordered.txt")
            try await log.export(to: output)
            let indexes = try entries(at: output).compactMap { ($0["values"] as? [String: Int])?["eventCount"] }
            try require(indexes == indexes.sorted() && indexes.last == 49 && indexes.first! > 0,
                        "Retained records are missing or out of order")
            let restarted = DiagnosticLog(directory: directory, maximumFileBytes: 512, retainedFileCount: 3)
            restarted.record(.applicationStopped)
            try require(restarted.flush() == nil, "Existing logs were not reusable after restart")
            try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3,
                        "Restart exceeded the retention cap")
        }

        await run("Concurrent events have bounded pending work and aggregate scroll counts exactly") { folder in
            let log = DiagnosticLog(directory: folder.appendingPathComponent("logs"), pendingLimit: 8, counterInterval: 60)
            DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
                log.record(.connectionStarted, role: .viewer)
                log.count(.scrollSent)
                log.count(.scrollReceived, amount: 2)
            }
            try require(log.flush() == nil, "Concurrent log writing failed")
            let output = folder.appendingPathComponent("concurrent.txt")
            try await log.export(to: output)
            let lines = try entries(at: output)
            let written = lines.filter { $0["event"] as? String == "connectionStarted" }.count
            let counters = lines.compactMap { $0["values"] as? [String: Int] }
            try require(written + counters.reduce(0, { $0 + ($1["entriesDropped"] ?? 0) }) == 2_000,
                        "Bounded queue did not account for dropped entries")
            try require(counters.reduce(0, { $0 + ($1["scrollSent"] ?? 0) }) == 2_000
                        && counters.reduce(0, { $0 + ($1["scrollReceived"] ?? 0) }) == 4_000,
                        "Concurrent aggregate input counts were lost or duplicated")
        }

        await run("Error logging excludes arbitrary domains, descriptions, paths and underlying payloads") { folder in
            let log = DiagnosticLog(directory: folder.appendingPathComponent("private-name-logs"))
            let secret = "PRIVATE-copy-file-192.168.1.123-PairingCode-987654"
            let error = NSError(domain: secret, code: 17, userInfo: [NSLocalizedDescriptionKey: secret,
                NSFilePathErrorKey: "/Users/private/" + secret,
                NSUnderlyingErrorKey: NSError(domain: secret, code: 999, userInfo: [:])])
            log.record(.clipboardFailed, role: .viewer, state: .failed, error: error)
            log.record(.captureFailed, error: NSError(domain: NSOSStatusErrorDomain, code: -12909))
            log.flush()
            let output = folder.appendingPathComponent("private-name-export.txt")
            try await log.export(to: output)
            let text = try String(contentsOf: output, encoding: .utf8)
            try require(!text.contains(secret) && !text.contains(folder.path) && !text.contains("/Users/private/")
                        && !text.contains("private-name-"), "Private error or path data entered the export")
            let errors = try entries(at: output).compactMap { $0["error"] as? [String: Any] }
            try require(errors.contains { $0["domain"] as? String == "other" && $0["code"] as? Int == 17 }
                        && errors.contains { $0["domain"] as? String == "osStatus" && $0["code"] as? Int == -12909 },
                        "Useful allowlisted error codes disappeared")
            let allowed = Set(["timestamp", "event", "role", "state", "values", "error", "environment"])
            for entry in try entries(at: output) {
                try require(Set(entry.keys).isSubset(of: allowed), "Unexpected arbitrary field entered a record")
            }
        }

        await run("Periodic counters persist without per-event writes and permissions are private") { folder in
            let directory = folder.appendingPathComponent("logs")
            let log = DiagnosticLog(directory: directory, counterInterval: 0.05)
            log.count(.scrollSuppressed, amount: 20)
            try await Task.sleep(for: .milliseconds(150))
            let file = directory.appendingPathComponent("quietdesk-current.jsonl")
            let records = try entries(at: file)
            try require(records.count == 1 && (records[0]["values"] as? [String: Int])?["scrollSuppressed"] == 20,
                        "Timer did not write one aggregate counter entry")
            let output = folder.appendingPathComponent("permissions.txt")
            try await log.export(to: output)
            for (url, expected) in [(directory, 0o700), (file, 0o600), (output, 0o600)] {
                let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                try require(permissions?.intValue == expected, "Log or export permissions are too broad")
            }
        }

        await run("Write failures report a safe error and recover without crashing the app") { folder in
            let directory = folder.appendingPathComponent("logs")
            try Data("occupied".utf8).write(to: directory)
            let log = DiagnosticLog(directory: directory)
            log.record(.connectionStarted)
            try require(log.flush() != nil, "Storage failure was hidden")
            do {
                try await log.export(to: folder.appendingPathComponent("failed.txt"))
                throw LogCheckFailure("Unreadable logs were exported as a success")
            } catch is DiagnosticLog.Failure {}
            try FileManager.default.removeItem(at: directory)
            log.record(.connectionReady)
            try require(log.flush() == nil, "Later writes did not recover")
            try await log.export(to: folder.appendingPathComponent("recovered.txt"))
        }

        await run("The first export recovers repaired storage without another runtime event") { folder in
            let directory = folder.appendingPathComponent("logs")
            try Data("occupied".utf8).write(to: directory)
            let log = DiagnosticLog(directory: directory)
            log.record(.applicationStarted)
            try require(log.flush() != nil, "Initial storage failure was hidden")
            try FileManager.default.removeItem(at: directory)
            let output = folder.appendingPathComponent("first-export-after-repair.txt")
            try await log.export(to: output)
            try require(log.flush() == nil, "The historical failure still blocks repaired storage")
            let exported = try entries(at: output)
            try require(exported.contains { $0["event"] as? String == "exportRequested" },
                        "Export did not probe repaired storage or retain the request event")
            try require(try entries(at: directory.appendingPathComponent("quietdesk-current.jsonl")).count == 1,
                        "Export recovery required or invented an external runtime event")
        }

        await run("Export rejects unsafe destinations and preserves existing source records") { folder in
            let directory = folder.appendingPathComponent("logs")
            let log = DiagnosticLog(directory: directory)
            log.record(.connectionReady)
            log.flush()
            let source = directory.appendingPathComponent("quietdesk-current.jsonl")
            let original = try Data(contentsOf: source)
            let link = folder.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let blocked = folder.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocked)
            for destination in [source, directory, link, blocked.appendingPathComponent("export.txt")] {
                do {
                    try await log.export(to: destination)
                    throw LogCheckFailure("An unsafe or unavailable destination was accepted")
                } catch is DiagnosticLog.Failure {}
            }
            let after = try Data(contentsOf: source)
            try require(after.starts(with: original), "Failed export changed existing source records")
            let appended = try entries(at: source).dropFirst()
            try require(appended.count == 1 && appended.allSatisfy { $0["event"] as? String == "exportRequested" },
                        "Failed export appended unexpected source data")
            try await log.export(to: folder.appendingPathComponent("valid.txt"))
        }

        await run("Unexpected log symlinks are never read, truncated or exported") { folder in
            let directory = folder.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let privateFile = folder.appendingPathComponent("private.txt")
            let original = Data("PRIVATE unrelated document".utf8)
            try original.write(to: privateFile)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("quietdesk-current.jsonl"), withDestinationURL: privateFile)
            let log = DiagnosticLog(directory: directory)
            log.record(.applicationStarted)
            try require(log.flush() != nil, "Unexpected symlink was treated as a log")
            do {
                try await log.export(to: folder.appendingPathComponent("export.txt"))
                throw LogCheckFailure("Unexpected symlink was exported")
            } catch is DiagnosticLog.Failure {}
            try require(try Data(contentsOf: privateFile) == original, "Unexpected symlink target was changed")
        }

        print("\(passed) diagnostic log checks passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
