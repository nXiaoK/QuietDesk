import Foundation
import QuietDeskCore

private func isMissingTrafficFile(_ error: Error) -> Bool {
    let value = error as NSError
    return value.domain == NSCocoaErrorDomain
        && (value.code == NSFileNoSuchFileError || value.code == NSFileReadNoSuchFileError)
}

enum LocalDeviceIdentity {
    private struct Document: Codable { let version: Int; let id: UUID }

    static func load(at url: URL) throws -> UUID {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            guard isMissingTrafficFile(error) else { throw error }
            let id = UUID()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Document(version: 1, id: id)).write(to: url, options: .atomic)
            return id
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw DeskError.invalid("设备标识文件版本不受支持") }
        return document.id
    }
}

final class TrafficHistoryStore: @unchecked Sendable {
    private struct Document: Codable { let version: Int; let records: [EndpointTrafficRecord] }
    private struct LegacyDocument: Decodable { let version: Int; let records: [DeviceTrafficRecord] }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppDataLocation.folderName(), isDirectory: true)
    }
    let localDeviceID: UUID?
    private let url: URL
    private let queue = DispatchQueue(label: "quietdesk.traffic-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var records: [TrafficEndpoint: EndpointTrafficRecord] = [:]
    private var legacyRecords: [DeviceTrafficRecord] = []
    private var legacyError: String?
    private var dirty = false
    private var unpublished = false
    private var protectsUnreadFile = false
    private var identityError: String?
    private var loadError: String?
    private var writeError: String?
    private var countingError: String?
    private var observer: (([EndpointTrafficRecord], [DeviceTrafficRecord], String?) -> Void)?

    init(directory: URL = TrafficHistoryStore.defaultDirectory, checkpointInterval: TimeInterval = 1) {
        url = directory.appendingPathComponent("traffic-history-v2.json")
        do { localDeviceID = try LocalDeviceIdentity.load(at: directory.appendingPathComponent("device-identity.json")) }
        catch {
            localDeviceID = nil
            identityError = "本机设备标识不可用：\(error.localizedDescription)。已保留原文件，本机暂不交换设备标识。"
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 2 else { throw DeskError.invalid("地址流量文件版本不受支持") }
            for record in document.records {
                guard records[record.id] == nil else { throw DeskError.invalid("地址流量文件含重复地址和端口") }
                records[record.id] = record
            }
        } catch {
            if !isMissingTrafficFile(error) {
                records = [:]
                protectsUnreadFile = true
                loadError = "历史流量读取失败：\(error.localizedDescription)。已保留原文件，新增统计暂存内存，尚未写入磁盘。"
            }
        }
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("traffic-history.json"))
            let document = try JSONDecoder().decode(LegacyDocument.self, from: data)
            guard document.version == 1 else { throw DeskError.invalid("旧版设备流量文件版本不受支持") }
            var identifiers = Set<UUID>()
            for var record in document.records {
                guard identifiers.insert(record.id).inserted else { throw DeskError.invalid("旧版设备流量含重复设备标识") }
                record.name = DeviceIdentity(id: record.id, name: record.name).displayName
                legacyRecords.append(record)
            }
            legacyRecords.sort { $0.lastSeen > $1.lastSeen }
        } catch {
            if !isMissingTrafficFile(error) {
                legacyRecords = []
                legacyError = "旧版设备流量读取失败：\(error.localizedDescription)。原文件保持不变，新增地址统计单独保存。"
            }
        }
        queue.setSpecific(key: queueKey, value: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + checkpointInterval, repeating: checkpointInterval)
        timer.setEventHandler { [weak self] in self?.checkpointAndPublish() }
        self.timer = timer
        timer.resume()
    }

    func observe(_ callback: @escaping ([EndpointTrafficRecord], [DeviceTrafficRecord], String?) -> Void) {
        queue.async { self.observer = callback; self.publish() }
    }

    func record(_ endpoint: TrafficEndpoint, delta: TrafficTotals, at date: Date = Date()) {
        queue.async {
            self.unpublished = true
            var record = self.records[endpoint]
                ?? EndpointTrafficRecord(endpoint: endpoint, firstSeen: date, lastSeen: date)
            do { try record.totals.add(delta) }
            catch { self.countingError = error.localizedDescription; self.publish(); return }
            record.lastSeen = max(record.lastSeen, date)
            self.records[endpoint] = record
            self.dirty = true
        }
    }

    func reportCountingError(_ message: String) {
        queue.async { self.countingError = message; self.unpublished = true; self.publish() }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) == true { checkpointAndPublish(forcePublish: true) }
        else { queue.sync { self.checkpointAndPublish(forcePublish: true) } }
    }

    func requestFlush() {
        queue.async { self.checkpointAndPublish(forcePublish: true) }
    }

    func snapshot() -> (records: [EndpointTrafficRecord], legacyRecords: [DeviceTrafficRecord], error: String?) {
        if DispatchQueue.getSpecific(key: queueKey) == true { return (orderedRecords, legacyRecords, combinedError) }
        return queue.sync { (orderedRecords, legacyRecords, combinedError) }
    }

    private var orderedRecords: [EndpointTrafficRecord] {
        records.values.sorted { $0.lastSeen == $1.lastSeen ? $0.endpoint.label < $1.endpoint.label : $0.lastSeen > $1.lastSeen }
    }
    private var combinedError: String? {
        let messages = [identityError, loadError, legacyError, writeError, countingError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func checkpointAndPublish(forcePublish: Bool = false) {
        let previousWriteError = writeError
        if dirty, !protectsUnreadFile {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Document(version: 2, records: orderedRecords))
                try data.write(to: url, options: .atomic)
                dirty = false
                writeError = nil
            } catch { writeError = "历史流量尚未保存：\(error.localizedDescription)。正在保留内存统计并重试。" }
        }
        if writeError != previousWriteError { unpublished = true }
        if unpublished || forcePublish { publish() }
    }

    private func publish() {
        unpublished = false
        observer?(orderedRecords, legacyRecords, combinedError)
    }
    deinit { timer?.cancel() }
}
