import AppKit
import Carbon
import QuietDeskCore

@MainActor
protocol TextKeyTyping: AnyObject {
    func prepareLayout()
    func typeCharacter(_ character: Character) -> Bool
    func pressReturn() -> Bool
    func pressTab() -> Bool
}

/// Types short text or credentials into the active remote input field as individual HID key events without
/// touching the host Mac's NSPasteboard. Re-verifies lock state, Accessibility trust, and session control
/// permission before every keystroke and before any trailing Return key, and never logs the text payload.
@MainActor
final class HostTextTyper: @unchecked Sendable {
    private let typingLock = NSLock()
    nonisolated(unsafe) private var typingValue = false
    nonisolated var typing: Bool { typingLock.withLock { typingValue } }
    private func setTyping(_ value: Bool) { typingLock.withLock { typingValue = value } }

    private let isLocked: () -> Bool
    private let isTrusted: () -> Bool
    private let canInject: () -> Bool
    private let keys: TextKeyTyping
    private let pause: (Duration) async -> Void

    init(
        isLocked: @escaping () -> Bool = { HostTextTyper.consoleScreenLocked() },
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        canInject: @escaping () -> Bool = { true },
        keys: TextKeyTyping? = nil,
        pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.isLocked = isLocked
        self.isTrusted = isTrusted
        self.canInject = canInject
        self.keys = keys ?? SystemTextKeys()
        self.pause = pause
    }

    func type(_ request: TypeTextRequest) async -> TypeTextResult {
        if request.cancel {
            return Self.makeResult(id: request.id, typedCount: 0, cancelled: true)
        }
        guard !typing else {
            return Self.makeResult(id: request.id, typedCount: 0, error: "正在执行上一次模拟键入，请稍候")
        }
        guard !isLocked() else {
            return Self.makeResult(id: request.id, typedCount: 0, error: "被控 Mac 当前处于锁屏状态，请先使用锁屏解锁功能")
        }
        guard isTrusted() else {
            return Self.makeResult(id: request.id, typedCount: 0, error: "被控端辅助功能权限未生效，无法模拟键入")
        }
        guard canInject() else {
            return Self.makeResult(id: request.id, typedCount: 0, error: "被控端当前不允许接收键盘输入")
        }

        setTyping(true)
        defer { setTyping(false) }
        keys.prepareLayout()

        let totalCharacters = request.text.count
        var typedCount = 0
        for (index, character) in request.text.enumerated() {
            if Task.isCancelled {
                let note = typedCount > 0 ? "模拟键入已停止（已输入 \(typedCount) 个字符）" : "模拟键入已取消"
                return Self.makeResult(id: request.id, typedCount: typedCount, cancelled: true, error: note)
            }
            if isLocked() {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "被控 Mac 已进入锁屏，停止输入剩余字符")
            }
            if !isTrusted() {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "被控端辅助功能权限已失效，停止输入")
            }
            if !canInject() {
                return Self.makeResult(id: request.id, typedCount: typedCount, cancelled: true, error: "会话控制状态已变更，停止模拟键入")
            }

            let posted: Bool
            if character == "\n" {
                posted = keys.pressReturn()
            } else if character == "\t" {
                posted = keys.pressTab()
            } else {
                posted = keys.typeCharacter(character)
            }
            guard posted else {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "无法向被控 Mac 发送按键事件")
            }
            typedCount += 1

            if index + 1 < totalCharacters || request.submitReturn {
                await pause(.milliseconds(12))
            }
        }

        if request.submitReturn {
            if Task.isCancelled {
                return Self.makeResult(
                    id: request.id,
                    typedCount: typedCount,
                    cancelled: true,
                    error: "模拟键入已停止，未发送末尾回车"
                )
            }
            if isLocked() {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "被控 Mac 已进入锁屏，未发送末尾回车")
            }
            if !isTrusted() {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "被控端辅助功能权限已失效，未发送末尾回车")
            }
            if !canInject() {
                return Self.makeResult(
                    id: request.id,
                    typedCount: typedCount,
                    cancelled: true,
                    error: "会话控制状态已变更，未发送末尾回车"
                )
            }
            guard keys.pressReturn() else {
                return Self.makeResult(id: request.id, typedCount: typedCount, error: "文字已输入，但无法发送末尾回车")
            }
        }

        return Self.makeResult(id: request.id, typedCount: typedCount)
    }

    nonisolated private static func consoleScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
            && session?["kCGSSessionOnConsoleKey"] as? Bool == true
    }

    private static func makeResult(
        id: UUID,
        typedCount: Int,
        cancelled: Bool = false,
        error: String? = nil
    ) -> TypeTextResult {
        let clampedCount = min(max(0, typedCount), TypeTextRequest.maximumCharacterCount)
        let boundedError: String?
        if let error, !error.isEmpty {
            boundedError = String(error.prefix(240))
        } else {
            boundedError = nil
        }
        return try! TypeTextResult(id: id, typedCount: clampedCount, cancelled: cancelled, error: boundedError)
    }
}

@MainActor
private final class SystemTextKeys: TextKeyTyping {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var layout: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]

    func prepareLayout() {
        layout = Self.currentLayout()
    }

    func typeCharacter(_ character: Character) -> Bool {
        let fullUTF16 = Array(String(character).utf16)
        if fullUTF16.count <= 20 {
            let key = layout[character]
            return postKey(code: key?.code ?? 0, flags: key?.flags ?? [], utf16: fullUTF16)
        }
        for scalar in String(character).unicodeScalars {
            let units = Array(String(scalar).utf16)
            guard postKey(code: 0, flags: [], utf16: units) else { return false }
        }
        return true
    }

    func pressReturn() -> Bool {
        postKey(code: CGKeyCode(kVK_Return), flags: [], utf16: Array("\r".utf16))
    }

    func pressTab() -> Bool {
        postKey(code: CGKeyCode(kVK_Tab), flags: [], utf16: Array("\t".utf16))
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags, utf16: [UniChar]) -> Bool {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                return false
            }
            event.flags = flags
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Maps ASCII-capable layout characters to virtual keycodes and modifiers so standard shortcuts/fields see
    /// native keycodes while arbitrary Unicode (CJK, accents, symbols) still arrives via `keyboardSetUnicodeString`.
    private static func currentLayout() -> [Character: (code: CGKeyCode, flags: CGEventFlags)] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let states: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])
        ]
        var map: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (state, flags) in states {
                for code in UInt16(0)..<128 {
                    var dead: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    guard UCKeyTranslate(
                        layout,
                        code,
                        UInt16(kUCKeyActionDown),
                        state,
                        UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &dead,
                        characters.count,
                        &length,
                        &characters
                    ) == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: characters, count: length)
                    guard text.count == 1, let character = text.first, map[character] == nil else { continue }
                    map[character] = (CGKeyCode(code), flags)
                }
            }
        }
        return map
    }
}
