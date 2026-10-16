import AppKit
import QuietDeskCore

func runSystemShortcutChecks() {
    let active = SystemShortcutScope(sessionActive: true, canControl: true, fullScreen: true, keyWindow: true, canvasFocused: true)
    run("System shortcuts are captured only for a focused, controllable fullscreen session") {
        var routing = SystemShortcutRouting()
        try check(routing.route(kind: .keyDown, keyCode: 49, scope: active) == .capture, "Command-Space was not capturable")
        for index in 0..<5 {
            var scope = active
            switch index {
            case 0: scope.sessionActive = false
            case 1: scope.canControl = false
            case 2: scope.fullScreen = false
            case 3: scope.keyWindow = false
            default: scope.canvasFocused = false
            }
            try check(routing.route(kind: .keyDown, keyCode: 49, scope: scope) == .passThrough && routing.capturedKeys.isEmpty,
                      "Inactive scope swallowed a local key or retained stale state")
        }
    }

    run("Captured key repeats and key-up pair once while release and reentry clear the old pair") {
        var routing = SystemShortcutRouting()
        try check(routing.route(kind: .keyDown, keyCode: 48, scope: active) == .capture, "Command-Tab down was not captured")
        try check(routing.route(kind: .keyDown, keyCode: 48, scope: active) == .capture && routing.capturedKeys.count == 1,
                  "Repeat created a second held key")
        try check(routing.route(kind: .flags, keyCode: 55, scope: active) == .capture, "Modifier release was not routed")
        try check(routing.route(kind: .keyUp, keyCode: 48, scope: active) == .capture, "Key-up was lost after modifiers changed")
        try check(routing.route(kind: .keyUp, keyCode: 48, scope: active) == .passThrough, "Duplicate up was captured twice")
        _ = routing.route(kind: .keyDown, keyCode: 49, scope: active)
        routing.reset()
        try check(routing.route(kind: .keyUp, keyCode: 49, scope: active) == .passThrough, "Reset retained an earlier key")
    }

    run("Caps Lock and unsupported input pass through the general system shortcut capture") {
        var routing = SystemShortcutRouting()
        for kind in [RemoteInput.Kind.keyDown, .keyUp, .flags] {
            try check(routing.route(kind: kind, keyCode: 57, scope: active) == .passThrough, "Caps Lock was captured by two monitors")
        }
        try check(routing.route(kind: .keyDown, keyCode: 128, scope: active) == .passThrough, "Unsupported key was swallowed")
        try check(routing.route(kind: .flags, keyCode: 0, scope: active) == .passThrough, "Unknown modifier was swallowed")
        try check(routing.route(kind: .scroll, keyCode: 0, scope: active) == .passThrough, "Pointer event entered keyboard capture")
    }

    run("Emergency release and fullscreen exit remain local while paste keeps its normal route") {
        let control = UInt64(NSEvent.ModifierFlags.control.rawValue), option = UInt64(NSEvent.ModifierFlags.option.rawValue)
        let command = UInt64(NSEvent.ModifierFlags.command.rawValue), shift = UInt64(NSEvent.ModifierFlags.shift.rawValue)
        try check(SystemShortcutRouting.localAction(keyCode: 53, flags: control | option) == .releaseControl, "Emergency release changed")
        try check(SystemShortcutRouting.localAction(keyCode: 53, flags: control | option | command | shift) == .releaseControl,
                  "Additional modifiers disabled emergency release")
        try check(SystemShortcutRouting.localAction(keyCode: 3, flags: control | command) == .toggleFullScreen, "Fullscreen exit changed")
        try check(SystemShortcutRouting.localAction(keyCode: 3, flags: control | command | shift) == nil, "A different combination exited fullscreen")
        try check(SystemShortcutRouting.localAction(keyCode: 49, flags: command) == nil, "Spotlight was treated as a local action")
        try check(SystemShortcutRouting.localAction(keyCode: 9, flags: command) == nil, "Paste bypassed the canvas paste preparation route")
    }

    run("Copied synthetic keyboard events preserve native key, modifier, release and repeat data without posting") {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true) else { throw CheckFailure("Cannot construct key event") }
        down.flags = .maskCommand
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        guard let copied = down.copy(), let native = NSEvent(cgEvent: copied) else { throw CheckFailure("Cannot copy native key event") }
        try check(native.type == .keyDown && native.keyCode == 49 && native.modifierFlags.contains(.command) && native.isARepeat,
                  "Copied event changed key or modifiers")
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false), let nativeUp = NSEvent(cgEvent: up) else {
            throw CheckFailure("Cannot construct key release")
        }
        try check(nativeUp.type == .keyUp && nativeUp.keyCode == 49, "Release changed type or key")
    }
}
