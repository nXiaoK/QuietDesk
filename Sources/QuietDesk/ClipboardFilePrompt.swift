import AppKit
import SwiftUI
import QuietDeskCore

@MainActor
final class ClipboardFilePrompt: NSWindowController, NSWindowDelegate {
    private var finished = false
    private let onDecision: (Bool) -> Void
    private var previousApp: NSRunningApplication?

    init(offer: ClipboardFileOffer, onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "接收文件"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        let content = NSHostingView(rootView: ClipboardFilePromptView(offer: offer) { [weak self] in self?.decide($0) })
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        finished = true
        window?.close()
        restoreFocus()
    }

    private func decide(_ accepted: Bool) {
        guard !finished else { return }
        finished = true
        window?.close()
        restoreFocus()
        onDecision(accepted)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        restoreFocus()
        onDecision(false)
    }

    private func restoreFocus() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }
}

private struct ClipboardFilePromptView: View {
    let offer: ClipboardFileOffer
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("另一台 Mac 复制了文件", systemImage: "doc.on.doc").font(.headline)
            Text("是否接收这次复制的文件或文件夹？")
            if !offer.names.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(offer.names.enumerated()), id: \.offset) { _, name in
                        Text(verbatim: name).lineLimit(2).truncationMode(.middle)
                    }
                    if offer.count > offer.names.count { Text("另有 \(offer.count - offer.names.count) 项…").foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
            Text("共 \(offer.count) 项 · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: offer.bytes), countStyle: .file))")
                .font(.callout).foregroundStyle(.secondary)
            Text("确认前不会下载文件内容。接收完成后即可粘贴；请求 90 秒后过期。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("不接收") { decide(false) }.keyboardShortcut(.cancelAction)
                Button("接收文件") { decide(true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
