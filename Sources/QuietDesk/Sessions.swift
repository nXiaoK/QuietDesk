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
    var streamer: ScreenStreamer?
    var injector: InputInjector?
    var captureTask: Task<Void, Never>?
    var capturedDisplay: DisplaySnapshot?
    var settingsTask: Task<Void, Never>?
    var settingsRequestID: UUID?
    var effects: HostSessionEffects?
    var effectsTask: Task<Void, Never>?
    var pauseTask: Task<Void, Never>?
    var paused = false
    var deviceIdentityAdvertised = false
    var remoteDeviceID: UUID?
    var desktopActions: RemoteDesktopActionExecutor?
    var desktopActionTask: Task<Void, Never>?
    var lastDesktopActionResult: DesktopActionResult?
    var unlocker: HostScreenUnlocker?
    var unlockTask: Task<Void, Never>?
}

@MainActor
final class ViewerSession {
    let helloDeadline = ConnectionStartupDeadline()
    var relayBridge: RelayViewerBridge?
    var mediaRelayBridge: RelayViewerBridge?
    var usesRelayControl = false
    var transportHost: String?
    var transportPort: UInt16?
    var relayTargetVerified = false
    var relayFallbackRequested = false
    var cursorRequestID: UUID?
    var cursorRequestedEnabled = false
    var cursorConfigured = false
    var cursorTimeout: Task<Void, Never>?
    var media: MediaSession?
    var mediaReceiver: MediaCanvasReceiver?
    var mediaCommitted = false
    var pointerSequence: UInt64 = 0
    var mediaQuality: MediaQualityPolicy?
    var automaticVideoSettings: StreamSettings?
    var automaticVideoAdjustment: MediaQualityPolicy.Adjustment?
    var terminationSubscribed = false
    var helloReceived = false
    var stableTask: Task<Void, Never>?
    var clipboardPullTimeout: Task<Void, Never>?
    var clipboardPullPending = false
    var videoDebounceTask: Task<Void, Never>?
    var videoRequestTimeout: Task<Void, Never>?
    var pendingVideoPreferenceCanSave = true
    var effectsRequestID: UUID?
    var effectsRequestTimeout: Task<Void, Never>?
    var pauseRequestTimeout: Task<Void, Never>?
    var lastLatencyAt: TimeInterval?
    var restoreCanvasFocusAfterIdle = false
    var desktopActionRequest: DesktopActionRequest?
    var desktopActionTimeout: Task<Void, Never>?
    var unlockRequestID: UUID?
    var unlockAutomatic = false
    var unlockTask: Task<Void, Never>?
    var unlockTimeout: Task<Void, Never>?
}
