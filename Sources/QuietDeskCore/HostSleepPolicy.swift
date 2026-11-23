import Foundation

/// Power adapter and lid state relevant to macOS host sleep prevention.
public struct HostPowerEnvironment: Equatable, Sendable {
    public var hasExternalPower: Bool
    public var isClamshellClosed: Bool

    public init(hasExternalPower: Bool, isClamshellClosed: Bool = false) {
        self.hasExternalPower = hasExternalPower
        self.isClamshellClosed = isClamshellClosed
    }
}

/// Desired `ProcessInfo` activity level while macOS screen sharing is running.
public enum HostActivityMode: Equatable, Sendable {
    /// Sharing is stopped or the system is entering sleep; hold no activity token.
    case none
    /// Keep scheduling responsive against App Nap while allowing display and system sleep.
    case allowingSleep
    /// Prevent idle display and system sleep while connected to external power, and keep scheduling responsive.
    case preventingSleep

    public var preventsSystemSleep: Bool {
        self == .preventingSleep
    }

    public var activityOptions: ProcessInfo.ActivityOptions? {
        switch self {
        case .none:
            return nil
        case .allowingSleep:
            return [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
        case .preventingSleep:
            return [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated, .latencyCritical]
        }
    }

    public var reason: String? {
        switch self {
        case .none:
            return nil
        case .allowingSleep:
            return "远程桌面共享（允许系统睡眠）"
        case .preventingSleep:
            return "远程桌面共享（已接外部电源，阻止空闲睡眠）"
        }
    }
}

public enum HostSleepPolicy {
    /// Prevents system and display idle sleep only when sharing is active (and not entering system sleep),
    /// sleep prevention is enabled by user preference, and the Mac is connected to external AC power.
    /// Whenever the preference is turned off or the Mac runs without external power — including when
    /// the lid is closed on battery or open on battery — sleep prevention is disabled.
    public static func activityMode(
        hostingActive: Bool,
        systemSleeping: Bool = false,
        preventSleepEnabled: Bool = true,
        power: HostPowerEnvironment
    ) -> HostActivityMode {
        guard hostingActive, !systemSleeping else { return .none }
        guard preventSleepEnabled else { return .allowingSleep }
        if power.isClamshellClosed && !power.hasExternalPower {
            return .allowingSleep
        }
        return power.hasExternalPower ? .preventingSleep : .allowingSleep
    }
}
