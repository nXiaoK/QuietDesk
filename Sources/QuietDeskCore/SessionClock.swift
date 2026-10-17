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
}
