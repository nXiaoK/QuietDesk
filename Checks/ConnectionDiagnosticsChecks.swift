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
}
