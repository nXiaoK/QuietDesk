import Carbon
import QuietDeskCore

@MainActor
protocol InputSourceAccess {
    func enabledSources() throws -> [KeyboardSource]
    func currentSource() -> KeyboardSource?
    func select(_ source: KeyboardSource) throws
    func prepareContextRefresh() -> InputSourceContextRefresh?
}

@MainActor
private final class SystemInputSourceAccess: InputSourceAccess {
    private var selectable: [String: TISInputSource] = [:]

    func prepareContextRefresh() -> InputSourceContextRefresh? { InputSourceContextRefresh() }

    func enabledSources() throws -> [KeyboardSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            throw DeskError.invalid("无法读取家里 Mac 的输入法列表")
        }
        selectable.removeAll(keepingCapacity: true)
        return list.map { source in
            let description = describe(source)
            selectable[description.id] = source
            return description
        }
    }

    func currentSource() -> KeyboardSource? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return describe(current)
    }

    func select(_ source: KeyboardSource) throws {
        guard let selectable = selectable[source.id] else { throw DeskError.invalid("远端输入法已不可用，请重试") }
        let result = TISSelectInputSource(selectable)
        guard result == noErr else { throw DeskError.system("远端输入法切换失败", result) }
    }

    private func describe(_ source: TISInputSource) -> KeyboardSource {
        let id = property(source, kTISPropertyInputSourceID) as? String ?? ""
        let name = property(source, kTISPropertyLocalizedName) as? String ?? id
        let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
        let ascii = property(source, kTISPropertyInputSourceIsASCIICapable) as? Bool ?? false
        return KeyboardSource(id: id, name: name, isChinese: languages.contains { $0 == "zh" || $0.hasPrefix("zh-") }, isASCII: ascii)
    }

    private func property(_ source: TISInputSource, _ key: CFString) -> CFTypeRef? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
    }
}

@MainActor
final class InputSources {
    var requiresKeyboardRefocus = false
    private var choice = InputSourceChoice()
    private let access: InputSourceAccess
    private let waitForChange: () async throws -> Void
    private var generation = UUID()

    init(access: InputSourceAccess? = nil, waitForChange: @escaping () async throws -> Void = {
        try await Task.sleep(nanoseconds: 20_000_000)
    }) {
        self.access = access ?? SystemInputSourceAccess()
        self.waitForChange = waitForChange
    }

    func toggle() async throws -> String {
        try Task.checkCancellation()
        let sources = try access.enabledSources()
        guard let current = access.currentSource() else { throw DeskError.invalid("无法读取家里 Mac 当前输入法") }
        guard let target = choice.target(current: current, enabled: sources) else {
            throw DeskError.invalid("请在家里 Mac 添加并启用中文输入法和 ABC / 英文键盘")
        }
        let token = UUID()
        generation = token
        let contextRefresh = target.isChinese ? access.prepareContextRefresh() : nil
        try access.select(target)
        try await confirm(target, token: token)
        if let contextRefresh {
            requiresKeyboardRefocus = true
            try await contextRefresh.refresh { self.generation != token }
            try await confirm(target, token: token)
        }
        requiresKeyboardRefocus = false
        return target.name
    }

    private func confirm(_ target: KeyboardSource, token: UUID) async throws {
        var consecutiveMatches = 0
        // Confirm the selected ID across main-loop turns; cross-process input activation
        // additionally requires the focus refresh above before later wire input can proceed.
        for _ in 0..<25 {
            try await waitForChange()
            guard generation == token else { throw CancellationError() }
            try Task.checkCancellation()
            if access.currentSource()?.id == target.id { consecutiveMatches += 1 }
            else { consecutiveMatches = 0 }
            if consecutiveMatches == 2 { return }
        }
        throw DeskError.invalid("尚未确认远端输入法切换生效，请重试；输入法内部的中英文模式需在远端核对")
    }

    func cancel() { generation = UUID() }
}
