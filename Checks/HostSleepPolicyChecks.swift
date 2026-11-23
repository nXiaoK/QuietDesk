import Foundation
import QuietDeskCore

func runHostSleepPolicyChecks() {
    run("Host sleep policy prevents sleep only when sharing is active on external power") {
        let acOpen = HostSleepPolicy.activityMode(
            hostingActive: true,
            power: HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false)
        )
        let acClamshell = HostSleepPolicy.activityMode(
            hostingActive: true,
            power: HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: true)
        )
        try check(acOpen == .preventingSleep && acOpen.preventsSystemSleep, "AC open-lid sharing did not prevent sleep")
        try check(acClamshell == .preventingSleep && acClamshell.preventsSystemSleep, "AC clamshell sharing did not prevent sleep")

        guard let acOptions = acOpen.activityOptions else {
            throw CheckFailure("Preventing sleep returned nil activity options")
        }
        try check(
            acOptions.contains(.idleSystemSleepDisabled)
                && acOptions.contains(.idleDisplaySleepDisabled)
                && acOptions.contains(.userInitiated)
                && acOptions.contains(.latencyCritical),
            "AC activity options missed expected sleep/latency flags"
        )
        try check(acOpen.reason?.isEmpty == false, "Preventing sleep had an empty activity reason")
    }

    run("Host sleep policy never prevents sleep when lid is closed without adapter or running on battery") {
        let batteryClamshell = HostSleepPolicy.activityMode(
            hostingActive: true,
            power: HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: true)
        )
        let batteryOpen = HostSleepPolicy.activityMode(
            hostingActive: true,
            power: HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: false)
        )
        try check(
            batteryClamshell == .allowingSleep && !batteryClamshell.preventsSystemSleep,
            "Clamshell closed without power adapter prevented system sleep"
        )
        try check(
            batteryOpen == .allowingSleep && !batteryOpen.preventsSystemSleep,
            "Battery power without external adapter prevented system sleep"
        )

        guard let allowOptions = batteryClamshell.activityOptions else {
            throw CheckFailure("Allowing sleep while sharing returned nil activity options")
        }
        // Notice `.userInitiated` includes `.idleSystemSleepDisabled`; ensure neither system nor display sleep is disabled.
        try check(
            !allowOptions.contains(.idleSystemSleepDisabled)
                && !allowOptions.contains(.idleDisplaySleepDisabled)
                && !allowOptions.contains(.userInitiated)
                && allowOptions.contains(.userInitiatedAllowingIdleSystemSleep)
                && allowOptions.contains(.latencyCritical),
            "Battery activity options still disabled idle system or display sleep"
        )
        try check(batteryClamshell.reason?.isEmpty == false, "Allowing sleep had an empty activity reason")
    }

    run("Host sleep policy holds no activity when sharing is inactive or system is entering sleep") {
        for hasPower in [false, true] {
            for closed in [false, true] {
                let env = HostPowerEnvironment(hasExternalPower: hasPower, isClamshellClosed: closed)
                let stopped = HostSleepPolicy.activityMode(hostingActive: false, systemSleeping: false, power: env)
                let sleeping = HostSleepPolicy.activityMode(hostingActive: true, systemSleeping: true, power: env)
                try check(
                    stopped == .none && stopped.activityOptions == nil && stopped.reason == nil && !stopped.preventsSystemSleep,
                    "Stopped host kept an activity mode for \(env)"
                )
                try check(
                    sleeping == .none && sleeping.activityOptions == nil && sleeping.reason == nil && !sleeping.preventsSystemSleep,
                    "Sleeping host kept an activity mode for \(env)"
                )
            }
        }
    }
}
