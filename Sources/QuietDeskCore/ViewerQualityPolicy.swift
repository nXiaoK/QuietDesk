import Foundation

public struct ViewerQualityPolicy {
    public private(set) var preferred: StreamSettings?
    public private(set) var maySaveCurrentChoice = true
    private var initialDecisionPending: Bool
    private var firstRoundTrip: Double?

    public init(preferred: StreamSettings? = nil) {
        self.preferred = preferred
        initialDecisionPending = preferred == nil
    }

    public mutating func settingsForConnection(hostDefault: StreamSettings, supportsExtended: Bool, supportsHighRefresh: Bool = false) -> StreamSettings {
        let desired = preferred ?? hostDefault
        let compatible = supportsHighRefresh ? desired : supportsExtended ? desired.extendedCompatible : desired.legacyCompatible
        maySaveCurrentChoice = preferred == nil || desired == compatible
        return compatible
    }

    public mutating func observeRoundTrip(_ milliseconds: Double) {
        guard initialDecisionPending, firstRoundTrip == nil, milliseconds.isFinite, milliseconds >= 0 else { return }
        firstRoundTrip = milliseconds
    }

    public mutating func takeInitialAutomaticSettings(supportsExtended: Bool, supportsHighRefresh: Bool = false) -> StreamSettings? {
        guard initialDecisionPending, let firstRoundTrip else { return nil }
        initialDecisionPending = false
        guard supportsExtended, firstRoundTrip < 10 else { return nil }
        return supportsHighRefresh ? .highest : StreamSettings.highest.extendedCompatible
    }

    public mutating func chooseManually() {
        initialDecisionPending = false
        maySaveCurrentChoice = true
    }

    public mutating func confirm(_ settings: StreamSettings, maySave: Bool) -> Bool {
        guard maySave else { return false }
        preferred = settings
        return true
    }

    public mutating func discardUnfinishedSample() {
        firstRoundTrip = nil
    }
}
