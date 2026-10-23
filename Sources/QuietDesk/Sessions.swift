import Foundation
import QuietDeskCore

// These resources belong to one connection. Reconnect intent and UI state live in DeskModel.
@MainActor
final class HostSession {
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
    var relayBridge: RelayViewerBridge?
    var mediaRelayBridge: RelayViewerBridge?
    var usesRelayControl = false
    var transportHost: String?
    var transportPort: UInt16?
    var relayTargetVerified = false
    var relayFallbackRequested = false
    var cursorRequestID: UUID?
    var cursorRequestedEnabled = false
    var cursorTimeout: Task<Void, Never>?
    var media: MediaSession?
    var mediaReceiver: MediaCanvasReceiver?
    var mediaCommitted = false
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
