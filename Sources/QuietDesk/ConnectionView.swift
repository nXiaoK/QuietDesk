import SwiftUI
import QuietDeskCore

struct ConnectionView: View {
    @ObservedObject var model: DeskModel
    @Binding var showOptions: Bool
    let openCaps: () -> Void
    let openTraffic: () -> Void
    let openEffects: () -> Void
    let openBenchmark: (ConnectionRecord?) -> Void
    @State private var showRecords = false
    @State private var showRelaySettings = false

    private var locked: Bool { model.active || model.working }

    var body: some View {
        ConnectionEntryView(records: model.connections, locked: locked, failure: model.connectionFailure,
                            status: model.status, relayEnabled: model.relayEnabled,
                            address: $model.address, port: $model.port, code: $model.viewerCode,
                            strategy: $model.relayStrategy, deviceID: $model.targetRelayDeviceID,
                            nodePicker: RelayNodePicker(model: model), showOptions: $showOptions,
                            options: ConnectionSettingsView(model: model, openCaps: { showOptions = false; openCaps() },
                                                            openTraffic: openTraffic, openEffects: openEffects,
                                                            openBenchmark: { showOptions = false; openBenchmark(nil) }),
                            connect: model.connect, cancel: { model.stop() }, quickConnect: model.quickConnect,
                            remove: model.removeConnection, manage: { showRecords = true },
                            openOptions: { model.canvas.releaseControl(); showOptions = true },
                            openCaps: openCaps,
                            openRelay: { model.canvas.releaseControl(); showRelaySettings = true },
                            openTraffic: openTraffic,
                            openBenchmark: { openBenchmark(nil) },
                            benchmarkRecord: { openBenchmark($0) })
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
                                Text(ConnectionEntryPresentation.title(record)).font(.headline)
                                Text(ConnectionEntryPresentation.endpoint(record)).font(.caption).monospaced()
                                    .foregroundStyle(.secondary).lineLimit(2)
                                if let relay = record.relay {
                                    Text("\(ConnectionEntryPresentation.route(record)) · \(relay.deviceID.uuidString.lowercased())")
                                        .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text(record.lastConnected.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("测速…") { showRecords = false; openBenchmark(record) }
                            Button("连接") { showRecords = false; model.quickConnect(record) }
                            Button("移除") { model.removeConnection(record) }
                        }.padding(.vertical, 6)
                    }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack { Spacer(); Button("完成") { showRecords = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 540, height: 420)
        }
        .sheet(isPresented: $showRelaySettings) {
            RelaySettingsView(enabled: model.relayEnabled, nodes: model.relayNodes, deviceID: model.relayDeviceID,
                              locked: model.relaySettingsLocked, measurements: model.relayNodeMeasurements,
                              loadTrust: model.relayCertificate, saveNode: model.saveRelayNode, save: model.saveRelayConfiguration)
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemQuitHandler.dismissSheets)) { _ in
            showRecords = false; showRelaySettings = false
        }
    }
}
