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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(peerName.isEmpty ? "接收另一台 Mac 的文件？" : "接收来自「\(peerName)」的文件？")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("确认后才下载文件，接收完成后可再次粘贴。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if offer.names.isEmpty {
                    Text("对方未提供文件名称")
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(Array(offer.names.prefix(3).enumerated()), id: \.offset) { index, name in
                        if index > 0 { Divider().padding(.leading, 34) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(verbatim: name)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    if offer.count > min(offer.names.count, 3) {
                        Divider()
                        Text("另有 \(offer.count - min(offer.names.count, 3)) 项，确认信息仅预览前三项名称")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                Divider()
                Text("共 \(offer.count) 项\(offer.entryCount == offer.count ? "" : "（含 \(offer.entryCount) 个文件和文件夹）") · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: offer.bytes), countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
            .font(.system(size: 13))
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 5) {
                Label("保存到接收文件目录", systemImage: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: ClipboardSync.receivingDirectory)
                    .font(.system(size: 10, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                Text("接收完成后会在此目录创建独立子目录。")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, 90 - (SessionClock.now - offer.createdUptime))
                VStack(alignment: .leading, spacing: 7) {
                    Label(remaining > 0 ? "约 \(Int(ceil(remaining))) 秒后未确认将自动拒绝" : "已到确认时限，等待请求清理…", systemImage: "clock")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    ProgressView(value: min(remaining, 90), total: 90)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .accessibilityLabel("剩余确认时间")
                        .accessibilityValue(remaining > 0 ? "约 \(Int(ceil(remaining))) 秒" : "等待请求清理")
                }
            }

            HStack(spacing: 10) {
                Text("关闭或按 Esc = 拒绝\n每次发送都需确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("拒绝") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 56)
                Button("接收") { decide(true) }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 56)
            }
        }
        .padding(24)
        .frame(width: 440)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }
}
