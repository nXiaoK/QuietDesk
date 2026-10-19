import AppKit
import CryptoKit
import Darwin
import Foundation
import QuietDeskCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message) }
}

private func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure("Invalid update was accepted")
}

private func command(_ name: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: name); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    try require(process.terminationStatus == 0, "Fixture command failed: \(name)")
}

private func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}

private func save<T: Encodable>(_ value: T, _ url: URL) throws {
    try JSONEncoder().encode(value).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private struct PreparedRecord: Codable {
    let applicationURL: URL
    let stagingDirectory: URL
    let expectation: UpdateInstaller.Expectation
}

private final class ProgressRecord: @unchecked Sendable {
    let lock = NSLock()
    var bytes: Int64 = 0
    var unknownLength = false
    var verifying = false
    func progress(_ received: Int64, _ total: Int64?) { lock.lock(); bytes = received; unknownLength = total == nil; lock.unlock() }
    func verify() { lock.lock(); verifying = true; lock.unlock() }
}

@main
private struct UpdateInstallerChecks {
    static let bundleID = "local.quietdesk.checks.updater"

    static func main() async {
        // Keep progress visible in CI logs if a later check stops the process.
        setvbuf(stdout, nil, _IOLBF, 0)
        let fixtureCache = (Bundle.main.object(forInfoDictionaryKey: "UpdateCheckCache") as? String).map { URL(fileURLWithPath: $0) }
        if CommandLine.arguments.contains("--quietdesk-install-update-v1"),
           Bundle.main.object(forInfoDictionaryKey: "UpdateCheckDelayReadiness") as? Bool == true,
           let marker = Bundle.main.object(forInfoDictionaryKey: "UpdateCheckMarker") as? String {
            try? Data().write(to: URL(fileURLWithPath: marker + "-installer-started"))
            usleep(1_000_000)
        }
        if UpdateInstaller.runInstallerIfRequested(cachesURL: fixtureCache) { return }
        if CommandLine.arguments.count >= 2, ["--validate-app", "--validate-archive"].contains(CommandLine.arguments[1]) {
            do { try validateArtifact() }
            catch { fputs("FAIL update artifact validation: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--fixture-parent") || CommandLine.arguments.contains("--fixture-parent-abort") ||
            CommandLine.arguments.contains("--fixture-parent-abort-before-ready") {
            do {
                let recordURL = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateCheckPrepared") as! String)
                let record = try JSONDecoder().decode(PreparedRecord.self, from: Data(contentsOf: recordURL))
                let installer = UpdateInstaller(cachesURL: fixtureCache)
                let prepared = UpdateInstaller.PreparedUpdate(applicationURL: record.applicationURL,
                    stagingDirectory: record.stagingDirectory, expectation: record.expectation)
                if CommandLine.arguments.contains("--fixture-parent-abort-before-ready") {
                    let launch = Task { try await installer.launchInstaller(for: prepared) }
                    let started = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateCheckMarker") as! String + "-installer-started")
                    let deadline = Date().addingTimeInterval(5)
                    while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try require(FileManager.default.fileExists(atPath: started.path), "Delayed helper did not start")
                    installer.abortPendingInstallation()
                    do { try await launch.value; throw CheckFailure("Aborted pending helper was accepted") }
                    catch is CancellationError { }
                    _exit(0)
                }
                try await installer.launchInstaller(for: prepared)
                if CommandLine.arguments.contains("--fixture-parent-abort") { installer.abortPendingInstallation() }
                _exit(0)
            } catch { fputs("Synthetic parent failed: \(error)\n", stderr); _exit(1) }
        }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2",
           let marker = Bundle.main.object(forInfoDictionaryKey: "UpdateCheckMarker") as? String {
            try? Data("synthetic-v2".utf8).write(to: URL(fileURLWithPath: marker))
            let result = UpdateInstaller(cachesURL: fixtureCache).consumeResult()
            try? Data((result?.message ?? "nil").utf8).write(to: URL(fileURLWithPath: marker + "-result"))
            return
        }
        do { try await runChecks() }
        catch { fputs("FAIL Update installer checks: \(error)\n", stderr); exit(1) }
    }

    static func validateArtifact() throws {
        let arguments = CommandLine.arguments
        let archiveMode = arguments[1] == "--validate-archive"
        guard arguments.count == (archiveMode ? 4 : 3) else { throw CheckFailure("Usage: --validate-app <app> or --validate-archive <zip> <app>") }
        let reference = URL(fileURLWithPath: arguments[archiveMode ? 3 : 2])
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: reference.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        let expectation = UpdateInstaller.Expectation(bundleIdentifier: info["CFBundleIdentifier"] as! String,
            version: info["CFBundleShortVersionString"] as! String, build: Int(info["CFBundleVersion"] as! String)!,
            minimumSystemVersion: info["LSMinimumSystemVersion"] as! String,
            archiveURL: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/download/validation/QuietDesk.zip")!,
            archiveSize: 1, sha256: String(repeating: "0", count: 64))
        if archiveMode {
            let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("artifact-\(UUID().uuidString)")
            try directory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = URL(fileURLWithPath: arguments[2])
            try UpdateInstaller.validateZIP(archive)
            try command("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try require(contents == ["QuietDesk.app"], "Release ZIP must extract to exactly QuietDesk.app")
            try UpdateInstaller.validateApplication(root.appendingPathComponent("QuietDesk.app"), expectation: expectation, currentTeamIdentifier: nil)
            print("PASS real release ZIP structure, ditto extraction, application metadata, native architecture and strict all-architecture signature (read-only artifact verification)")
        } else {
            try UpdateInstaller.validateApplication(reference, expectation: expectation, currentTeamIdentifier: nil)
            print("PASS application metadata, native architecture and strict all-architecture signature (read-only artifact verification)")
        }
    }

    static func runChecks() async throws {
        print("Update checks use synthetic ad-hoc apps and temporary Applications under work/update-checks; no production app, permissions or user data are touched.")
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: environment["QUIETDESK_UPDATE_CHECK_ROOT"]!).resolvingSymlinksInPath()
        let base = URL(string: environment["QUIETDESK_UPDATE_CHECK_URL"]!)!
        let fixtures = root.appendingPathComponent("fixtures-\(UUID().uuidString)")
        try directory(fixtures)
        defer { if environment["QUIETDESK_KEEP_UPDATE_FIXTURE"] == nil { try? FileManager.default.removeItem(at: fixtures) } }
        let executable = Bundle.main.executableURL!
        let cache = fixtures.appendingPathComponent("Cache")
        try directory(cache)
        let application = fixtures.appendingPathComponent("Applications/QuietDesk.app")
        let marker = fixtures.appendingPathComponent("v2-started")
        let preparedRecord = fixtures.appendingPathComponent("prepared.json")

        func makeApp(_ url: URL, version: String = "0.0.2", build: Int = 2, identifier: String = bundleID,
                     delayReadiness: Bool = false) throws {
            try directory(url.appendingPathComponent("Contents/MacOS"))
            let binary = url.appendingPathComponent("Contents/MacOS/UpdateInstallerChecks")
            try FileManager.default.copyItem(at: executable, to: binary)
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "QuietDesk Update Checks (Synthetic State)",
                "CFBundleExecutable": "UpdateInstallerChecks", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
                "CFBundleVersion": String(build), "LSMinimumSystemVersion": "14.0", "LSUIElement": true,
                "UpdateCheckCache": cache.path, "UpdateCheckMarker": marker.path, "UpdateCheckPrepared": preparedRecord.path,
                "UpdateCheckDelayReadiness": delayReadiness]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            try command("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        }
        try makeApp(application, version: "0.0.1", build: 1)
        let source = fixtures.appendingPathComponent("source/QuietDesk.app")
        try makeApp(source)
        let metadataFile = source.appendingPathComponent("Contents/Info.plist")
        let metadata = Data("synthetic metadata".utf8)
        _ = metadata.withUnsafeBytes { setxattr(metadataFile.path, "com.quietdesk.checks.metadata", $0.baseAddress, $0.count, 0, 0) }
        let archive = root.appendingPathComponent("archive.zip")
        try? FileManager.default.removeItem(at: archive)
        try command("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path])
        let archiveData = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        func expectation(size: Int64? = nil, sha: String? = nil, path: String = "archive.zip") -> UpdateInstaller.Expectation {
            .init(bundleIdentifier: bundleID, version: "0.0.2", build: 2, minimumSystemVersion: "14.0",
                  archiveURL: base.appendingPathComponent(path), archiveSize: size ?? Int64(archiveData.count), sha256: sha ?? digest)
        }

        let key = Curve25519.Signing.PrivateKey()
        let manifest = UpdateManifest(bundleIdentifier: bundleID, version: "0.0.2", build: 2, minimumSystemVersion: "14.0",
            publishedAt: "2026-10-19T00:00:00Z", revision: "", releaseNotesURL: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/tag/v0.0.2")!,
            archive: .init(url: expectation().archiveURL, size: Int64(archiveData.count), sha256: digest))
        let payload = try JSONEncoder().encode(manifest)
        let signature = try key.signature(for: UpdateManifestVerifier.signingPrefix + payload)
        let envelope = SignedUpdateEnvelope(keyID: "temporary", payload: payload.base64EncodedString(), signature: signature.base64EncodedString())
        try save(envelope, root.appendingPathComponent("manifest.json"))
        let network = URLSession(configuration: .ephemeral)
        let (feed, _) = try await network.data(from: base.appendingPathComponent("manifest.json"))
        network.invalidateAndCancel()
        let keys = [UpdatePublicKey(id: "temporary", key: key.publicKey.rawRepresentation.base64EncodedString())]
        guard case .supported = try UpdateManifestVerifier.verify(feed, publicKeys: keys, bundleIdentifier: bundleID, allowLoopbackForTesting: true) else {
            throw CheckFailure("Synthetic signed feed was not accepted")
        }
        let badEnvelope = SignedUpdateEnvelope(keyID: envelope.keyID, payload: envelope.payload, signature: Data(repeating: 0, count: 64).base64EncodedString())
        try rejects { _ = try UpdateManifestVerifier.verify(JSONEncoder().encode(badEnvelope), publicKeys: keys,
            bundleIdentifier: bundleID, allowLoopbackForTesting: true) }
        print("PASS signed loopback feed and invalid signature rejection")

        let installer = UpdateInstaller(applicationURL: application, cachesURL: cache,
            replacementDirectory: fixtures.appendingPathComponent("Staging"))
        let progress = ProgressRecord()
        let prepared = try await installer.downloadAndStage(expectation: expectation(),
            progress: { progress.progress($0, $1) }, onVerifying: { progress.verify() })
        try require(progress.bytes == Int64(archiveData.count) && progress.verifying, "Download progress did not report actual bytes and verification")
        let top = try FileManager.default.contentsOfDirectory(atPath: prepared.stagingDirectory.path)
        try require(top == ["QuietDesk.app"], "ditto did not merge __MACOSX metadata into one top-level app")
        print("PASS actual ditto release ZIP, SHA-256, real progress, staging, architecture and ad-hoc signature")

        for (name, request) in [("SHA mismatch", expectation(sha: String(repeating: "0", count: 64))),
                                ("size mismatch", expectation(size: Int64(archiveData.count + 1))),
                                ("oversized response", expectation(size: Int64(archiveData.count - 1))),
                                ("oversized unknown-length stream", expectation(size: Int64(archiveData.count - 1), path: "unknown/archive.zip")),
                                ("unsafe download redirect", expectation(path: "insecure-redirect"))] {
            do {
                let unexpected = try await installer.downloadAndStage(expectation: request, progress: { _, _ in })
                installer.discard(unexpected)
                throw CheckFailure("\(name) was accepted")
            } catch is CheckFailure { throw CheckFailure("\(name) was accepted") }
            catch { print("PASS \(name)") }
        }
        let unknownProgress = ProgressRecord()
        let unknownLength = try await installer.downloadAndStage(expectation: expectation(path: "unknown/archive.zip"),
            progress: { unknownProgress.progress($0, $1) })
        try require(unknownProgress.bytes == Int64(archiveData.count) && unknownProgress.unknownLength,
                    "Unknown transfer length was estimated instead of remaining indeterminate")
        installer.discard(unknownLength)
        print("PASS unknown-length progress remains indeterminate and hashes actual bytes")

        let wrongID = UpdateInstaller.Expectation(bundleIdentifier: "local.quietdesk.checks.wrong", version: "0.0.2", build: 2,
            minimumSystemVersion: "14.0", archiveURL: expectation().archiveURL, archiveSize: Int64(archiveData.count), sha256: digest)
        try rejects { try UpdateInstaller.validateApplication(source, expectation: wrongID, currentTeamIdentifier: nil) }
        let wrongVersion = UpdateInstaller.Expectation(bundleIdentifier: bundleID, version: "0.0.3", build: 3,
            minimumSystemVersion: "14.0", archiveURL: expectation().archiveURL, archiveSize: Int64(archiveData.count), sha256: digest)
        try rejects { try UpdateInstaller.validateApplication(source, expectation: wrongVersion, currentTeamIdentifier: nil) }
        let damaged = fixtures.appendingPathComponent("damaged/QuietDesk.app")
        try directory(damaged.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: damaged)
        try Data("tampered".utf8).write(to: damaged.appendingPathComponent("Contents/extra"))
        try rejects { try UpdateInstaller.validateApplication(damaged, expectation: expectation(), currentTeamIdentifier: nil) }
        let linked = fixtures.appendingPathComponent("linked/QuietDesk.app")
        try directory(linked.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: linked)
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        try rejects { try UpdateInstaller.validateApplication(linked, expectation: expectation(), currentTeamIdentifier: nil) }
        let hardlinked = fixtures.appendingPathComponent("hardlinked/QuietDesk.app")
        try directory(hardlinked.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: hardlinked)
        try FileManager.default.linkItem(at: hardlinked.appendingPathComponent("Contents/Info.plist"),
                                        to: hardlinked.appendingPathComponent("Contents/Info-copy.plist"))
        try rejects { try UpdateInstaller.validateApplication(hardlinked, expectation: expectation(), currentTeamIdentifier: nil) }
        print("PASS bundle/version mismatch, damaged code signature, symbolic and hard links")

        let twoApps = fixtures.appendingPathComponent("two")
        try directory(twoApps)
        try FileManager.default.copyItem(at: source, to: twoApps.appendingPathComponent("QuietDesk.app"))
        try FileManager.default.copyItem(at: source, to: twoApps.appendingPathComponent("Other.app"))
        let twoZIP = root.appendingPathComponent("two.zip")
        try command("/usr/bin/ditto", ["-c", "-k", twoApps.path, twoZIP.path])
        try rejects { try UpdateInstaller.validateZIP(twoZIP) }
        let linkZIP = root.appendingPathComponent("link.zip")
        try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", linked.path, linkZIP.path])
        try rejects { try UpdateInstaller.validateZIP(linkZIP) }
        try command("/usr/bin/python3", ["-c", "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('QuietDesk.app/../../escaped','unsafe'); z.close()", root.appendingPathComponent("traversal.zip").path])
        try rejects { try UpdateInstaller.validateZIP(root.appendingPathComponent("traversal.zip")) }
        print("PASS two apps, ZIP symlink and pre-extraction path traversal rejection")

        let malformedZIP = root.appendingPathComponent("malformed.zip")
        let malformedScript = """
        import struct, sys, zipfile, zlib
        mode, path = sys.argv[1:]
        with zipfile.ZipFile(path, 'w') as z:
            if mode == 'collision':
                z.writestr('QuietDesk.app/File', 'first')
                z.writestr('QuietDesk.app/file', 'second')
            elif mode == 'file-parent':
                z.writestr('QuietDesk.app/parent', 'first')
                z.writestr('QuietDesk.app/parent/child', 'second')
            else:
                z.writestr('QuietDesk.app/file', 'first')
                z.writestr('QuietDesk.app/other', 'second')
        data = bytearray(open(path, 'rb').read())
        central = data.index(b'PK\\x01\\x02')
        if mode == 'method': struct.pack_into('<H', data, 8, 8)
        if mode == 'flags': struct.pack_into('<H', data, 6, 1)
        if mode == 'size': struct.pack_into('<I', data, 22, 99)
        if mode == 'overlap':
            second = data.index(b'PK\\x01\\x02', central + 4)
            payload_start = 30 + struct.unpack_from('<H', data, 26)[0]
            size = central - payload_start
            crc = zlib.crc32(data[payload_start:central])
            struct.pack_into('<III', data, 14, crc, size, size)
            struct.pack_into('<III', data, central + 16, crc, size, size)
        open(path, 'wb').write(data)
        """
        for name in ["collision", "file-parent", "method", "flags", "size", "overlap"] {
            try command("/usr/bin/python3", ["-c", malformedScript, name, malformedZIP.path])
            try rejects { try UpdateInstaller.validateZIP(malformedZIP) }
        }
        print("PASS case-colliding ZIP paths, file-as-parent paths, inconsistent local headers and overlapping entries")

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: application.deletingLastPathComponent().path)
        try require(installer.installationAvailability() != nil, "Unwritable installation directory accepted")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: application.deletingLastPathComponent().path)
        let translocated = UpdateInstaller(applicationURL: fixtures.appendingPathComponent("AppTranslocation/QuietDesk.app"), cachesURL: cache)
        try require(translocated.installationAvailability() != nil, "App Translocation accepted")
        try require(UpdateInstallationPolicy.availability(hasHostConnection: false, applicationURL: application,
            isReadOnlyVolume: true, parentDirectoryWritable: true) == .manualRequired(.readOnlyVolume), "Read-only volume policy accepted")
        print("PASS unwritable directory, Translocation and synthetic read-only-volume policy")

        let slowRequest = expectation(path: "slow/archive.zip")
        let slow = Task { try await installer.downloadAndStage(expectation: slowRequest, progress: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await installer.downloadAndStage(expectation: expectation(), progress: { _, _ in })
            throw CheckFailure("Concurrent download was accepted")
        } catch UpdateInstaller.Failure.busy { }
        installer.cancel()
        do { _ = try await slow.value; throw CheckFailure("Cancelled download completed") }
        catch is CancellationError { }
        let taskCancelled = Task { try await installer.downloadAndStage(expectation: slowRequest, progress: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(100))
        taskCancelled.cancel()
        do { _ = try await taskCancelled.value; throw CheckFailure("Swift task cancellation was ignored") }
        catch is CancellationError { }
        print("PASS mid-download cancellation and concurrent-trigger exclusion")

        let updates = cache.appendingPathComponent("Updates")
        let planURL = updates.appendingPathComponent("install-plan.json")
        func plan(parent: Int32, staging: URL = prepared.stagingDirectory) -> UpdateInstaller.InstallPlan {
            .init(parentPID: parent, applicationURL: application, stagedApplicationURL: staging.appendingPathComponent("QuietDesk.app"),
                  stagingDirectory: staging, backupURL: application.deletingLastPathComponent().appendingPathComponent(".QuietDesk-update-backup-check.app"),
                  resultURL: updates.appendingPathComponent("install-result.json"), readyURL: updates.appendingPathComponent("installer-check.ready"),
                  acknowledgementURL: updates.appendingPathComponent("installer-check.ack"), expectation: expectation(), currentTeamIdentifier: nil)
        }
        try rejects { try UpdateInstaller.performInstallation(plan(parent: getpid()), planURL: planURL, waitTimeout: 0.1, restartTimeout: 0) }
        try require(Bundle(url: application)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "1", "Timeout replaced a running parent")
        print("PASS parent-exit timeout leaves current app intact")

        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try sleeper.run(); sleeper.waitUntilExit()
        let exitedPID = sleeper.processIdentifier
        var renameCount = 0
        try rejects {
            try UpdateInstaller.performInstallation(plan(parent: exitedPID), planURL: planURL, waitTimeout: 0.1, restartTimeout: 0,
                renameItem: { from, to in
                    renameCount += 1
                    if renameCount == 2 { throw CheckFailure("Injected second rename failure") }
                    try require(rename(from.path, to.path) == 0, "Test rename failed")
                }, reopen: { _ in })
        }
        try require(renameCount == 3 && FileManager.default.fileExists(atPath: application.path) &&
            Bundle(url: application)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "1", "Second-rename failure did not restore original")
        print("PASS second-rename failure rolls back complete original app")

        renameCount = 0
        var rollbackReopenCount = 0
        try rejects {
            try UpdateInstaller.performInstallation(plan(parent: exitedPID), planURL: planURL, waitTimeout: 0.1, restartTimeout: 0,
                renameItem: { from, to in
                    renameCount += 1
                    try require(rename(from.path, to.path) == 0, "Test rename failed")
                    if renameCount == 2 { try Data("changed after replacement".utf8).write(to: to.appendingPathComponent("Contents/injected")) }
                }, reopen: { _ in rollbackReopenCount += 1 })
        }
        try require(renameCount == 4 && rollbackReopenCount == 0 &&
            FileManager.default.fileExists(atPath: application.path) &&
            !FileManager.default.fileExists(atPath: plan(parent: exitedPID).backupURL.path),
            "Post-replacement signature failure did not restore original before the entry publishes its result")
        try FileManager.default.removeItem(at: prepared.applicationURL.appendingPathComponent("Contents/injected"))
        print("PASS installed-package signature failure restores original before failure publication and reopen")

        for failReopen in [true, false] {
            let staged = try await installer.downloadAndStage(expectation: expectation(), progress: { _, _ in })
            let trial = plan(parent: exitedPID, staging: staged.stagingDirectory)
            try save(trial, planURL)
            try UpdateInstaller.performInstallation(trial, planURL: planURL, waitTimeout: 0.1, restartTimeout: 0,
                reopen: { _ in if failReopen { throw CheckFailure("Injected open failure") } })
            let result = try JSONDecoder().decode(UpdateInstaller.InstallationResult.self, from: Data(contentsOf: trial.resultURL))
            try require(result.succeeded && !result.restartObserved && FileManager.default.fileExists(atPath: trial.backupURL.path),
                        "Unobserved/failed restart discarded original backup")
            let consumed = installer.consumeResult()
            try require(consumed?.succeeded == true && installer.consumeResult() == nil,
                        "Installed result was not consumed exactly once")
            try require(!FileManager.default.fileExists(atPath: trial.backupURL.path) &&
                        !FileManager.default.fileExists(atPath: trial.stagingDirectory.path), "Startup did not clean acknowledged backup and staging")
            try? FileManager.default.removeItem(at: trial.acknowledgementURL)
            try FileManager.default.removeItem(at: application)
            try makeApp(application, version: "0.0.1", build: 1)
        }
        print("PASS failed open and unobserved restart preserve backup until one-time startup consumption")

        try save(plan(parent: getpid()), planURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: planURL.path)
        // Child entry reads this file using O_NOFOLLOW/owner/mode validation; invoke it
        // with a helper process to ensure an unsafe plan is rejected before readiness.
        let unsafe = Process(); unsafe.executableURL = application.appendingPathComponent("Contents/MacOS/UpdateInstallerChecks")
        unsafe.arguments = ["--quietdesk-install-update-v1", planURL.path]
        try unsafe.run(); unsafe.waitUntilExit()
        try require(!FileManager.default.fileExists(atPath: plan(parent: exitedPID).readyURL.path), "Unsafe plan reached readiness")
        try FileManager.default.removeItem(at: planURL)
        print("PASS unsafe plan permissions rejected by real installation entry")

        try save(PreparedRecord(applicationURL: prepared.applicationURL, stagingDirectory: prepared.stagingDirectory,
                                expectation: prepared.expectation), preparedRecord)
        let delayedApplication = fixtures.appendingPathComponent("DelayedApplications/QuietDesk.app")
        try makeApp(delayedApplication, version: "0.0.1", build: 1, delayReadiness: true)
        let earlyAbort = Process(); earlyAbort.executableURL = delayedApplication.appendingPathComponent("Contents/MacOS/UpdateInstallerChecks")
        earlyAbort.arguments = ["--fixture-parent-abort-before-ready"]
        try earlyAbort.run(); earlyAbort.waitUntilExit()
        try require(earlyAbort.terminationStatus == 0 && !FileManager.default.fileExists(atPath: planURL.path),
                    "Shutdown before readiness left a detached installer")
        try await Task.sleep(for: .milliseconds(1100))
        let delayedInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: delayedApplication.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        try require(delayedInfo["CFBundleVersion"] as? String == "1" &&
                    FileManager.default.fileExists(atPath: prepared.applicationURL.path), "Early aborted helper replaced the old app after parent exit")
        print("PASS abort while helper is awaiting readiness prevents installation after parent exit")

        let abortedParent = Process(); abortedParent.executableURL = application.appendingPathComponent("Contents/MacOS/UpdateInstallerChecks")
        abortedParent.arguments = ["--fixture-parent-abort"]
        try abortedParent.run(); abortedParent.waitUntilExit()
        try require(abortedParent.terminationStatus == 0 && !FileManager.default.fileExists(atPath: planURL.path),
                    "Cancelled quit did not abort installer and remove plan")
        let stillOriginal = try PropertyListSerialization.propertyList(from: Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        try require(stillOriginal["CFBundleVersion"] as? String == "1", "Cancelled quit still replaced original")
        print("PASS abort after readiness preserves original app and removes pending plan")

        let parent = Process(); parent.executableURL = application.appendingPathComponent("Contents/MacOS/UpdateInstallerChecks")
        parent.arguments = ["--fixture-parent"]
        try parent.run()
        parent.waitUntilExit()
        try require(parent.terminationStatus == 0, "Synthetic parent did not finish installer handshake")
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(FileManager.default.fileExists(atPath: marker.path), "Detached installer did not reopen synthetic v2 after parent exit")
        for _ in 0..<50 {
            let files = try FileManager.default.contentsOfDirectory(atPath: updates.path)
            if !FileManager.default.fileExists(atPath: planURL.path) &&
                !files.contains(where: { $0.hasSuffix(".ack") || $0.hasSuffix(".ready") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finalBundle = Bundle(url: application)
        // Foundation may cache Bundle objects for replaced paths; inspect saved plist.
        _ = finalBundle
        let finalInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
        try require(finalInfo["CFBundleVersion"] as? String == "2", "Synthetic v2 was not installed")
        try require(!FileManager.default.fileExists(atPath: planURL.path), "Startup acknowledgement did not clean the install plan")
        try require(!FileManager.default.fileExists(atPath: prepared.stagingDirectory.path), "Staging directory was not cleaned")
        let consumedMessage = try String(contentsOf: URL(fileURLWithPath: marker.path + "-result"), encoding: .utf8)
        try require(consumedMessage == "已更新到 0.0.2", "Synthetic v2 did not receive installation result")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: updates.path)
        try require(!leftovers.contains(where: { $0.hasSuffix(".ack") || $0.hasSuffix(".ready") }), "Installer handshake artifacts remain after result cleanup")
        print("PASS end-to-end signed feed → download → verify → detached install after parent exit → reopen v2 → result consumption and cleanup")
        print("PASS all update installer checks (synthetic; App Management, TCC, other macOS versions and Intel remain real-machine acceptance items)")
    }
}
