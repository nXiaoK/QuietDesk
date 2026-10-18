import AppKit
import IOKit.hid
import QuietDeskCore
import Darwin

// Callbacks run on the main run loop. Only the Caps Lock HID element is observed.
@MainActor
final class CapsLockMonitor {
    var isActive: () -> Bool = { false }
    var onAction: ((RemoteInput.Kind) -> Void)?
    var onFailure: ((String) -> Void)?
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gesture = CapsLockPress()
    private var pressedDevices = Set<UInt>()
    private let permissionsGranted: () -> Bool
    private let restoreTap: (CFMachPort?) -> Bool
    private(set) var generation = UUID()
    var isRunning: Bool {
        guard manager != nil, let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(permissionsGranted: @escaping () -> Bool = {
        AXIsProcessTrusted() && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }, restoreTap: @escaping (CFMachPort?) -> Bool = { tap in
        guard let tap, CFMachPortIsValid(tap) else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }) {
        self.permissionsGranted = permissionsGranted
        self.restoreTap = restoreTap
    }

    func handleTapInterruption(_ type: CGEventType) {
        reset()
        // A slow main-loop turn can disable a healthy tap. Restore only this transient
        // timeout, with fresh permission checks, rather than permanently stopping HID input.
        if type == .tapDisabledByTimeout, permissionsGranted(), restoreTap(tap) { return }
        onFailure?("Caps Lock 捕获已被系统暂停，请重新启用")
    }

    func receiveCapsLockValue(device: UInt, isDown: Bool, time: TimeInterval) {
        guard isActive() else { reset(); return }
        if isDown { pressedDevices.insert(device) }
        else { pressedDevices.remove(device) }
        if let action = gesture.update(isDown: !pressedDevices.isEmpty, time: time) { onAction?(action) }
    }

    func start() throws {
        if isRunning { return }
        stop()
        guard AXIsProcessTrusted() else { throw DeskError.invalid("请在公司 Mac 的辅助功能中允许 QuietDesk，然后再次启用 Caps Lock") }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw DeskError.invalid("请在公司 Mac 的输入监控中允许 QuietDesk，退出重开应用后再次启用 Caps Lock")
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let monitor = Unmanaged<CapsLockMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.handleTapInterruption(type)
                        return Unmanaged.passUnretained(event)
                    }
                    guard event.getIntegerValueField(.keyboardEventKeycode) == 57,
                          monitor.isActive() else { return Unmanaged.passUnretained(event) }
                    guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
                        monitor.reset()
                        monitor.onFailure?("Caps Lock 权限已失效，请检查公司 Mac 的辅助功能和输入监控")
                        return Unmanaged.passUnretained(event)
                    }
                    return nil
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw DeskError.invalid("系统尚未建立 Caps Lock 监听，请重新检测或完全退出后重开应用")
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw DeskError.invalid("无法建立 Caps Lock 监听，请完全退出后重新打开应用")
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                              kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
                                                  kIOHIDElementUsageKey: kHIDUsage_KeyboardCapsLock] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<CapsLockMonitor>.fromOpaque(context).takeUnretainedValue()
                let element = IOHIDValueGetElement(value)
                guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad,
                      IOHIDElementGetUsage(element) == kHIDUsage_KeyboardCapsLock else { return }
                let device = IOHIDElementGetDevice(element)
                let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
                monitor.receiveCapsLockValue(device: id, isDown: IOHIDValueGetIntegerValue(value) != 0,
                    time: Double(IOHIDValueGetTimeStamp(value)) * CapsLockMonitor.secondsPerTick)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<CapsLockMonitor>.fromOpaque(context).takeUnretainedValue().reset()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { stop(); throw DeskError.system("无法监听 Caps Lock", result) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reset() { gesture.reset(); pressedDevices.removeAll() }

    func stop() {
        generation = UUID()
        reset()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); self.tap = nil }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes); self.runLoopSource = nil }
    }

    deinit {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }
}
