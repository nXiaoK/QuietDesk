import Foundation

public struct SessionEffectsState: Codable, Equatable, Sendable {
    public let muted: Bool
    public let privacy: Bool
    /// Lock the host screen as soon as this control session ends. Endpoints without the field mean off.
    public let lockOnDisconnect: Bool
    public init(muted: Bool = false, privacy: Bool = false, lockOnDisconnect: Bool = false) {
        self.muted = muted; self.privacy = privacy; self.lockOnDisconnect = lockOnDisconnect
    }

    private enum CodingKeys: String, CodingKey { case muted, privacy, lockOnDisconnect }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        muted = try container.decode(Bool.self, forKey: .muted)
        privacy = try container.decode(Bool.self, forKey: .privacy)
        lockOnDisconnect = try container.decodeIfPresent(Bool.self, forKey: .lockOnDisconnect) ?? false
    }
}

public struct SessionEffectsRequest: Codable, Sendable {
    public let id: UUID
    public let state: SessionEffectsState
    public init(id: UUID = UUID(), state: SessionEffectsState) { self.id = id; self.state = state }
}

public struct SessionEffectsResult: Codable, Sendable {
    public let id: UUID?
    public let state: SessionEffectsState
    public let error: String?
    public init(id: UUID? = nil, state: SessionEffectsState, error: String? = nil) {
        self.id = id; self.state = state; self.error = error
    }
}

/// Viewer-side memory of the effects the user switched on, requested again when each new connection is ready.
/// Switching an effect off is remembered at once, so a lost reply cannot bring it back on the next connection.
/// Switching one on is remembered as the host actually applied it, so a failed attempt is not repeated.
public struct SessionEffectsMemory: Sendable {
    public private(set) var remembered: SessionEffectsState
    private var pending: (id: UUID, muted: Bool, privacy: Bool, lock: Bool)?

    public init(remembered: SessionEffectsState = SessionEffectsState()) { self.remembered = remembered }

    /// The state a new connection requests, or nil when nothing is remembered.
    public var connectionState: SessionEffectsState? { remembered == SessionEffectsState() ? nil : remembered }

    /// Records a user toggle that changes `current` into `request.state`.
    public mutating func requested(_ request: SessionEffectsRequest, from current: SessionEffectsState) {
        let next = request.state
        remembered = SessionEffectsState(muted: remembered.muted && !(current.muted && !next.muted),
                                         privacy: remembered.privacy && !(current.privacy && !next.privacy),
                                         lockOnDisconnect: remembered.lockOnDisconnect && !(current.lockOnDisconnect && !next.lockOnDisconnect))
        pending = (request.id, !current.muted && next.muted, !current.privacy && next.privacy,
                   !current.lockOnDisconnect && next.lockOnDisconnect)
    }

    /// Applies the host's reply to the recorded toggle; replies to other requests leave the memory unchanged.
    public mutating func confirmed(_ result: SessionEffectsResult) {
        guard let pending, result.id == pending.id else { return }
        self.pending = nil
        remembered = SessionEffectsState(muted: pending.muted ? result.state.muted : remembered.muted,
                                         privacy: pending.privacy ? result.state.privacy : remembered.privacy,
                                         lockOnDisconnect: pending.lock ? result.state.lockOnDisconnect : remembered.lockOnDisconnect)
    }

    /// Drops a recorded toggle whose reply can no longer arrive.
    public mutating func cancel() { pending = nil }
}

public struct SessionMuteSnapshot: Codable, Equatable, Sendable {
    public let deviceUID: String
    public let originallyMuted: Bool
    public init(deviceUID: String, originallyMuted: Bool) {
        self.deviceUID = deviceUID; self.originallyMuted = originallyMuted
    }
}

public protocol SessionMuteDeviceIO {
    func currentOutputDeviceUIDs() throws -> [String]
    func muteValue(for deviceUID: String) throws -> Bool
    func canSetMute(for deviceUID: String) throws -> Bool
    func setMuted(_ muted: Bool, for deviceUID: String) throws
}

public struct SessionMuteTransaction {
    public private(set) var snapshots: [SessionMuteSnapshot]
    public private(set) var isMuted = false
    private var changedDevices = Set<String>()

    private init(snapshots: [SessionMuteSnapshot]) { self.snapshots = snapshots }

    public init(recovering snapshots: [SessionMuteSnapshot]) {
        self.snapshots = snapshots
        changedDevices = Set(snapshots.filter { !$0.originallyMuted }.map(\.deviceUID))
        isMuted = !changedDevices.isEmpty
    }

    public static func prepare(using io: SessionMuteDeviceIO) throws -> SessionMuteTransaction {
        let devices = Array(Set(try io.currentOutputDeviceUIDs())).sorted()
        guard !devices.isEmpty else { throw DeskError.invalid("没有可用的默认音频输出设备") }
        let snapshots = try devices.map { uid in
            guard try io.canSetMute(for: uid) else { throw DeskError.invalid("当前音频输出设备不支持系统静音") }
            return SessionMuteSnapshot(deviceUID: uid, originallyMuted: try io.muteValue(for: uid))
        }
        return SessionMuteTransaction(snapshots: snapshots)
    }

    public mutating func mute(using io: SessionMuteDeviceIO) throws {
        guard !isMuted else { return }
        guard Set(try io.currentOutputDeviceUIDs()) == Set(snapshots.map(\.deviceUID)) else {
            throw DeskError.invalid("音频输出设备已变化，请重新开启会话静音")
        }
        for snapshot in snapshots {
            guard try io.canSetMute(for: snapshot.deviceUID),
                  try io.muteValue(for: snapshot.deviceUID) == snapshot.originallyMuted else {
                throw DeskError.invalid("音频输出状态已变化，请重新开启会话静音")
            }
        }
        do {
            for snapshot in snapshots where !snapshot.originallyMuted {
                changedDevices.insert(snapshot.deviceUID)
                try io.setMuted(true, for: snapshot.deviceUID)
            }
            isMuted = true
        } catch {
            let original = error.localizedDescription
            do { try restore(using: io) }
            catch { throw DeskError.invalid("\(original)；恢复静音失败：\(error.localizedDescription)") }
            throw DeskError.invalid(original)
        }
    }

    public mutating func restore(using io: SessionMuteDeviceIO) throws {
        var errors: [String] = []
        for snapshot in snapshots where changedDevices.contains(snapshot.deviceUID) {
            do {
                if try io.muteValue(for: snapshot.deviceUID) { try io.setMuted(false, for: snapshot.deviceUID) }
                changedDevices.remove(snapshot.deviceUID)
            } catch { errors.append(error.localizedDescription) }
        }
        isMuted = !changedDevices.isEmpty
        if !errors.isEmpty { throw DeskError.invalid(errors.joined(separator: "；")) }
    }
}
