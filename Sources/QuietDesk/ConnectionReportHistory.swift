import Combine
import Darwin
import Foundation
import QuietDeskCore

@MainActor
final class ConnectionReportHistoryFeed: ObservableObject {
    @Published private(set) var reports: [ConnectionDiagnosticReport] = []
    @Published private(set) var error: String?

    func update(reports: [ConnectionDiagnosticReport], error: String?) {
        if self.reports != reports { self.reports = reports }
        if self.error != error { self.error = error }
    }
}

final class ConnectionReportHistoryStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let reports: [ConnectionDiagnosticReport]
    }

    private static let limit = 100
    private let url: URL
    private let queue = DispatchQueue(label: "quietdesk.connection-report-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var reports: [ConnectionDiagnosticReport] = []
    private var protectsUnreadFile = false
    private var dirty = false
    private var loadError: String?
    private var writeError: String?
    private var observer: (([ConnectionDiagnosticReport], String?) -> Void)?
    private var error: String? { loadError ?? writeError }

    init(directory: URL = TrafficHistoryStore.defaultDirectory) {
        url = directory.appendingPathComponent("session-reports-v1.json")
        queue.setSpecific(key: queueKey, value: true)
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else {
                protectFile("连接报告历史文件版本不受支持")
                return
            }
            guard Set(document.reports.map(\.id)).count == document.reports.count else {
                protectFile("连接报告历史含重复记录")
                return
            }
            reports = Self.latest(document.reports)
        } catch {
            let failure = error as NSError
            if failure.domain != NSCocoaErrorDomain
                || (failure.code != NSFileNoSuchFileError && failure.code != NSFileReadNoSuchFileError) {
                protectFile("无法读取连接报告历史")
            }
        }
    }

    func observe(_ callback: @escaping ([ConnectionDiagnosticReport], String?) -> Void) {
        queue.async {
            self.observer = callback
            self.publish()
        }
    }

    func append(_ report: ConnectionDiagnosticReport) {
        queue.async {
            self.reports.removeAll { $0.id == report.id }
            self.reports.append(report)
            self.reports = Self.latest(self.reports)
            self.didChange()
        }
    }

    func delete(id: UUID) {
        queue.async {
            guard let index = self.reports.firstIndex(where: { $0.id == id }) else { return }
            self.reports.remove(at: index)
            self.didChange()
        }
    }

    func clearAll() {
        queue.async {
            guard !self.reports.isEmpty else { return }
            self.reports.removeAll()
            self.didChange()
        }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) == true { checkpointAndPublish() }
        else { queue.sync { checkpointAndPublish() } }
    }

    func snapshot() -> (reports: [ConnectionDiagnosticReport], error: String?) {
        if DispatchQueue.getSpecific(key: queueKey) == true { return (reports, error) }
        return queue.sync { (reports, error) }
    }

    private static func latest(_ reports: [ConnectionDiagnosticReport]) -> [ConnectionDiagnosticReport] {
        Array(reports.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }.prefix(limit))
    }

    private func protectFile(_ message: String) {
        protectsUnreadFile = true
        loadError = "\(message)。已保留原文件，新报告暂存内存，尚未写入磁盘。"
    }

    private func didChange() {
        dirty = true
        checkpointAndPublish()
    }

    private func checkpointAndPublish() {
        if dirty, !protectsUnreadFile {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(Document(version: 1, reports: reports))
                try writePrivately(data)
                dirty = false
                writeError = nil
            } catch {
                writeError = "连接报告历史尚未保存。新记录已保留在内存中，将在下次保存时重试。"
            }
        }
        publish()
    }

    private func writePrivately(_ data: Data) throws {
        let pending = url.deletingLastPathComponent().appendingPathComponent(".session-reports-\(UUID().uuidString)")
        let descriptor = open(pending.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: pending)
        }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(pending.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func publish() { observer?(reports, error) }
}
