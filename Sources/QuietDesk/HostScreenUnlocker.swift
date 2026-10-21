import AppKit
import Carbon
import IOKit.pwr_mgt
import QuietDeskCore

/// Whether this login session is the one on the display and its screen is locked.
enum ScreenLockState {
    static var isLockedOnConsole: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true && session?["kCGSSessionOnConsoleKey"] as? Bool == true
    }
}

@MainActor
protocol UnlockKeyTyping: AnyObject {
    /// Wakes the display and brings the password field up without typing a character.
    func wake()
    func type(_ character: Character) -> Bool
    func pressReturn() -> Bool
}

/// Types a lock screen password the viewer sent. It types only while this session is locked on the
/// console, checks again before every character so nothing lands in an app after a local unlock,
/// and never keeps the password after the attempt.
@MainActor
final class HostScreenUnlocker {
    private(set) var typing = false
    private let isLocked: () -> Bool
    private let isTrusted: () -> Bool
    private let keys: UnlockKeyTyping
    private let pause: (Duration) async -> Void

    init(isLocked: @escaping () -> Bool = { ScreenLockState.isLockedOnConsole },
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         keys: UnlockKeyTyping? = nil,
         pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.isLocked = isLocked; self.isTrusted = isTrusted; self.pause = pause
        self.keys = keys ?? SystemUnlockKeys()
    }

    func unlock(_ request: SessionUnlockRequest) async -> SessionUnlockResult {
        func failed(_ message: String) -> SessionUnlockResult { SessionUnlockResult(id: request.id, outcome: .failed, error: message) }
        guard !typing else { return failed("正在输入上一次的解锁密码") }
        guard isLocked() else { return SessionUnlockResult(id: request.id, outcome: .notLocked) }
        guard isTrusted() else { return failed("被控端未授权辅助功能，无法输入锁屏密码") }
        typing = true
        defer { typing = false }
        keys.wake()
        await pause(.milliseconds(800))
        for character in request.password {
            guard !Task.isCancelled else { return failed("连接已结束，停止输入") }
            guard isLocked() else {
                return SessionUnlockResult(id: request.id, outcome: .notLocked, error: "输入期间被控 Mac 已在本机解锁，其余字符没有输入")
            }
            guard keys.type(character) else { return failed("无法向锁屏界面输入字符") }
            // Paced so the viewer sees the field fill in, which shows the Mac was locked.
            await pause(.milliseconds(70))
        }
        guard !Task.isCancelled else { return failed("连接已结束，未提交密码") }
        guard isLocked() else { return SessionUnlockResult(id: request.id, outcome: .notLocked) }
        guard keys.pressReturn() else { return failed("无法向锁屏界面提交密码") }
        for _ in 0..<40 {
            await pause(.milliseconds(200))
            if !isLocked() { return SessionUnlockResult(id: request.id, outcome: .unlocked) }
        }
        return failed("已输入密码，但被控 Mac 仍在锁屏，请检查保存的密码")
    }
}

@MainActor
private final class SystemUnlockKeys: UnlockKeyTyping {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var layout: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]

    func wake() {
        var assertion = IOPMAssertionID(0)
        if IOPMAssertionDeclareUserActivity("QuietDesk 自动解锁" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess {
            IOPMAssertionRelease(assertion)
        }
        // The lock screen's keyboard layout is read now, not when the session started.
        layout = Self.currentLayout()
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: down) else { continue }
            event.type = .flagsChanged
            event.flags = down ? .maskShift : []
            event.post(tap: .cghidEventTap)
        }
    }

    func type(_ character: Character) -> Bool {
        let text = Array(String(character).utf16)
        let key = layout[character]
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key?.code ?? 0, keyDown: down) else { return false }
            event.flags = key?.flags ?? []
            // The text travels with the key, so characters the layout cannot reach still arrive intact.
            event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    func pressReturn() -> Bool {
        let text = Array("\r".utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down) else { return false }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Maps each character of the current ASCII-capable layout to a key, preferring no modifier, then
    /// Shift, Option and Shift-Option, and the main keys over the keypad.
    private static func currentLayout() -> [Character: (code: CGKeyCode, flags: CGEventFlags)] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let states: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate), (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])]
        var map: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (state, flags) in states {
                for code in UInt16(0)..<128 {
                    var dead: UInt32 = 0, length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                         OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters) == noErr,
                          length > 0 else { continue }
                    let text = String(utf16CodeUnits: characters, count: length)
                    guard text.count == 1, let character = text.first, map[character] == nil else { continue }
                    map[character] = (CGKeyCode(code), flags)
                }
            }
        }
        return map
    }
}
