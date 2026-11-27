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

    /// What a connection without a saved choice starts from: what the host offers, or the local default when
    /// the host left its default to the viewer and the viewer dialled it at a local address. Limited to what
    /// the host supports.
    public static func defaultCeiling(offered: StreamSettings, leftToViewer: Bool, localPath: Bool,
                                      supportsExtended: Bool, supportsHighRefresh: Bool) -> StreamSettings {
        guard leftToViewer, localPath else { return offered }
        let local = StreamSettings.automaticLocalDefault
        return supportsHighRefresh ? local : supportsExtended ? local.extendedCompatible : local.legacyCompatible
    }

    /// `defaultIsAutomatic`: the default depends on the path of this connection, so it is not saved with the
    /// record; the next connection decides again. A choice made by hand is saved as before.
    public mutating func settingsForConnection(hostDefault: StreamSettings, defaultIsAutomatic: Bool = false,
                                             supportsExtended: Bool, supportsHighRefresh: Bool = false,
                                             supportsHigherFrameRate: Bool = false) -> StreamSettings {
        let desired = preferred ?? hostDefault
        let compatible = supportsHighRefresh ? (supportsHigherFrameRate ? desired : desired.highRefreshCompatible)
            : supportsExtended ? desired.extendedCompatible : desired.legacyCompatible
        maySaveCurrentChoice = preferred == nil ? !defaultIsAutomatic : desired == compatible
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

    public mutating func chooseManually(savePreference: Bool = true) {
        initialDecisionPending = false
        maySaveCurrentChoice = savePreference
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
