import Foundation
@testable import QuietDeskCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

@main
private enum ConnectionReportHistoryChecks {
    static func main() {
        var passed = 0
        var failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Session reports persist, publish and delete independently of address history") {
            try temporaryDirectory { folder in
                let original = Data("existing address history".utf8)
                let addressFile = folder.appendingPathComponent("traffic-history-v2.json")
                try original.write(to: addressFile)
                let store = ConnectionReportHistoryStore(directory: folder)
                let first = report(10)
                let second = report(20)
                let published = DispatchSemaphore(value: 0)
                store.observe { reports, error in
                    if reports.first?.id == second.id, error == nil { published.signal() }
                }
                store.append(first)
                store.append(second)
                store.append(second)
                try require(published.wait(timeout: .now() + 5) == .success, "Appended report was not published")
                store.flush()
                let reportFile = folder.appendingPathComponent("session-reports-v1.json")
                let permissions = try FileManager.default.attributesOfItem(atPath: reportFile.path)[.posixPermissions] as? NSNumber
                try require(permissions?.intValue == 0o600, "Report was written without owner-only access")
                let reloaded = ConnectionReportHistoryStore(directory: folder)
                try require(reloaded.snapshot().reports == [second, first], "Reports were duplicated or changed by reload")
                reloaded.delete(id: second.id)
                reloaded.flush()
                try require(ConnectionReportHistoryStore(directory: folder).snapshot().reports == [first], "Deletion was not persisted")
                reloaded.clearAll()
                reloaded.flush()
                try require(ConnectionReportHistoryStore(directory: folder).snapshot().reports.isEmpty, "Clearing was not persisted")
                try require(try Data(contentsOf: addressFile) == original, "Address history was modified by report operations")
            }
        }

        run("History retains the latest 100 report start times, even with out-of-order appends") {
            try temporaryDirectory { folder in
                let store = ConnectionReportHistoryStore(directory: folder)
                let reports = (0..<103).map(report)
                reports.reversed().forEach { store.append($0) }
                store.flush()
                let reloaded = ConnectionReportHistoryStore(directory: folder)
                try require(reloaded.snapshot().reports.map(\.id) == reports.dropFirst(3).reversed().map(\.id),
                            "The history limit discarded a newer connection")
            }
        }

        run("Unreadable and newer report files are preserved through append, delete and clear") {
            let fixtures = ["invalid-json", #"{"version":2,"reports":[]}"#]
            for fixture in fixtures {
                try temporaryDirectory { folder in
                    let file = folder.appendingPathComponent("session-reports-v1.json")
                    let original = Data(fixture.utf8)
                    try original.write(to: file)
                    let store = ConnectionReportHistoryStore(directory: folder)
                    let fresh = report(10)
                    store.append(fresh)
                    try require(store.snapshot().reports == [fresh] && store.snapshot().error != nil,
                                "Protected history lost its in-memory report or error")
                    store.delete(id: fresh.id)
                    store.append(fresh)
                    store.clearAll()
                    store.flush()
                    try require(try Data(contentsOf: file) == original, "Unreadable or newer file was overwritten")
                    try require(store.snapshot().reports.isEmpty && store.snapshot().error != nil,
                                "Clearing should affect only in-memory reports")
                }
            }
        }

        run("A report write failure retains memory and flush retries once space is restored") {
            try temporaryDirectory { folder in
                let store = ConnectionReportHistoryStore(directory: folder)
                let file = folder.appendingPathComponent("session-reports-v1.json")
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                let fresh = report(10)
                store.append(fresh)
                store.flush()
                try require(store.snapshot().reports == [fresh] && store.snapshot().error != nil,
                            "Report or error disappeared after a failed write")
                try FileManager.default.removeItem(at: file)
                store.flush()
                try require(store.snapshot().error == nil && ConnectionReportHistoryStore(directory: folder).snapshot().reports == [fresh],
                            "Retry left an error or duplicated the report")
            }
        }

        run("Relay TCP and mixed UDP paths keep directions and count at the forwarding boundary once") {
            var now: TimeInterval = 0
            let viewer = ViewerConnectionDiagnostics(clock: { now })
            let channel = newChannel()
            let counter = RelayPeerTrafficCounter()
            viewer.attachRelayTrafficCounter(counter)
            viewer.attach(channel, relayed: true, node: "tls://relay.example:7443")
            viewer.setVideoPath(.committed(.udp, relayedUDP: true), on: channel)
            channel.recordChannelTraffic(.controlTCP, sent: 8, received: 40)
            channel.recordChannelTraffic(.videoTCP, sent: 2, received: 12)
            channel.recordChannelTraffic(.bulkTCP, sent: 90, received: 6)
            channel.recordDatagramTraffic(relayed: true, sent: 55, received: 90)
            counter.record(relayedSent: 61, relayedReceived: 97)
            for _ in 0..<30 { channel.recordFrame() }
            now = 1
            viewer.setPeerPath(.direct(.srflx))
            channel.recordDatagramTraffic(relayed: true, sent: 30, received: 42)
            counter.record(relayedSent: 4, directSent: 34, directReceived: 48)
            for _ in 0..<9 { channel.recordFrame() }
            now = 2
            viewer.sample()
            viewer.setPaused(true)
            channel.recordChannelTraffic(.controlTCP, sent: 3, received: 4)
            now = 3
            let report = viewer.finish(remoteName: "Fixture", reason: "结束")
            let traffic = report.traffic
            try require(counter.detailedSnapshot == .init(relayedSent: 65, relayedReceived: 97, directSent: 34, directReceived: 48),
                        "Relay directional snapshot changed")
            try require(traffic.relayTCP == .init(sentBytes: 103, receivedBytes: 62), "TCP was duplicated or attributed incorrectly")
            try require(traffic.relayUDP == .init(sentBytes: 65, receivedBytes: 97) &&
                        traffic.punchedUDP == .init(sentBytes: 34, receivedBytes: 48), "Loopback counted twice or relay/punch misclassified")
            try require(traffic.controlChannel.totalBytes == 55 && traffic.bulkChannel.totalBytes == 96 &&
                        traffic.videoChannel.totalBytes == 258 && traffic.totalBytes == 409, "Channel and path totals disagree")
            try require(report.totals.bytes == 382, "Relay framing changed the application throughput used by benchmarks")
            try require(report.frameRate.activeSamples == 2 && report.frameRate.activeSeconds == 2 &&
                        report.frameRate.idleSeconds == 0 && report.frameRate.dropEvents == 1, "Pause or path switch changed decoded frame accounting")
            try require(report.routes.first { $0.route.media == .punchedUDP }?.quality.traffic.relayUDP.sentBytes == 4,
                        "Residual relay traffic during a confirmed punched route was lost")
        }

        run("Direct UDP and forwarded UDP coexist, and same-clock finish drains late bytes") {
            var now: TimeInterval = 0
            let viewer = ViewerConnectionDiagnostics(clock: { now })
            let channel = newChannel()
            viewer.attach(channel, relayed: false, node: nil)
            viewer.setVideoPath(.trialUDP(relayed: true), on: channel)
            channel.recordDatagramTraffic(relayed: false, sent: 12, received: 25)
            channel.recordDatagramTraffic(relayed: true, sent: 14, received: 23)
            now = 1
            viewer.sample()
            channel.recordChannelTraffic(.controlTCP, sent: 8, received: 1)
            let report = viewer.finish(remoteName: "Fixture", reason: "结束")
            try require(report.traffic.directUDP == .init(sentBytes: 12, receivedBytes: 25) &&
                        report.traffic.relayUDP == .init(sentBytes: 14, receivedBytes: 23) &&
                        report.traffic.directTCP == .init(sentBytes: 8, receivedBytes: 1),
                        "Concurrent datagrams or final zero-duration traffic changed attribution")
        }

        run("Short route-boundary drains preserve frames and active time without distorting jitter") {
            var now: TimeInterval = 0
            let viewer = ViewerConnectionDiagnostics(clock: { now })
            let channel = newChannel()
            viewer.attach(channel, relayed: false, node: nil)
            viewer.setVideoPath(.committed(.udp, relayedUDP: false), on: channel)
            for _ in 0..<30 { channel.recordFrame() }
            now = 1
            viewer.sample()
            channel.recordFrame()
            now = 1.001
            viewer.setVideoPath(.committed(.tcp, relayedUDP: false), on: channel)
            for _ in 0..<30 { channel.recordFrame() }
            now = 2.001
            let report = viewer.finish(remoteName: "Fixture", reason: "结束")
            try require(report.totals.frames == 61 && abs(report.frameRate.activeSeconds - 2.001) < 0.0001,
                        "Short drains lost actual frames or time")
            try require(report.frameRate.activeSamples == 2 && abs((report.frameRate.maximumFPS ?? 0) - 30) < 0.0001
                        && report.frameRate.dropEvents == 0, "A one-millisecond drain polluted jitter")
        }

        run("Tailscale paths switch at the sampling boundary, and unobserved paths stay unknown") {
            var now: TimeInterval = 0
            let viewer = ViewerConnectionDiagnostics(clock: { now })
            let channel = newChannel()
            viewer.attach(channel, relayed: false, node: nil, tailnet: true)
            viewer.setVideoPath(.committed(.udp, relayedUDP: false), on: channel)
            channel.recordChannelTraffic(.controlTCP, sent: 1, received: 2)
            channel.recordDatagramTraffic(relayed: false, sent: 3, received: 4)
            now = 1
            viewer.setTailnetPath(peerPath: "direct", relay: "home-region")
            channel.recordChannelTraffic(.videoTCP, sent: 5, received: 6)
            channel.recordDatagramTraffic(relayed: false, sent: 7, received: 8)
            now = 2
            viewer.setTailnetPath(peerPath: "derp", relay: "region")
            channel.recordChannelTraffic(.bulkTCP, sent: 9, received: 10)
            channel.recordDatagramTraffic(relayed: false, sent: 11, received: 12)
            now = 3
            viewer.setTailnetPath(peerPath: "peer-relay", relay: "region")
            channel.recordChannelTraffic(.controlTCP, sent: 13, received: 14)
            now = 4
            let report = viewer.finish(remoteName: "Fixture", reason: "结束")
            let traffic = report.traffic
            try require(traffic.tailnetUnknownTCP == .init(sentBytes: 14, receivedBytes: 16)
                        && traffic.tailnetUnknownUDP == .init(sentBytes: 3, receivedBytes: 4), "Unknown route was guessed")
            try require(traffic.tailnetDirectTCP == .init(sentBytes: 5, receivedBytes: 6)
                        && traffic.tailnetDirectUDP == .init(sentBytes: 7, receivedBytes: 8), "P2P route was misclassified")
            try require(traffic.tailnetDERPTCP == .init(sentBytes: 9, receivedBytes: 10)
                        && traffic.tailnetDERPUDP == .init(sentBytes: 11, receivedBytes: 12), "DERP route was misclassified")
            try require(traffic.totalBytes == 105 && traffic.directBytes == 0 && traffic.relayUDP.totalBytes == 0,
                        "Overlay bytes were included more than once")
        }

        print("\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    private static func report(_ timestamp: Int) -> ConnectionDiagnosticReport {
        let recorder = ConnectionDiagnosticRecorder(startedAt: Date(timeIntervalSince1970: Double(timestamp)), now: 0,
            route: .init(control: .direct, media: .directUDP))
        var traffic = DiagnosticTrafficBreakdown()
        traffic.directUDP.add(sent: 7, received: 120)
        traffic.videoChannel = traffic.directUDP
        recorder.recordDetailedTraffic(traffic, frames: 30, seconds: 1, at: 1)
        return recorder.finish(remoteName: "Fixture", endpointLabel: "192.0.2.1:5908", reason: "结束", at: 2)
    }

    private static func newChannel() -> SessionDataChannel {
        SessionDataChannel(send: { _ in }, onFreshFrame: { _ in })
    }

    private static func temporaryDirectory(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quietdesk-session-reports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }
}
