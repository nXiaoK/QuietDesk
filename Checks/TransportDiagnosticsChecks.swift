import Foundation
import Network
import QuietDeskCore

func runTransportDiagnosticsChecks() {
    if CommandLine.arguments.contains("--skip-network") { return }

    run("Optional diagnostics preserve default TLS peers and measure existing round-trip probes") {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.setEnabled(true)
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.diagnostics-rtt"))
        let server = Box<Peer?>(nil), correct = Box(false)
        let measured = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { message in
                correct.set(message.kind == .input && message.payload == Data([7, 8, 9]))
                received.signal()
            }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No diagnostics RTT port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 100, diagnostics: diagnostics)
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.onRoundTripMilliseconds = { _ in measured.signal() }
        client.start()
        try wait(measured, "Optional diagnostics interrupted the existing heartbeat")
        client.send(Message(.input, Data([7, 8, 9])))
        try wait(received, "Default peer did not receive application data")
        try check(correct.read(), "Optional diagnostics changed message bytes or exposed heartbeats")
        let summaries = diagnostics.drain()
        guard let roundTrip = summaries.first(where: { $0.metric == .roundTrip }) else {
            throw CheckFailure("No diagnostic round-trip summary")
        }
        try check(roundTrip.count == 1 && roundTrip.unit == .microseconds
            && roundTrip.messageKind == MessageKind.pong.rawValue && roundTrip.worstIdentifier != nil,
            "Round-trip diagnostics lost their kind, unit or probe identifier")
    }

    run("TCP reports follow mid-connection diagnostic changes and stop after close") {
        let diagnostics = PerformanceDiagnostics()
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.diagnostics-tcp"))
        let server = Box<Peer?>(nil)
        let ready = DispatchSemaphore(value: 0), echoed = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { [weak peer] message in peer?.send(message) }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No TCP report port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 0.05, diagnostics: diagnostics)
        defer { client.close(); server.read()?.close(); listener.cancel() }
        client.onReady = { ready.signal() }
        client.onMessage = { _ in echoed.signal() }
        client.onClose = { _ in closed.signal() }
        client.start()
        try wait(ready, "TCP diagnostic peer did not connect")
        client.send(Message(.input, Data([1, 2, 3])))
        try wait(echoed, "Disabled TCP diagnostics changed application delivery")
        Thread.sleep(forTimeInterval: 0.15)
        try check(diagnostics.drain().isEmpty, "Disabled TCP diagnostics retained samples")

        let tcpMetrics: Set<PerformanceMetric> = [.tcpSmoothedRTT, .tcpMinimumRTT, .tcpRTTVariance,
                                                 .tcpReportDuration, .tcpRetransmittedBytes, .tcpOutOfOrderBytes,
                                                 .tcpSentBytes, .tcpReceivedBytes]
        diagnostics.setEnabled(true)
        var observed: Set<PerformanceMetric> = []
        let deadline = Date().addingTimeInterval(3)
        while observed != tcpMetrics, Date() < deadline {
            for summary in diagnostics.drain() where tcpMetrics.contains(summary.metric) {
                observed.insert(summary.metric)
                try check(summary.count >= 1 && summary.messageKind == nil && summary.worstIdentifier == nil,
                          "TCP report was labeled as an application message")
            }
            if observed != tcpMetrics { Thread.sleep(forTimeInterval: 0.01) }
        }
        try check(observed == tcpMetrics, "Enabling diagnostics on a ready peer did not collect TCP reports")
        diagnostics.setEnabled(false)
        client.queue.sync {}
        diagnostics.setEnabled(true)
        diagnostics.setEnabled(false)
        client.queue.sync {}
        Thread.sleep(forTimeInterval: 0.15)
        try check(diagnostics.drain().isEmpty, "A late TCP report survived disabling diagnostics")

        diagnostics.setEnabled(true)
        client.close()
        try wait(closed, "TCP diagnostic peer did not close")
        _ = diagnostics.drain()
        diagnostics.setEnabled(false)
        diagnostics.setEnabled(true)
        Thread.sleep(forTimeInterval: 0.15)
        try check(diagnostics.drain().isEmpty, "A closed peer collected reports after a diagnostic epoch change")
    }

    run("TLS diagnostics separate fragmented bodies, send queue and handlers while fencing stale callbacks") {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.setEnabled(true)
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.diagnostics-delivery"))
        let server = Box<Peer?>(nil), messages = Box<[Message]>([]), resumes = Box<[() -> Void]>([])
        let ready = DispatchSemaphore(value: 0), header = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let firstHeader = Box(false), networkError = Box<NWError?>(nil)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100, diagnostics: diagnostics)
            server.set(peer)
            peer.onTraffic = { count in
                firstHeader.update { observed in
                    if !observed, count == 4 { observed = true; header.signal() }
                }
            }
            peer.onMessageHandled = { message, resume in
                messages.update { $0.append(message) }
                resumes.update { $0.append(resume) }
                delivered.signal()
            }
            peer.onClose = { _ in closed.signal() }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No diagnostics delivery port") }
        let raw = NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key))
        raw.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        defer { raw.cancel(); server.read()?.close(); listener.cancel() }
        raw.start(queue: DispatchQueue(label: "checks.diagnostics-raw"))
        try wait(ready, "Raw diagnostic sender did not establish TLS")

        var avcc = Data()
        avcc.put(UInt32(131_073))
        avcc.append(Data(repeating: 0x65, count: 131_073))
        let payload = try VideoPacket(sequence: 42, sps: Data(), pps: Data(), avcc: avcc).encode()
        let framed = try Message(.video, payload).framed()
        raw.send(content: Data(framed.prefix(4)), completion: .contentProcessed { networkError.set($0) })
        try wait(header, "Peer did not consume the separated header")
        guard let peer = server.read() else { throw CheckFailure("No diagnostic server peer") }
        peer.queue.sync {}
        raw.send(content: Data(framed[4..<65_540]), completion: .contentProcessed { if let error = $0 { networkError.set(error) } })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
            raw.send(content: Data(framed.dropFirst(65_540)), completion: .contentProcessed { if let error = $0 { networkError.set(error) } })
        }
        try wait(delivered, "Fragmented diagnostic frame was not reassembled")
        try check(messages.read().first?.payload == payload && networkError.read() == nil,
            "Diagnostics changed the fragmented frame or TLS send failed")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0), sendSucceeded = Box(false)
        peer.queue.async { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        try wait(entered, "Send-queue delay was not installed")
        var acknowledgement = Data(); acknowledgement.put(UInt32(42))
        peer.send(Message(.acknowledgement, acknowledgement)) { sendSucceeded.set($0); sent.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { release.signal() }
        try wait(sent, "Diagnostic acknowledgement did not complete")
        try check(sendSucceeded.read(), "Diagnostics failed the acknowledgement send")
        let resume = resumes.read()[0]
        resume(); resume()
        peer.queue.sync {}
        let summaries = diagnostics.drain()
        guard let headerWait = summaries.first(where: { $0.metric == .receiveHeaderWait }),
              let body = summaries.first(where: { $0.metric == .receiveBody }),
              let queue = summaries.first(where: { $0.metric == .sendQueue }),
              let handler = summaries.first(where: { $0.metric == .messageHandler }),
              let completion = summaries.first(where: { $0.metric == .sendCompletion }),
              let pending = summaries.first(where: { $0.metric == .pendingSendBytes }) else {
            throw CheckFailure("Missing transport phase summary")
        }
        try check(headerWait.count == 1 && headerWait.unit == .microseconds
            && headerWait.messageKind == nil && headerWait.worstIdentifier == nil,
            "Header wait was omitted or mislabeled as a known message")
        try check(body.count == 1 && body.minimum >= 80_000 && body.worstIdentifier == 42
            && body.messageKind == MessageKind.video.rawValue, "Body assembly delay or video sequence was lost")
        try check(queue.minimum >= 80_000 && queue.worstIdentifier == 42,
            "Peer queue delay was conflated with send completion")
        try check(handler.count == 1 && handler.minimum >= 80_000 && handler.worstIdentifier == 42,
            "Handler delay was lost or duplicate continuation was counted")
        try check(completion.count == 1 && completion.unit == .microseconds
            && pending.maximum >= acknowledgement.count + 5 && pending.unit == .bytes,
            "Send completion or pending-byte metrics have incorrect units")

        raw.send(content: try Message(.input, Data([1, 2, 3, 4])).framed(), completion: .contentProcessed { _ in })
        try wait(delivered, "Second diagnostic message was not delivered")
        try check(diagnostics.drain().allSatisfy { $0.worstIdentifier == nil },
            "Diagnostics extracted an identifier from application content")
        diagnostics.setEnabled(false)
        diagnostics.setEnabled(true)
        resumes.read()[1]()
        peer.queue.sync {}
        try check(diagnostics.drain().isEmpty, "Pre-toggle handler callback contaminated the new diagnostic epoch")

        raw.send(content: try Message(.acknowledgement, Data([1])).framed(), completion: .contentProcessed { _ in })
        try wait(delivered, "Malformed-identifier test message was not delivered")
        try check(diagnostics.drain().allSatisfy { $0.worstIdentifier == nil },
            "Diagnostics accepted a truncated acknowledgement identifier")
        peer.close()
        try wait(closed, "Diagnostic peer did not close")
        resumes.read()[2]()
        peer.queue.sync {}
        try check(diagnostics.drain().isEmpty, "Closed peer's late continuation produced diagnostic data")
    }
}
