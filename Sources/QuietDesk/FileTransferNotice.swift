import QuietDeskCore
import SwiftUI

struct FileTransferNotice: Identifiable, Equatable {
    let result: ClipboardFileResult
    let keptLocalCopy: Bool
    var id: UUID { result.id }
    var canOpenFolder: Bool { !result.files.isEmpty }

    var title: String {
        switch (result.direction, result.outcome) {
        case (.sending, .completed): return "文件已发送"
        case (.receiving, .completed): return "文件已接收"
        case (_, .cancelled): return "文件传输已取消"
        case (_, .failed): return "文件传输未完成"
        }
    }

    var nextStep: String {
        if canOpenFolder {
            if keptLocalCopy { return "文件已保存到接收目录，未放入剪贴板；保留了新的本机复制内容。可打开目录取用。" }
            return "完整文件已保存在接收目录。打开目录取用；剪贴板之后可能随新的复制内容变化。"
        }
        if result.outcome == .completed { return "如需粘贴，请在接收端操作；新的复制内容可能替换剪贴板。" }
        return "需要重试时，请在发送端重新复制文件，并在接收端再次确认。"
    }
}

struct ClipboardActivityView: View {
    let notice: FileTransferNotice?
    let status: String?
    let pendingOffer: Bool
    let keptFilesMessage: String?
    let cancelReception: (() -> Void)?
    let openFolder: () -> Void
    let dismissResult: () -> Void
    let dismissStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice {
                FileTransferResultView(notice: notice, openFolder: openFolder, dismiss: dismissResult)
            }
            if let status {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: pendingOffer ? "doc.on.doc" : (cancelReception != nil ? "arrow.down.circle" : "arrow.triangle.2.circlepath"))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(pendingOffer ? DeskPalette.amber : DeskPalette.accent)
                            .accessibilityHidden(true)
                        Text(pendingOffer ? "1 个文件请求待确认" : (cancelReception != nil ? "正在接收文件" : "剪贴板与文件"))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(DeskPalette.ink)
                        Spacer(minLength: 4)
                        Button(action: dismissStatus) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DeskPalette.muted)
                        .help("收起状态提示")
                        .accessibilityLabel("收起状态提示")
                    }

                    Text(status)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DeskPalette.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let keptFilesMessage {
                        Text(keptFilesMessage)
                            .font(.caption)
                            .foregroundStyle(DeskPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if cancelReception != nil || keptFilesMessage != nil {
                        HStack {
                            Spacer()
                            if let cancelReception {
                                Button("中断接收", role: .destructive, action: cancelReception)
                                    .buttonStyle(DeskButtonStyle(.danger))
                            }
                            if keptFilesMessage != nil {
                                Button("打开目录", action: openFolder)
                                    .buttonStyle(DeskButtonStyle(.secondary))
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}

struct FileTransferResultView: View {
    let notice: FileTransferNotice
    let openFolder: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: notice.result.outcome == .completed ? "checkmark.circle.fill"
                      : notice.result.outcome == .cancelled ? "minus.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13.5))
                    .foregroundStyle(notice.result.outcome == .completed ? DeskPalette.emerald : DeskPalette.amber)
                    .accessibilityHidden(true)
                Text(notice.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DeskPalette.ink)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DeskPalette.muted)
                .help("收起文件传输结果")
                .accessibilityLabel("收起文件传输结果")
            }

            Text(notice.result.message)
                .font(.system(size: 12.5))
                .foregroundStyle(DeskPalette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(notice.nextStep)
                .font(.system(size: 11.5))
                .foregroundStyle(DeskPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if notice.canOpenFolder {
                    Button("打开目录", action: openFolder)
                        .buttonStyle(DeskButtonStyle(.secondary))
                } else {
                    Button("收起", action: dismiss)
                        .buttonStyle(DeskButtonStyle(.secondary))
                }
            }
            .padding(.top, 2)
        }
    }
}
