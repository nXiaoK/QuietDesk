import Foundation
import QuietDeskCore

// These resources belong to one connection. Reconnect intent and UI state live in DeskModel.
@MainActor
final class HostSession {
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
}

@MainActor
final class ViewerSession {
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
}
