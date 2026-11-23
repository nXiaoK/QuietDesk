import Foundation
import QuietDeskCore

private struct CheckFailure: Error { let message: String }

private final class FakeActivityToken: NSObject {
    let id: Int
    let options: ProcessInfo.ActivityOptions
    let reason: String

    init(id: Int, options: ProcessInfo.ActivityOptions, reason: String) {
        self.id = id
        self.options = options
        self.reason = reason
    }
}

private final class FakeProcessActivity: ProcessActivityControlling {
    private var nextID = 1
    private(set) var activeTokens: [Int: FakeActivityToken] = [:]
    private(set) var history: [(action: String, id: Int, options: ProcessInfo.ActivityOptions)] = []

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        let id = nextID
        nextID += 1
        let token = FakeActivityToken(id: id, options: options, reason: reason)
        activeTokens[id] = token
        history.append(("begin", id, options))
        return token
    }

    func endActivity(_ activity: NSObjectProtocol) {
        guard let token = activity as? FakeActivityToken,
              let removed = activeTokens.removeValue(forKey: token.id) else {
            history.append(("invalid-end", -1, []))
            return
        }
        history.append(("end", removed.id, removed.options))
    }
}

@main
struct HostPowerChecks {
    @MainActor
    static func main() {
        var passed = 0, failed = 0
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CheckFailure(message: message) }
        }
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("AC power prevents sleep and unplugging with lid closed immediately releases sleep prevention") {
            let fake = FakeProcessActivity()
            var power = HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false)
            let controller = HostActivityController(processActivity: fake, readPowerEnvironment: { power })

            try require(controller.update(hostingActive: true, systemSleeping: false) == .preventingSleep, "Expected preventingSleep on AC")
            try require(fake.activeTokens.count == 1, "Expected exactly 1 active token on AC")
            let firstToken = try {
                guard let token = fake.activeTokens.values.first else { throw CheckFailure(message: "Missing token") }
                return token
            }()
            try require(
                firstToken.options.contains(.idleSystemSleepDisabled) && firstToken.options.contains(.idleDisplaySleepDisabled),
                "AC token did not disable idle sleep"
            )

            // Unchanged refresh is idempotent.
            try require(controller.refresh() == .preventingSleep && fake.history.count == 1, "Idempotent refresh recreated token")

            // Lid closed while on AC (clamshell desktop mode) keeps preventing sleep.
            power = HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: true)
            try require(controller.refresh() == .preventingSleep && fake.history.count == 1, "AC clamshell needlessly churned token")

            // Unplug power adapter while lid is closed -> must stop preventing sleep immediately.
            power = HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: true)
            try require(controller.refresh() == .allowingSleep, "Clamshell on battery did not switch to allowingSleep")
            try require(fake.activeTokens.count == 1 && fake.activeTokens[firstToken.id] == nil, "Previous sleep-preventing token leaked")
            guard let batteryToken = fake.activeTokens.values.first else {
                throw CheckFailure(message: "Missing allowingSleep token")
            }
            try require(
                !batteryToken.options.contains(.idleSystemSleepDisabled)
                    && !batteryToken.options.contains(.idleDisplaySleepDisabled)
                    && batteryToken.options.contains(.userInitiatedAllowingIdleSystemSleep)
                    && batteryToken.options.contains(.latencyCritical),
                "Battery clamshell token still blocked sleep"
            )

            // Opening lid while still on battery keeps allowing sleep without churning tokens.
            let historyBeforeOpen = fake.history.count
            power = HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: false)
            try require(controller.refresh() == .allowingSleep && fake.history.count == historyBeforeOpen, "Battery open-lid churned token")

            // Plugging AC adapter back in restores sleep prevention.
            power = HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false)
            try require(controller.refresh() == .preventingSleep, "Reconnecting AC did not restore preventingSleep")
            try require(fake.activeTokens.count == 1 && fake.activeTokens[batteryToken.id] == nil, "Battery token leaked after AC reconnect")

            controller.stop()
            try require(controller.currentMode == .none && fake.activeTokens.isEmpty, "Stop left active tokens")
        }

        run("System sleep drops all tokens and waking on battery closed-lid never re-acquires sleep prevention") {
            let fake = FakeProcessActivity()
            var power = HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false)
            var reads = 0
            let controller = HostActivityController(processActivity: fake) {
                reads += 1
                return power
            }

            _ = controller.update(hostingActive: true, systemSleeping: false)
            try require(reads == 1 && fake.activeTokens.count == 1, "Initial AC start failed")

            // System entering sleep ends token without querying power sources.
            let readsBeforeSleep = reads
            try require(controller.update(hostingActive: true, systemSleeping: true) == .none, "System sleep kept mode")
            try require(fake.activeTokens.isEmpty && reads == readsBeforeSleep, "Sleeping retained token or queried power")

            // System wakes briefly in backpack on battery with lid closed.
            power = HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: true)
            try require(controller.update(hostingActive: true, systemSleeping: false) == .allowingSleep, "Battery wake prevented sleep")
            guard let wakeToken = fake.activeTokens.values.first else {
                throw CheckFailure(message: "Missing wake token")
            }
            try require(
                !wakeToken.options.contains(.idleSystemSleepDisabled) && !wakeToken.options.contains(.idleDisplaySleepDisabled),
                "Wake on battery with closed lid prevented sleep"
            )
            controller.stop()
            try require(fake.activeTokens.isEmpty, "Cleanup failed")
        }

        run("Deinit releases an unstopped activity token without leaking") {
            let fake = FakeProcessActivity()
            do {
                let controller = HostActivityController(
                    processActivity: fake,
                    readPowerEnvironment: { HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false) }
                )
                _ = controller.update(hostingActive: true, systemSleeping: false)
                try require(fake.activeTokens.count == 1, "Expected active token before deinit")
            }
            try require(fake.activeTokens.isEmpty, "Deinit leaked activity token")
        }

        run("Toggling preventSleepEnabled live releases and restores sleep prevention without restarting sharing") {
            let fake = FakeProcessActivity()
            var power = HostPowerEnvironment(hasExternalPower: true, isClamshellClosed: false)
            var reads = 0
            let controller = HostActivityController(processActivity: fake) {
                reads += 1
                return power
            }

            try require(
                controller.update(hostingActive: true, systemSleeping: false, preventSleepEnabled: true) == .preventingSleep,
                "Expected preventingSleep when switch is on and AC connected"
            )
            let readsAfterEnable = reads
            guard let initialToken = fake.activeTokens.values.first else {
                throw CheckFailure(message: "Missing initial preventingSleep token")
            }

            // Turning the switch off live on AC power drops sleep prevention immediately without needing IOKit power reads.
            try require(
                controller.update(hostingActive: true, systemSleeping: false, preventSleepEnabled: false) == .allowingSleep,
                "Turning off switch on AC did not switch to allowingSleep"
            )
            try require(reads == readsAfterEnable, "Disabled switch still queried power source unnecessarily")
            try require(fake.activeTokens.count == 1 && fake.activeTokens[initialToken.id] == nil, "Previous AC token leaked")
            guard let disabledToken = fake.activeTokens.values.first else {
                throw CheckFailure(message: "Missing allowingSleep token while switch disabled")
            }
            try require(
                !disabledToken.options.contains(.idleSystemSleepDisabled)
                    && !disabledToken.options.contains(.idleDisplaySleepDisabled),
                "Disabled switch token still blocked sleep"
            )

            // Turning the switch back on while on AC power immediately restores sleep prevention.
            try require(
                controller.update(hostingActive: true, systemSleeping: false, preventSleepEnabled: true) == .preventingSleep,
                "Re-enabling switch on AC did not restore preventingSleep"
            )
            try require(fake.activeTokens.count == 1 && fake.activeTokens[disabledToken.id] == nil, "Disabled token leaked")

            // Turning the switch on while on battery + closed lid still allows sleep.
            power = HostPowerEnvironment(hasExternalPower: false, isClamshellClosed: true)
            try require(
                controller.update(hostingActive: true, systemSleeping: false, preventSleepEnabled: true) == .allowingSleep,
                "Enabled switch on battery closed-lid prevented sleep"
            )

            controller.stop()
            try require(fake.activeTokens.isEmpty, "Stop left active tokens")
        }

        run("HostPowerMonitor starts, reads environment, restarts and stops cleanly") {
            let monitor = HostPowerMonitor()
            monitor.start()
            let first = monitor.readEnvironment()
            monitor.start()
            let second = monitor.readEnvironment()
            monitor.stop()
            let standalone = HostPowerMonitor.currentEnvironment()
            try require(first.hasExternalPower == second.hasExternalPower, "Restart changed power reading unexpectedly")
            try require(standalone.hasExternalPower == second.hasExternalPower, "Standalone reading disagreed with monitor")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
