import CoreGraphics
import Foundation

/// In full screen the session toolbar stays out of the remote picture until the pointer rests at the top
/// edge, where macOS itself brings back a full-screen window's menu bar. Works from samples of where the
/// pointer is, so it does not depend on any event being delivered.
public struct FullScreenToolbarReveal: Sendable {
    public enum Zone: Sendable, Equatable {
        /// At the top edge, or just above it where the menu bar or a camera housing is.
        case edge
        /// Around the toolbar, and between it and the edge.
        case toolbar
        case elsewhere
    }

    /// How long the pointer rests at the edge before the toolbar comes, so that passing by or reaching for
    /// something at the top of the remote picture does not bring it.
    public static let dwell: TimeInterval = 0.3
    /// How long the toolbar stays once the pointer has left it.
    public static let linger: TimeInterval = 0.8
    /// Distance of the toolbar from the top edge: below the menu bar and title strip macOS shows there.
    public static let toolbarTop: CGFloat = 56
    public static let toolbarHeight: CGFloat = 36

    static let edgeDepth: CGFloat = 3
    /// How far above the picture still counts: the pointer stops in the menu bar when that is shown.
    static let edgeReach: CGFloat = 48
    static let edgeHalfWidth: CGFloat = 180
    static let keepDepth: CGFloat = toolbarTop + toolbarHeight + 18
    static let keepHalfWidth: CGFloat = 330

    public private(set) var revealed = false
    private var restingSince: TimeInterval?
    private var leftAt: TimeInterval?

    public init() {}

    /// `x` and `fromTop` are in points from the top-left corner of the full-screen picture; a negative
    /// `fromTop` is above it.
    public static func zone(x: CGFloat, fromTop: CGFloat, containerWidth: CGFloat) -> Zone {
        guard x.isFinite, fromTop.isFinite, containerWidth.isFinite, containerWidth > 0, fromTop >= -edgeReach else { return .elsewhere }
        let offset = abs(x - containerWidth / 2)
        if fromTop <= edgeDepth, offset <= edgeHalfWidth { return .edge }
        if fromTop <= keepDepth, offset <= keepHalfWidth { return .toolbar }
        return .elsewhere
    }

    /// One sample of the pointer; returns whether `revealed` changed. A pressed button never brings the
    /// toolbar: something is being dragged to the edge.
    @discardableResult
    public mutating func sample(_ zone: Zone, buttonPressed: Bool, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if revealed {
            guard zone == .elsewhere else { leftAt = nil; return false }
            guard let leftAt else { self.leftAt = now; return false }
            return now - leftAt >= Self.linger ? hide() : false
        }
        guard zone == .edge, !buttonPressed else { restingSince = nil; return false }
        guard let restingSince else { self.restingSince = now; return false }
        guard now - restingSince >= Self.dwell else { return false }
        revealed = true; self.restingSince = nil
        return true
    }

    /// Full screen ended or the toolbar was turned off; returns whether `revealed` changed.
    @discardableResult
    public mutating func hide() -> Bool {
        let changed = revealed
        revealed = false; restingSince = nil; leftAt = nil
        return changed
    }
}
