import AppKit
import SwiftUI

@main private struct RelaySettingsPreview {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            Text("SYNTHETIC STATE · 中继设置预览").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.top, 10)
            RelaySettingsView(enabled: true, address: "tls://relay.example.test:7443", deviceID: "672d6104-a890-4c4c-8862-c8f28f55953a", locked: false) { _, _, _, _ in }
        }.background(Color(nsColor: .windowBackgroundColor)))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "QuietDesk Relay Preview (Synthetic State)"; window.contentView = view
        window.orderBack(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
             try data.write(to: output.appendingPathComponent("relay-settings.png")) }
        catch { exit(1) }
        window.orderOut(nil)
    }
}
