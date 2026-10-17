import AppKit

@MainActor
enum ClipboardPrivacy {
    private static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    ]

    static func isSensitive(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !sensitiveTypes.isDisjoint(with: types)
    }

    static func copyPairingCode(_ code: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(code, forType: .string) else { return false }
        for type in sensitiveTypes {
            guard item.setData(Data(), forType: type) else { return false }
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects([item]) else { return false }
        let change = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard pasteboard.changeCount == change else { return }
            pasteboard.clearContents()
        }
        return true
    }
}
