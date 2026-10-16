import SwiftUI
import AppKit
import Carbon
import QuietDeskCore

@main
struct QuietDeskApp: App {
    @StateObject private var model = DeskModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let state = DeskModel()
        _model = StateObject(wrappedValue: state)
        appDelegate.model = state
    }

    var body: some Scene {
        Window("QuietDesk", id: "main") {
            DeskView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.initialLaunch(atLogin: appDelegate.launchedAtLogin)
                }
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("远程控制") {
                Button(model.isFullScreen ? "退出全屏" : "进入全屏") { model.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button("释放键盘鼠标") { model.canvas.releaseControl() }
                    .keyboardShortcut(.escape, modifiers: [.control, .option])
                Button("断开连接 / 停止共享") { model.stop() }.disabled(!model.active && !model.working)
            }
        }
        MenuBarExtra("QuietDesk", systemImage: "display.2") {
            TrayView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DeskModel?
    private(set) var launchedAtLogin = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.mode == .host && (model?.active == true || model?.working == true || model?.autoStartSharing == true))
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin = launchedAtLogin || NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        model?.initialLaunch(atLogin: launchedAtLogin)
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshLoginStatus() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.prepareShowWindow()
        model?.mainWindow?.deminiaturize(nil)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

struct DeskView: View {
    @ObservedObject var model: DeskModel
    @State private var showCode = false
    @State private var showCapsSettings = false
    @State private var showOptions = false
    @State private var showFullScreenMenu = false

    private var locked: Bool { model.active || model.working }
    private var immersive: Bool { model.isFullScreen && model.mode == .viewer }

    var body: some View {
        VStack(spacing: 0) {
            if !immersive {
                HStack(spacing: 12) {
                    Image(systemName: "display.2").font(.system(size: 26)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("QuietDesk").font(.title2.weight(.semibold))
                        Text("为两台 Mac 之间的专注工作而做").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("模式", selection: $model.mode) {
                        ForEach(DeskModel.Mode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented).frame(width: 310).disabled(locked)
                }
                .padding(20)

                Divider()
            }

            if model.mode == .viewer {
                if !immersive { viewerControls }
                ZStack {
                    Color.black
                    CanvasView(canvas: model.canvas)
                    if !model.connected {
                        VStack(spacing: 14) {
                            Image(systemName: "macbook.and.macmini").font(.system(size: 48, weight: .light))
                            Text(model.reconnecting ? "正在自动重连…" : model.working ? "正在连接家里的 Mac…" : "你的另一张书桌").font(.title2)
                            Text(model.reconnecting ? model.status : model.working ? "正在验证配对码并准备画面" : "输入地址和配对码，继续手边的工作")
                                .font(.callout).foregroundStyle(.gray)
                            if model.working { ProgressView().controlSize(.small) }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .allowsHitTesting(false)
                    }
                }
                .frame(minWidth: 760, minHeight: 320, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if immersive {
                        Button {
                            model.canvas.releaseControl()
                            showFullScreenMenu.toggle()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.25)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("展开控制与设置")
                        .help("点击展开控制与设置")
                        .padding(.trailing, 16)
                        .popover(isPresented: $showFullScreenMenu, arrowEdge: .leading) {
                            ScrollView {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("控制与设置").font(.headline)
                                        Spacer()
                                        Button("收起") { showFullScreenMenu = false }
                                    }.padding(16)
                                    HStack {
                                        Button("退出全屏") { showFullScreenMenu = false; model.toggleFullScreen() }
                                        Button("释放控制") { model.canvas.releaseControl() }
                                    }
                                    Divider().padding(.top, 14)
                                    connectionSettings
                                    Divider()
                                    capsSettings
                                    Divider()
                                    HStack {
                                        Button("发送文字") { model.pushClipboard() }.disabled(!model.connected)
                                        Button("获取文字") { model.pullClipboard() }.disabled(!model.connected)
                                        Spacer()
                                        Button(model.active ? "断开" : "返回连接") {
                                            showFullScreenMenu = false
                                            if model.active { model.stop() } else { model.toggleFullScreen() }
                                        }
                                    }.padding(16)
                                }
                            }
                            .frame(width: 400, height: min(680, max(360, (model.mainWindow?.frame.height ?? 760) - 100)))
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if immersive && model.showFullScreenStatistics {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("延迟 \(model.latency) · \(model.resolution.isEmpty ? "—" : model.resolution)")
                            Text("\(model.frameRate) · 收发 \(model.traffic)")
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                        .padding(10).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .padding(16).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if immersive && model.clipboardStatus.hasPrefix("正在") {
                        Text(model.clipboardStatus).font(.caption).lineLimit(3)
                            .frame(maxWidth: 360, alignment: .leading)
                            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(12).allowsHitTesting(false)
                    }
                }
                if !immersive {
                    HStack {
                        Text(model.controlling ? "正在控制远端 · 按 ⌃⌥Esc 释放键盘鼠标" : "点击画面操作 · ⌃⌥Esc 返回本机")
                        Spacer()
                        capsButton
                        optionsButton
                        Button { model.pushClipboard() } label: { Label("发送文字", systemImage: "arrow.up.doc.on.clipboard") }
                            .disabled(!model.connected)
                        Button { model.pullClipboard() } label: { Label("获取文字", systemImage: "arrow.down.doc") }
                            .disabled(!model.connected)
                        Button { model.toggleFullScreen() } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
                            .help("进入全屏（⌃⌘F）")
                    }
                    .font(.caption).padding(.horizontal, 16).padding(.vertical, 9)
                }
            } else {
                hostControls
            }

            if !immersive {
                Divider()
                HStack(spacing: 9) {
                    Circle().fill(model.connected ? .green : model.active ? .orange : .secondary).frame(width: 7, height: 7)
                    Text(model.status).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if !model.resolution.isEmpty { Text(model.resolution).monospacedDigit() }
                    if model.connected { Text(model.latency).monospacedDigit().help("网络往返延迟（RTT）") }
                    Text(model.frameRate).monospacedDigit()
                    Text(model.traffic).monospacedDigit()
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 16).padding(.vertical, 12)
                if !model.clipboardStatus.isEmpty {
                    Text(model.clipboardStatus).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
                }
                if !model.inputStatus.isEmpty {
                    Text(model.inputStatus).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
        }
        .background(.background)
        .background(WindowReader { model.attachWindow($0) }.frame(width: 0, height: 0))
        .frame(minWidth: 860, minHeight: 640)
        .alert("QuietDesk", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: immersive) { _, _ in showFullScreenMenu = false; showOptions = false; showCapsSettings = false }
    }

    private var optionsButton: some View {
        Button { showOptions = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("画质与连接设置")
            .help("画质、连接与剪贴板设置")
            .popover(isPresented: $showOptions) { connectionSettings }
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画质与连接设置").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("画质 · 连接中即时调整").font(.headline)
                    if model.connected && !model.supportsLiveSettings {
                        Text("请将家里 Mac 更新到 0.4.0，以支持动态调节。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("最长边", selection: Binding(get: { model.viewerSettings.longestEdge }, set: { value in
                            var settings = model.viewerSettings; settings.longestEdge = value; model.chooseViewerSettings(settings)
                        })) {
                            ForEach(StreamSettings.longestEdges, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("帧率上限", selection: Binding(get: { model.viewerSettings.framesPerSecond }, set: { value in
                            var settings = model.viewerSettings; settings.framesPerSecond = value; model.chooseViewerSettings(settings)
                        })) {
                            ForEach(StreamSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        Picker("目标码率", selection: Binding(get: { model.viewerSettings.megabits }, set: { value in
                            var settings = model.viewerSettings; settings.megabits = value; model.chooseViewerSettings(settings)
                        })) {
                            ForEach(StreamSettings.bitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                    }
                    if let state = model.activeVideoState {
                        Text("生效值：\(state.settings.summary)\n视频尺寸：\(state.width) × \(state.height)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top) {
                        if model.videoTuning?.pending != nil { ProgressView().controlSize(.small) }
                        Text(model.connected ? model.videoSettingsStatus : "连接后可动态调整，无需先停止共享。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .disabled(!model.connected || !model.supportsLiveSettings)
            }
            Toggle("全屏显示连接状态", isOn: $model.showFullScreenStatistics)
            Text("显示网络往返延迟、分辨率、视频 FPS 和收发流量。延迟约每 5 秒更新，静止画面的 FPS 可能为 0。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("断线自动重连", isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) }))
            Toggle("双向同步文字、图片和文件", isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) }))
            Text("文字和图片自动同步；文件先提示接收，确认后下载，完成后再粘贴。")
                .font(.caption).foregroundStyle(.secondary)
            Button("打开接收文件目录") { model.openReceivedFiles() }
            if !model.lastDisconnect.isEmpty {
                Divider()
                Text("上次断开：\(model.lastDisconnect)").font(.caption).textSelection(.enabled)
            }
        }
        .padding(18).frame(width: 360)
    }

    private var capsButton: some View {
        Button { showCapsSettings = true } label: {
            Label(model.capsLockEnabled ? "Caps Lock ✓" : "Caps Lock", systemImage: "keyboard")
        }
        .popover(isPresented: $showCapsSettings) { capsSettings }
    }

    private var capsSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caps Lock 操作远端").font(.headline)
            Text("短按切换中英文；按住至少 0.6 秒后松开，切换大写锁定。大写锁定开启时，短按先解除大写。")
            Toggle("启用 Caps Lock 转发", isOn: Binding(get: { model.capsLockEnabled },
                set: { model.setCapsLockEnabled($0) }))
            Text("公司 Mac 需授权辅助功能和输入监控。仅在远程画面获得焦点时捕获 Caps Lock。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("辅助功能权限") { model.requestAccessibility() }
                Button("输入监控权限") { model.requestInputMonitoring() }
            }
            if !model.inputStatus.isEmpty { Text(model.inputStatus).font(.caption).textSelection(.enabled) }
        }
        .font(.callout).padding(20).frame(width: 340)
    }

    private var viewerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("家里 Mac 的地址").font(.caption).foregroundStyle(.secondary)
                    TextField("域名或 IP", text: $model.address).textFieldStyle(.roundedBorder).frame(minWidth: 160)
                }
                .disabled(locked)
                VStack(alignment: .leading, spacing: 5) {
                    Text("映射后的端口").font(.caption).foregroundStyle(.secondary)
                    TextField("5908", text: $model.port).textFieldStyle(.roundedBorder).frame(width: 85)
                }
                .disabled(locked)
                VStack(alignment: .leading, spacing: 5) {
                    Text("家里 Mac 显示的配对码").font(.caption).foregroundStyle(.secondary)
                    SecureField("粘贴完整配对码", text: $model.viewerCode).textFieldStyle(.roundedBorder).frame(minWidth: 180)
                }
                .disabled(locked)
                if locked {
                    Button("断开") { model.stop() }.controlSize(.large)
                } else {
                    Button("连接") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            if !model.connections.isEmpty {
                HStack {
                    Menu("最近连接") {
                        ForEach(model.connections) { record in
                            Button("\(record.name) · \(record.address):\(record.port)") { model.quickConnect(record) }
                        }
                    }
                    .disabled(locked)
                    ForEach(Array(model.connections.prefix(2))) { record in
                        Button(record.name) { model.quickConnect(record) }.disabled(locked)
                            .help("\(record.address):\(record.port)")
                    }
                    Spacer()
                    Menu("管理记录") {
                        ForEach(model.connections) { record in
                            Button("移除 \(record.name) · \(record.address)") { model.removeConnection(record) }
                        }
                    }.disabled(locked)
                }.font(.caption)
            }
        }.padding(16)
    }

    private var hostControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把这张书桌带走").font(.largeTitle.weight(.semibold))
                    Text("在家里 Mac 开启共享，然后从公司 Mac 连接。使用现有的 TCP 端口映射。")
                        .foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("默认共享设置", systemImage: "slider.horizontal.3").font(.headline)
                            Spacer()
                            Text("H.264 · 加密连接").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 24) {
                            Picker("显示器", selection: $model.displayID) {
                                ForEach(model.screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                            }
                            HStack { Text("监听端口"); TextField("5908", text: $model.hostPort).frame(width: 80) }
                        }
                        HStack(spacing: 24) {
                            Picker("最长边", selection: $model.settings.longestEdge) {
                                Text("1280 · 省流").tag(1280)
                                Text("1920 · 办公").tag(1920)
                                Text("2560 · 清晰").tag(2560)
                                Text("3840 · 高分辨率").tag(3840)
                            }
                            Picker("帧率上限", selection: $model.settings.framesPerSecond) {
                                Text("10 fps").tag(10); Text("15 fps").tag(15); Text("30 fps").tag(30)
                            }
                            Picker("目标码率", selection: $model.settings.megabits) {
                                ForEach([1, 2, 3, 5, 8, 12], id: \.self) { Text("\($0) Mbps").tag($0) }
                            }
                        }
                        Text("建议先用 1920 / 15 fps / 3 Mbps。静止画面不重复编码；码率是目标值，关键帧和网络开销可能产生短时峰值。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.connected, let state = model.activeVideoState {
                            Text("当前会话：\(state.settings.summary)。控制端动态调整不会修改这里的默认值。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10).disabled(locked)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("后台与登录启动", systemImage: "power").font(.headline)
                        Toggle("登录后自动启动 QuietDesk", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                        Toggle("启动后自动开启共享", isOn: $model.autoStartSharing)
                        Toggle("登录自动启动时最小化窗口", isOn: $model.minimizeAtLogin)
                        Toggle("双向同步文字、图片和文件", isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) }))
                        Text("文件和文件夹需接收端确认后才下载；文字和图片仍自动同步。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("打开接收文件目录") { model.openReceivedFiles() }
                        if model.loginNeedsApproval { Button("在系统设置中允许登录启动") { LaunchSettings.openSettings() } }
                        Text("建议先将应用移到应用程序文件夹并完成屏幕录制、辅助功能授权。登录前 / FileVault 解锁前无法共享。关闭共享窗口后仍可从菜单栏打开，退出应用会停止共享。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("配对码", systemImage: "key.horizontal").font(.headline)
                        Text("持有码即可查看和控制这台 Mac，请只交给自己的设备。配对码保存在本机钥匙串。")
                            .font(.callout).foregroundStyle(.secondary)
                        if showCode {
                            Text(model.hostCode.isEmpty ? "尚未生成" : model.hostCode)
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                        HStack {
                            Button("复制配对码") { model.copyHostCode() }
                            Button(showCode ? "隐藏" : "显示") { model.prepareHostCode(); showCode.toggle() }
                            Spacer()
                            Button("重新生成") { model.regenerateKey() }.disabled(locked)
                        }
                    }
                    .padding(10)
                }
                HStack(spacing: 12) {
                    Button("屏幕录制权限") { model.openScreenPermission() }
                    Button("辅助功能权限") { model.requestAccessibility() }
                    Spacer()
                    if locked {
                        Button("停止共享") { model.stop() }.controlSize(.large)
                    } else {
                        Button("开启共享") { model.startHosting() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                Text("共享期间 Mac 保持唤醒。支持一个显示器与一个控制连接；暂不包含音频和登录窗口控制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}

private struct TrayView: View {
    @ObservedObject var model: DeskModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Button("打开主窗口") {
            model.prepareShowWindow()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.mainWindow?.deminiaturize(nil)
            model.mainWindow?.makeKeyAndOrderFront(nil)
        }
        if model.mode == .host {
            Button(model.active || model.working ? "停止共享" : "开启共享") {
                if model.active || model.working { model.stop() } else { model.startHosting() }
            }
        }
        Divider()
        Button("退出 QuietDesk") { NSApp.terminate(nil) }
    }
}

private struct WindowReader: NSViewRepresentable {
    let resolved: (NSWindow) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.resolved = resolved; return view }
    func updateNSView(_ view: Probe, context: Context) { view.resolved = resolved }
    final class Probe: NSView {
        var resolved: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { resolved?(window) } }
    }
}
