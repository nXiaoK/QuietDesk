import AppKit
import SwiftUI
import IOKit.hid

@MainActor
final class PermissionGuide: NSWindowController {
    enum Kind {
        case screenRecording, accessibility, inputMonitoring

        var title: String {
            switch self {
            case .screenRecording: return "屏幕录制"
            case .accessibility: return "辅助功能"
            case .inputMonitoring: return "输入监控"
            }
        }

        var settingsURL: URL? {
            let pane: String
            switch self {
            case .screenRecording: pane = "Privacy_ScreenCapture"
            case .accessibility: pane = "Privacy_Accessibility"
            case .inputMonitoring: pane = "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)
        }

        var isEffective: Bool {
            switch self {
            case .screenRecording: return CGPreflightScreenCaptureAccess()
            case .accessibility: return AXIsProcessTrusted()
            case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            }
        }
    }

    private let state: PermissionGuideState
    private let onRefresh: () -> Void
    var isVisible: Bool { window?.isVisible == true }

    init(bundleURL: URL = Bundle.main.bundleURL, onRefresh: @escaping () -> Void) {
        state = PermissionGuideState(bundleURL: bundleURL)
        self.onRefresh = onRefresh
        let panel = PermissionGuidePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.backgroundColor = .windowBackgroundColor
        panel.animationBehavior = .utilityWindow
        super.init(window: panel)
        let content = PermissionGuideHostingView(rootView: PermissionGuideView(state: state,
            onRefresh: { [weak self] in self?.onRefresh() }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(for kind: Kind) {
        state.kind = kind
        state.effective = kind.isEffective
        guard let window else { return }
        window.title = "QuietDesk · \(kind.title)权限引导"
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.minY + 20))
        }
        window.orderFrontRegardless()
    }

    func refreshStatus() {
        guard isVisible else { return }
        state.effective = state.kind.isEffective
    }
}

@MainActor
private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PermissionGuideState: ObservableObject {
    @Published var kind: PermissionGuide.Kind = .accessibility
    @Published var effective = false
    let bundleURL: URL
    let applicationURL: URL?

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        var directory: ObjCBool = false
        applicationURL = bundleURL.pathExtension.lowercased() == "app"
            && FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &directory) && directory.boolValue
            ? bundleURL : nil
    }
}

@MainActor
private final class PermissionGuideHostingView: NSHostingView<PermissionGuideView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private struct PermissionGuideView: View {
    @ObservedObject var state: PermissionGuideState
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 16) {
                if let applicationURL = state.applicationURL {
                    PermissionApplicationIcon(applicationURL: applicationURL)
                        .frame(width: 76, height: 76)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .help("将当前正在运行的应用拖到系统设置的权限列表")
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                        .frame(width: 76, height: 76)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.applicationURL == nil ? "当前运行的不是 .app 应用" : "拖动应用图标到权限列表")
                        .font(.system(size: 15, weight: .semibold))
                    Text(state.applicationURL == nil
                         ? "命令行运行目录不能作为应用拖入。请先打开已打包的 QuietDesk.app，再从应用中前往授权。"
                         : "在系统设置的「\(state.kind.title)」列表添加 QuietDesk，再手动打开它的开关。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.applicationURL != nil {
                        Text("页面不接受拖入时，请使用「+」选择当前应用；没有「+」时，按系统提示在现有列表中开启。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: state.effective ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state.effective ? Color.green : Color.secondary)
                Text("\(state.kind.title)：\(state.effective ? "系统权限已生效" : "尚未生效")")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Button("重新检测", action: onRefresh).controlSize(.small)
                if let applicationURL = state.applicationURL {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([applicationURL]) }
                        .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("\(state.applicationURL == nil ? "运行目录" : "当前应用")：\(state.bundleURL.path)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(state.bundleURL.path)
                    .fixedSize(horizontal: false, vertical: true)
                Text("系统已开启但仍未生效时，请完全退出 QuietDesk 后重开。此面板不会替你开启权限。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct PermissionApplicationIcon: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context: Context) -> PermissionApplicationDragView {
        PermissionApplicationDragView(applicationURL: applicationURL)
    }

    func updateNSView(_ view: PermissionApplicationDragView, context: Context) { }
}

@MainActor
private final class PermissionApplicationDragView: NSView, NSDraggingSource {
    private let applicationURL: URL
    private let icon: NSImage
    private var pressedAt: NSPoint?

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("拖动当前 QuietDesk 应用")
        setAccessibilityHelp("将应用图标拖到系统设置的权限列表，再手动打开权限开关")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: iconRect)
    }

    private var iconRect: NSRect {
        let edge = min(60, bounds.width, bounds.height)
        return NSRect(x: bounds.midX - edge / 2, y: bounds.midY - edge / 2, width: edge, height: edge)
    }

    override func mouseDown(with event: NSEvent) { pressedAt = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { pressedAt = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressedAt.x, point.y - pressedAt.y) >= 3,
              FileManager.default.fileExists(atPath: applicationURL.path) else { return }
        self.pressedAt = nil
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(iconRect, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
