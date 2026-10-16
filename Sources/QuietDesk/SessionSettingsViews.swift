import AppKit
import QuietDeskCore
import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var model: DeskModel
    let openCaps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SessionQualitySection(model: model, compact: false)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("连接").font(.headline)
                Toggle(isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) })) { Text("断线自动重连").frame(maxWidth: .infinity, alignment: .leading) }
                Toggle(isOn: $model.showFullScreenStatistics) { Text("全屏显示连接状态").frame(maxWidth: .infinity, alignment: .leading) }
                Text("显示往返延迟、分辨率、视频 FPS 和收发流量。往返延迟约每 5 秒更新，FPS 与流量每秒更新；静止画面 FPS 可能为 0。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("剪贴板与文件").font(.headline)
                Toggle(isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })) { Text("双向同步文字、图片和文件").frame(maxWidth: .infinity, alignment: .leading) }
                Text("文字和图片按控制端焦点同步；文件需逐次确认后下载，完成后再粘贴。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { model.openReceivedFiles() } label: {
                    Label("打开接收文件目录", systemImage: "folder")
                }
                .help("~/Library/Application Support/QuietDesk/Clipboard/received/")
            }
            Divider()
            HStack(spacing: 8) {
                Label("Caps Lock 转发", systemImage: "capslock")
                CapsLockStateLabel(model: model)
                Spacer(minLength: 0)
                Button("设置…", action: openCaps).buttonStyle(.link)
            }
            if !model.lastDisconnect.isEmpty {
                Text("上次断开：\(model.lastDisconnect)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled).help(model.lastDisconnect)
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.switch).controlSize(.small)
        .padding(16).frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CapsLockSettingsView: View {
    @ObservedObject var model: DeskModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "capslock")
                    .font(.system(size: 23)).foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Caps Lock 操作远端").font(.system(size: 15, weight: .semibold))
                    Text("仅在远程画面获得焦点时捕获 Caps Lock。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CapsLockDetails(model: model, compact: false)
            HStack {
                Spacer()
                Button("完成", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13)).controlSize(.regular)
        .padding(22).frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.canvas.releaseControl()
            model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
        }
        .onExitCommand(perform: done)
    }
}

struct FullScreenSettingsView: View {
    @ObservedObject var model: DeskModel
    let close: () -> Void
    @State private var showingCaps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if showingCaps {
                    Button { showingCaps = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).frame(width: 20, height: 24).help("返回控制与设置")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(showingCaps ? "Caps Lock 操作远端" : (model.remoteName.isEmpty ? "控制与设置" : model.remoteName))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if showingCaps {
                        Text("仅在远程画面获得焦点时捕获")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                            Text("\(model.connected ? "已连接" : (model.reconnecting ? "正在重连" : "未连接")) · \(model.latency)")
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("收起控制与设置")
            }
            if showingCaps {
                CapsLockDetails(model: model, compact: true)
            } else {
                HStack(spacing: 8) {
                    Button { model.canvas.releaseControl() } label: {
                        VStack(spacing: 3) {
                            Label("释放控制", systemImage: "cursorarrow")
                            Text("⌃⌥ Esc").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                    Button { close(); model.toggleFullScreen() } label: {
                        VStack(spacing: 3) {
                            Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                            Text("⌃⌘F").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                Divider()
                SessionQualitySection(model: model, compact: true)
                Divider()
                VStack(spacing: 6) {
                    Toggle(isOn: $model.showFullScreenStatistics) { Text("显示连接状态").frame(maxWidth: .infinity, alignment: .leading) }
                        .help("显示往返延迟、分辨率、视频 FPS 和收发流量。往返延迟约每 5 秒更新，FPS 与流量每秒更新；静止画面 FPS 可能为 0。")
                    Toggle(isOn: Binding(get: { model.autoReconnect }, set: { model.setAutoReconnect($0) })) { Text("断线自动重连").frame(maxWidth: .infinity, alignment: .leading) }
                    Toggle(isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) })) { Text("双向同步文字、图片和文件").frame(maxWidth: .infinity, alignment: .leading) }
                        .help("文字和图片按控制端焦点同步；文件需逐次确认后下载，完成后再粘贴。")
                }
                .toggleStyle(.switch).controlSize(.small)
                Divider()
                VStack(spacing: 0) {
                    Button { model.openReceivedFiles() } label: {
                        HStack {
                            Label("打开接收文件目录", systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.frame(minHeight: 28)
                    }
                    .help("~/Library/Application Support/QuietDesk/Clipboard/received/")
                    Button {
                        showingCaps = true
                        model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true)
                    } label: {
                        HStack(spacing: 8) {
                            Label("Caps Lock 转发", systemImage: "capslock")
                            CapsLockStateLabel(model: model)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.frame(minHeight: 28)
                    }
                }
                .buttonStyle(.plain)
                if !model.lastDisconnect.isEmpty {
                    Text("上次断开：\(model.lastDisconnect)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled).help(model.lastDisconnect)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 7) {
                Button { model.pushClipboard() } label: { Label("发送文字", systemImage: "doc.badge.arrow.up") }
                    .disabled(!model.connected)
                Button { model.pullClipboard() } label: { Label("获取文字", systemImage: "arrow.down.doc") }
                    .disabled(!model.connected)
                Spacer(minLength: 0)
                Button(model.active ? "断开" : "返回连接") {
                    close()
                    if model.active { model.stop() } else { model.toggleFullScreen() }
                }
                .foregroundStyle(model.active ? Color.red : Color.primary)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(14).frame(width: 324, height: 568)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.active) { _, active in if !active { close() } }
        .onExitCommand(perform: close)
    }
}

private struct SessionQualitySection: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    private var changing: Bool {
        model.videoTuning?.pending != nil || (model.connected && model.supportsLiveSettings && model.viewerSettings != model.activeVideoState?.settings)
    }

    private var settingsMessage: String? {
        let status = model.videoSettingsStatus
        guard !status.isEmpty, !status.hasPrefix("当前生效："), !status.hasPrefix("已生效："), !status.hasPrefix("正在应用：") else { return nil }
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            HStack(spacing: 7) {
                Text("本次会话画质").font(.headline)
                Text("仅本次会话")
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: compact ? 5 : 7) {
                GridRow {
                    Text("最长边").foregroundStyle(.secondary)
                    Picker("最长边", selection: Binding(get: { model.viewerSettings.longestEdge }, set: { value in
                        var settings = model.viewerSettings; settings.longestEdge = value; model.chooseViewerSettings(settings)
                    })) {
                        ForEach(model.viewerLongestEdges, id: \.self) { Text(StreamSettings.resolutionLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("帧率上限").foregroundStyle(.secondary)
                    Picker("帧率上限", selection: Binding(get: { model.viewerSettings.framesPerSecond }, set: { value in
                        var settings = model.viewerSettings; settings.framesPerSecond = value; model.chooseViewerSettings(settings)
                    })) {
                        ForEach(StreamSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("目标码率").foregroundStyle(.secondary)
                    Picker("目标码率", selection: Binding(get: { model.viewerSettings.megabits }, set: { value in
                        var settings = model.viewerSettings; settings.megabits = value; model.chooseViewerSettings(settings)
                    })) {
                        ForEach(model.viewerBitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
            }
            .pickerStyle(.menu).controlSize(.small)
            .disabled(!model.connected || !model.supportsLiveSettings)
            if !model.connected {
                Text("连接后可即时调整画质，无需停止共享。")
                    .foregroundStyle(.secondary)
            } else if !model.supportsLiveSettings {
                Label("共享端版本不支持会话中调整画质", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.orange)
                Text("当前使用共享端画质。请将家里 Mac 的 QuietDesk 更新到 0.4.0 或更新版本。")
                    .foregroundStyle(.secondary)
            } else if changing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在应用…")
                }
                if let state = model.activeVideoState {
                    Text("当前仍为 \(state.settings.summary)").foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let message = settingsMessage {
                Label {
                    Text(message).textSelection(.enabled)
                } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                .lineLimit(compact ? 3 : nil).help(message)
                if let state = model.activeVideoState {
                    Text("当前生效 \(state.settings.summary)").foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let state = model.activeVideoState {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    Text("已生效")
                    Spacer(minLength: 0)
                    Text("视频尺寸 \(state.width) × \(state.height)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !compact {
                Text(model.supportsExtendedVideoSettings ? "已保存画质与手动选择优先；首次 RTT <10 ms 的低延迟新连接默认最高画质。" : "已保存的连接会恢复画质；原分辨率和 30 Mbps 需共享端更新后使用。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: compact ? 11 : 12))
        .help("画质调整只改变当前共享会话，不修改共享端默认值；同一连接记录会恢复上次确认的画质。无已保存画质时，首次 RTT 低于 10 ms 默认选最高画质，手动选择优先。RTT 不代表网络类型。原分辨率不放大，上限单边 8192 像素、总计 3600 万像素；H.264 仍为有损。可连续选择，等待时会合并为最新设置。")
    }
}

private struct CapsLockStateLabel: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        Text(!model.capsLockEnabled ? "已关闭" : (model.capsLockRunning ? "已开启" : "待生效"))
            .font(.system(size: 10))
            .foregroundStyle(!model.capsLockEnabled ? Color.secondary : (model.capsLockRunning ? Color.green : Color.orange))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((!model.capsLockEnabled ? Color.secondary : (model.capsLockRunning ? Color.green : Color.orange)).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct CapsLockDetails: View {
    @ObservedObject var model: DeskModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            Toggle(isOn: Binding(get: { model.capsLockEnabled }, set: { model.setCapsLockEnabled($0) })) { Text("启用 Caps Lock 转发").frame(maxWidth: .infinity, alignment: .leading) }
                .toggleStyle(.switch).controlSize(.small)
                .padding(compact ? 9 : 11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text("按键行为").font(.headline)
                if compact {
                    VStack(alignment: .leading, spacing: 8) {
                        CapsBehaviorCard(key: "⇪ 短按", title: "切换中英文", detail: "切换远端输入法", compact: true)
                        CapsBehaviorCard(key: "⇪ 按住 ≥ 0.6 秒后松开", title: "切换大写锁定", detail: "开启 / 关闭远端大写", compact: true)
                        CapsBehaviorCard(key: "大写已开启", title: "短按先解除大写", detail: "再次短按才切换中英文", compact: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        CapsBehaviorCard(key: "⇪ Caps Lock · 短按", title: "切换中英文", detail: "切换远端输入法", compact: false)
                        CapsBehaviorCard(key: "按住 ≥ 0.6 秒后松开", title: "切换大写锁定", detail: "开启 / 关闭远端大写", compact: false)
                        CapsBehaviorCard(key: "大写已开启", title: "短按先解除大写", detail: "再次短按才切换中英文", compact: false)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("本机权限").font(.headline)
                    Spacer()
                    Button("重新检测") { model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) }
                        .controlSize(.small)
                }
                VStack(spacing: 0) {
                    CapsPermissionRow(title: "辅助功能", symbol: "accessibility", effective: model.localAccessibility, compact: compact) { model.requestAccessibility() }
                    Divider().padding(.horizontal, 10)
                    CapsPermissionRow(title: "输入监控", symbol: "keyboard.badge.eye", effective: model.localInputMonitoring, compact: compact) { model.requestInputMonitoring() }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Text("当前应用：\(Bundle.main.bundleURL.path)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3).textSelection(.enabled).help(Bundle.main.bundleURL.path)
                Text("两项权限均生效后才能监听。系统中已勾选但未生效时，请完全退出后重开，无需反复添加。")
                    .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("实际状态").fontWeight(.semibold)
                    CapsLockStateLabel(model: model)
                    if model.capsLockRunning {
                        Text("本机监听已就绪").foregroundStyle(.secondary)
                    }
                }
                if !model.inputStatus.isEmpty {
                    Text(model.inputStatus)
                        .foregroundStyle(model.capsLockEnabled && !model.capsLockRunning ? Color.orange : Color.secondary)
                        .lineLimit(compact ? 3 : nil).textSelection(.enabled).help(model.inputStatus)
                }
            }
            .font(.system(size: compact ? 10 : 11))
        }
    }
}

private struct CapsBehaviorCard: View {
    let key: String
    let title: String
    let detail: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 7) {
            Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
            if compact {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 27 : 76, alignment: .topLeading)
        .padding(compact ? 8 : 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CapsPermissionRow: View {
    let title: String
    let symbol: String
    let effective: Bool
    let compact: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: compact ? 5 : 8) {
            Label(title, systemImage: symbol).font(.system(size: compact ? 11 : 12))
            Spacer(minLength: 0)
            Text(effective ? "已生效" : "未生效")
                .font(.system(size: 10)).foregroundStyle(effective ? Color.green : Color.orange)
            Button(compact ? "系统设置…" : "打开系统设置…", action: openSettings).controlSize(.small)
        }
        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 7 : 8)
    }
}
