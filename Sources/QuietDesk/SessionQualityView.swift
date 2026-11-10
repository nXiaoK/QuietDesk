import QuietDeskCore
import SwiftUI

enum SessionQualityPreset: String, CaseIterable, Equatable {
    case dataSaver
    case clearOffice
    case highRefresh
    case original

    var title: String {
        switch self {
        case .dataSaver: return "省流"
        case .clearOffice: return "清晰办公"
        case .highRefresh: return "高刷流畅"
        case .original: return "原画"
        }
    }

    func resolvedSettings(longestEdges: [Int], frameRates: [Int], bitRates: [Int]) -> StreamSettings {
        let edge: Int
        let fps: Int
        let mbps: Int
        switch self {
        case .dataSaver:
            edge = longestEdges.contains(1280) ? 1280 : (longestEdges.filter { $0 > 0 }.min() ?? 1280)
            fps = frameRates.contains(30) ? 30 : (frameRates.min() ?? 30)
            mbps = bitRates.filter { $0 <= 3 }.max() ?? (bitRates.min() ?? 3)
        case .clearOffice:
            edge = longestEdges.contains(2560) ? 2560 : (longestEdges.filter { $0 > 0 && $0 <= 2560 }.max() ?? 1920)
            fps = frameRates.contains(30) ? 30 : (frameRates.filter { $0 <= 30 }.max() ?? 30)
            mbps = bitRates.filter { $0 <= 12 }.max() ?? 8
        case .highRefresh:
            edge = longestEdges.contains(1920) ? 1920 : (longestEdges.filter { $0 > 0 && $0 <= 1920 }.max() ?? 1920)
            fps = frameRates.filter { $0 <= 120 }.max() ?? (frameRates.max() ?? 60)
            mbps = bitRates.filter { $0 <= 30 }.max() ?? (bitRates.max() ?? 12)
        case .original:
            edge = longestEdges.contains(StreamSettings.nativeLongestEdge)
                ? StreamSettings.nativeLongestEdge
                : (longestEdges.max() ?? 1920)
            fps = frameRates.contains(60) ? 60 : (frameRates.filter { $0 <= 60 }.max() ?? 30)
            mbps = bitRates.filter { $0 <= 60 }.max() ?? (bitRates.max() ?? 30)
        }
        return StreamSettings(longestEdge: edge, framesPerSecond: fps, megabits: mbps)
    }

    static func matching(_ settings: StreamSettings,
                         longestEdges: [Int],
                         frameRates: [Int],
                         bitRates: [Int]) -> SessionQualityPreset? {
        allCases.first {
            $0.resolvedSettings(longestEdges: longestEdges, frameRates: frameRates, bitRates: bitRates) == settings
        }
    }
}

struct SessionQualityPresentation {
    enum Availability { case disconnected, unsupported, ready }
    enum Update: Equatable {
        case idle
        case preparing(StreamSettings)
        case awaiting(StreamSettings, latest: StreamSettings?)
    }

    let availability: Availability
    let applied: VideoStreamState?
    let update: Update
    let message: String?

    init(connected: Bool, supportsLiveSettings: Bool, applied: VideoStreamState?, tuning: VideoTuningSession?, status: String) {
        availability = !connected ? .disconnected : supportsLiveSettings ? .ready : .unsupported
        self.applied = connected ? applied : nil
        guard availability == .ready else { update = .idle; message = nil; return }
        if let tuning, let pending = tuning.pending {
            update = .awaiting(pending.settings, latest: tuning.desired == pending.settings ? nil : tuning.desired)
        } else if let tuning, tuning.desired != tuning.applied.settings || tuning.desiredCodec != tuning.appliedCodec {
            update = .preparing(tuning.desired)
        } else { update = .idle }
        message = status.isEmpty || status.hasPrefix("当前生效：") || status.hasPrefix("已生效：") || status.hasPrefix("正在应用：") ? nil : status
    }
}

struct SessionQualityView: View {
    @Binding var settings: StreamSettings
    let presentation: SessionQualityPresentation
    let longestEdges: [Int]
    let frameRates: [Int]
    let bitRates: [Int]
    let supportsMediaTransport: Bool
    let supportsExtendedVideoSettings: Bool
    let supportsAdaptiveVideo: Bool
    let localNetworkQuality: Bool
    let qualityHelp: String
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            HStack(spacing: 7) {
                Text("连接画质").font(.headline)
                Text("按连接记忆")
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            Text("手动选择确认后按连接记录保存，不改共享端默认。自动调节不覆盖已保存选择。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("场景预设").fontWeight(.medium)
            HStack(spacing: compact ? 4 : 6) {
                ForEach(SessionQualityPreset.allCases, id: \.self) { preset in
                    let resolved = preset.resolvedSettings(longestEdges: longestEdges, frameRates: frameRates, bitRates: bitRates)
                    let isSelected = settings == resolved
                    Button {
                        settings = resolved
                    } label: {
                        Text(preset.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? Color.accentColor : nil)
                    .controlSize(.small)
                    .help("\(preset.title)：\(resolved.summary)")
                }
            }
            .disabled(presentation.availability != .ready)
            Text("所选上限").fontWeight(.medium)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: compact ? 5 : 7) {
                GridRow {
                    Text("最长边").foregroundStyle(.secondary)
                    Picker("最长边", selection: $settings.longestEdge) {
                        ForEach(longestEdges, id: \.self) { Text(StreamSettings.resolutionLabel($0)).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("帧率上限").foregroundStyle(.secondary)
                    Picker("帧率上限", selection: $settings.framesPerSecond) {
                        ForEach(frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("目标码率").foregroundStyle(.secondary)
                    Picker("目标码率", selection: $settings.megabits) {
                        ForEach(bitRates, id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
            }
            .pickerStyle(.menu).controlSize(.small)
            .disabled(presentation.availability != .ready)
            switch presentation.availability {
            case .disconnected:
                Text("连接后可即时调整画质，无需停止共享。")
                    .foregroundStyle(.secondary)
            case .unsupported:
                Label("共享端版本不支持会话中调整画质", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.orange)
                Text("当前使用共享端画质。请将共享端的 QuietDesk 更新到 0.4.0 或更新版本。")
                    .foregroundStyle(.secondary)
            case .ready:
                updateStatus
                if let message = presentation.message {
                    Label {
                        Text(message).textSelection(.enabled)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
                    .lineLimit(compact ? 3 : nil).help(message)
                }
            }
            if let state = presentation.applied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前生效").fontWeight(.medium)
                    Text(state.settings.summary).monospacedDigit()
                    Text("视频尺寸 \(state.width) × \(state.height)").foregroundStyle(.secondary).monospacedDigit()
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if presentation.availability == .ready {
                if localNetworkQuality {
                    Text("局域网优先所选画质 · 持续高延迟时才降档")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .help(qualityHelp)
                } else if supportsAdaptiveVideo || supportsMediaTransport {
                    Text(compact ? "实际画质随网络与编解码负载调整，不超过所选上限。"
                         : supportsAdaptiveVideo ? "实际画质按丢包和延迟自动调整：先调码率，码率过低时再降帧率和最长边，网络好转后逐步恢复。"
                         : "已保存画质与手动选择作为自动调节上限；实际画质随网络负载调整。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if !compact {
                    Text(supportsExtendedVideoSettings ? "已保存画质与手动选择优先；旧传输首次 RTT <10 ms 的新连接默认最高画质。"
                         : "已保存的连接会恢复画质；原分辨率和 30 Mbps 需共享端更新后使用。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("帧率为上限、码率为目标，并非实测值。实际受屏幕刷新率、硬件和网络限制；超过 60 fps 需两端更新。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: compact ? 11 : 12))
        .help("画质调整不修改共享端默认值；同一连接记录会恢复已保存的选择，保存失败时会提示。自动调节不覆盖已保存选择。RTT 不代表网络类型或画面上屏延迟。原分辨率不放大，上限单边 8192 像素、总计 3600 万像素。最高可选 240 fps，超过 60 fps 需两端更新；实际帧率受被控屏幕刷新率、硬件和网络限制。60/100 Mbps 需两端支持；H.264 / 4:2:0 仍为有损，两端都有 HEVC 硬件编解码时自动改用同为 4:2:0 的 HEVC。可连续选择，等待时合并为最新设置。")
    }

    @ViewBuilder private var updateStatus: some View {
        switch presentation.update {
        case .idle:
            EmptyView()
        case .preparing(let desired):
            progress("准备请求共享端")
            Text("待请求：\(desired.summary)")
                .foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        case .awaiting(let requested, let latest):
            progress("等待共享端确认")
            Text("已请求：\(requested.summary)")
                .foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            if let latest {
                Text("最新选择（待合并）：\(latest.summary)")
                    .foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title)
        }
    }
}
