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

    /// True-color HEVC 4:4:4 eliminates 2×2 chroma subsampling blur on fine colored UI text; motion-first
    /// or low-bandwidth presets keep 4:2:0 for lighter frame cost.
    var prefersTrueColor: Bool {
        switch self {
        case .clearOffice, .original: return true
        case .dataSaver, .highRefresh: return false
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
        } else if let tuning,
                  tuning.desired != tuning.applied.settings
                  || tuning.desiredCodec != tuning.appliedCodec
                  || tuning.desiredChroma != tuning.appliedChroma {
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
    var supportsTrueColor: Bool = false
    var trueColor: Binding<Bool>? = nil
    var appliedCodec: VideoCodec = .h264
    var appliedChroma: VideoChromaSubsampling = .yuv420
    var onSelectPreset: ((SessionQualityPreset) -> Void)? = nil
    let localNetworkQuality: Bool
    let qualityHelp: String
    let compact: Bool
    @State private var showFineTuning = false
    @State private var showHelpPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 7) {
                DeskSectionHeading(title: "画质预设")
                Spacer(minLength: 0)
                Button {
                    showHelpPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("查看画质调节与自适应说明")
                .popover(isPresented: $showHelpPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("连接画质与自适应上限说明")
                            .font(.subheadline.weight(.semibold))
                        Text("手动选择确认后按连接记录保存，不修改共享端默认；自动降档不会覆盖已保存选择。")
                        Text("帧率为上限、码率为目标而非实测吞吐，实际受屏幕刷新率、硬件与网络限制；超过 60 fps 需两端更新。")
                        if !qualityHelp.isEmpty {
                            Text(qualityHelp)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(width: 310, alignment: .leading)
                    .background(DeskPalette.cardBackground)
                }
            }

            if let state = presentation.applied {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("当前已生效")
                        .foregroundStyle(DeskPalette.secondary)
                    Spacer(minLength: 4)
                    Text("\(state.settings.summary) · \(state.width) × \(state.height)")
                        .foregroundStyle(DeskPalette.emerald)
                        .monospacedDigit()
                    Text(appliedCodec == .hevc ? (appliedChroma == .yuv444 ? "HEVC 4:4:4" : "HEVC 4:2:0") : "H.264")
                        .foregroundStyle(DeskPalette.muted)
                }
                .font(.system(size: 11))
            }

            VStack(spacing: 2) {
                ForEach(SessionQualityPreset.allCases, id: \.self) { preset in
                    let resolved = preset.resolvedSettings(longestEdges: longestEdges, frameRates: frameRates, bitRates: bitRates)
                    let isSelected = settings == resolved
                        && (!supportsTrueColor || (trueColor?.wrappedValue ?? false) == preset.prefersTrueColor)
                    Button {
                        if let onSelectPreset {
                            onSelectPreset(preset)
                        } else {
                            settings = resolved
                            if supportsTrueColor { trueColor?.wrappedValue = preset.prefersTrueColor }
                        }
                    } label: {
                        HStack {
                            Text(preset.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            Spacer(minLength: 6)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DeskPalette.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(minHeight: 29)
                        .background(isSelected ? DeskPalette.subtleFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .help("\(preset.title)：\(resolved.summary)\(supportsTrueColor && preset.prefersTrueColor ? " · 4:4:4 真彩" : "")")
                }
            }
            .disabled(presentation.availability != .ready)
            .opacity(presentation.availability == .ready ? 1 : 0.58)

            if supportsTrueColor, let trueColor {
                Toggle(isOn: trueColor) {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("4:4:4 真彩模式")
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                        Text("硬件 HEVC Main 4:4:4，消除彩色代码色度模糊")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(presentation.availability != .ready)
            }

            if compact {
                DisclosureGroup("高级画质设置（\(settings.summary)）", isExpanded: $showFineTuning) {
                    parameterGrid
                        .padding(.top, 6)
                }
                .font(.system(size: 11, weight: .medium))
            } else {
                parameterGrid
            }

            switch presentation.availability {
            case .disconnected:
                Text("连接建立后可即时调整画质，无需重启共享。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unsupported:
                Label("共享端版本较旧，不支持会话中动态调画质", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(DeskPalette.amber)
            case .ready:
                updateStatus
                if let message = presentation.message {
                    Label {
                        Text(message).textSelection(.enabled)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.caption)
                    .foregroundStyle(DeskPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(compact ? 3 : nil)
                    .help(message)
                }
            }

        }
        .font(.system(size: compact ? 11.5 : 12))
        .help(qualityHelp)
    }

    private var parameterGrid: some View {
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
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(presentation.availability != .ready)
    }

    @ViewBuilder private var updateStatus: some View {
        switch presentation.update {
        case .idle:
            EmptyView()
        case .preparing(let desired):
            progress("准备请求共享端：\(desired.summary)")
        case .awaiting(let requested, let latest):
            progress("等待共享端确认：\(requested.summary)")
            if let latest {
                Text("最新待合并：\(latest.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
