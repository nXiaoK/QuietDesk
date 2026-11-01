import Foundation
import Darwin

public enum SessionClock {
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    // Monotonic elapsed time includes system sleep and is unaffected by wall-clock changes.
    public static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }

    /// System uptime excludes system sleep, but still advances during App Nap and process suspension.
    public static var uptime: TimeInterval { Double(mach_absolute_time()) * secondsPerTick }
}

/// A delayed local timer is not evidence that the peer failed to answer while we could receive.
/// Only scheduling gaps grant a fresh response window; regular ticks and incoming bytes do not.
struct LocalSchedulingGrace {
    private var lastCheckAt: TimeInterval
    private(set) var until: TimeInterval = 0

    init(now: TimeInterval = SessionClock.uptime) { lastCheckAt = now }

    @discardableResult
    mutating func observe(now: TimeInterval, interval: TimeInterval, allowance: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastCheckAt else { return false }
        let delayed = now - lastCheckAt > interval + max(0.25, interval)
        lastCheckAt = now
        if delayed { until = now + allowance }
        return delayed
    }

    func isActive(at now: TimeInterval) -> Bool { now < until }
}
