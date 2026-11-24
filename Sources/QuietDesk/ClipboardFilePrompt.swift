import AppKit
import SwiftUI
import QuietDeskCore

@MainActor
final class ClipboardFilePrompt: NSWindowController, NSWindowDelegate {
    private var finished = false
    private let onDecision: (Bool) -> Void
    private var previousApp: NSRunningApplication?

    init(offer: ClipboardFileOffer, peerName: String = "", onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "接收文件"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        let content = NSHostingView(rootView: ClipboardFilePromptView(offer: offer, peerName: peerName) { [weak self] in self?.decide($0) })
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

@MainActor
struct ClipboardFilePromptView: View {
    let offer: ClipboardFileOffer
    var peerName: String = ""
    let decide: (Bool) -> Void

    private func itemSymbol(for name: String) -> String {
        if name.hasSuffix("/") || (name as NSString).pathExtension.isEmpty {
            return "folder"
        }
        return "doc.text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text(peerName.isEmpty ? "接收来自对端的文件？" : "接收来自 \(peerName) 的文件？")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DeskPalette.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("确认后才开始下载")
                    .font(.system(size: 13))
                    .foregroundStyle(DeskPalette.secondary)
            }

            DeskSurfaceCard(padding: 0, cornerRadius: 9) {
                VStack(alignment: .leading, spacing: 0) {
                    if offer.names.isEmpty {
                        Text("对方未提供文件名称")
                            .font(.system(size: 13))
                            .foregroundStyle(DeskPalette.secondary)
                            .padding(12)
                    } else {
                        ForEach(Array(offer.names.prefix(3).enumerated()), id: \.offset) { index, name in
                            if index > 0 { Divider().padding(.leading, 38) }
                            HStack(spacing: 10) {
                                Image(systemName: itemSymbol(for: name))
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(DeskPalette.secondary)
                                    .frame(width: 16)
                                Text(verbatim: name)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(DeskPalette.ink)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        if offer.count > min(offer.names.count, 3) {
                            Divider()
                            Text("另有 \(offer.count - min(offer.names.count, 3)) 项，确认面板仅预览前三项名称")
                                .font(.system(size: 11.5))
                                .foregroundStyle(DeskPalette.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("共 \(offer.count) 项\(offer.entryCount == offer.count ? "" : "（含 \(offer.entryCount) 个文件和文件夹）") · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: offer.bytes), countStyle: .file))")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DeskPalette.secondary)
                    .monospacedDigit()
                Text("保存到接收文件目录，并创建独立子目录。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DeskPalette.secondary)
                    .help(ClipboardSync.receivingDirectory)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, 90 - (SessionClock.now - offer.createdUptime))
                VStack(alignment: .leading, spacing: 5) {
                    Text(remaining > 0 ? "剩余 \(Int(ceil(remaining))) 秒 · 每次发送都需确认" : "已到确认时限，等待请求清理…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DeskPalette.amber)
                        .monospacedDigit()
                    Text("关闭或按 Esc 即拒绝；90 秒未确认自动拒绝。")
                        .font(.system(size: 12))
                        .foregroundStyle(DeskPalette.secondary)
                    GeometryReader { proxy in
                        let fraction = max(0, min(1, remaining / 90))
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DeskPalette.subtleFill)
                            Capsule()
                                .fill(remaining <= 20 ? DeskPalette.amber : DeskPalette.accent)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: 6)
                    .padding(.top, 3)
                    .accessibilityElement()
                    .accessibilityLabel("剩余确认时间")
                    .accessibilityValue(remaining > 0 ? "约 \(Int(ceil(remaining))) 秒" : "等待请求清理")
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("拒绝") { decide(false) }
                    .buttonStyle(DeskButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("接收") { decide(true) }
                    .buttonStyle(DeskButtonStyle(.primary))
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 460)
        .deskSurface()
        .fixedSize(horizontal: false, vertical: true)
    }
}
