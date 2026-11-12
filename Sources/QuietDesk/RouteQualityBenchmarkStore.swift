import Foundation
import QuietDeskCore

@MainActor
final class RouteQualityBenchmarkStore: ObservableObject {
    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.folderName(), isDirectory: true)
            .appendingPathComponent("route-benchmark-history.json")
    }

    let fileURL: URL
    @Published private(set) var archive: RouteBenchmarkHistoryArchive
    @Published private(set) var warningMessage: String?
    private let protectsUnreadFile: Bool

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL
        self.fileURL = resolvedURL
        let loaded = RouteBenchmarkHistoryPersistence.load(from: resolvedURL)
        self.archive = loaded.archive
        self.protectsUnreadFile = loaded.protectsUnreadFile
        self.warningMessage = loaded.warningMessage
    }

    func record(_ run: RouteBenchmarkRunRecord) {
        archive.record(run)
        persistIfAllowed()
    }

    func removeRun(id: UUID) {
        archive.removeRun(id: id)
        persistIfAllowed()
    }

    func removeRuns(matching target: RouteBenchmarkTargetDescriptor) {
        archive.removeRuns(matching: target)
        persistIfAllowed()
    }

    func removeAll() {
        archive.removeAll()
        persistIfAllowed()
    }

    private func persistIfAllowed() {
        guard !protectsUnreadFile else { return }
        do {
            try RouteBenchmarkHistoryPersistence.save(archive, to: fileURL)
            warningMessage = nil
        } catch {
            warningMessage = "历史测速记录尚未写入磁盘：\(error.localizedDescription)。本次结果仍保留在当前会话内存中。"
        }
    }
}
