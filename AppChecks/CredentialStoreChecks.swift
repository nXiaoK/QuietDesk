import Foundation
import Darwin
import QuietDeskCore

private struct CredentialCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CredentialCheckFailure(message) }
}

private func expectFailure(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch is DeskError { return }
    throw CredentialCheckFailure("Unsafe or invalid storage was accepted")
}

private func testKey(_ digit: Character = "A") throws -> PairingKey {
    try PairingKey(code: String(repeating: String(digit), count: 64))
}

private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func launchWorker(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    try process.run()
    return process
}

@main
private struct CredentialStoreChecks {
    static func main() throws {
        if CommandLine.arguments.count > 2 {
            let store = LocalCredentialStore(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            if CommandLine.arguments[1] == "--worker" {
                let worker = CommandLine.arguments[3]
                for index in 0..<20 {
                    try store.save(testKey(), account: "process.\(worker).\(index)")
                }
                return
            }
            if CommandLine.arguments[1] == "--write-failure" {
                var limit = rlimit()
                guard getrlimit(RLIMIT_FSIZE, &limit) == 0 else { exit(2) }
                limit.rlim_cur = 16
                guard setrlimit(RLIMIT_FSIZE, &limit) == 0 else { exit(2) }
                signal(SIGXFSZ, SIG_IGN)
                try expectFailure { try store.save(testKey("B")) }
                return
            }
        }

        var passed = 0, failed = 0
        func run(_ name: String, _ body: (URL) throws -> Void) {
            do {
                guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                    throw CredentialCheckFailure("Cannot resolve the temporary fixture directory")
                }
                let temporaryDirectory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                free(resolved)
                let folder = temporaryDirectory.appendingPathComponent("quietdesk-credentials-" + UUID().uuidString,
                                                                        isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                try body(folder)
                passed += 1; print("PASS \(name)")
            } catch {
                failed += 1; print("FAIL \(name): \(error)")
            }
        }

        run("Bundle-specific data folders preserve production paths") { _ in
            try require(AppDataLocation.folderName(bundleIdentifier: nil) == "QuietDesk", "Unbundled path changed")
            try require(AppDataLocation.folderName(bundleIdentifier: "local.quietdesk.app") == "QuietDesk", "Production path changed")
            try require(AppDataLocation.folderName(bundleIdentifier: "") == "QuietDesk", "Empty bundle path changed")
            try require(AppDataLocation.folderName(bundleIdentifier: "local.quietdesk.preview") == "QuietDesk-local.quietdesk.preview", "Preview is not isolated")
            try require(AppDataLocation.folderName(bundleIdentifier: "preview/a b") == "QuietDesk-preview_a_b", "Unsafe path characters survived")
        }

        run("Empty storage and absent removal preserve unrelated files") { folder in
            let marker = folder.appendingPathComponent("existing-metadata.json")
            let original = Data("unchanged metadata".utf8)
            try original.write(to: marker)
            let directory = folder.appendingPathComponent("Credentials", isDirectory: true)
            let store = LocalCredentialStore(directory: directory)
            try require(try store.load() == nil, "New storage invented a host key")
            try store.remove()
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pairing-codes.json").path),
                        "Absent removal created a credential document")
            try require(try Data(contentsOf: marker) == original, "Unrelated metadata changed")
        }

        run("Host and remote codes persist independently across store instances") { folder in
            let store = LocalCredentialStore(directory: folder)
            try store.save(testKey())
            try store.save(testKey("B"), account: "remote.device")
            try store.save(testKey("C"), account: "../literal-account")
            let reopened = LocalCredentialStore(directory: folder)
            try require(try reopened.load()?.code == testKey().code, "Host code did not persist")
            try require(try reopened.load(account: "remote.device")?.code == testKey("B").code,
                        "Remote code did not persist")
            try require(try reopened.load(account: "../literal-account")?.code == testKey("C").code,
                        "Account name was interpreted as a filesystem path")
            try reopened.remove(account: "remote.device")
            try require(try store.load(account: "remote.device") == nil, "Removal retained the remote code")
            try require(try store.load()?.code == testKey().code, "Remote removal lost the host code")
            try store.remove()
            try require(try reopened.load(account: "../literal-account") != nil, "Host removal lost another code")
        }

        run("Storage is explicitly plaintext JSON with private directory, document and lock permissions") { folder in
            let directory = folder.appendingPathComponent("Credentials", isDirectory: true)
            let store = LocalCredentialStore(directory: directory)
            try store.save(testKey())
            let file = directory.appendingPathComponent("pairing-codes.json")
            let data = try Data(contentsOf: file)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try require(json?["version"] as? Int == 1, "Document version is missing")
            try require((json?["codes"] as? [String: String])?["host"] == testKey().code,
                        "Storage format does not match the stated plaintext format")
            try require(try permissions(directory) == 0o700, "Credential directory is not 0700")
            try require(try permissions(file) == 0o600, "Credential document is not 0600")
            try require(try permissions(directory.appendingPathComponent(".lock")) == 0o600,
                        "Credential lock is not 0600")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try store.load()
            try require(try permissions(directory) == 0o700 && permissions(file) == 0o600,
                        "Existing storage permissions were not tightened")
        }

        run("Damaged JSON and invalid account values reject reads, saves and removals without replacement") { folder in
            let store = LocalCredentialStore(directory: folder)
            let file = folder.appendingPathComponent("pairing-codes.json")
            for invalid in [Data("broken JSON".utf8), Data("{\"version\":1,\"codes\":{\"other\":\"invalid\"}}".utf8)] {
                try invalid.write(to: file)
                try expectFailure { _ = try store.load() }
                try expectFailure { try store.save(testKey()) }
                try expectFailure { try store.remove(account: "other") }
                try require(try Data(contentsOf: file) == invalid, "Damaged storage was replaced")
            }
        }

        run("Unknown versions reject mutations and retain their exact original data") { folder in
            let file = folder.appendingPathComponent("pairing-codes.json")
            let data = try JSONSerialization.data(withJSONObject: ["version": 99, "codes": ["host": testKey().code]])
            try data.write(to: file)
            let store = LocalCredentialStore(directory: folder)
            try expectFailure { _ = try store.load() }
            try expectFailure { try store.save(testKey("B")) }
            try expectFailure { try store.remove() }
            try require(try Data(contentsOf: file) == data, "Unknown-version data was overwritten")
        }

        run("Credential and lock symlinks cannot read or modify their external targets") { folder in
            for name in ["pairing-codes.json", ".lock"] {
                let directory = folder.appendingPathComponent(name + "-store", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = folder.appendingPathComponent(name + "-target")
                let original = Data("external target".utf8)
                try original.write(to: target)
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: target)
                let store = LocalCredentialStore(directory: directory)
                try expectFailure { _ = try store.load() }
                try expectFailure { try store.save(testKey()) }
                try expectFailure { try store.remove() }
                try require(try Data(contentsOf: target) == original, "Symlink target changed")
            }
        }

        run("Symlink directory components and non-directory storage paths are rejected") { folder in
            let target = folder.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let link = folder.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            for directory in [link, link.appendingPathComponent("nested", isDirectory: true)] {
                try expectFailure { try LocalCredentialStore(directory: directory).save(testKey()) }
            }
            try require(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty,
                        "Directory symlink was followed")
            let occupied = folder.appendingPathComponent("file")
            try Data("original".utf8).write(to: occupied)
            try expectFailure { try LocalCredentialStore(directory: occupied).save(testKey()) }
        }

        run("Non-regular documents and locks fail promptly without blocking") { folder in
            for name in ["pairing-codes.json", ".lock"] {
                for kind in ["directory", "fifo"] {
                    let directory = folder.appendingPathComponent(name + "-" + kind, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let item = directory.appendingPathComponent(name)
                    if kind == "directory" {
                        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
                    } else {
                        try require(mkfifo(item.path, mode_t(0o600)) == 0, "Could not create FIFO fixture")
                    }
                    let store = LocalCredentialStore(directory: directory)
                    try expectFailure { _ = try store.load() }
                    try expectFailure { try store.save(testKey()) }
                }
            }
        }

        run("Hard-linked documents and locks are rejected without changing external files") { folder in
            for name in ["pairing-codes.json", ".lock"] {
                let directory = folder.appendingPathComponent(name + "-store", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = folder.appendingPathComponent(name + "-target")
                let original = Data("external hard link".utf8)
                try original.write(to: target)
                try FileManager.default.linkItem(at: target, to: directory.appendingPathComponent(name))
                try expectFailure { try LocalCredentialStore(directory: directory).save(testKey()) }
                try require(try Data(contentsOf: target) == original, "Hard-linked external file changed")
            }
        }

        run("Concurrent instances preserve all accounts") { folder in
            let failures = NSMutableArray()
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: 80) { index in
                do { try LocalCredentialStore(directory: folder).save(testKey(), account: "thread.\(index)") }
                catch { lock.lock(); failures.add(error); lock.unlock() }
            }
            try require(failures.count == 0, "A concurrent save failed: \(failures)")
            let store = LocalCredentialStore(directory: folder)
            for index in 0..<80 {
                try require(try store.load(account: "thread.\(index)")?.code == testKey().code,
                            "A concurrent instance lost another account")
            }
        }

        run("Concurrent processes preserve all accounts through atomic replacements") { folder in
            var processes: [Process] = []
            for worker in 0..<8 {
                processes.append(try launchWorker(["--worker", folder.path, String(worker)]))
            }
            for process in processes { process.waitUntilExit() }
            for process in processes {
                try require(process.terminationReason == .exit && process.terminationStatus == 0,
                            "A concurrent worker failed")
            }
            let store = LocalCredentialStore(directory: folder)
            for worker in 0..<8 {
                for index in 0..<20 {
                    try require(try store.load(account: "process.\(worker).\(index)")?.code == testKey().code,
                                "A concurrent process lost another account")
                }
            }
        }

        run("Partial write failure preserves the previous value and removes temporary files") { folder in
            let store = LocalCredentialStore(directory: folder)
            try store.save(testKey())
            let file = folder.appendingPathComponent("pairing-codes.json")
            let original = try Data(contentsOf: file)
            let process = try launchWorker(["--write-failure", folder.path])
            process.waitUntilExit()
            try require(process.terminationReason == .exit && process.terminationStatus == 0,
                        "Controlled write failure did not report failure")
            try require(try Data(contentsOf: file) == original && store.load()?.code == testKey().code,
                        "A failed save damaged the previous value")
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            try require(Set(files) == Set(["pairing-codes.json", ".lock"]), "A failed save leaked a temporary file")
        }

        run("Re-entering a code retains the selected duplicate record's identity and quality") { _ in
            let first = ConnectionRecord(address: "device.local", port: 5900, name: "First")
            let selected = ConnectionRecord(address: "device.local", port: 5900, name: "Selected",
                                            videoSettings: .highest)
            let records = [first, selected]
            let matched = ConnectionStore.matching(records, address: "DEVICE.local", port: 5900,
                                                   preferredID: selected.id)
            try require(matched?.id == selected.id && matched?.videoSettings == .highest,
                        "Re-entry selected a different duplicate or discarded its quality")
            try require(ConnectionStore.matching(records, address: "device.local", port: 5900)?.id == first.id,
                        "Matching without selection changed the previous first-match behavior")
        }

        run("Changing the selected route cannot reuse that record's identity") { _ in
            let old = ConnectionRecord(address: "old.local", port: 5900, name: "Old")
            let other = ConnectionRecord(address: "new.local", port: 5900, name: "Other")
            try require(ConnectionStore.matching([old], address: "new.local", port: 5900,
                                                  preferredID: old.id) == nil,
                        "An address change reused the old record")
            try require(ConnectionStore.matching([old], address: "old.local", port: 5901,
                                                  preferredID: old.id) == nil,
                        "A port change reused the old record")
            try require(ConnectionStore.matching([old, other], address: "new.local", port: 5900,
                                                  preferredID: old.id)?.id == other.id,
                        "A stale selection prevented matching the actual new route")
        }

        run("Legacy connection metadata retains identity without quality or secret fields") { _ in
            let id = UUID()
            let data = try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "address": "legacy.local",
                "port": 5900, "name": "Legacy", "lastConnected": 0]])
            let records = try JSONDecoder().decode([ConnectionRecord].self, from: data)
            try require(records.count == 1 && records[0].id == id && records[0].videoSettings == nil,
                        "Legacy metadata without quality no longer decodes")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as? [[String: Any]]
            try require(encoded?.first.map { Set($0.keys) } == Set(["id", "address", "port", "name", "lastConnected"]),
                        "Connection metadata gained secret or unexpected fields")
        }

        print("\(passed) credential and re-entry checks passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
