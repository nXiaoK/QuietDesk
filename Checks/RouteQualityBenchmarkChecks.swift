import Foundation
import QuietDeskCore

func runRouteQualityBenchmarkChecks() {
    run("QualityProbeControl wire round trip, bounds validation and Hello capability compatibility") {
        try check(MessageKind.qualityProbeControl.rawValue == 40, "Unexpected qualityProbeControl wire tag")
        try check(RouteBenchmarkDuration.seconds30.rawValue == 30 && RouteBenchmarkDuration.seconds60.rawValue == 60,
                  "Default 30s / 1m durations changed")

        let enable = QualityProbeControl(enabled: true, durationSeconds: 30)
        let framed = try enable.message().framed()
        let body = try Wire.decodeBody(Data(framed.dropFirst(4)))
        try check(body.kind == .qualityProbeControl, "Wrong message kind")
        let decoded = try QualityProbeControl.read(body.payload)
        try check(decoded == enable, "QualityProbeControl round trip changed")

        let disable = QualityProbeControl(enabled: false, durationSeconds: 0)
        try check(try QualityProbeControl.read(disable.message().payload) == disable, "Disable probe round trip failed")

        try rejects("Accepted enabled probe shorter than minimum") {
            _ = try QualityProbeControl(enabled: true, durationSeconds: 3).message()
        }
        try rejects("Accepted enabled probe longer than maximum") {
            _ = try QualityProbeControl(enabled: true, durationSeconds: 121).message()
        }
        try rejects("Accepted negative disable duration") {
            _ = try QualityProbeControl(enabled: false, durationSeconds: -1).message()
        }

        let legacyHelloData = try JSONEncoder().encode(
            Hello(name: "Old Mac", width: 1920, height: 1080, settings: .init(), canControl: true)
        )
        let legacyHello = try JSONDecoder().decode(Hello.self, from: legacyHelloData)
        try check(legacyHello.qualityProbeV1 == nil, "Legacy Hello unexpectedly set qualityProbeV1")

        let modernHelloData = try JSONEncoder().encode(
            Hello(name: "New Mac", width: 2560, height: 1440, settings: .init(), canControl: true, qualityProbeV1: true)
        )
        let modernHello = try JSONDecoder().decode(Hello.self, from: modernHelloData)
        try check(modernHello.qualityProbeV1 == true, "Modern Hello lost qualityProbeV1")
    }

    run("RouteBenchmarkPlanner enumerates direct and multi-node relay modes while filtering uncredentialed nodes") {
        let nodeA = try RelayEndpoint(address: "tls://hk.relay.invalid:7443")
        let nodeB = try RelayEndpoint(address: "tls://sh.relay.invalid:7443")
        let nodeMissing = try RelayEndpoint(address: "tls://missing.relay.invalid:7443")
        let deviceID = UUID(uuidString: "11112222-3333-4444-5555-666677778888")!

        let fullPlan = RouteBenchmarkPlanner.plan(
            address: "192.168.1.20",
            portString: "5908",
            relayEnabled: true,
            relayDeviceIDString: deviceID.uuidString,
            preferredNodeAddress: nodeB.address,
            configuredNodes: [nodeA, nodeB, nodeMissing],
            nodesWithCredentials: [nodeA.address, nodeB.address]
        )
        try check(fullPlan.candidates.count == 8, "Expected 2 direct + 2x3 relay candidates, got \(fullPlan.candidates.count)")
        try check(fullPlan.candidates[0].kind == .directUDP && fullPlan.candidates[1].kind == .directTCP,
                  "Direct candidates should lead")
        try check(fullPlan.candidates[2].relayEndpoint == nodeB && fullPlan.candidates[2].kind == .relayAutoPunch,
                  "Preferred relay node should be ordered first")
        try check(fullPlan.candidates[5].relayEndpoint == nodeA && fullPlan.candidates[7].kind == .relayPureTCP,
                  "Remaining credentialed relay node modes missing")
        try check(fullPlan.notes.contains { $0.contains("missing.relay.invalid") },
                  "Missing credential note not reported")

        let relayOnlyPlan = RouteBenchmarkPlanner.plan(
            address: "  ",
            portString: "5908",
            relayEnabled: true,
            relayDeviceIDString: deviceID.uuidString,
            configuredNodes: [nodeA],
            nodesWithCredentials: [nodeA.address]
        )
        try check(relayOnlyPlan.candidates.map(\.kind) == [.relayAutoPunch, .relayPureUDP, .relayPureTCP],
                  "Relay-only plan should include auto-punch, pure UDP and pure TCP")

        let badInputPlan = RouteBenchmarkPlanner.plan(
            address: "https://bad.invalid",
            portString: "99999",
            relayEnabled: true,
            relayDeviceIDString: "not-a-uuid",
            configuredNodes: [nodeA],
            nodesWithCredentials: [nodeA.address]
        )
        try check(badInputPlan.candidates.isEmpty && badInputPlan.notes.count >= 2,
                  "Invalid host/UUID should skip candidates with explanatory notes")
    }

    run("RouteBenchmarkMetrics and RouteBenchmarkScorer rank clean UDP, punched relay and loss-resilient TCP accurately") {
        let start = Date(timeIntervalSince1970: 2_000)
        let node = try RelayEndpoint(address: "tls://relay.invalid:7443")
        let deviceID = UUID()

        // 1. Clean Direct UDP (12 ms RTT, 0% loss, 30 fps, 18 Mbps)
        let directUDPCandidate = RouteBenchmarkCandidate(kind: .directUDP, address: "198.51.100.10", port: 5908)
        let recDirect = ConnectionDiagnosticRecorder(
            startedAt: start, now: 0, route: DiagnosticRoute(control: .direct, media: .directUDP)
        )
        for sec in 1...30 {
            recDirect.recordTraffic(bytes: 2_250_000, frames: 30, seconds: 1, at: Double(sec))
            recDirect.recordUDPRoundTrip(milliseconds: 12, at: Double(sec))
            recDirect.recordLoss(settled: 180, lost: 0, at: Double(sec))
        }
        let directMetrics = RouteBenchmarkMetrics.from(
            report: recDirect.finish(remoteName: "Mac", reason: "Done", at: 30),
            candidate: directUDPCandidate,
            connectMilliseconds: 85,
            firstFrameMilliseconds: 260,
            finalRouteLabel: "UDP 视频",
            appliedQualitySummary: "2880×1800 · 60 fps · 20 Mbps · HEVC",
            hostSupportsQualityProbe: true
        )
        let directEval = RouteBenchmarkScorer.evaluate(candidate: directUDPCandidate, metrics: directMetrics)
        try check(directEval.grade == .excellent && directEval.score >= 90, "Clean direct UDP should score excellent, got \(directEval.score)")

        // 2. Relay Auto-Punch that punched direct UDP, vs Relay Pure UDP with heavy 8.5% packet loss, vs Relay Pure TCP
        let punchCandidate = RouteBenchmarkCandidate(kind: .relayAutoPunch, relayEndpoint: node, relayDeviceID: deviceID)
        let recPunch = ConnectionDiagnosticRecorder(
            startedAt: start, now: 0, route: DiagnosticRoute(control: .relay, media: .relayUDP, node: node.address)
        )
        recPunch.recordTraffic(bytes: 1_500_000, frames: 25, seconds: 1, at: 1)
        recPunch.changeRoute(DiagnosticRoute(control: .relay, media: .punchedUDP, node: node.address), at: 1)
        for sec in 2...30 {
            recPunch.recordTraffic(bytes: 2_000_000, frames: 30, seconds: 1, at: Double(sec))
            recPunch.recordUDPRoundTrip(milliseconds: 22, at: Double(sec))
            recPunch.recordLoss(settled: 160, lost: 0, at: Double(sec))
        }
        let punchMetrics = RouteBenchmarkMetrics.from(
            report: recPunch.finish(remoteName: "Mac", reason: "Done", at: 30),
            candidate: punchCandidate,
            connectMilliseconds: 240,
            firstFrameMilliseconds: 520,
            finalRouteLabel: "直连 UDP 视频（中继打洞）",
            appliedQualitySummary: "2560×1440 · 60 fps · 16 Mbps",
            hostSupportsQualityProbe: true
        )
        try check(punchMetrics.punchedDirect && !punchMetrics.fellBackToTCP, "Punched direct state not detected")
        let punchEval = RouteBenchmarkScorer.evaluate(candidate: punchCandidate, metrics: punchMetrics)

        let lossyUDPCandidate = RouteBenchmarkCandidate(kind: .relayPureUDP, relayEndpoint: node, relayDeviceID: deviceID)
        let recLossy = ConnectionDiagnosticRecorder(
            startedAt: start, now: 0, route: DiagnosticRoute(control: .relay, media: .relayUDP, node: node.address)
        )
        for sec in 1...30 {
            recLossy.recordTraffic(bytes: 600_000, frames: 12, seconds: 1, at: Double(sec))
            recLossy.recordUDPRoundTrip(milliseconds: 65, at: Double(sec))
            recLossy.recordLoss(settled: 100, lost: 9, at: Double(sec)) // 9% loss!
        }
        let lossyMetrics = RouteBenchmarkMetrics.from(
            report: recLossy.finish(remoteName: "Mac", reason: "Done", at: 30),
            candidate: lossyUDPCandidate,
            connectMilliseconds: 310,
            firstFrameMilliseconds: 1_500,
            finalRouteLabel: "中继 UDP 视频",
            appliedQualitySummary: "1280×800 · 30 fps · 4 Mbps",
            hostSupportsQualityProbe: true
        )
        let lossyEval = RouteBenchmarkScorer.evaluate(candidate: lossyUDPCandidate, metrics: lossyMetrics)

        let pureTCPCandidate = RouteBenchmarkCandidate(kind: .relayPureTCP, relayEndpoint: node, relayDeviceID: deviceID)
        let recTCP = ConnectionDiagnosticRecorder(
            startedAt: start, now: 0, route: DiagnosticRoute(control: .relay, media: .relayTCP, node: node.address)
        )
        for sec in 1...30 {
            recTCP.recordTraffic(bytes: 1_500_000, frames: 28, seconds: 1, at: Double(sec))
            recTCP.recordRoundTrip(milliseconds: 48, at: Double(sec))
        }
        let tcpMetrics = RouteBenchmarkMetrics.from(
            report: recTCP.finish(remoteName: "Mac", reason: "Done", at: 30),
            candidate: pureTCPCandidate,
            connectMilliseconds: 290,
            firstFrameMilliseconds: 680,
            finalRouteLabel: "中继 TCP 视频",
            appliedQualitySummary: "1920×1200 · 60 fps · 12 Mbps",
            hostSupportsQualityProbe: true
        )
        let tcpEval = RouteBenchmarkScorer.evaluate(candidate: pureTCPCandidate, metrics: tcpMetrics)

        try check(directEval.score > punchEval.score, "Clean direct UDP should beat relayed auto-punch")
        try check(punchEval.score > tcpEval.score, "Clean punched UDP should beat pure relay TCP")
        try check(tcpEval.score > lossyEval.score + 15,
                  "Pure TCP (\(tcpEval.score)) should decisively beat 9%-loss UDP (\(lossyEval.score))")

        // Verify recommendation when UDP is lossy and TCP wins
        let lossyComparison = [
            RouteBenchmarkResult(candidate: lossyUDPCandidate, status: .completed, metrics: lossyMetrics, evaluation: lossyEval),
            RouteBenchmarkResult(candidate: pureTCPCandidate, status: .completed, metrics: tcpMetrics, evaluation: tcpEval),
            RouteBenchmarkResult(candidate: directUDPCandidate, status: .failed("连接超时"))
        ]
        let recommendation = RouteBenchmarkScorer.recommendBest(from: lossyComparison)
        try check(recommendation?.winner.id == pureTCPCandidate.id, "Expected Pure TCP to be recommended over 9%-loss UDP")
        try check(recommendation?.reason.contains("高丢包") == true, "Recommendation should explain avoiding high UDP loss")
    }
}
