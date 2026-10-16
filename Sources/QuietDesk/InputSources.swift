import Carbon
import QuietDeskCore

@MainActor
final class InputSources {
    private var choice = InputSourceChoice()

    func toggle() throws -> String {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw DeskError.invalid("无法读取家里 Mac 的输入法列表")
        }
        let sources = list.map { describe($0) }
        guard let target = choice.target(current: describe(current), enabled: sources),
              let index = sources.firstIndex(where: { $0.id == target.id }) else {
            throw DeskError.invalid("请在家里 Mac 添加并启用中文输入法和 ABC / 英文键盘")
        }
        let result = TISSelectInputSource(list[index])
        guard result == noErr else { throw DeskError.system("远端输入法切换失败", result) }
        return target.name
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
