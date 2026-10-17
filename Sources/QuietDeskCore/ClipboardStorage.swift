import Foundation
import Darwin

// A live process holds the lease while any of its transfers can use this directory.
final class ClipboardPartialStorage {
    let directory: URL
    private let descriptor: Int32

    init(storage: URL) throws {
        let partial = storage.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = partial.appendingPathComponent("instance-" + UUID().uuidString, isDirectory: true)
        var descriptor: Int32 = -1
        try Self.withDirectoryLock(storage: storage) {
            try Self.removeAbandonedUnlocked(partial: partial)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lease = directory.appendingPathComponent(".lease")
            descriptor = Darwin.open(lease.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: directory)
                throw DeskError.system("无法创建接收目录锁", code)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: directory)
                throw DeskError.system("无法锁定接收目录", code)
            }
        }
        self.directory = directory
        self.descriptor = descriptor
    }

    static func removeAbandoned(storage: URL) throws {
        let partial = storage.appendingPathComponent("partial", isDirectory: true)
        guard FileManager.default.fileExists(atPath: partial.path) else { return }
        try withDirectoryLock(storage: storage) { try removeAbandonedUnlocked(partial: partial) }
    }

    private static func withDirectoryLock(storage: URL, _ body: () throws -> Void) throws {
        let path = storage.appendingPathComponent(".partial-cleanup.lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DeskError.system("无法打开接收目录管理锁", errno) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw DeskError.system("无法锁定接收目录管理", errno) }
        try body()
    }

    private static func removeAbandonedUnlocked(partial: URL) throws {
        let folders = try FileManager.default.contentsOfDirectory(at: partial,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for folder in folders {
            let name = folder.lastPathComponent
            guard name.hasPrefix("instance-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            // Legacy transfer folders might still belong to an older running app.
            let descriptor = Darwin.open(folder.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }
            var attributes = stat()
            guard Darwin.fstat(descriptor, &attributes) == 0,
                  attributes.st_mode & S_IFMT == S_IFREG,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func availableCapacity(at storage: URL) throws -> UInt64 {
        let important = (try? storage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap(\.volumeAvailableCapacityForImportantUsage).flatMap { $0 >= 0 ? UInt64($0) : nil }
        let physical = (try? FileManager.default.attributesOfFileSystem(forPath: storage.path))?[.systemFreeSize] as? NSNumber
        if let physical { return max(physical.uint64Value, important ?? 0) }
        if let important { return important }
        throw DeskError.invalid("无法检查接收目录的可用磁盘空间")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        Darwin.close(descriptor)
    }
}
