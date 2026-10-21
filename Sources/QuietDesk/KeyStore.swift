import Foundation
import Darwin
import QuietDeskCore

enum KeyStore {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(AppDataLocation.folderName())/Credentials", isDirectory: true)
    private static let store = LocalCredentialStore(directory: directory)
    // Other secrets live in their own file: older versions reject a pairing-code file holding anything else.
    private static let secrets = LocalCredentialStore(directory: directory, filename: "session-secrets.json", holdsPairingCodes: false)

    static func load(account: String = "host") throws -> PairingKey? {
        try store.load(account: account)
    }

    static func save(_ key: PairingKey, account: String = "host") throws {
        try store.save(key, account: account)
    }

    static func remove(account: String = "host") throws {
        try store.remove(account: account)
    }

    static func loadSecret(account: String) throws -> String? { try secrets.loadSecret(account: account) }
    static func saveSecret(_ value: String, account: String) throws { try secrets.saveSecret(value, account: account) }
    static func removeSecret(account: String) throws { try secrets.remove(account: account) }
}

// Codes are plaintext JSON protected by the current account's file permissions, not encryption.
// This store deliberately never reads, migrates or deletes existing Keychain items.
struct LocalCredentialStore: Sendable {
    static let maximumSecretLength = 1024
    let directory: URL
    var filename = "pairing-codes.json"
    /// False for a file of other secrets, whose values are only checked for size.
    var holdsPairingCodes = true
    private static let lockFilename = ".lock"

    private struct Document: Codable {
        let version: Int
        var codes: [String: String]
    }

    private struct Identity {
        let device: dev_t
        let inode: ino_t
    }

    private struct Snapshot {
        var document: Document
        let identity: Identity?
    }

    func load(account: String = "host") throws -> PairingKey? {
        try withLockedDirectory { descriptor in
            guard let code = try read(descriptor).document.codes[account] else { return nil }
            return try PairingKey(code: code)
        }
    }

    func save(_ key: PairingKey, account: String = "host") throws {
        try withLockedDirectory { descriptor in
            removeStaleTemporaryFiles(in: descriptor)
            var snapshot = try read(descriptor)
            guard snapshot.document.codes[account] != key.code else { return }
            snapshot.document.codes[account] = key.code
            try write(snapshot, to: descriptor)
        }
    }

    func loadSecret(account: String) throws -> String? {
        try withLockedDirectory { descriptor in try read(descriptor).document.codes[account] }
    }

    func saveSecret(_ value: String, account: String) throws {
        guard !value.isEmpty, value.count <= Self.maximumSecretLength else { throw DeskError.invalid("要保存的凭据为空或过长") }
        try withLockedDirectory { descriptor in
            removeStaleTemporaryFiles(in: descriptor)
            var snapshot = try read(descriptor)
            guard snapshot.document.codes[account] != value else { return }
            snapshot.document.codes[account] = value
            try write(snapshot, to: descriptor)
        }
    }

    func remove(account: String = "host") throws {
        try withLockedDirectory { descriptor in
            removeStaleTemporaryFiles(in: descriptor)
            var snapshot = try read(descriptor)
            guard snapshot.document.codes.removeValue(forKey: account) != nil else { return }
            try write(snapshot, to: descriptor)
        }
    }

    private func withLockedDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let directoryDescriptor = try openDirectory()
        defer { close(directoryDescriptor) }
        let lockFlags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var lock = openat(directoryDescriptor, Self.lockFilename, lockFlags)
        if lock < 0 && errno == ENOENT {
            lock = openat(directoryDescriptor, Self.lockFilename, lockFlags | O_CREAT | O_EXCL, mode_t(0o600))
            if lock < 0 && errno == EEXIST {
                lock = openat(directoryDescriptor, Self.lockFilename, lockFlags)
            }
        }
        guard lock >= 0 else { throw failure("无法打开本机\(label)文件锁") }
        defer { close(lock) }
        try validatePrivateFile(lock)
        while flock(lock, LOCK_EX) != 0 {
            guard errno == EINTR else { throw failure("无法锁定本机\(label)文件") }
        }
        defer { flock(lock, LOCK_UN) }
        var locked = stat()
        guard fstat(lock, &locked) == 0 else { throw failure("无法检查本机\(label)文件锁") }
        try verifyEntry(Self.lockFilename, in: directoryDescriptor,
                        expected: Identity(device: locked.st_dev, inode: locked.st_ino))
        return try body(directoryDescriptor)
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw DeskError.invalid("本机\(label)目录必须是绝对文件路径")
        }
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw DeskError.invalid("本机\(label)目录路径无效")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("无法打开本机\(label)目录") }
        do {
            for (index, component) in components.enumerated() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw failure("无法创建本机\(label)目录")
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("本机\(label)目录不可用，拒绝符号链接或非目录路径") }
                close(descriptor)
                descriptor = next
                if index == components.count - 1 {
                    var info = stat()
                    guard fstat(descriptor, &info) == 0 else { throw failure("无法检查本机\(label)目录") }
                    guard info.st_uid == geteuid() else {
                        throw DeskError.invalid("本机\(label)目录不属于当前账户，已停止访问")
                    }
                    guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw failure("无法保护本机\(label)目录") }
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validatePrivateFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("无法检查本机\(label)文件") }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
            throw DeskError.invalid("本机\(label)文件类型或所有者异常，已停止访问")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw failure("无法保护本机\(label)文件") }
    }

    private func read(_ directoryDescriptor: Int32) throws -> Snapshot {
        let descriptor = openat(directoryDescriptor, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 && errno == ENOENT {
            return Snapshot(document: Document(version: 1, codes: [:]), identity: nil)
        }
        guard descriptor >= 0 else { throw failure("无法读取本机\(label)文件，拒绝符号链接或异常路径") }
        defer { close(descriptor) }
        try validatePrivateFile(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("无法检查本机\(label)文件") }
        let identity = Identity(device: info.st_dev, inode: info.st_ino)
        try verifyEntry(filename, in: directoryDescriptor, expected: identity)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("无法读取本机\(label)文件") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw damagedFile()
        }
        guard document.version == 1 else {
            throw DeskError.invalid("本机\(label)文件版本不受支持，已保留原文件。请备份并移走 Credentials/\(filename) 后重新填写。")
        }
        do {
            for code in document.codes.values {
                if holdsPairingCodes { _ = try PairingKey(code: code) }
                else if code.isEmpty || code.count > Self.maximumSecretLength { throw damagedFile() }
            }
        } catch {
            throw damagedFile()
        }
        return Snapshot(document: document, identity: identity)
    }

    private func removeStaleTemporaryFiles(in directoryDescriptor: Int32) {
        let descriptor = dup(directoryDescriptor)
        guard descriptor >= 0 else { return }
        guard let directory = fdopendir(descriptor) else { close(descriptor); return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            var bytes = entry.pointee.d_name
            let name = withUnsafePointer(to: &bytes) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name.hasPrefix(".pairing-"), name.hasSuffix(".tmp") else { continue }
            let identifier = name.dropFirst(".pairing-".count).dropLast(".tmp".count)
            guard identifier.utf8.count == 36, UUID(uuidString: String(identifier)) != nil else { continue }
            var info = stat()
            guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else { continue }
            _ = unlinkat(directoryDescriptor, name, 0)
        }
    }

    private func write(_ snapshot: Snapshot, to directoryDescriptor: Int32) throws {
        let data = try JSONEncoder().encode(snapshot.document)
        let temporaryName = ".pairing-" + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryDescriptor, temporaryName,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure("无法保存本机\(label)文件") }
        var committed = false
        defer {
            close(descriptor)
            if !committed { unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        try validatePrivateFile(descriptor)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("无法写入本机\(label)文件", code: count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure("无法同步本机\(label)文件") }
        try verifyEntry(filename, in: directoryDescriptor, expected: snapshot.identity)
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, filename) == 0 else {
            throw failure("无法替换本机\(label)文件，原文件已保留")
        }
        committed = true
        // The rename is the commit point. Directory sync is best effort after a successful commit.
        _ = fsync(directoryDescriptor)
    }

    private func verifyEntry(_ name: String, in directoryDescriptor: Int32, expected: Identity?) throws {
        var info = stat()
        let result = fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW)
        if result < 0 && errno == ENOENT && expected == nil { return }
        guard result == 0 else { throw failure("本机\(label)文件在访问时发生变化，请重试") }
        guard let expected, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev == expected.device, info.st_ino == expected.inode, info.st_nlink == 1 else {
            throw DeskError.invalid("本机\(label)文件在访问时发生变化或路径异常，已保留原文件")
        }
    }

    private var label: String { holdsPairingCodes ? "配对码" : "会话凭据" }

    private func damagedFile() -> DeskError {
        DeskError.invalid(holdsPairingCodes ? "本机配对码文件已损坏，已保留原文件。请备份并移走 Credentials/\(filename) 后重新填写配对码。"
            : "本机会话凭据文件已损坏，已保留原文件。请备份并移走 Credentials/\(filename) 后重新保存。")
    }

    private func failure(_ message: String, code: Int32 = errno) -> DeskError {
        .system(message, code)
    }
}
