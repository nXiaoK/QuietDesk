import Foundation

// Production and unbundled builds keep their existing data folders.
enum AppDataLocation {
    static let productionBundleIdentifier = "local.quietdesk.app"

    static func folderName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let id = bundleIdentifier, id != productionBundleIdentifier, !id.isEmpty else { return "QuietDesk" }
        let safe = id.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? String($0) : "_"
        }.joined()
        return "QuietDesk-" + safe
    }
}
