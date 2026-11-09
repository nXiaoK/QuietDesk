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
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: pendingOffer ? "doc.on.doc" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(pendingOffer ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(pendingOffer ? "1 个文件请求待确认" : "剪贴板与文件").font(.headline)
                        Text(status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let keptFilesMessage {
                            Text(keptFilesMessage).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let cancelReception {
                            Button("中断接收", role: .destructive, action: cancelReception).controlSize(.small)
                        }
                        if keptFilesMessage != nil {
                            Button("打开接收文件目录", action: openFolder).controlSize(.small)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: dismissStatus) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("收起状态提示").accessibilityLabel("收起状态提示")
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.result.outcome == .completed ? "checkmark.circle.fill"
                  : notice.result.outcome == .cancelled ? "minus.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.result.outcome == .completed ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 7) {
                Text(notice.title).font(.headline)
                Text(notice.result.message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.nextStep).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.canOpenFolder {
                    Button("打开接收文件目录", action: openFolder).controlSize(.small)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("收起文件传输结果").accessibilityLabel("收起文件传输结果")
        }
    }
}
