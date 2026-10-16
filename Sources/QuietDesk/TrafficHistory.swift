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
    private struct Document: Codable { let version: Int; let records: [DeviceTrafficRecord] }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuietDesk", isDirectory: true)
    }
    let localDeviceID: UUID?
    private let url: URL
    private let queue = DispatchQueue(label: "quietdesk.traffic-history", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var records: [UUID: DeviceTrafficRecord] = [:]
    private var dirty = false
    private var protectsUnreadFile = false
    private var identityError: String?
    private var loadError: String?
    private var writeError: String?
    private var countingError: String?
    private var observer: (([DeviceTrafficRecord], String?) -> Void)?

    init(directory: URL = TrafficHistoryStore.defaultDirectory, checkpointInterval: TimeInterval = 1) {
        url = directory.appendingPathComponent("traffic-history.json")
        do { localDeviceID = try LocalDeviceIdentity.load(at: directory.appendingPathComponent("device-identity.json")) }
        catch {
            localDeviceID = nil
            identityError = "本机设备标识不可用：\(error.localizedDescription)。已保留原文件，本机暂不交换设备标识。"
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw DeskError.invalid("历史流量文件版本不受支持") }
            for var record in document.records {
                guard records[record.id] == nil else { throw DeskError.invalid("历史流量文件含重复设备标识") }
                record.name = DeviceIdentity(id: record.id, name: record.name).displayName
                records[record.id] = record
            }
        } catch {
            if !isMissingTrafficFile(error) {
                records = [:]
                protectsUnreadFile = true
                loadError = "历史流量读取失败：\(error.localizedDescription)。已保留原文件，新增统计暂存内存，尚未写入磁盘。"
            }
        }
        queue.setSpecific(key: queueKey, value: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + checkpointInterval, repeating: checkpointInterval)
        timer.setEventHandler { [weak self] in self?.checkpointAndPublish() }
        self.timer = timer
        timer.resume()
    }

    func observe(_ callback: @escaping ([DeviceTrafficRecord], String?) -> Void) {
        queue.async { self.observer = callback; self.publish() }
    }

    func record(_ identity: DeviceIdentity, delta: TrafficTotals, at date: Date = Date()) {
        queue.async {
            var record = self.records[identity.id]
                ?? DeviceTrafficRecord(id: identity.id, name: identity.displayName, firstSeen: date, lastSeen: date)
            do { try record.totals.add(delta) }
            catch { self.countingError = error.localizedDescription; self.publish(); return }
            record.name = identity.displayName
            record.lastSeen = max(record.lastSeen, date)
            self.records[identity.id] = record
            self.dirty = true
        }
    }

    func reportCountingError(_ message: String) {
        queue.async { self.countingError = message; self.publish() }
    }

    func flush() {
        if DispatchQueue.getSpecific(key: queueKey) == true { checkpointAndPublish(forcePublish: true) }
        else { queue.sync { self.checkpointAndPublish(forcePublish: true) } }
    }

    func requestFlush() {
        queue.async { self.checkpointAndPublish(forcePublish: true) }
    }

    func snapshot() -> (records: [DeviceTrafficRecord], error: String?) {
        if DispatchQueue.getSpecific(key: queueKey) == true { return (orderedRecords, combinedError) }
        return queue.sync { (orderedRecords, combinedError) }
    }

    private var orderedRecords: [DeviceTrafficRecord] {
        records.values.sorted { $0.lastSeen == $1.lastSeen ? $0.id.uuidString < $1.id.uuidString : $0.lastSeen > $1.lastSeen }
    }
    private var combinedError: String? {
        let messages = [identityError, loadError, writeError, countingError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func checkpointAndPublish(forcePublish: Bool = false) {
        guard dirty else { if forcePublish { publish() }; return }
        if !protectsUnreadFile {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(Document(version: 1, records: orderedRecords))
                try data.write(to: url, options: .atomic)
                dirty = false
                writeError = nil
            } catch { writeError = "历史流量尚未保存：\(error.localizedDescription)。正在保留内存统计并重试。" }
        }
        publish()
    }

    private func publish() { observer?(orderedRecords, combinedError) }
    deinit { timer?.cancel() }
}
