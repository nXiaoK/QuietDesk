import Foundation
import CryptoKit

public enum UpdateManifestError: Error, Equatable, LocalizedError {
    case envelopeTooLarge
    case malformedEnvelope
    case unsupportedFormat
    case unknownKey
    case invalidSignature
    case invalidPayload
    case invalidField(String)
    case unsafeURL

    public var errorDescription: String? {
        switch self {
        case .envelopeTooLarge: return "更新清单超过大小限制。"
        case .malformedEnvelope: return "更新清单格式无效。"
        case .unsupportedFormat: return "不支持此更新清单格式。"
        case .unknownKey: return "更新清单使用了未知的签名密钥。"
        case .invalidSignature: return "更新清单签名校验失败。"
        case .invalidPayload: return "更新清单内容无效。"
        case .invalidField(let name): return "更新清单字段无效：\(name)。"
        case .unsafeURL: return "更新清单包含不允许的下载地址。"
        }
    }
}

public struct UpdatePublicKey: Codable, Equatable, Sendable {
    public let id: String
    public let key: String
    public init(id: String, key: String) { self.id = id; self.key = key }
}

public struct SignedUpdateEnvelope: Codable, Equatable, Sendable {
    public let format: Int
    public let keyID: String
    public let payload: String
    public let signature: String
    public init(format: Int = 1, keyID: String, payload: String, signature: String) {
        self.format = format; self.keyID = keyID; self.payload = payload; self.signature = signature
    }
}

// Compare decimal components as strings so valid versions cannot overflow a machine integer.
public struct UpdateVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    private let components: [String]
    public init(_ value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3, components.allSatisfy(Self.validComponent) else {
            throw UpdateManifestError.invalidField("version")
        }
        description = value
        self.components = components
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { compare(lhs.components, rhs.components) }
    fileprivate static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
            && (value.count == 1 || !value.hasPrefix("0"))
    }
    fileprivate static func compare(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left.count == right.count ? left < right : left.count < right.count
        }
        return false
    }
}

public struct UpdateSystemVersion: Comparable, Equatable, Sendable {
    private let components: [String]
    public init(_ value: String) throws {
        let values = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(values.count), values.allSatisfy(UpdateVersion.validComponent) else {
            throw UpdateManifestError.invalidField("minimumSystemVersion")
        }
        components = values + Array(repeating: "0", count: 3 - values.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { UpdateVersion.compare(lhs.components, rhs.components) }
}

public struct UpdateArchive: Codable, Equatable, Sendable {
    public let url: URL
    public let size: Int64
    public let sha256: String
    public init(url: URL, size: Int64, sha256: String) { self.url = url; self.size = size; self.sha256 = sha256 }
}

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate
    case available
    case requiresNewerSystem(String)
    case inconsistentBuild
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let bundleIdentifier: String
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let publishedAt: String
    public let revision: String
    public let releaseNotesURL: URL
    public let notes: String?
    public let archive: UpdateArchive

    public init(schema: Int = 1, bundleIdentifier: String, version: String, build: Int,
                minimumSystemVersion: String, publishedAt: String, revision: String,
                releaseNotesURL: URL, notes: String? = nil, archive: UpdateArchive) {
        self.schema = schema; self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
        self.minimumSystemVersion = minimumSystemVersion; self.publishedAt = publishedAt; self.revision = revision
        self.releaseNotesURL = releaseNotesURL; self.notes = notes; self.archive = archive
    }

    public func validate(bundleIdentifier expectedBundleIdentifier: String, allowLoopbackForTesting: Bool = false,
                         repository: String = "nXiaoK/QuietDesk") throws {
        guard schema == 1 else { throw UpdateManifestError.invalidField("schema") }
        guard !expectedBundleIdentifier.isEmpty, bundleIdentifier == expectedBundleIdentifier else {
            throw UpdateManifestError.invalidField("bundleIdentifier")
        }
        _ = try UpdateVersion(version)
        guard build > 0 else { throw UpdateManifestError.invalidField("build") }
        _ = try UpdateSystemVersion(minimumSystemVersion)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: publishedAt)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard publishedAt.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\\z", options: .regularExpression) != nil,
              (date ?? formatter.date(from: publishedAt)) != nil else {
            throw UpdateManifestError.invalidField("publishedAt")
        }
        guard revision.isEmpty || (revision.utf8.count == 40 && revision.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        })) else { throw UpdateManifestError.invalidField("revision") }
        guard (notes?.unicodeScalars.count ?? 0) <= 4_000 else { throw UpdateManifestError.invalidField("notes") }
        try UpdateURLPolicy.validateReleaseNotesURL(releaseNotesURL)
        try UpdateURLPolicy.validateArchiveURL(archive.url, bundleIdentifier: bundleIdentifier,
                                              allowLoopbackForTesting: allowLoopbackForTesting, repository: repository)
        guard archive.size > 0, archive.size <= UpdateManifestVerifier.maximumArchiveBytes else {
            throw UpdateManifestError.invalidField("archive.size")
        }
        guard archive.sha256.utf8.count == 64, archive.sha256.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw UpdateManifestError.invalidField("archive.sha256") }
    }

    public func assess(currentVersion: String, currentBuild: Int, systemVersion: String) throws -> UpdateAvailability {
        guard currentBuild > 0 else { throw UpdateManifestError.invalidField("currentBuild") }
        guard try UpdateVersion(version) > UpdateVersion(currentVersion) else { return .upToDate }
        guard build > currentBuild else { return .inconsistentBuild }
        guard try UpdateSystemVersion(minimumSystemVersion) <= UpdateSystemVersion(systemVersion) else {
            return .requiresNewerSystem(minimumSystemVersion)
        }
        return .available
    }
}

public enum UpdateManifestVerificationResult: Equatable, Sendable {
    case supported(UpdateManifest)
    case requiresManualUpdate(schema: Int, releaseNotesURL: URL)
}

public enum UpdateManifestVerifier {
    public static let signingPrefix = Data("QuietDesk-update-v1\n".utf8)
    public static let maximumEnvelopeBytes = 64 * 1_024
    public static let maximumArchiveBytes: Int64 = 64 * 1_024 * 1_024

    public static func verify(_ data: Data, publicKeys: [UpdatePublicKey], bundleIdentifier: String,
                              allowLoopbackForTesting: Bool = false,
                              repository: String = "nXiaoK/QuietDesk") throws -> UpdateManifestVerificationResult {
        guard data.count <= maximumEnvelopeBytes else { throw UpdateManifestError.envelopeTooLarge }
        let envelope: SignedUpdateEnvelope
        do { envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: data) }
        catch { throw UpdateManifestError.malformedEnvelope }
        guard envelope.format == 1 else { throw UpdateManifestError.unsupportedFormat }
        let matchingKeys = publicKeys.filter { $0.id == envelope.keyID }
        guard matchingKeys.count == 1, let configuredKey = matchingKeys.first else { throw UpdateManifestError.unknownKey }
        guard let keyBytes = Data(base64Encoded: configuredKey.key), keyBytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              publicKey.isValidSignature(signature, for: signingPrefix + payload) else {
            throw UpdateManifestError.invalidSignature
        }
        // Payload bytes remain opaque until the signature above has authenticated them.
        struct Header: Decodable { let schema: Int; let releaseNotesURL: URL }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: payload) }
        catch { throw UpdateManifestError.invalidPayload }
        guard header.schema > 0 else { throw UpdateManifestError.invalidField("schema") }
        try UpdateURLPolicy.validateReleaseNotesURL(header.releaseNotesURL)
        if header.schema > 1 { return .requiresManualUpdate(schema: header.schema, releaseNotesURL: header.releaseNotesURL) }
        let manifest: UpdateManifest
        do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: payload) }
        catch { throw UpdateManifestError.invalidPayload }
        try manifest.validate(bundleIdentifier: bundleIdentifier, allowLoopbackForTesting: allowLoopbackForTesting,
                              repository: repository)
        return .supported(manifest)
    }
}

public enum UpdateURLPolicy {
    public static let productionBundleIdentifier = "local.quietdesk.app"

    public static func validateReleaseNotesURL(_ url: URL) throws {
        guard isHTTPS(url), url.host?.lowercased() == "github.com" else { throw UpdateManifestError.unsafeURL }
    }

    public static func validateArchiveURL(_ url: URL, bundleIdentifier: String,
                                          allowLoopbackForTesting: Bool = false,
                                          repository: String = "nXiaoK/QuietDesk") throws {
        if isAllowedLoopback(url, bundleIdentifier: bundleIdentifier, enabled: allowLoopbackForTesting) { return }
        guard isHTTPS(url), url.host?.lowercased() == "github.com", validRepository(repository) else {
            throw UpdateManifestError.unsafeURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.fragment == nil else {
            throw UpdateManifestError.unsafeURL
        }
        let prefix = "/\(repository)/releases/download/"
        let path = url.path
        let pathParts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix(prefix), path.dropFirst(prefix.count).split(separator: "/").count >= 2,
              pathParts.allSatisfy({ part in
                  guard let decoded = String(part).removingPercentEncoding else { return false }
                  return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\")
              }) else { throw UpdateManifestError.unsafeURL }
    }

    public static func validateFeedURL(_ url: URL, bundleIdentifier: String,
                                       allowLoopbackForTesting: Bool = false) throws {
        if isAllowedLoopback(url, bundleIdentifier: bundleIdentifier, enabled: allowLoopbackForTesting) { return }
        guard isHTTPS(url), url.host?.lowercased() == "github.com",
              url.path.hasSuffix("/releases/latest/download/QuietDesk-update.json"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil else { throw UpdateManifestError.unsafeURL }
        let repository = String(url.path.dropFirst().dropLast("/releases/latest/download/QuietDesk-update.json".count))
        guard validRepository(repository) else { throw UpdateManifestError.unsafeURL }
    }

    public static func allowsRedirect(to url: URL, bundleIdentifier: String,
                                      allowLoopbackForTesting: Bool = false) -> Bool {
        isHTTPS(url) || isAllowedLoopback(url, bundleIdentifier: bundleIdentifier, enabled: allowLoopbackForTesting)
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
    private static func isAllowedLoopback(_ url: URL, bundleIdentifier: String, enabled: Bool) -> Bool {
        enabled && bundleIdentifier != productionBundleIdentifier && !bundleIdentifier.isEmpty
            && url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
    }
    private static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }
    }
}

public enum UpdateCheckPolicy {
    public static func shouldPresentConsent(updaterEnabled: Bool, autoCheckPreference: Bool?, mainWindowVisible: Bool,
                                            applicationActive: Bool, isControlling: Bool, isFullScreen: Bool,
                                            hasHostConnection: Bool, hasOtherPrompt: Bool) -> Bool {
        updaterEnabled && autoCheckPreference == nil && mainWindowVisible && applicationActive
            && !isControlling && !isFullScreen && !hasHostConnection && !hasOtherPrompt
    }
    public static func shouldAutomaticallyCheck(updaterEnabled: Bool, autoCheckPreference: Bool?, now: Date,
                                               launchedAt: Date, lastCheck: Date?) -> Bool {
        guard updaterEnabled, autoCheckPreference == true, now.timeIntervalSince(launchedAt) >= 120 else { return false }
        return lastCheck.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
    }
    public static func shouldOffer(version: String, skippedVersion: String?, manual: Bool) -> Bool {
        manual || version != skippedVersion
    }
}

public enum UpdateManualInstallReason: Equatable, Sendable {
    case appTranslocation
    case readOnlyVolume
    case directoryNotWritable
}

public enum UpdateInstallationAvailability: Equatable, Sendable {
    case available
    case blockedByRemoteConnection
    case manualRequired(UpdateManualInstallReason)
}

public enum UpdateInstallationPolicy {
    public static func availability(hasHostConnection: Bool, applicationURL: URL, isReadOnlyVolume: Bool,
                                    parentDirectoryWritable: Bool) -> UpdateInstallationAvailability {
        if hasHostConnection { return .blockedByRemoteConnection }
        if applicationURL.path.contains("/AppTranslocation/") { return .manualRequired(.appTranslocation) }
        if isReadOnlyVolume { return .manualRequired(.readOnlyVolume) }
        if !parentDirectoryWritable { return .manualRequired(.directoryNotWritable) }
        return .available
    }
}
