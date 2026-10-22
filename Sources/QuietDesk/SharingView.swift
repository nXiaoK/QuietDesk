import SwiftUI
import AppKit
import QuietDeskCore

struct SharingView: View {
    @ObservedObject var model: DeskModel
    let openTraffic: () -> Void
    @State private var showCode = false
    @State private var confirmingRegeneration = false
    @State private var previousCode = ""
    @State private var showRelaySettings = false

    private var locked: Bool { model.active || model.working }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if geometry.size.width >= 960 {
                    HStack(alignment: .top, spacing: 24) {
                        mainColumn
                            .frame(maxWidth: .infinity)
                        secondaryColumn
                            .frame(width: 288)
                    }
                    .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        mainColumn
                        secondaryColumn
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { model.prepareHostCode() }
        .onDisappear { previousCode = "" }
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(enabled: model.relayEnabled, nodes: model.relayNodes, deviceID: model.relayDeviceID,
                              locked: model.relaySettingsLocked, measurements: model.relayNodeMeasurements,
                              loadTrust: model.relayCertificate, saveNode: model.saveRelayNode, save: model.saveRelayConfiguration)
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRelaySettings = false; confirmingRegeneration = false
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusCard
            pairingSection
            defaultsSection
        }
    }

    private var secondaryColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            launchSection
            clipboardSection
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("自托管中继", systemImage: "network").font(.headline)
                    Text(model.relayEnabled ? model.relayHostStatus : "未启用；现有直连方式保持可用。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.relayEnabled, model.relayNodes.count > 1 {
                        Text("共享时在 \(model.relayNodes.count) 个节点同时登记，另一台 Mac 可经任一节点连接。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.relayEnabled, !model.relayDeviceID.isEmpty {
                        Text("本机设备标识").font(.caption).foregroundStyle(.secondary)
                        Text(model.relayDeviceID).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.relayEnabled { RelayPeerAssistPicker(model: model) }
                    Button("中继设置…") { showRelaySettings = true }.buttonStyle(.link)
                }
            }
            Button(action: openTraffic) { Label("设备流量统计…", systemImage: "chart.bar.xaxis") }
                .buttonStyle(.link)
            Text("共享期间 Mac 保持唤醒。支持一个显示器与一个控制连接；暂不包含音频和登录窗口控制。开启共享后仍可在「连接家里 Mac」连接其他 Mac，连接期间这台 Mac 暂不接受控制连接；正被控制时不能外连。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.connected ? "chart.bar" : "desktopcomputer")
                        .font(.system(size: 20))
                        .foregroundStyle(model.connected ? Color.green : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background(model.connected ? Color.green.opacity(0.12) : Color(nsColor: .quaternaryLabelColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(model.connected ? "正在共享" : model.active ? "共享已开启" : model.working ? "正在准备共享" : "共享已停止")
                                .font(.title2.weight(.semibold))
                            if model.connected {
                                Text("1 个控制连接")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        if locked {
                            Text(model.status)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if model.connected, let state = model.activeVideoState {
                                Text("当前会话：\(state.settings.summary)（控制端临时调整，不修改下方默认值）")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("把这张书桌带走：在家里 Mac 开启共享，然后从另一台 Mac 通过端口映射或自托管中继连接。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.status != "准备就绪", model.status != "共享已停止" {
                                Text(model.status)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if locked {
                        Button { model.stop() } label: { Label("停止共享", systemImage: "stop.circle") }
                            .controlSize(.large)
                    } else {
                        Button { model.startHosting() } label: { Label("开启共享", systemImage: "power") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                Divider()
                HStack {
                    Text("需要的权限").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("重新检测") { model.refreshPermissions(checkScreenCapture: true, retryCapsLock: true) }
                        .controlSize(.small)
                }
                HStack(spacing: 16) {
                    permissionRow("屏幕录制", symbol: "rectangle.dashed.badge.record", granted: model.localScreenRecording) {
                        model.openScreenPermission()
                    }
                    permissionRow("辅助功能", symbol: "accessibility", granted: model.localAccessibility) {
                        model.requestAccessibility()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("建议先将应用移到「应用程序」再授权。已勾选仍未生效时，请完全退出后重开；升级后的旧授权记录可能需要移除并重新添加当前应用一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("当前应用：\(Bundle.main.bundleURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("配对码", systemImage: "key.horizontal").font(.headline)
                Spacer()
                Text("保存在本机私有文件").font(.caption).foregroundStyle(.secondary)
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text(model.hostCode.isEmpty ? "尚未配置" : showCode ? model.hostCode : "••••-••••-••••-••••")
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            model.prepareHostCode()
                            showCode.toggle()
                        } label: {
                            Label(showCode ? "隐藏" : "显示", systemImage: showCode ? "eye.slash" : "eye")
                        }
                        Button { model.copyHostCode() } label: { Label("复制配对码", systemImage: "doc.on.doc") }
                            .disabled(model.hostCode.isEmpty)
                    }
                    .controlSize(.small)
                    if model.hostCodeNeedsSetup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已有配对码请补录一次，保持原设备连接。这里不再读取钥匙串；无法取得旧码时可在下方生成新码。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                SecureField("输入原来的完整配对码", text: $previousCode)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("原来的主机配对码")
                                Button("保存原配对码") {
                                    if model.restoreHostCode(previousCode) { previousCode = "" }
                                }
                                .disabled(previousCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .disabled(locked)
                        }
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("持有配对码即可查看和控制这台 Mac，请只交给自己的设备。")
                            Text("本机文件由当前账户权限保护，未单独加密。生成新码会让原配对码失效。")
                            if locked { Text("共享中不可重新生成；停止共享后可用。") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(model.hostCode.isEmpty ? "生成新配对码" : "重新生成…") {
                            if model.hostCode.isEmpty { model.regenerateKey() }
                            else { confirmingRegeneration = true }
                        }
                        .controlSize(.small)
                        .disabled(locked)
                        .confirmationDialog("重新生成配对码？", isPresented: $confirmingRegeneration, titleVisibility: .visible) {
                            Button("重新生成", role: .destructive) { model.regenerateKey() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("旧配对码会立即失效，所有已配对的控制端都需要输入新配对码才能连接。")
                        }
                    }
                }
            }
        }
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("默认共享设置", systemImage: "slider.horizontal.3").font(.headline)
                Text("H.264 · 加密连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            if locked {
                Label("共享中不可修改，停止共享后可编辑", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Text("显示器")
                            Picker("显示器", selection: Binding(get: { model.displayID }, set: { model.chooseDisplay($0) })) {
                                ForEach(model.screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 8) {
                            Text("监听端口")
                            TextField("5908", text: $model.hostPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .accessibilityLabel("监听端口")
                        }
                    }
                    if let notice = model.displayFallbackNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Text("最长边")
                            Picker("最长边", selection: $model.settings.longestEdge) {
                                Text("1280 · 省流").tag(1280)
                                Text("1920 · 办公").tag(1920)
                                Text("2560 · 清晰").tag(2560)
                                Text("3840 · 高分辨率").tag(3840)
                                Text(StreamSettings.resolutionLabel(StreamSettings.nativeLongestEdge)).tag(StreamSettings.nativeLongestEdge)
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)
                        HStack(spacing: 8) {
                            Text("帧率上限")
                            Picker("帧率上限", selection: $model.settings.framesPerSecond) {
                                ForEach(StreamSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)
                        HStack(spacing: 8) {
                            Text("目标码率")
                            Picker("目标码率", selection: $model.settings.megabits) {
                                ForEach(StreamSettings.bitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("建议先用 1920 / 15 fps / 3 Mbps。静止画面不重复编码；码率是目标值，关键帧和网络开销可能产生短时峰值。")
                        Text("控制端在会话中调整画质不会修改这里的默认值。")
                        Text("原分辨率不放大画面，上限为单边 8192 像素、总计 3600 万像素；仍使用有损 H.264 / 4:2:0；窗口缩放也会影响清晰度。帧率最高可选 240 fps，超过 60 fps 需两端更新；实际帧率受被控屏幕刷新率、硬件和网络限制。旧控制端沿用兼容画质。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(locked)
            }
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("后台与登录启动", systemImage: "power").font(.headline)
                Spacer()
                Text("低频设置").font(.caption).foregroundStyle(.secondary)
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录后自动启动 QuietDesk", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    Divider()
                    Toggle("启动后自动开启共享", isOn: $model.autoStartSharing)
                    Divider()
                    Toggle("登录自动启动时最小化窗口", isOn: $model.minimizeAtLogin)
                    if model.loginNeedsApproval {
                        Button("在系统设置中允许登录启动") { LaunchSettings.openSettings() }
                            .controlSize(.small)
                    }
                    Divider()
                    Text("登录前 / FileVault 解锁前无法共享。关闭共享窗口后仍可从菜单栏打开，退出应用会停止共享。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("剪贴板与文件", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("双向同步文字、图片和文件", isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboardEnabled($0) }))
                        .toggleStyle(.checkbox)
                    Divider()
                    Text("文字和图片按控制端焦点同步；文件和文件夹需接收端逐次确认后才下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.openReceivedFiles() } label: { Label("打开接收文件目录", systemImage: "folder") }
                        .controlSize(.small)
                    if let id = model.receivingFileID {
                        Button("中断接收", role: .destructive) { model.cancelFileReception(id: id) }.controlSize(.small)
                    }
                    if !model.clipboardStatus.isEmpty {
                        Divider()
                        Text(model.clipboardStatus).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func permissionRow(_ title: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label("\(title) · \(granted ? "已生效" : "未生效")", systemImage: symbol)
                .font(.caption)
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background((granted ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
            Button("系统设置…", action: action)
                .controlSize(.small)
                .accessibilityLabel("打开\(title)系统设置")
        }
        .frame(maxWidth: .infinity)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            }
    }
}
