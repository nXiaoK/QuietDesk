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

        var symbol: String {
            switch self {
            case .screenRecording: return "display"
            case .accessibility: return "figure.wave.circle"
            case .inputMonitoring: return "keyboard"
            }
        }

        var purpose: String {
            switch self {
            case .screenRecording: return "用于被控 Mac 传送画面；生效后请返回“共享这台 Mac”点“开启共享”，不会自动开始。"
            case .accessibility: return "在被控 Mac 上用于接受键盘鼠标控制；在控制 Mac 上用于本机键盘监听。两台 Mac 的授权不能互相代替。"
            case .inputMonitoring: return "用于这台控制 Mac 监听 Caps Lock 与系统快捷键；不代替被控 Mac 的控制授权。"
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
    private let permissionCheck: (Kind) -> Bool
    private let onRefresh: () -> Void
    var isVisible: Bool { window?.isVisible == true }

    init(bundleURL: URL = Bundle.main.bundleURL,
         permissionCheck: @escaping (Kind) -> Bool = { $0.isEffective },
         openSettings: @escaping (Kind) -> Void = { kind in
             if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
         },
         onRefresh: @escaping () -> Void) {
        state = PermissionGuideState(bundleURL: bundleURL)
        self.permissionCheck = permissionCheck
        self.onRefresh = onRefresh
        let panel = PermissionGuidePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
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
            onRefresh: { [weak self] in self?.onRefresh() },
            openSettings: openSettings,
            done: { [weak self] in self?.close() }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(for kind: Kind) {
        state.kind = kind
        state.effective = permissionCheck(kind)
        if state.effective {
            close()
            return
        }
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
        state.effective = permissionCheck(state.kind)
        if state.effective { close() }
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

private enum GuidePalette {
    static let accent = adaptive(0x0A74E6, 0x68B3FF)
    static let actionFill = adaptive(0x0A74E6, 0x0A68D0)
    static let ink = adaptive(0x1D232A, 0xEEF1F6)
    static let secondary = adaptive(0x525E6B, 0xAEB9C6)
    static let canvas = adaptive(0xF5F6F8, 0x1E2228)
    static let card = adaptive(0xFFFFFF, 0x272C34)
    static let inset = adaptive(0xECEFF3, 0x2A303A)
    static let hairline = adaptive(0xDFE3E8, 0x3D444F)
    static let emerald = adaptive(0x127A50, 0x5CD6A5)
    static let amber = adaptive(0x94540F, 0xF3BC6E)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        })
    }
}

@MainActor
private struct PermissionGuideView: View {
    @ObservedObject var state: PermissionGuideState
    let onRefresh: () -> Void
    let openSettings: (PermissionGuide.Kind) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("允许" + state.kind.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(GuidePalette.ink)
                .accessibilityAddTraits(.isHeader)

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: state.kind.symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(GuidePalette.secondary)
                    .frame(width: 28, alignment: .center)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text(state.kind.purpose + " 系统设置中已勾选不等于当前进程实际生效。")
                    .font(.system(size: 13))
                    .foregroundStyle(GuidePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            applicationCard

            HStack(spacing: 10) {
                guideButton("打开\(state.kind.title)系统设置…", primary: false) {
                    openSettings(state.kind)
                }
                if let applicationURL = state.applicationURL {
                    guideButton("在访达中显示", primary: false) {
                        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.effective ? "checkmark.circle" : "info.circle")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(state.effective ? GuidePalette.emerald : GuidePalette.amber)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.effective ? "系统权限已生效" : "尚未生效")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.effective ? GuidePalette.emerald : GuidePalette.amber)
                    if !state.effective {
                        Text("完全退出后重开，再返回检测；此面板不会替你开启权限。")
                            .font(.system(size: 12))
                            .foregroundStyle(GuidePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                (state.effective ? GuidePalette.emerald : GuidePalette.amber).opacity(0.09),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder((state.effective ? GuidePalette.emerald : GuidePalette.amber).opacity(0.25), lineWidth: 1)
            }

            Text("\(state.applicationURL == nil ? "运行目录" : "当前应用")：\(state.bundleURL.path)")
                .font(.system(size: 12))
                .foregroundStyle(GuidePalette.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(state.bundleURL.path)

            HStack(spacing: 10) {
                Spacer()
                guideButton("重新检测", primary: false, action: onRefresh)
                guideButton("完成", primary: true, action: done)
            }
            .padding(.top, 4)
        }
        .tint(GuidePalette.accent)
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(GuidePalette.canvas)
    }

    private func guideButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? Color.white : GuidePalette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 31)
                .background(
                    primary ? GuidePalette.actionFill : GuidePalette.card,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(primary ? .clear : GuidePalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var applicationCard: some View {
        HStack(spacing: 14) {
            if let applicationURL = state.applicationURL {
                PermissionApplicationIcon(applicationURL: applicationURL)
                    .frame(width: 56, height: 56)
                    .help("将当前正在运行的应用拖到系统设置的权限列表")
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(GuidePalette.secondary)
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(state.applicationURL?.lastPathComponent ?? "当前运行目录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GuidePalette.ink)
                Text(state.applicationURL == nil
                     ? "请先打开已打包的 QuietDesk.app，再从应用中前往授权。"
                     : "拖入系统隐私列表，或通过「+」选择当前应用。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(GuidePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(GuidePalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(GuidePalette.hairline, lineWidth: 1)
        }
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
        let edge = min(54, bounds.width, bounds.height)
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
