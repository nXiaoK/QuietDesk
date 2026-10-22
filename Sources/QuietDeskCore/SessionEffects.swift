import Foundation

public struct SessionEffectsState: Codable, Equatable, Sendable {
    public let muted: Bool
    public let privacy: Bool
    /// Lock the host screen as soon as this control session ends. Endpoints without the field mean off.
    public let lockOnDisconnect: Bool
    /// Turn the host laptop's built-in display brightness down to zero. Endpoints without the field mean off.
    public let dimBuiltInDisplay: Bool
    public init(muted: Bool = false, privacy: Bool = false, lockOnDisconnect: Bool = false, dimBuiltInDisplay: Bool = false) {
        self.muted = muted; self.privacy = privacy; self.lockOnDisconnect = lockOnDisconnect
        self.dimBuiltInDisplay = dimBuiltInDisplay
    }

    private enum CodingKeys: String, CodingKey { case muted, privacy, lockOnDisconnect, dimBuiltInDisplay }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        muted = try container.decode(Bool.self, forKey: .muted)
        privacy = try container.decode(Bool.self, forKey: .privacy)
        lockOnDisconnect = try container.decodeIfPresent(Bool.self, forKey: .lockOnDisconnect) ?? false
        dimBuiltInDisplay = try container.decodeIfPresent(Bool.self, forKey: .dimBuiltInDisplay) ?? false
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
    private var pending: (id: UUID, muted: Bool, privacy: Bool, lock: Bool, dim: Bool)?

    public init(remembered: SessionEffectsState = SessionEffectsState()) { self.remembered = remembered }

    /// The state a new connection requests, or nil when nothing is remembered.
    public var connectionState: SessionEffectsState? { remembered == SessionEffectsState() ? nil : remembered }

    /// Records a user toggle that changes `current` into `request.state`.
    public mutating func requested(_ request: SessionEffectsRequest, from current: SessionEffectsState) {
        let next = request.state
        remembered = SessionEffectsState(muted: remembered.muted && !(current.muted && !next.muted),
                                         privacy: remembered.privacy && !(current.privacy && !next.privacy),
                                         lockOnDisconnect: remembered.lockOnDisconnect && !(current.lockOnDisconnect && !next.lockOnDisconnect),
                                         dimBuiltInDisplay: remembered.dimBuiltInDisplay && !(current.dimBuiltInDisplay && !next.dimBuiltInDisplay))
        pending = (request.id, !current.muted && next.muted, !current.privacy && next.privacy,
                   !current.lockOnDisconnect && next.lockOnDisconnect, !current.dimBuiltInDisplay && next.dimBuiltInDisplay)
    }

    /// Applies the host's reply to the recorded toggle; replies to other requests leave the memory unchanged.
    public mutating func confirmed(_ result: SessionEffectsResult) {
        guard let pending, result.id == pending.id else { return }
        self.pending = nil
        remembered = SessionEffectsState(muted: pending.muted ? result.state.muted : remembered.muted,
                                         privacy: pending.privacy ? result.state.privacy : remembered.privacy,
                                         lockOnDisconnect: pending.lock ? result.state.lockOnDisconnect : remembered.lockOnDisconnect,
                                         dimBuiltInDisplay: pending.dim ? result.state.dimBuiltInDisplay : remembered.dimBuiltInDisplay)
    }

    /// Drops a recorded toggle whose reply can no longer arrive.
    public mutating func cancel() { pending = nil }
}

/// Reads and sets the brightness of one display, from 0 to 1.
public protocol DisplayBrightnessIO {
    func brightness() throws -> Float
    func setBrightness(_ value: Float) throws
}

/// The brightness a session found before turning a display dark, so that only its own change is undone.
public struct DisplayDimTransaction: Equatable, Sendable {
    /// Readings at or below this count as dark; one brightness key step is far above it.
    public static let darkLimit: Float = 0.001
    public let original: Float

    public init(original: Float) { self.original = original }

    public static func isDark(_ brightness: Float) -> Bool { brightness <= darkLimit }

    /// Remembers the current brightness without changing it.
    public static func begin(using io: DisplayBrightnessIO) throws -> DisplayDimTransaction {
        let value = try io.brightness()
        guard value.isFinite, (0...1).contains(value) else { throw DeskError.invalid("内建屏幕亮度读数无效") }
        return DisplayDimTransaction(original: value)
    }

    public func dim(using io: DisplayBrightnessIO) throws { try io.setBrightness(0) }

    /// Puts the original brightness back while the display is still dark. Returns false without writing
    /// when the brightness has been raised since, so that whoever raised it keeps their choice.
    @discardableResult
    public func restore(using io: DisplayBrightnessIO) throws -> Bool {
        guard Self.isDark(try io.brightness()) else { return false }
        if !Self.isDark(original) { try io.setBrightness(original) }
        return true
    }
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
