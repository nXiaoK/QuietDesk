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

    /// Time this process was actually scheduled. System sleep, App Nap and a suspended process do not
    /// advance it, so a liveness deadline measured with it cannot expire while the app itself was frozen.
    public static var running: TimeInterval { Double(mach_absolute_time()) * secondsPerTick }
}
