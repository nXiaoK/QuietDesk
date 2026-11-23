import CryptoKit
import Darwin
import Foundation
import QuietDeskCore

private enum ToolError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

private struct AppMetadata {
    let bundleIdentifier: String
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let revision: String
    let publicKeys: [UpdatePublicKey]
    let repository: String

    init(url: URL) throws {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = value["CFBundleIdentifier"] as? String,
              let version = value["CFBundleShortVersionString"] as? String,
              let buildString = value["CFBundleVersion"] as? String,
              let build = Int(buildString), build > 0, String(build) == buildString,
              let minimum = value["LSMinimumSystemVersion"] as? String,
              let rawKeys = value["QuietDeskUpdatePublicKeys"] as? [[String: Any]] else {
            throw ToolError.invalid("应用元数据或更新公钥表无效")
        }
        _ = try UpdateVersion(version)
        bundleIdentifier = identifier
        self.version = version
        self.build = build
        minimumSystemVersion = minimum
        revision = value["QuietDeskBuildRevision"] as? String ?? ""
        publicKeys = try JSONDecoder().decode([UpdatePublicKey].self, from: JSONSerialization.data(withJSONObject: rawKeys))
        if let feed = value["QuietDeskUpdateFeedURL"] as? String, let url = URL(string: feed), url.host == "github.com" {
            let parts = url.path.split(separator: "/")
            guard parts.count == 6, parts[2] == "releases", parts[3] == "latest", parts[4] == "download" else {
                throw ToolError.invalid("应用更新源无效")
            }
            repository = "\(parts[0])/\(parts[1])"
        } else {
            repository = "nXiaoK/QuietDesk"
        }
    }
}

private func arguments() throws -> (String, [String: String]) {
    let items = Array(CommandLine.arguments.dropFirst())
    guard let command = items.first else {
        throw ToolError.invalid("用法: QuietDeskUpdateTool generate-key|sign|verify|sign-windows|verify-windows|check-key [选项]")
    }
    let allowed: Set<String>
    switch command {
    case "generate-key": allowed = ["--out"]
    case "sign": allowed = ["--app", "--archive", "--tag", "--repository", "--notes-file", "--out"]
    case "verify": allowed = ["--app", "--archive", "--manifest"]
    case "sign-windows":
        allowed = [
            "--config", "--app-id", "--version", "--build", "--revision", "--tag", "--repository",
            "--x64-zip", "--x64-installer", "--arm64-zip", "--arm64-installer", "--require-installers",
            "--notes-file", "--out"
        ]
    case "verify-windows":
        allowed = [
            "--config", "--app-id", "--version", "--build", "--revision", "--repository",
            "--x64-zip", "--x64-installer", "--arm64-zip", "--arm64-installer", "--require-installers",
            "--manifest"
        ]
    case "check-key": allowed = ["--config"]
    default: throw ToolError.invalid("未知子命令")
    }
    var options: [String: String] = [:]
    var index = 1
    while index < items.count {
        let name = items[index]
        guard allowed.contains(name), options[name] == nil, index + 1 < items.count, !items[index + 1].hasPrefix("--") else {
            throw ToolError.invalid("未知、重复或缺少值的选项")
        }
        options[name] = items[index + 1]
        index += 2
    }
    return (command, options)
}

private func required(_ name: String, in options: [String: String]) throws -> String {
    guard let value = options[name], !value.isEmpty else { throw ToolError.invalid("缺少 \(name)") }
    return value
}

private func signingKey() throws -> Curve25519.Signing.PrivateKey {
    guard let value = ProcessInfo.processInfo.environment["QUIETDESK_UPDATE_SIGNING_KEY"],
          let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        throw ToolError.invalid("签名私钥缺失或无效；请设置 QUIETDESK_UPDATE_SIGNING_KEY 后重跑")
    }
    return key
}

private func matchedKey(_ key: Curve25519.Signing.PrivateKey, in keys: [UpdatePublicKey]) throws -> UpdatePublicKey {
    guard Set(keys.map(\.id)).count == keys.count,
          keys.allSatisfy({ item in
              item.id.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
                  && Data(base64Encoded: item.key)?.count == 32
          }) else { throw ToolError.invalid("更新公钥表无效") }
    let encoded = key.publicKey.rawRepresentation.base64EncodedString()
    guard let match = keys.first(where: { $0.key == encoded }) else { throw ToolError.invalid("签名私钥与内置公钥不匹配") }
    return match
}

private func archiveDigest(_ url: URL) throws -> (Int64, String) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let count = attributes[.size] as? NSNumber, count.int64Value > 0,
          count.int64Value <= UpdateManifestVerifier.maximumArchiveBytes else {
        throw ToolError.invalid("归档必须是非空普通文件，且不超过 64 MiB")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size: Int64 = 0
    while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
        size += Int64(data.count)
        guard size <= UpdateManifestVerifier.maximumArchiveBytes else { throw ToolError.invalid("归档超过 64 MiB") }
        hasher.update(data: data)
    }
    guard size == count.int64Value else { throw ToolError.invalid("读取期间归档大小发生变化") }
    return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
}

private func generateKey(to path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: parent.path) else { throw ToolError.invalid("私钥输出目录必须已存在") }
    var ancestor = parent
    while true {
        if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
            throw ToolError.invalid("拒绝将私钥写入仓库目录；请指定仓库外路径")
        }
        let next = ancestor.deletingLastPathComponent()
        if next == ancestor { break }
        ancestor = next
    }
    let key = Curve25519.Signing.PrivateKey()
    let destination = parent.appendingPathComponent(url.lastPathComponent)
    let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ToolError.invalid("无法创建私钥文件，文件可能已存在") }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: destination)
        throw ToolError.invalid("无法设置私钥文件权限")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: destination)
        throw ToolError.invalid("无法保存私钥文件")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM"
    let publicKey = UpdatePublicKey(id: formatter.string(from: Date()), key: key.publicKey.rawRepresentation.base64EncodedString())
    print(String(decoding: try JSONEncoder().encode(publicKey), as: UTF8.self))
}

private func sign(_ options: [String: String]) throws {
    let app = try AppMetadata(url: URL(fileURLWithPath: required("--app", in: options)))
    let archiveURL = URL(fileURLWithPath: try required("--archive", in: options))
    let tag = try required("--tag", in: options)
    let repository = try required("--repository", in: options)
    guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
          tag == "v" + app.version,
          archiveURL.lastPathComponent == "QuietDesk-\(app.version)-macOS-universal.zip" else {
        throw ToolError.invalid("仓库、版本标签或 Universal ZIP 文件名不一致")
    }
    let key = try signingKey()
    let trusted = try matchedKey(key, in: app.publicKeys)
    let (size, digest) = try archiveDigest(archiveURL)
    let notes = try options["--notes-file"].map { path in
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(4_000)))
    }
    let manifest = UpdateManifest(bundleIdentifier: app.bundleIdentifier, version: app.version, build: app.build,
                                  minimumSystemVersion: app.minimumSystemVersion,
                                  publishedAt: ISO8601DateFormatter().string(from: Date()), revision: app.revision,
                                  releaseNotesURL: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!, notes: notes,
                                  archive: UpdateArchive(url: URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(archiveURL.lastPathComponent)")!,
                                                         size: size, sha256: digest))
    try manifest.validate(bundleIdentifier: app.bundleIdentifier, repository: repository)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(manifest)
    let signature = try key.signature(for: UpdateManifestVerifier.signingPrefix + payload)
    let envelope = SignedUpdateEnvelope(keyID: trusted.id, payload: payload.base64EncodedString(), signature: signature.base64EncodedString())
    let data = try encoder.encode(envelope)
    guard data.count <= UpdateManifestVerifier.maximumEnvelopeBytes else { throw ToolError.invalid("更新清单超过 64 KiB") }
    try data.write(to: URL(fileURLWithPath: required("--out", in: options)), options: .atomic)
    print("已签名更新清单")
}

private func verify(_ options: [String: String]) throws {
    let app = try AppMetadata(url: URL(fileURLWithPath: required("--app", in: options)))
    let url = URL(fileURLWithPath: try required("--manifest", in: options))
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: UpdateManifestVerifier.maximumEnvelopeBytes + 1) ?? Data()
    let result = try UpdateManifestVerifier.verify(data, publicKeys: app.publicKeys, bundleIdentifier: app.bundleIdentifier, repository: app.repository)
    guard case .supported(let manifest) = result,
          manifest.version == app.version, manifest.build == app.build,
          manifest.minimumSystemVersion == app.minimumSystemVersion, manifest.revision == app.revision else {
        throw ToolError.invalid("清单与应用元数据不一致")
    }
    let archive = try archiveDigest(URL(fileURLWithPath: required("--archive", in: options)))
    guard archive.0 == manifest.archive.size, archive.1 == manifest.archive.sha256 else { throw ToolError.invalid("归档大小或 SHA-256 不匹配") }
    print("更新签名、应用元数据与归档校验通过")
}

private struct FeedConfig: Decodable {
    let feedURL: String?
    let publicKeys: [UpdatePublicKey]

    var repository: String? {
        guard let feed = feedURL, let url = URL(string: feed), url.host == "github.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 6, parts[2] == "releases", parts[3] == "latest", parts[4] == "download" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}

private func parseRequireInstallers(_ options: [String: String]) throws -> Bool {
    guard let raw = options["--require-installers"] else { return true }
    switch raw {
    case "true": return true
    case "false": return false
    default: throw ToolError.invalid("--require-installers 必须为 true 或 false")
    }
}

private func buildWindowsArchive(path: String, expectedName: String, repository: String, tag: String) throws -> UpdateArchive {
    let url = URL(fileURLWithPath: path)
    guard url.lastPathComponent == expectedName else {
        throw ToolError.invalid("Windows 归档文件名不匹配，期望 \(expectedName)，实际为 \(url.lastPathComponent)")
    }
    let (size, digest) = try archiveDigest(url)
    let downloadURL = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(expectedName)")!
    return UpdateArchive(url: downloadURL, size: size, sha256: digest)
}

private func signWindows(_ options: [String: String]) throws {
    let configURL = URL(fileURLWithPath: options["--config"] ?? "Resources/update-feed.json")
    let config = try JSONDecoder().decode(FeedConfig.self, from: Data(contentsOf: configURL))
    let appId = options["--app-id"] ?? WindowsUpdateManifest.productionAppID
    let version = try required("--version", in: options)
    _ = try UpdateVersion(version)
    let buildString = try required("--build", in: options)
    guard let build = Int(buildString), build > 0, String(build) == buildString else {
        throw ToolError.invalid("构建号无效")
    }
    let revision = options["--revision"] ?? ""
    let tag = try required("--tag", in: options)
    let repository = try required("--repository", in: options)
    guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
          tag == "v" + version else {
        throw ToolError.invalid("仓库或版本标签不一致")
    }
    if let configuredRepo = config.repository, configuredRepo != repository {
        throw ToolError.invalid("仓库与更新源配置不一致")
    }
    let requireInstallers = try parseRequireInstallers(options)
    if requireInstallers && (options["--x64-installer"] == nil || options["--arm64-installer"] == nil) {
        throw ToolError.invalid("缺少 Windows Setup 安装包参数（--x64-installer / --arm64-installer）")
    }
    let key = try signingKey()
    let trusted = try matchedKey(key, in: config.publicKeys)
    let x64Portable = try buildWindowsArchive(
        path: required("--x64-zip", in: options),
        expectedName: "QuietDesk-\(version)-Windows-x64.zip",
        repository: repository,
        tag: tag
    )
    let x64Installer = try options["--x64-installer"].map {
        try buildWindowsArchive(
            path: $0,
            expectedName: "QuietDesk-\(version)-Windows-x64-Setup.exe",
            repository: repository,
            tag: tag
        )
    }
    let arm64Portable = try buildWindowsArchive(
        path: required("--arm64-zip", in: options),
        expectedName: "QuietDesk-\(version)-Windows-arm64.zip",
        repository: repository,
        tag: tag
    )
    let arm64Installer = try options["--arm64-installer"].map {
        try buildWindowsArchive(
            path: $0,
            expectedName: "QuietDesk-\(version)-Windows-arm64-Setup.exe",
            repository: repository,
            tag: tag
        )
    }
    let notes = try options["--notes-file"].map { path in
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(4_000)))
    }
    let manifest = WindowsUpdateManifest(
        appId: appId,
        version: version,
        build: build,
        publishedAt: ISO8601DateFormatter().string(from: Date()),
        revision: revision,
        releaseNotesURL: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!,
        notes: notes,
        packages: [
            "x64": WindowsArchPackages(portable: x64Portable, installer: x64Installer),
            "arm64": WindowsArchPackages(portable: arm64Portable, installer: arm64Installer)
        ]
    )
    try manifest.validate(appId: appId, repository: repository)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(manifest)
    let signature = try key.signature(for: WindowsUpdateManifestVerifier.signingPrefix + payload)
    let envelope = SignedUpdateEnvelope(keyID: trusted.id, payload: payload.base64EncodedString(), signature: signature.base64EncodedString())
    let data = try encoder.encode(envelope)
    guard data.count <= UpdateManifestVerifier.maximumEnvelopeBytes else { throw ToolError.invalid("Windows 更新清单超过 64 KiB") }
    try data.write(to: URL(fileURLWithPath: required("--out", in: options)), options: .atomic)
    print("已签名 Windows 更新清单")
}

private func verifyWindows(_ options: [String: String]) throws {
    let configURL = URL(fileURLWithPath: options["--config"] ?? "Resources/update-feed.json")
    let config = try JSONDecoder().decode(FeedConfig.self, from: Data(contentsOf: configURL))
    let appId = options["--app-id"] ?? WindowsUpdateManifest.productionAppID
    let version = try required("--version", in: options)
    let buildString = try required("--build", in: options)
    guard let build = Int(buildString), build > 0, String(build) == buildString else {
        throw ToolError.invalid("构建号无效")
    }
    let expectedRevision = options["--revision"]
    let repository = options["--repository"] ?? config.repository ?? "nXiaoK/QuietDesk"
    let requireInstallers = try parseRequireInstallers(options)
    let manifestURL = URL(fileURLWithPath: try required("--manifest", in: options))
    let handle = try FileHandle(forReadingFrom: manifestURL)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: UpdateManifestVerifier.maximumEnvelopeBytes + 1) ?? Data()
    let result = try WindowsUpdateManifestVerifier.verify(data, publicKeys: config.publicKeys, appId: appId, repository: repository)
    guard case .supported(let manifest) = result,
          manifest.version == version,
          manifest.build == build,
          expectedRevision == nil || manifest.revision == expectedRevision,
          let x64 = manifest.packages["x64"],
          let arm64 = manifest.packages["arm64"] else {
        throw ToolError.invalid("Windows 清单与期望版本、构建号或架构表不一致")
    }
    let x64Zip = try archiveDigest(URL(fileURLWithPath: required("--x64-zip", in: options)))
    let arm64Zip = try archiveDigest(URL(fileURLWithPath: required("--arm64-zip", in: options)))
    guard x64Zip.0 == x64.portable.size, x64Zip.1 == x64.portable.sha256,
          arm64Zip.0 == arm64.portable.size, arm64Zip.1 == arm64.portable.sha256 else {
        throw ToolError.invalid("Windows 便携包大小或 SHA-256 不匹配")
    }
    if requireInstallers && (x64.installer == nil || arm64.installer == nil || options["--x64-installer"] == nil || options["--arm64-installer"] == nil) {
        throw ToolError.invalid("Windows 清单或校验参数缺少 Setup 安装包")
    }
    if let x64InstallerPath = options["--x64-installer"] {
        guard let recorded = x64.installer else { throw ToolError.invalid("Windows 清单缺少 x64 安装包记录") }
        let actual = try archiveDigest(URL(fileURLWithPath: x64InstallerPath))
        guard actual.0 == recorded.size, actual.1 == recorded.sha256 else {
            throw ToolError.invalid("Windows x64 安装包大小或 SHA-256 不匹配")
        }
    }
    if let arm64InstallerPath = options["--arm64-installer"] {
        guard let recorded = arm64.installer else { throw ToolError.invalid("Windows 清单缺少 arm64 安装包记录") }
        let actual = try archiveDigest(URL(fileURLWithPath: arm64InstallerPath))
        guard actual.0 == recorded.size, actual.1 == recorded.sha256 else {
            throw ToolError.invalid("Windows arm64 安装包大小或 SHA-256 不匹配")
        }
    }
    print("Windows 更新签名、版本元数据与全部安装包校验通过")
}

private func checkKey(_ options: [String: String]) -> Int32 {
    do {
        struct Configuration: Decodable { let publicKeys: [UpdatePublicKey] }
        let url = URL(fileURLWithPath: try required("--config", in: options))
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard !config.publicKeys.isEmpty else { print("缺失"); return 0 }
        guard let value = ProcessInfo.processInfo.environment["QUIETDESK_UPDATE_SIGNING_KEY"], !value.isEmpty else { print("缺失"); return 1 }
        _ = try matchedKey(signingKey(), in: config.publicKeys)
        print("匹配")
        return 0
    } catch {
        print("不匹配")
        return 1
    }
}

do {
    let (command, options) = try arguments()
    switch command {
    case "generate-key": try generateKey(to: required("--out", in: options))
    case "sign": try sign(options)
    case "verify": try verify(options)
    case "sign-windows": try signWindows(options)
    case "verify-windows": try verifyWindows(options)
    case "check-key": exit(checkKey(options))
    default: break
    }
} catch {
    FileHandle.standardError.write(Data("更新工具失败: \(error)\n".utf8))
    exit(1)
}
