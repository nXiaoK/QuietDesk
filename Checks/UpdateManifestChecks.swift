import Foundation
import CryptoKit
import QuietDeskCore

func runUpdateManifestChecks() {
    run("Signed update manifests authenticate original payload bytes before parsing") {
        let key = Curve25519.Signing.PrivateKey()
        let manifest = updateCheckManifest()
        let payload = try JSONEncoder().encode(manifest)
        let data = try signedUpdateCheckData(payload, key: key)
        let keys = updateCheckKeys(key)
        try check(try UpdateManifestVerifier.verify(data, publicKeys: keys, bundleIdentifier: "local.quietdesk.app") == .supported(manifest),
                  "Valid manifest changed")
        for offset in payload.indices {
            var changed = payload
            changed[offset] ^= 1
            let envelope = SignedUpdateEnvelope(keyID: "checks", payload: changed.base64EncodedString(),
                                                signature: try key.signature(for: UpdateManifestVerifier.signingPrefix + payload).base64EncodedString())
            try rejects("Payload byte \(offset) was not authenticated") {
                _ = try UpdateManifestVerifier.verify(JSONEncoder().encode(envelope), publicKeys: keys, bundleIdentifier: "local.quietdesk.app")
            }
        }
        let invalidPayload = Data("not JSON".utf8)
        let invalidEnvelope = SignedUpdateEnvelope(keyID: "checks", payload: invalidPayload.base64EncodedString(),
                                                   signature: Data(repeating: 0, count: 64).base64EncodedString())
        do {
            _ = try UpdateManifestVerifier.verify(JSONEncoder().encode(invalidEnvelope), publicKeys: keys, bundleIdentifier: "local.quietdesk.app")
            throw CheckFailure("Invalid signature was accepted")
        } catch let error as UpdateManifestError {
            try check(error == .invalidSignature, "Unauthenticated payload was parsed")
        }
    }

    run("Update envelope rejects unknown keys, bad signatures, encodings and excessive size") {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(updateCheckManifest())
        let signature = try key.signature(for: UpdateManifestVerifier.signingPrefix + payload)
        let badEnvelopes = [
            SignedUpdateEnvelope(format: 2, keyID: "checks", payload: payload.base64EncodedString(), signature: signature.base64EncodedString()),
            SignedUpdateEnvelope(keyID: "other", payload: payload.base64EncodedString(), signature: signature.base64EncodedString()),
            SignedUpdateEnvelope(keyID: "checks", payload: "*not base64*", signature: signature.base64EncodedString()),
            SignedUpdateEnvelope(keyID: "checks", payload: payload.base64EncodedString(), signature: "*not base64*"),
            SignedUpdateEnvelope(keyID: "checks", payload: payload.base64EncodedString(), signature: signature.dropLast().base64EncodedString()),
            SignedUpdateEnvelope(keyID: "checks", payload: payload.base64EncodedString(), signature: try key.signature(for: payload).base64EncodedString())
        ]
        for envelope in badEnvelopes {
            try rejects("Malformed envelope was accepted") {
                _ = try UpdateManifestVerifier.verify(JSONEncoder().encode(envelope), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
            }
        }
        let valid = try signedUpdateCheckData(payload, key: key)
        try rejects("Wrong public key was accepted") {
            _ = try UpdateManifestVerifier.verify(valid, publicKeys: updateCheckKeys(Curve25519.Signing.PrivateKey()), bundleIdentifier: "local.quietdesk.app")
        }
        try rejects("Duplicate key ID was accepted") {
            _ = try UpdateManifestVerifier.verify(valid, publicKeys: updateCheckKeys(key) + updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
        }
        try rejects("Oversized envelope was accepted") {
            _ = try UpdateManifestVerifier.verify(Data(repeating: 32, count: 65_537), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
        }
        try rejects("Missing required outer field was accepted") {
            _ = try UpdateManifestVerifier.verify(Data("{}".utf8), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
        }
    }

    run("Update payload requires valid fields while retaining unknown-field compatibility") {
        let key = Curve25519.Signing.PrivateKey()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updateCheckManifest())) as! [String: Any]
        var future = original
        future["unknownFutureField"] = ["ignored": true]
        let futureResult = try UpdateManifestVerifier.verify(signedUpdateCheckObject(future, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
        try check(futureResult == .supported(updateCheckManifest()), "Unknown field changed supported manifest")
        for name in ["schema", "bundleIdentifier", "version", "build", "minimumSystemVersion", "publishedAt", "revision", "releaseNotesURL", "archive"] {
            var missing = original
            missing.removeValue(forKey: name)
            try rejects("Missing \(name) was accepted") {
                _ = try UpdateManifestVerifier.verify(signedUpdateCheckObject(missing, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
            }
            var wrongType = original
            wrongType[name] = name == "build" || name == "schema" ? "1" : 42
            try rejects("Wrong type for \(name) was accepted") {
                _ = try UpdateManifestVerifier.verify(signedUpdateCheckObject(wrongType, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
            }
        }
        let invalidFields: [(String, Any)] = [
            ("bundleIdentifier", "other.app"), ("schema", 0), ("build", 0), ("build", -1),
            ("version", "01.2.3"), ("version", "1.2"), ("version", "1.2.3-beta"),
            ("minimumSystemVersion", "14.bad"), ("publishedAt", "yesterday"),
            ("revision", "not-a-git-revision"), ("notes", String(repeating: "a", count: 4_001))
        ]
        for (name, value) in invalidFields {
            var changed = original
            changed[name] = value
            try rejects("Invalid \(name) was accepted") {
                _ = try UpdateManifestVerifier.verify(signedUpdateCheckObject(changed, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
            }
        }
        for (name, value) in [("size", 0 as Any), ("size", 67_108_865 as Any), ("sha256", String(repeating: "A", count: 64) as Any), ("sha256", "a" as Any)] {
            var changed = original
            var archive = changed["archive"] as! [String: Any]
            archive[name] = value
            changed["archive"] = archive
            try rejects("Invalid archive \(name) was accepted") {
                _ = try UpdateManifestVerifier.verify(signedUpdateCheckObject(changed, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
            }
        }
    }

    run("Future update schemas return safe manual-update links without requiring old payload fields") {
        let key = Curve25519.Signing.PrivateKey()
        let url = URL(string: "https://github.com/nXiaoK/QuietDesk/releases/latest")!
        let future: [String: Any] = ["schema": 2, "releaseNotesURL": url.absoluteString, "future": true]
        try check(try UpdateManifestVerifier.verify(signedUpdateCheckObject(future, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app") == .requiresManualUpdate(schema: 2, releaseNotesURL: url), "Future schema was not a manual update")
        var unsafe = future
        unsafe["releaseNotesURL"] = "https://example.com/update"
        try rejects("Future schema allowed an unsafe manual URL") {
            _ = try UpdateManifestVerifier.verify(signedUpdateCheckObject(unsafe, key: key), publicKeys: updateCheckKeys(key), bundleIdentifier: "local.quietdesk.app")
        }
    }

    run("Update versions follow three integer components and prevent downgrade or build replay") {
        try check(try UpdateVersion("1.10.0") > UpdateVersion("1.9.99"), "Versions used lexical ordering")
        try check(try UpdateVersion("999999999999999999999999.0.0") > UpdateVersion("999999999999999999999998.999.999"), "Large valid component overflowed")
        for version in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.-1", "1.2.3\n", "１.2.3", "1.2.3+build", " 1.2.3"] {
            try rejects("Invalid version \(version) was accepted") { _ = try UpdateVersion(version) }
        }
        let manifest = updateCheckManifest()
        try check(try manifest.assess(currentVersion: "0.7.0", currentBuild: 30, systemVersion: "14.0") == .available, "New version was not offered")
        try check(try manifest.assess(currentVersion: "0.8.0", currentBuild: 30, systemVersion: "14.0") == .upToDate, "Same version was offered")
        try check(try manifest.assess(currentVersion: "0.9.0", currentBuild: 30, systemVersion: "14.0") == .upToDate, "Downgrade was offered")
        try check(try manifest.assess(currentVersion: "0.7.0", currentBuild: 31, systemVersion: "14.0") == .inconsistentBuild, "Equal build was offered")
        try check(try manifest.assess(currentVersion: "0.7.0", currentBuild: 32, systemVersion: "14.0") == .inconsistentBuild, "Older build was offered")
        try check(try manifest.assess(currentVersion: "0.7.0", currentBuild: 30, systemVersion: "13.6.9") == .requiresNewerSystem("14.0"), "System minimum was ignored")
        try check(try UpdateSystemVersion("14") == UpdateSystemVersion("14.0.0"), "Equivalent system versions differ")
    }

    run("Update URL policy restricts archive ownership, credentials and test-only loopback sources") {
        let safe = updateCheckManifest().archive.url
        try UpdateURLPolicy.validateArchiveURL(safe, bundleIdentifier: "local.quietdesk.app")
        for string in [
            "http://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/app.zip",
            "https://example.com/nXiaoK/QuietDesk/releases/download/v0.8.0/app.zip",
            "https://github.com/other/QuietDesk/releases/download/v0.8.0/app.zip",
            "https://github.com/nXiaoK/Other/releases/download/v0.8.0/app.zip",
            "https://user:pass@github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/app.zip",
            "https://github.com:444/nXiaoK/QuietDesk/releases/download/v0.8.0/app.zip",
            "https://github.com/nXiaoK/QuietDesk/releases/download/../other/app.zip",
            "https://github.com/nXiaoK/QuietDesk/releases/download/%2e%2e/other/app.zip",
            "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0%2f..%2fother/app.zip"
        ] {
            try rejects("Unsafe archive URL was accepted: \(string)") {
                try UpdateURLPolicy.validateArchiveURL(URL(string: string)!, bundleIdentifier: "local.quietdesk.app")
            }
        }
        for string in ["http://127.0.0.1:1234/app.zip", "http://localhost:1234/app.zip"] {
            let url = URL(string: string)!
            try UpdateURLPolicy.validateArchiveURL(url, bundleIdentifier: "local.quietdesk.checks.updater", allowLoopbackForTesting: true)
            try rejects("Production ID allowed loopback") { try UpdateURLPolicy.validateArchiveURL(url, bundleIdentifier: "local.quietdesk.app", allowLoopbackForTesting: true) }
            try rejects("Loopback was enabled without explicit test configuration") { try UpdateURLPolicy.validateArchiveURL(url, bundleIdentifier: "local.quietdesk.checks.updater") }
        }
        try rejects("Test mode permitted arbitrary HTTP") {
            try UpdateURLPolicy.validateArchiveURL(URL(string: "http://192.0.2.1/app.zip")!, bundleIdentifier: "local.quietdesk.checks.updater", allowLoopbackForTesting: true)
        }
        try UpdateURLPolicy.validateFeedURL(URL(string: "https://github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json")!, bundleIdentifier: "local.quietdesk.app")
        try rejects("Unsafe feed was accepted") { try UpdateURLPolicy.validateFeedURL(URL(string: "https://example.com/update.json")!, bundleIdentifier: "local.quietdesk.app") }
        try check(UpdateURLPolicy.allowsRedirect(to: URL(string: "https://release-assets.githubusercontent.com/archive")!, bundleIdentifier: "local.quietdesk.app"), "Secure GitHub CDN redirect was refused")
        try check(!UpdateURLPolicy.allowsRedirect(to: URL(string: "http://github.com/archive")!, bundleIdentifier: "local.quietdesk.app"), "Insecure redirect was allowed")
        try rejects("Credentials were allowed in release notes") { try UpdateURLPolicy.validateReleaseNotesURL(URL(string: "https://user@github.com/releases")!) }
    }

    run("First update consent waits for an unobstructed active main window and persists either choice") {
        func shouldPresent(_ preference: Bool? = nil, enabled: Bool = true, visible: Bool = true,
                           active: Bool = true, controlling: Bool = false, fullScreen: Bool = false,
                           host: Bool = false, prompt: Bool = false) -> Bool {
            UpdateCheckPolicy.shouldPresentConsent(updaterEnabled: enabled, autoCheckPreference: preference,
                mainWindowVisible: visible, applicationActive: active, isControlling: controlling,
                isFullScreen: fullScreen, hasHostConnection: host, hasOtherPrompt: prompt)
        }
        try check(shouldPresent(), "Eligible first launch did not ask")
        try check(!shouldPresent(enabled: false), "Disabled updater asked for consent")
        try check(!shouldPresent(visible: false) && !shouldPresent(active: false), "Hidden or inactive window asked")
        try check(!shouldPresent(controlling: true) && !shouldPresent(fullScreen: true), "Remote or full screen session was interrupted")
        try check(!shouldPresent(host: true) && !shouldPresent(prompt: true), "Host connection or existing prompt was interrupted")
        try check(!shouldPresent(true) && !shouldPresent(false), "Stored choice was asked again")
        let originalPreference: Bool? = nil
        try check(UpdateCheckPolicy.shouldOffer(version: "0.8.0", skippedVersion: "0.8.0", manual: true), "Manual check respected skipped version")
        try check(originalPreference == nil && shouldPresent(originalPreference), "Manual check changed the unasked preference")
    }

    run("Automatic update checks require consent, startup delay and a persistent daily interval") {
        let launch = Date(timeIntervalSince1970: 1_000)
        let now = launch.addingTimeInterval(120)
        func due(_ preference: Bool?, time: Date = now, last: Date? = nil, enabled: Bool = true) -> Bool {
            UpdateCheckPolicy.shouldAutomaticallyCheck(updaterEnabled: enabled, autoCheckPreference: preference, now: time, launchedAt: launch, lastCheck: last)
        }
        try check(!due(nil) && !due(false) && !due(true, enabled: false), "Automatic check ran without enabled consent")
        try check(!due(true, time: launch.addingTimeInterval(119.9)) && due(true), "First check ignored startup boundary")
        try check(!due(true, last: now.addingTimeInterval(-86_399)) && due(true, last: now.addingTimeInterval(-86_400)), "Daily interval boundary changed")
        try check(!due(true, last: now.addingTimeInterval(1)), "Clock rollback caused repeated check")
        try check(!UpdateCheckPolicy.shouldOffer(version: "0.8.0", skippedVersion: "0.8.0", manual: false), "Skipped version was offered automatically")
        try check(UpdateCheckPolicy.shouldOffer(version: "0.8.1", skippedVersion: "0.8.0", manual: false), "Newer version inherited old skip")
    }

    run("Update installation blocks remote host sessions and falls back for unsafe destinations") {
        let normal = URL(fileURLWithPath: "/Applications/QuietDesk.app")
        func availability(host: Bool = false, url: URL = normal, readOnly: Bool = false, writable: Bool = true) -> UpdateInstallationAvailability {
            UpdateInstallationPolicy.availability(hasHostConnection: host, applicationURL: url,
                isReadOnlyVolume: readOnly, parentDirectoryWritable: writable)
        }
        try check(availability() == .available, "Writable local application could not update")
        try check(availability(host: true) == .blockedByRemoteConnection, "Connected host could install")
        try check(availability(url: URL(fileURLWithPath: "/private/var/folders/test/AppTranslocation/id/d/QuietDesk.app")) == .manualRequired(.appTranslocation), "Translocation could install")
        try check(availability(readOnly: true) == .manualRequired(.readOnlyVolume), "Read-only volume could install")
        try check(availability(writable: false) == .manualRequired(.directoryNotWritable), "Non-writable parent could install")
    }
}

private func updateCheckManifest() -> UpdateManifest {
    UpdateManifest(bundleIdentifier: "local.quietdesk.app", version: "0.8.0", build: 31,
        minimumSystemVersion: "14.0", publishedAt: "2026-10-20T08:00:00Z", revision: String(repeating: "a", count: 40),
        releaseNotesURL: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/tag/v0.8.0")!, notes: "更新说明",
        archive: UpdateArchive(url: URL(string: "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/QuietDesk-0.8.0-macOS-universal.zip")!,
                               size: 3_451_356, sha256: String(repeating: "a", count: 64)))
}

private func updateCheckKeys(_ key: Curve25519.Signing.PrivateKey) -> [UpdatePublicKey] {
    [UpdatePublicKey(id: "checks", key: key.publicKey.rawRepresentation.base64EncodedString())]
}

private func signedUpdateCheckObject(_ object: [String: Any], key: Curve25519.Signing.PrivateKey) throws -> Data {
    try signedUpdateCheckData(JSONSerialization.data(withJSONObject: object), key: key)
}

private func signedUpdateCheckData(_ payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
    let envelope = SignedUpdateEnvelope(keyID: "checks", payload: payload.base64EncodedString(),
        signature: try key.signature(for: UpdateManifestVerifier.signingPrefix + payload).base64EncodedString())
    return try JSONEncoder().encode(envelope)
}
