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

    run("RouteBenchmarkHistoryArchive target unification, retention cap, disk permissions and forward-compatible decoding") {
        let node = try RelayEndpoint(address: "tls://hk.relay.invalid:7443")
        let deviceA = UUID(uuidString: "aaaa1111-2222-3333-4444-555566667777")!
        let deviceB = UUID(uuidString: "bbbb1111-2222-3333-4444-555566667777")!

        let directCand = RouteBenchmarkCandidate(kind: .directUDP, address: "198.51.100.10", port: 5908)
        let punchCand = RouteBenchmarkCandidate(kind: .relayAutoPunch, relayEndpoint: node, relayDeviceID: deviceA)

        // Skipped-only run should not be persisted
        let skippedOnly = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_002),
            perRouteDurationSeconds: 30,
            stoppedEarly: true,
            target: RouteBenchmarkTargetDescriptor(displayName: "Home", directEndpoint: "198.51.100.10:5908"),
            results: [RouteBenchmarkResult(candidate: directCand, status: .skipped)]
        )
        try check(skippedOnly == nil, "Aborted run with zero evaluated routes should not be saved")

        let cleanMetrics = RouteBenchmarkMetrics(
            connectMilliseconds: 90,
            firstFrameMilliseconds: 260,
            measuredSeconds: 30,
            finalRoute: .punchedUDP,
            finalRouteLabel: "直连 UDP 视频（中继打洞）",
            punchedDirect: true,
            fellBackToTCP: false,
            udpRTTMeanMilliseconds: 20,
            udpRTTMaxMilliseconds: 32,
            udpLossMeanPercent: 0,
            udpLossMaxPercent: 0,
            settledFragments: 3_000,
            lostFragments: 0,
            averageMegabits: 16.5,
            peakMegabits: 18.0,
            averageFPS: 30.0,
            peakFPS: 30.0,
            decodedFrames: 900,
            appliedQualitySummary: "2560×1440 · 60 fps · 16 Mbps",
            hostSupportsQualityProbe: true
        )
        let cleanEval = RouteBenchmarkScorer.evaluate(candidate: punchCand, metrics: cleanMetrics)

        // Run 1: Direct + Relay for Mac A
        let targetCombinedA = RouteBenchmarkTargetDescriptor(
            displayName: "家里 Mac（198.51.100.10:5908）",
            directEndpoint: RouteBenchmarkTargetDescriptor.normalizedDirectEndpoint(address: "198.51.100.10", port: 5908),
            relayDeviceID: deviceA
        )
        let run1 = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 3_000),
            finishedAt: Date(timeIntervalSince1970: 3_065),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: targetCombinedA,
            results: [
                RouteBenchmarkResult(candidate: directCand, status: .failed("连接超时")),
                RouteBenchmarkResult(candidate: punchCand, status: .completed, metrics: cleanMetrics, evaluation: cleanEval)
            ]
        )!

        // Run 2: Relay-only for Mac A (no direct address filled)
        let targetRelayOnlyA = RouteBenchmarkTargetDescriptor(
            displayName: "中继设备 \(deviceA.uuidString.lowercased())",
            relayDeviceID: deviceA
        )
        let run2 = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 4_000),
            finishedAt: Date(timeIntervalSince1970: 4_035),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: targetRelayOnlyA,
            results: [
                RouteBenchmarkResult(candidate: punchCand, status: .completed, metrics: cleanMetrics, evaluation: cleanEval)
            ]
        )!

        // Run 3: Distinct Mac B
        let otherDirect = RouteBenchmarkCandidate(kind: .directUDP, address: "203.0.113.77", port: 5908)
        let run3 = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 5_000),
            finishedAt: Date(timeIntervalSince1970: 5_032),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: RouteBenchmarkTargetDescriptor(
                displayName: "办公室 Mac",
                directEndpoint: "203.0.113.77:5908",
                relayDeviceID: deviceB
            ),
            results: [
                RouteBenchmarkResult(candidate: otherDirect, status: .failed("拒绝连接"))
            ]
        )!

        var archive = RouteBenchmarkHistoryArchive(runs: [run1, run2, run3])
        try check(archive.distinctTargets().count == 2, "Expected 2 unified distinct targets, got \(archive.distinctTargets().count)")

        // Querying Mac A by direct-only endpoint still unifies Run 1 and Run 2 via learned relayDeviceID!
        let directOnlyQueryA = RouteBenchmarkTargetDescriptor(displayName: "198.51.100.10:5908", directEndpoint: "198.51.100.10:5908")
        let matchedA = archive.runs(matching: directOnlyQueryA)
        try check(matchedA.count == 2 && matchedA[0].id == run2.id && matchedA[1].id == run1.id,
                  "Unified target lookup failed to join direct+relay and relay-only runs for Mac A")

        // Disk persistence round trip, POSIX 0600 permissions, and zero secret material
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-route-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("route-benchmark-history.json")

        let emptyLoad = RouteBenchmarkHistoryPersistence.load(from: fileURL)
        try check(emptyLoad.archive.runs.isEmpty && !emptyLoad.protectsUnreadFile && emptyLoad.warningMessage == nil,
                  "Missing history file should load cleanly as empty")

        try RouteBenchmarkHistoryPersistence.save(archive, to: fileURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try check((perms & 0o777) == 0o600, String(format: "Expected 0600 permissions on history file, got %04o", perms & 0o777))

        let reloaded = RouteBenchmarkHistoryPersistence.load(from: fileURL)
        try check(!reloaded.protectsUnreadFile && reloaded.archive == archive, "Saved archive did not round-trip identically")

        // Retention cap at maximumRuns (200)
        for index in 0..<205 {
            var extra = run2
            extra = RouteBenchmarkRunRecord(
                startedAt: Date(timeIntervalSince1970: Double(10_000 + index)),
                finishedAt: Date(timeIntervalSince1970: Double(10_010 + index)),
                perRouteDurationSeconds: 15,
                target: targetRelayOnlyA,
                entries: run2.entries
            )
            archive.record(extra)
        }
        try check(archive.runs.count == RouteBenchmarkHistoryArchive.maximumRuns,
                  "Archive exceeded maximumRuns cap: \(archive.runs.count)")
        try check(archive.runs.first?.startedAt == Date(timeIntervalSince1970: 10_204),
                  "Archive should retain newest runs first")

        // Future schema version sets protectsUnreadFile = true
        let futureURL = tempDir.appendingPathComponent("future.json")
        try Data(#"{"version":99,"runs":[]}"#.utf8).write(to: futureURL)
        let futureLoad = RouteBenchmarkHistoryPersistence.load(from: futureURL)
        try check(futureLoad.protectsUnreadFile && futureLoad.warningMessage != nil,
                  "Unsupported future version must protect unread file instead of overwriting")

        // Unknown future DiagnosticRoute.Media case decodes gracefully as .negotiating
        let unknownMedia = try JSONDecoder().decode(DiagnosticRoute.Media.self, from: Data(#""quicDatagramV9""#.utf8))
        try check(unknownMedia == .negotiating, "Unknown DiagnosticRoute.Media should fall back to .negotiating")
    }

    run("RouteBenchmarkHistoryEvaluator penalizes intermittent failures and packet-loss spikes across historical runs") {
        let node = try RelayEndpoint(address: "tls://sh.relay.invalid:7443")
        let deviceID = UUID()
        let target = RouteBenchmarkTargetDescriptor(
            displayName: "家里 Mac",
            directEndpoint: "198.51.100.25:5908",
            relayDeviceID: deviceID
        )

        let directUDP = RouteBenchmarkCandidate(kind: .directUDP, address: "198.51.100.25", port: 5908)
        let autoPunch = RouteBenchmarkCandidate(kind: .relayAutoPunch, relayEndpoint: node, relayDeviceID: deviceID)
        let relayUDP = RouteBenchmarkCandidate(kind: .relayPureUDP, relayEndpoint: node, relayDeviceID: deviceID)
        let relayTCP = RouteBenchmarkCandidate(kind: .relayPureTCP, relayEndpoint: node, relayDeviceID: deviceID)

        func makeMetrics(
            route: DiagnosticRoute.Media,
            punched: Bool = false,
            rtt: Double,
            lossPercent: Double?,
            fps: Double,
            mbps: Double
        ) -> RouteBenchmarkMetrics {
            let settled = lossPercent == nil ? 0 : 2_000
            let lost = lossPercent.map { Int(($0 / 100.0 * 2_000.0).rounded()) } ?? 0
            return RouteBenchmarkMetrics(
                connectMilliseconds: 150,
                firstFrameMilliseconds: 420,
                measuredSeconds: 30,
                finalRoute: route,
                finalRouteLabel: route.rawValue,
                punchedDirect: punched,
                fellBackToTCP: false,
                controlRTTMeanMilliseconds: rtt,
                controlRTTMaxMilliseconds: rtt + 12,
                udpRTTMeanMilliseconds: lossPercent == nil ? nil : rtt,
                udpRTTMaxMilliseconds: lossPercent == nil ? nil : rtt + 12,
                udpLossMeanPercent: lossPercent,
                udpLossMaxPercent: lossPercent.map { $0 * 1.3 },
                settledFragments: settled,
                lostFragments: lost,
                averageMegabits: mbps,
                peakMegabits: mbps + 2,
                averageFPS: fps,
                peakFPS: fps,
                decodedFrames: Int(fps * 30),
                appliedQualitySummary: "1920×1080",
                hostSupportsQualityProbe: true
            )
        }

        let directGoodM = makeMetrics(route: .directUDP, rtt: 11, lossPercent: 0, fps: 30, mbps: 18)
        let directGoodE = RouteBenchmarkScorer.evaluate(candidate: directUDP, metrics: directGoodM)

        let punchSteadyM = makeMetrics(route: .punchedUDP, punched: true, rtt: 22, lossPercent: 0.05, fps: 30, mbps: 16)
        let punchSteadyE = RouteBenchmarkScorer.evaluate(candidate: autoPunch, metrics: punchSteadyM)

        let udpSpikeLossM = makeMetrics(route: .relayUDP, rtt: 58, lossPercent: 9.5, fps: 13, mbps: 4.5)
        let udpSpikeLossE = RouteBenchmarkScorer.evaluate(candidate: relayUDP, metrics: udpSpikeLossM)

        let tcpSteadyM = makeMetrics(route: .relayTCP, rtt: 42, lossPercent: nil, fps: 29, mbps: 13)
        let tcpSteadyE = RouteBenchmarkScorer.evaluate(candidate: relayTCP, metrics: tcpSteadyM)

        // Single-run check: stability must be .singleSample, not .rockSolid
        let runA = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_120),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: target,
            results: [
                RouteBenchmarkResult(candidate: directUDP, status: .completed, metrics: directGoodM, evaluation: directGoodE),
                RouteBenchmarkResult(candidate: autoPunch, status: .completed, metrics: punchSteadyM, evaluation: punchSteadyE),
                RouteBenchmarkResult(candidate: relayUDP, status: .completed, metrics: udpSpikeLossM, evaluation: udpSpikeLossE),
                RouteBenchmarkResult(candidate: relayTCP, status: .completed, metrics: tcpSteadyM, evaluation: tcpSteadyE)
            ]
        )!
        let singleAssessment = RouteBenchmarkHistoryEvaluator.assess(runs: [runA])!
        try check(singleAssessment.overallStability == .singleSample,
                  "Single benchmark run must report .singleSample stability")

        // Runs B & C: Direct UDP fails both times (1/3 = 33% availability!), while Auto-Punch & Relay TCP stay 100% solid
        let runB = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 2_000),
            finishedAt: Date(timeIntervalSince1970: 2_120),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: target,
            results: [
                RouteBenchmarkResult(candidate: directUDP, status: .failed("超过 12 秒未能建立连接")),
                RouteBenchmarkResult(candidate: autoPunch, status: .completed, metrics: punchSteadyM, evaluation: punchSteadyE),
                RouteBenchmarkResult(candidate: relayUDP, status: .completed, metrics: udpSpikeLossM, evaluation: udpSpikeLossE),
                RouteBenchmarkResult(candidate: relayTCP, status: .completed, metrics: tcpSteadyM, evaluation: tcpSteadyE)
            ]
        )!
        let runC = RouteBenchmarkRunRecord.from(
            startedAt: Date(timeIntervalSince1970: 3_000),
            finishedAt: Date(timeIntervalSince1970: 3_120),
            perRouteDurationSeconds: 30,
            stoppedEarly: false,
            target: target,
            results: [
                RouteBenchmarkResult(candidate: directUDP, status: .failed("超过 12 秒未能建立连接")),
                RouteBenchmarkResult(candidate: autoPunch, status: .completed, metrics: punchSteadyM, evaluation: punchSteadyE),
                RouteBenchmarkResult(candidate: relayUDP, status: .completed, metrics: udpSpikeLossM, evaluation: udpSpikeLossE),
                RouteBenchmarkResult(candidate: relayTCP, status: .completed, metrics: tcpSteadyM, evaluation: tcpSteadyE)
            ]
        )!

        let multiAssessment = RouteBenchmarkHistoryEvaluator.assess(runs: [runA, runB, runC])!
        try check(multiAssessment.runCount == 3 && multiAssessment.reachableRunCount == 3, "Unexpected run count")
        try check(multiAssessment.recommendedRoute?.id == autoPunch.id,
                  "Consistent 100%-available Auto-Punch must beat 33%-available Direct UDP; got \(multiAssessment.recommendedRoute?.candidate.title ?? "nil")")
        try check(multiAssessment.overallStability == .rockSolid,
                  "3 identical 100%-available runs should earn .rockSolid stability")
        try check(multiAssessment.recommendedRoute?.punchedDirectRatePercent == 100,
                  "Expected 100% NAT hole-punch rate")

        let directHist = multiAssessment.routeSummaries.first { $0.id == directUDP.id }!
        let tcpHist = multiAssessment.routeSummaries.first { $0.id == relayTCP.id }!
        let lossyUDPHist = multiAssessment.routeSummaries.first { $0.id == relayUDP.id }!

        try check(directHist.completedCount == 1 && directHist.failedCount == 2 && directHist.stability == .unstable,
                  "Flaky Direct UDP should record 1/3 completed and .unstable stability")
        try check(tcpHist.overallScore > directHist.overallScore,
                  "100%-available Relay TCP (\(tcpHist.overallScore)) should outrank 33%-available Direct UDP (\(directHist.overallScore))")
        try check(tcpHist.overallScore > lossyUDPHist.overallScore + 15,
                  "Steady Relay TCP (\(tcpHist.overallScore)) should decisively outrank 9.5%-loss Relay UDP (\(lossyUDPHist.overallScore))")
        try check(multiAssessment.insights.contains { $0.contains("丢包") },
                  "Assessment insights should warn about historical high UDP packet loss")
        try check(multiAssessment.insights.contains { $0.contains("打洞") },
                  "Assessment insights should summarize NAT hole-punch success rate")
    }
}
