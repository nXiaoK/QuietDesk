import SwiftUI
import AppKit
import QuietDeskCore

struct ConnectionView: View {
    @ObservedObject var model: DeskModel
    @Binding var showOptions: Bool
    let openCaps: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    @State private var showRecords = false
    @State private var showRelaySettings = false

    private var locked: Bool { model.active || model.working }
    private var failure: String? { model.connectionFailure }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("你的另一张书桌").font(.system(size: 22, weight: .bold))
                            Text("输入地址和配对码，继续手边的工作")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(action: openTraffic) { Label("流量统计…", systemImage: "chart.bar.xaxis") }
                            .buttonStyle(.link).font(.callout)
                    }
                    VStack(spacing: 14) {
                        VStack(spacing: 0) {
                            if model.relayEnabled {
                                formRow("连接策略") {
                                    Picker("连接策略", selection: $model.relayStrategy) {
                                        ForEach(RelayConnectionStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
                                    }.labelsHidden().pickerStyle(.menu)
                                }
                                Divider()
                                if model.relayStrategy != .direct {
                                    formRow("目标设备标识") {
                                        VStack(alignment: .leading, spacing: 4) {
                                            TextField("被控 Mac 显示的完整设备标识", text: $model.targetRelayDeviceID)
                                                .accessibilityLabel("目标中继设备标识")
                                            Text(model.viewerRelayAddress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Divider()
                                }
                            }
                            if !model.relayEnabled || model.relayStrategy != .relay {
                                formRow("家里 Mac 的地址") {
                                    TextField(model.relayEnabled && model.relayStrategy == .automatic ? "可选：已知域名或 IP" : "域名或 IP", text: $model.address)
                                        .accessibilityLabel("家里 Mac 的地址")
                                }
                                Divider()
                                formRow("映射后的端口") {
                                    HStack(spacing: 10) {
                                        TextField("5908", text: $model.port).frame(width: 80)
                                            .accessibilityLabel("映射后的端口")
                                        Text("家里 Mac 的监听端口经路由器映射后的端口")
                                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Divider()
                            }
                            formRow("配对码") {
                                SecureField("粘贴完整配对码", text: $model.viewerCode)
                                    .accessibilityLabel("家里 Mac 显示的配对码")
                            }
                        }
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(locked)

                        HStack(spacing: 18) {
                            Button { model.canvas.releaseControl(); showOptions = true } label: { Label("连接选项…", systemImage: "slider.horizontal.3") }
                                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                                    ConnectionSettingsView(model: model, openCaps: { showOptions = false; openCaps() },
                                                           openTraffic: openTraffic, openEffects: openEffects)
                                }
                            Button(action: openCaps) { Label("键盘设置…", systemImage: "keyboard") }
                            Button { model.canvas.releaseControl(); showRelaySettings = true } label: { Label("中继设置…", systemImage: "network") }
                            Spacer()
                            if locked {
                                ProgressView().controlSize(.small)
                                Button("取消") { model.stop() }.controlSize(.large)
                            } else {
                                Button("连接") { model.connect() }
                                    .buttonStyle(.borderedProminent).controlSize(.large).frame(minWidth: 84)
                            }
                        }
                        .buttonStyle(.link).font(.callout)
                        if locked {
                            HStack(spacing: 8) {
                                Text(model.status).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Text(model.relayEnabled && model.relayStrategy == .relay ? "设备 \(model.targetRelayDeviceID.prefix(8))" : "\(model.address):\(model.port)")
                                    .font(.caption).monospaced().foregroundStyle(.secondary)
                            }
                        }
                        if let failure {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                Text(failure).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button("重试") { model.connect() }
                            }
                            .padding(12).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if model.connections.isEmpty {
                        firstUse
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("最近连接").font(.headline)
                                Spacer()
                                Button("管理记录…") { showRecords = true }.buttonStyle(.link).disabled(locked)
                            }
                            HStack(spacing: 12) {
                                ForEach(Array(model.connections.prefix(2))) { record in
                                    ConnectionCard(record: record, connect: { model.quickConnect(record) },
                                                   remove: { model.removeConnection(record) })
                                }
                            }.disabled(locked)
                            Text("点按「连接」使用本机保存的配对码；旧记录首次需补录原码一次。悬停卡片或右键可移除记录。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: geometry.size.width < 960 ? 540 : 580)
                .padding(.top, max(28, min(72, geometry.size.height * 0.10)))
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showRecords) {
            VStack(alignment: .leading, spacing: 16) {
                Text("管理连接记录").font(.title3.weight(.semibold))
                Text("配对码保存在本机私有文件，由当前账户的文件权限保护，未单独加密。移除记录会删除本机文件中对应的配对码；旧钥匙串条目保持不动。")
                    .font(.callout).foregroundStyle(.secondary)
                if model.connections.isEmpty {
                    ContentUnavailableView("没有连接记录", systemImage: "desktopcomputer")
                } else {
                    List(model.connections) { record in
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.name).font(.headline)
                                Text(connectionEndpointLabel(record)).font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(2)
                                Text(record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("连接") { showRecords = false; model.quickConnect(record) }
                            Button("移除") { model.removeConnection(record) }
                        }.padding(.vertical, 6)
                    }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack { Spacer(); Button("完成") { showRecords = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 540, height: 420)
        }
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(enabled: model.relayEnabled, address: model.relayAddress, deviceID: model.relayDeviceID,
                              locked: locked, loadTrust: model.relayCertificate, save: model.saveRelayConfiguration)
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.body).frame(width: 112, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 42)
    }

    private var firstUse: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第一次使用").font(.headline)
            HStack(alignment: .top, spacing: 0) {
                guideStep(1, text: "在家里 Mac 打开 QuietDesk，切到「共享这台 Mac」")
                Divider()
                guideStep(2, text: "开启共享，使用端口映射或配置自托管中继")
                Divider()
                guideStep(3, text: "复制配对码，回到这里粘贴后连接")
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func guideStep(_ number: Int, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 20, height: 20).background(Color.accentColor.opacity(0.12), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private func connectionEndpointLabel(_ record: ConnectionRecord) -> String {
    if let relay = record.relay {
        return "\(relay.strategy == .automatic ? "自动" : "中继") · \(relay.deviceID.uuidString.lowercased()) · \(relay.endpoint.address)"
    }
    return "\(record.address):\(record.port)"
}

private struct ConnectionCard: View {
    let record: ConnectionRecord
    let connect: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.system(size: 18)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name).font(.headline).lineLimit(1).help(record.name)
                Text(connectionEndpointLabel(record)).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                    .help(connectionEndpointLabel(record))
                Text("上次连接 \(record.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("连接", action: connect).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if hovered {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .secondary) }
                    .buttonStyle(.plain).offset(x: -5, y: -5).help("移除此记录").accessibilityLabel("移除 \(record.name)")
            }
        }
        .onHover { hovered = $0 }
        .contextMenu { Button("移除", action: remove) }
    }
}
