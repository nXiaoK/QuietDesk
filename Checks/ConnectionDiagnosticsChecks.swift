import Foundation
import QuietDeskCore

func runConnectionDiagnosticsChecks() {
    let start = Date(timeIntervalSince1970: 1_000)
    let direct = DiagnosticRoute(control: .direct, media: .directUDP)
    let relay = DiagnosticRoute(control: .direct, media: .relayUDP, node: "relay.test:7443")
    let reconnect = DiagnosticRoute(control: .unavailable, media: .reconnecting)

    run("Connection report separates video and control routes, measurements and reconnect gaps") {
        let recorder = ConnectionDiagnosticRecorder(startedAt: start, now: 10, route: direct)
        recorder.recordTraffic(bytes: 1_000_000, frames: 40, seconds: 2, at: 12)
        recorder.recordRoundTrip(milliseconds: 80, at: 12)
        recorder.recordUDPRoundTrip(milliseconds: 12, at: 12)
        recorder.recordLoss(settled: 20, lost: 4, at: 12)
        recorder.changeRoute(direct, at: 12)
        recorder.changeRoute(reconnect, at: 12)
        recorder.recordLoss(settled: 30, lost: 10, at: 14)
        recorder.recordUDPRoundTrip(milliseconds: 1, at: 14)
        recorder.changeRoute(relay, at: 15)
        recorder.recordTraffic(bytes: 500_000, frames: 60, seconds: 1, at: 16)
        recorder.recordLoss(settled: 80, lost: 0, at: 16)
        recorder.recordRoundTrip(milliseconds: 100, at: 16)
        let report = recorder.finish(remoteName: "Test Mac", reason: "Ended by host", at: 16)
        try check(report.remoteName == "Test Mac" && report.reason == "Ended by host" && report.startedAt == start && report.duration == 6,
                  "Session identity or timing lost")
        try check(report.routes.map(\.route) == [direct, reconnect, relay] && report.routes.map(\.duration) == [2, 3, 1],
                  "Route duration or direct-control/relay-video identity lost")
        try check(report.routes.map(\.visits) == [1, 1, 1], "Repeated route notification counted as a new visit")
        let all = report.totals
        try check(all.roundTrip.mean == 90 && all.roundTrip.maximum == 100 && all.udpRoundTrip.mean == 12,
                  "Control and video RTT mixed across routes")
        try check(all.loss.count == 2 && all.loss.mean == 0.04 && all.loss.maximum == 0.2 && all.loss.settledFragments == 100 && all.loss.lostFragments == 4,
                  "UDP loss denominator or collection peak lost")
        try check(all.megabitsPerSecond == 4 && all.framesPerSecond == 100.0 / 3 && all.bytes == 1_500_000,
                  "Rates did not use total counts and measured time")
        try check(report.routes[2].quality.loss.mean == 0 && report.routes[2].quality.udpRoundTrip.mean == nil,
                  "Measured zero and unavailable data conflated")
        let gap = report.timeline.filter { $0.start >= 2 && $0.end <= 5 }
        try check(gap.count == 3 && gap.allSatisfy { $0.routes == [reconnect: 1] && $0.quality.framesPerSecond == nil && $0.quality.loss.mean == nil },
                  "Disconnected intervals acquired synthetic media data")
    }

    run("Long and flapping connection reports retain both ends, all route time and sparse observations") {
        let recorder = ConnectionDiagnosticRecorder(startedAt: start, now: 0, route: direct)
        for second in 0..<3_600 {
            if second != 0 { recorder.changeRoute(second.isMultiple(of: 2) ? direct : relay, at: Double(second)) }
            recorder.recordTraffic(bytes: 1_000, frames: 2, seconds: 1, at: Double(second + 1))
        }
        recorder.changeRoute(reconnect, at: 3_600)
        let day: Double = 86_400
        recorder.changeRoute(direct, at: day)
        recorder.recordRoundTrip(milliseconds: 404, at: day + 0.5)
        let report = recorder.finish(remoteName: "", reason: "Disconnect", at: day + 0.5)
        try check(report.timeline.count <= 256 && report.timeline.first?.start == 0 && report.timeline.last?.end == day + 0.5,
                  "Long-session trend did not fit the complete timespan in bounded space")
        try check(report.routes.map(\.duration) == [1_800.5, 1_800, day - 3_600], "Route flapping lost or double-counted elapsed time")
        try check(report.routes.map(\.visits) == [1_801, 1_800, 1], "Revisits lost after coarsening the timeline")
        try check(report.timeline.allSatisfy { $0.routes.values.reduce(0, +) == $0.end - $0.start }
                  && report.timeline.reduce(0) { $0 + $1.quality.bytes } == 3_600_000,
                  "Compacting lost bytes or the occupancy of a mixed-route bucket")
        try check(report.timeline.first?.quality.framesPerSecond == 2 && report.timeline.last?.quality.roundTrip.maximum == 404,
                  "First or last observations were lost after compaction")
    }

    run("Connection diagnostics traffic partitions protocols and paths without counting channels twice") {
        var breakdown = DiagnosticTrafficBreakdown()
        let paths: [WritableKeyPath<DiagnosticTrafficBreakdown, DiagnosticTrafficBucket>] = [
            \.directTCP, \.directUDP, \.relayTCP, \.relayUDP, \.punchedUDP, \.tailnetDirectTCP,
            \.tailnetDirectUDP, \.tailnetDERPTCP, \.tailnetDERPUDP, \.tailnetUnknownTCP, \.tailnetUnknownUDP,
        ]
        for (index, path) in paths.enumerated() {
            let sent = UInt64(index + 1)
            breakdown[keyPath: path].add(sent: sent, received: sent * 10)
        }
        breakdown.controlChannel.add(sent: 28, received: 280)
        breakdown.videoChannel.add(sent: 38, received: 380)
        try check(breakdown.tcp == .init(sentBytes: 28, receivedBytes: 280)
                  && breakdown.udp == .init(sentBytes: 38, receivedBytes: 380), "TCP and UDP were misclassified")
        try check(breakdown.totalSentBytes == 66 && breakdown.totalReceivedBytes == 660 && breakdown.totalBytes == 726
                  && breakdown.tcpBytes + breakdown.udpBytes == breakdown.totalBytes, "Channels duplicated path bytes")
        try check(breakdown.directBytes == 33 && breakdown.relayedBytes == 264 && breakdown.punchedBytes == 198
                  && breakdown.tailnetUnknownBytes == 231, "Direct, relayed, punched or unknown traffic was misclassified")
        try check(breakdown.directBytes + breakdown.relayedBytes + breakdown.punchedBytes + breakdown.tailnetUnknownBytes
                    == breakdown.totalBytes, "Route groups overlapped or omitted traffic")
        try check(breakdown.relayShareFraction == 264.0 / 726 && breakdown.punchedShareFraction == 198.0 / 726
                  && breakdown.punchedSavedRelayFraction == 198.0 / 462, "Traffic shares used the wrong denominators")
        try check(DiagnosticTrafficBreakdown().relayShareFraction == nil && DiagnosticTrafficBreakdown().punchedSavedRelayFraction == nil,
                  "An empty report claimed measurable savings")
        var limit = DiagnosticTrafficBucket(sentBytes: UInt64.max - 1, receivedBytes: 1)
        limit.merge(.init(sentBytes: 2, receivedBytes: UInt64.max))
        try check(limit.sentBytes == UInt64.max && limit.receivedBytes == UInt64.max && limit.totalBytes == UInt64.max,
                  "Directional counters did not saturate on overflow")
    }

    run("Connection diagnostics frame-rate variation excludes idle samples and counts only abrupt active drops") {
        var frameRate = DiagnosticFrameRateStats()
        var previous: Double?
        for fps in [40.0, 12, 30, 0, 9, 60, 30] {
            frameRate.recordSample(fps: fps, seconds: 1, previousActiveFPS: &previous)
        }
        frameRate.recordIdle(seconds: 2)
        let mean = 181.0 / 6
        let deviation = sqrt(7_225.0 / 6 - mean * mean)
        try check(frameRate.activeSamples == 6 && frameRate.activeSeconds == 6 && frameRate.idleSeconds == 3
                  && frameRate.activeMeanFPS == mean, "Idle intervals changed the active frame-rate mean")
        try check(frameRate.minimumActiveFPS == 9 && frameRate.maximumFPS == 60
                  && frameRate.standardDeviationFPS == deviation && frameRate.coefficientOfVariation == deviation / mean,
                  "Active extrema or variation lost precision")
        try check(frameRate.histogram.count == 12 && frameRate.histogram.reduce(0, +) == 6
                  && frameRate.p10LowFPS == 7.5 && frameRate.lowFrameRateShare == 2.0 / 6, "Histogram or low frame-rate share was wrong")
        try check(frameRate.dropEvents == 1 && frameRate.stabilityLabel == "明显波动", "Idle or an exact 50% drop counted as a sudden drop")
        try check(DiagnosticFrameRateStats().stabilityLabel == "样本不足", "No observations produced a stability claim")
    }

    run("Connection diagnostics report JSON preserves mixed routes, compacted extrema, compatibility and privacy") {
        let tailnetDERP = DiagnosticRoute(control: .tailnet, media: .tailnetUDP, tailnetPath: "derp")
        let paused = DiagnosticRoute(control: .tailnet, media: .paused, tailnetPath: "derp")
        let recorder = ConnectionDiagnosticRecorder(startedAt: start, now: 0, route: direct)
        var original = DiagnosticTrafficBreakdown()
        original.directUDP.add(sent: 15, received: 30)
        original.videoChannel = original.directUDP
        recorder.recordDetailedTraffic(original, frames: 10, seconds: 0.5, at: 0.5)
        recorder.changeRoute(tailnetDERP, at: 0.5)
        var derp = DiagnosticTrafficBreakdown()
        derp.tailnetDERPUDP.add(sent: 40, received: 80)
        derp.videoChannel = derp.tailnetDERPUDP
        recorder.recordDetailedTraffic(derp, frames: 30, seconds: 0.5, at: 1)
        recorder.changeRoute(paused, at: 1)
        recorder.recordDetailedTraffic(.init(), frames: 0, seconds: 1, at: 2)
        recorder.changeRoute(reconnect, at: 2)
        recorder.recordTraffic(bytes: 0, frames: 0, seconds: 1, at: 3)
        recorder.changeRoute(tailnetDERP, at: 3)
        recorder.recordDetailedTraffic(.init(), frames: 0, seconds: 1, at: 4)
        recorder.recordDetailedTraffic(derp, frames: 0, seconds: 0, at: 4)
        recorder.recordRoundTrip(milliseconds: 40, at: 640)
        let report = recorder.finish(remoteName: "Test Mac", endpointLabel: "[fd00::1]:7443", reason: "Disconnect", at: 640)
        try check(report.endedAt == start.addingTimeInterval(640)
                  && report.totals.bytes == 285 && report.traffic.totalBytes == 285, "Detailed and legacy byte totals diverged")
        try check(report.frameRate.activeSamples == 2 && report.frameRate.idleSeconds == 1,
                  "Paused or disconnected time appeared as an idle observation")
        let first = report.timeline.first
        try check(first?.routes == [direct: 0.5, tailnetDERP: 1.5, paused: 1, reconnect: 1]
                  && first?.quality.frameRate.minimumActiveFPS == 20 && first?.quality.frameRate.maximumFPS == 60,
                  "Compaction lost mixed routes or their observed frame-rate range")
        let json = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ConnectionDiagnosticReport.self, from: json)
        try check(decoded == report && report.timeline.count <= 256, "Detailed report was not preserved in a bounded JSON round trip")
        try check(report.plainTextSummary().contains("传输流量合计　285 B"), "Shareable summary omitted the recorded traffic")

        var previousFormat = try (JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:]
        previousFormat.removeValue(forKey: "endpointLabel")
        previousFormat.removeValue(forKey: "endedAt")
        if var totals = previousFormat["totals"] as? [String: Any] {
            totals.removeValue(forKey: "traffic")
            totals.removeValue(forKey: "frameRate")
            previousFormat["totals"] = totals
        }
        let legacy = try JSONDecoder().decode(ConnectionDiagnosticReport.self, from: JSONSerialization.data(withJSONObject: previousFormat))
        try check(legacy.endpointLabel == "" && legacy.endedAt == report.endedAt
                  && legacy.totals.bytes == 285 && legacy.traffic.totalBytes == 0 && legacy.frameRate.activeSamples == 0,
                  "Older reports without new fields could not preserve legacy measurements")

        let pairingCode = Array(repeating: "ABCD0123", count: 8).joined(separator: "-")
        let privateRecorder = ConnectionDiagnosticRecorder(startedAt: start, now: 0, route:
            .init(control: .relay, media: .relayTCP, node: "tls://user:relay-secret@relay.test:7443"))
        let privateReport = privateRecorder.finish(remoteName: "Test \(pairingCode)", endpointLabel: "/Users/example/private-folder/file",
                                                   reason: "锁屏密码：screen-secret", at: 1)
        let export = String(decoding: try JSONEncoder().encode(privateReport), as: UTF8.self)
        for sensitive in [pairingCode, "relay-secret", "private-folder", "screen-secret"] {
            try check(!privateReport.plainTextSummary().contains(sensitive) && !export.contains(sensitive),
                      "Shareable report exposed private metadata")
        }
    }
}
