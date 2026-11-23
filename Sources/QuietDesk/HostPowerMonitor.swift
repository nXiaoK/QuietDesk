import Darwin
import Foundation
import IOKit
import IOKit.ps
import notify
import QuietDeskCore

protocol ProcessActivityControlling: AnyObject {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol
    func endActivity(_ activity: NSObjectProtocol)
}

final class SystemProcessActivityControl: ProcessActivityControlling {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    func endActivity(_ activity: NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(activity)
    }
}

/// Keeps the host `ProcessInfo` activity token synchronized with sharing state,
/// external power adapter availability, and laptop clamshell state.
@MainActor
final class HostActivityController {
    private let processActivity: ProcessActivityControlling
    private let readPowerEnvironment: () -> HostPowerEnvironment
    private var currentToken: NSObjectProtocol?
    private(set) var currentMode: HostActivityMode = .none
    private var hostingActive = false
    private var systemSleeping = false
    private var preventSleepEnabled = true

    init(
        processActivity: ProcessActivityControlling = SystemProcessActivityControl(),
        readPowerEnvironment: @escaping () -> HostPowerEnvironment = { HostPowerMonitor.currentEnvironment() }
    ) {
        self.processActivity = processActivity
        self.readPowerEnvironment = readPowerEnvironment
    }

    @discardableResult
    func update(hostingActive: Bool, systemSleeping: Bool, preventSleepEnabled: Bool = true) -> HostActivityMode {
        self.hostingActive = hostingActive
        self.systemSleeping = systemSleeping
        self.preventSleepEnabled = preventSleepEnabled
        return refresh()
    }

    @discardableResult
    func refresh() -> HostActivityMode {
        let desired: HostActivityMode
        if !hostingActive || systemSleeping {
            desired = .none
        } else if !preventSleepEnabled {
            desired = .allowingSleep
        } else {
            desired = HostSleepPolicy.activityMode(
                hostingActive: true,
                systemSleeping: false,
                preventSleepEnabled: true,
                power: readPowerEnvironment()
            )
        }
        guard desired != currentMode else { return currentMode }
        if let existing = currentToken {
            processActivity.endActivity(existing)
            currentToken = nil
        }
        if let options = desired.activityOptions, let reason = desired.reason {
            currentToken = processActivity.beginActivity(options: options, reason: reason)
        }
        currentMode = desired
        return desired
    }

    func stop() {
        hostingActive = false
        if let existing = currentToken {
            processActivity.endActivity(existing)
            currentToken = nil
        }
        currentMode = .none
    }

    deinit {
        if let currentToken {
            processActivity.endActivity(currentToken)
        }
    }
}

/// Observes external AC power and clamshell (lid) transitions on the main run loop.
@MainActor
final class HostPowerMonitor {
    nonisolated static let clamshellNotificationName = "com.apple.system.powermanagement.clamshellstate"

    var onChange: (() -> Void)?
    private var limitedPowerSource: CFRunLoopSource?
    private var powerNotificationSource: CFRunLoopSource?
    private var clamshellNotifyToken: Int32 = NOTIFY_TOKEN_INVALID

    init(onChange: (() -> Void)? = nil) {
        self.onChange = onChange
    }

    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<HostPowerMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
            }
        }
        if let limited = IOPSCreateLimitedPowerNotification(callback, context)?.takeRetainedValue() {
            limitedPowerSource = limited
            CFRunLoopAddSource(CFRunLoopGetMain(), limited, .commonModes)
        }
        if let general = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerNotificationSource = general
            CFRunLoopAddSource(CFRunLoopGetMain(), general, .commonModes)
        }
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(Self.clamshellNotificationName, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
        if status == NOTIFY_STATUS_OK {
            clamshellNotifyToken = token
        }
    }

    func stop() {
        if let limitedPowerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), limitedPowerSource, .commonModes)
            CFRunLoopSourceInvalidate(limitedPowerSource)
            self.limitedPowerSource = nil
        }
        if let powerNotificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerNotificationSource, .commonModes)
            CFRunLoopSourceInvalidate(powerNotificationSource)
            self.powerNotificationSource = nil
        }
        if clamshellNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(clamshellNotifyToken)
            clamshellNotifyToken = NOTIFY_TOKEN_INVALID
        }
    }

    func readEnvironment() -> HostPowerEnvironment {
        HostPowerEnvironment(
            hasExternalPower: Self.hasExternalPower(),
            isClamshellClosed: Self.isClamshellClosed(notifyToken: clamshellNotifyToken)
        )
    }

    nonisolated static func currentEnvironment() -> HostPowerEnvironment {
        HostPowerEnvironment(
            hasExternalPower: hasExternalPower(),
            isClamshellClosed: isClamshellClosed(notifyToken: NOTIFY_TOKEN_INVALID)
        )
    }

    nonisolated static func hasExternalPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return false
        }
        return sourceType == kIOPMACPowerKey
    }

    nonisolated static func isClamshellClosed(notifyToken: Int32 = NOTIFY_TOKEN_INVALID) -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if rootDomain != IO_OBJECT_NULL {
            defer { IOObjectRelease(rootDomain) }
            if let closed = IORegistryEntryCreateCFProperty(
                rootDomain,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Bool {
                return closed
            }
        }
        if notifyToken != NOTIFY_TOKEN_INVALID {
            var state: UInt64 = 0
            if notify_get_state(notifyToken, &state) == NOTIFY_STATUS_OK {
                return state != 0
            }
        } else {
            var tempToken: Int32 = NOTIFY_TOKEN_INVALID
            if notify_register_check(clamshellNotificationName, &tempToken) == NOTIFY_STATUS_OK {
                defer { notify_cancel(tempToken) }
                var state: UInt64 = 0
                if notify_get_state(tempToken, &state) == NOTIFY_STATUS_OK {
                    return state != 0
                }
            }
        }
        return false
    }

    deinit {
        if let limitedPowerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), limitedPowerSource, .commonModes)
            CFRunLoopSourceInvalidate(limitedPowerSource)
        }
        if let powerNotificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerNotificationSource, .commonModes)
            CFRunLoopSourceInvalidate(powerNotificationSource)
        }
        if clamshellNotifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(clamshellNotifyToken)
        }
    }
}
