import AppKit
import Carbon
import IOKit.hid
import QuietDeskCore

@MainActor
final class SystemShortcutMonitor {
    var scope: () -> SystemShortcutScope = { SystemShortcutScope() }
    var onEvent: ((NSEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var routing = SystemShortcutRouting()
    private(set) var generation = UUID()
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() throws {
        if isRunning { return }
        stop()
        guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw DeskError.invalid("系统快捷键转发等待本机辅助功能和输入监控生效")
        }
        guard !Self.secureInputActive else { throw DeskError.invalid("本机安全输入已开启，系统快捷键转发暂不可用") }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let monitor = Unmanaged<SystemShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.routing.reset()
                        monitor.onFailure?("系统快捷键转发已被系统暂停，请重新检测")
                        return Unmanaged.passUnretained(event)
                    }
                    let scope = monitor.scope()
                    guard scope.isActive else { monitor.routing.reset(); return Unmanaged.passUnretained(event) }
                    guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                          !SystemShortcutMonitor.secureInputActive else {
                        monitor.routing.reset()
                        monitor.onFailure?("系统快捷键转发的权限或安全输入状态已变化，请重新检测")
                        return Unmanaged.passUnretained(event)
                    }
                    let kind: RemoteInput.Kind
                    switch type {
                    case .keyDown: kind = .keyDown
                    case .keyUp: kind = .keyUp
                    case .flagsChanged: kind = .flags
                    default: return Unmanaged.passUnretained(event)
                    }
                    let code = event.getIntegerValueField(.keyboardEventKeycode)
                    guard (0...127).contains(code), monitor.routing.route(kind: kind, keyCode: UInt16(code), scope: scope) == .capture else {
                        return Unmanaged.passUnretained(event)
                    }
                    guard let copy = event.copy() else {
                        monitor.onFailure?("无法读取系统快捷键事件，已保留本机处理")
                        return Unmanaged.passUnretained(event)
                    }
                    let token = monitor.generation
                    // Deliver after the tap callback so local release/fullscreen actions can safely stop it.
                    DispatchQueue.main.async { [weak monitor] in
                        guard let monitor, monitor.generation == token, monitor.scope().isActive else { return }
                        guard let native = NSEvent(cgEvent: copy) else {
                            monitor.onFailure?("无法转换系统快捷键事件，已停止转发并释放控制")
                            return
                        }
                        monitor.onEvent?(native)
                    }
                    return nil
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw DeskError.invalid("系统未建立快捷键转发监听，请重新检测或完全退出后重开")
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw DeskError.invalid("无法建立系统快捷键转发运行循环")
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isRunning else { stop(); throw DeskError.invalid("系统快捷键监听尚未生效，请重新检测") }
    }

    func stop() {
        generation = UUID()
        routing.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap); self.tap = nil }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes); self.runLoopSource = nil }
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }
}
