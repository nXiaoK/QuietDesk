import Foundation
import QuietDeskCore

final class HostInputGate: @unchecked Sendable {
    struct Snapshot {
        var closed = false
        var sessionReady = false
        var canInject = false
        var desktopActionRunning = false
        var injector: InputInjector?
        var unlocker: HostScreenUnlocker?
        var textTyper: HostTextTyper?
    }

    private let lock = NSLock()
    private var state = Snapshot()

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&state) }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state }
    }

    func close() {
        lock.withLock {
            state.closed = true
            state.sessionReady = false
            state.canInject = false
            state.desktopActionRunning = false
            state.injector = nil
            state.unlocker = nil
            state.textTyper = nil
        }
    }
}

// These resources belong to one connection. Reconnect intent and UI state live in DeskModel.
@MainActor
final class HostSession {
    let inputGate = HostInputGate()
    let startupDeadline = ConnectionStartupDeadline()
    var startupPhase = DiagnosticLog.StartupPhase.sessionPreparation
    var terminationSubscribed = false
    var connectionID: UUID?
    var updateCheckReady = false
    var qualityProbeActive = false
    var viewerSupportsUpdateRestart = false
    var restartingForUpdate = false
    var usesRelayControl = false
    var media: MediaSession?
    var mediaPrepared = false
    let cursorID = UUID()
    var cursorEpoch: UInt32 = 0
    var cursorEnabled = false
    var cursorSubscribed = false
    var cursorTask: Task<Void, Never>?
    var cursorSampler: HostCursorSampler?
    var cursorShapeRevision: UInt64 = 0
    var cursorPositionSequence: UInt64 = 0
    var audioEpoch: UInt32 = 0
    var audioEnabled = false
    var audioTask: Task<Void, Never>?
    var audioTaskID: UUID?
    var audioSender: HostAudioSender?
    var streamer: ScreenStreamer?
    var injector: InputInjector?
    var captureTask: Task<Void, Never>?
    var capturedDisplay: DisplaySnapshot?
    var displayUpdatesSubscribed = false
    var preferredDisplayIDOverride: UInt32?
    var displayTask: Task<Void, Never>?
    var displaySwitchRequestID: UUID?
    var pendingAutomaticDisplayRefresh = false
    var lastSentDisplays: [RemoteDisplayInfo] = []
    var settingsTask: Task<Void, Never>?
    var settingsRequestID: UUID?
    var videoViewport: VideoViewport?
    var effects: HostSessionEffects?
    var effectsTask: Task<Void, Never>?
    var pauseTask: Task<Void, Never>?
    var paused = false
    var deviceIdentityAdvertised = false
    var remoteDeviceID: UUID?
    var qualityProbeRequested = false
    var desktopActions: RemoteDesktopActionExecutor?
    var desktopActionTask: Task<Void, Never>?
    var lastDesktopActionResult: DesktopActionResult?
    var unlocker: HostScreenUnlocker?
    var unlockTask: Task<Void, Never>?
    var textTyper: HostTextTyper?
    var typeTextRequestID: UUID?
    var typeTextTask: Task<Void, Never>?
    private var initialSettingsContinuation: CheckedContinuation<StreamSettingsRequest?, Never>?
    private var initialSettingsTimeout: Task<Void, Never>?

    var isAwaitingInitialSettings: Bool {
        initialSettingsContinuation != nil
    }

    func awaitInitialSettings(grace: Duration) async -> StreamSettingsRequest? {
        cancelInitialSettingsWait()
        return await withCheckedContinuation { continuation in
            initialSettingsContinuation = continuation
            initialSettingsTimeout = Task { [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                self?.resolveInitialSettings(nil)
            }
        }
    }

    func resolveInitialSettings(_ request: StreamSettingsRequest?) {
        initialSettingsTimeout?.cancel()
        initialSettingsTimeout = nil
        guard let continuation = initialSettingsContinuation else { return }
        initialSettingsContinuation = nil
        continuation.resume(returning: request)
    }

    func cancelInitialSettingsWait() {
        resolveInitialSettings(nil)
    }
}

@MainActor
final class ViewerSession {
    struct HostUpdateWait {
        let version: String
        let startedAt: TimeInterval
        var deadline: TimeInterval { startedAt + HostUpdateRestartNotice.maximumWaitSeconds }
        var status: String { "被控端正在更新至 v\(version) 并重启，等待自动重连…" }
    }

    let helloDeadline = ConnectionStartupDeadline()
    // Keep the authenticated mapping identity available if the saved route is deleted while connected.
    var mappingRecordID: UUID?
    var mappingHostDeviceID: UUID?
    var relayBridge: RelayViewerBridge?
    var mediaRelayBridge: RelayViewerBridge?
    var usesRelayControl = false
    var closeTailnetBridge: (() -> Void)?
    var transportHost: String?
    var transportPort: UInt16?
    var relayTargetVerified = false
    var relayFallbackRequested = false
    var cursorRequestID: UUID?
    var cursorRequestedEnabled = false
    var cursorConfigured = false
    var cursorTimeout: Task<Void, Never>?
    var audioRequestID: UUID?
    var audioRequestedEnabled = false
    var audioTimeout: Task<Void, Never>?
    var audioPlayer: ViewerAudioPlayer?
    var media: MediaSession?
    var mediaReceiver: MediaCanvasReceiver?
    var mediaCommitted = false
    var pointerSequence: UInt64 = 0
    var mediaQuality: MediaQualityPolicy?
    /// Identifies this session's video route for the starting-bitrate memory; nil when it takes no part.
    var startingBitrateRoute: String?
    var automaticVideoSettings: StreamSettings?
    var automaticVideoAdjustment: MediaQualityPolicy.Adjustment?
    var terminationSubscribed = false
    var hostUpdateRestartNegotiated = false
    var awaitingHostUpdate: HostUpdateWait?
    var helloReceived = false
    var stableTask: Task<Void, Never>?
    var clipboardPullTimeout: Task<Void, Never>?
    var clipboardPullPending = false
    var videoDebounceTask: Task<Void, Never>?
    var videoViewportTask: Task<Void, Never>?
    var supportsVideoViewport = false
    var videoRequestTimeout: Task<Void, Never>?
    var pendingVideoPreferenceCanSave = true
    var effectsRequestID: UUID?
    var effectsRequestTimeout: Task<Void, Never>?
    var pauseRequestTimeout: Task<Void, Never>?
    var lastLatencyAt: TimeInterval?
    var restoreCanvasFocusAfterIdle = false
    var desktopActionRequest: DesktopActionRequest?
    var desktopActionTimeout: Task<Void, Never>?
    var displayUpdatesSubscribed = false
    var displaySwitchRequestID: UUID?
    var displaySwitchTimeout: Task<Void, Never>?
    var unlockRequestID: UUID?
    var unlockAutomatic = false
    var unlockTask: Task<Void, Never>?
    var unlockTimeout: Task<Void, Never>?
    var typeTextRequestID: UUID?
    var typeTextCharacterCount = 0
    var typeTextTimeout: Task<Void, Never>?
}
