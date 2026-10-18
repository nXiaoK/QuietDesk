import Foundation
import Network
import QuietDeskCore

func runVideoPacingChecks() {
    run("Video pacing derives a bounded rate and spends at most one burst of credit") {
        let megabitsPerSecond = { (megabits: Int) in VideoSendPacing(megabits: megabits).bytesPerSecond * 8 / 1_000_000 }
        try check(megabitsPerSecond(3) == 40 && megabitsPerSecond(8) == 40 && megabitsPerSecond(30) == 75
            && megabitsPerSecond(60) == 150 && megabitsPerSecond(100) == 200, "Pacing rate is outside its intended bounds")

        let pacing = VideoSendPacing(megabits: 100)
        let slice = VideoSendPacing.sliceBytes
        var pacer = VideoSendPacer(pacing, now: 10)
        for _ in 0..<(VideoSendPacing.burstBytes / slice) {
            try check(pacer.next(remaining: 1_000_000, now: 10) == (slice, 0), "Initial burst credit was not available")
        }
        let wait = pacer.next(remaining: 1_000_000, now: 10)
        try check(wait.bytes == 0 && abs(wait.delay - Double(slice) / pacing.bytesPerSecond) < 1e-9,
            "Exhausted credit did not wait one slice at the pacing rate")
        try check(pacer.next(remaining: 1_000_000, now: 10 + wait.delay).bytes == slice, "Exact wait did not release a slice")
        try check(pacer.next(remaining: 100, now: 10 + wait.delay * 2).bytes == 100, "Short tail was not sent as one piece")
        try check(pacer.next(remaining: 0, now: 11) == (0, 0), "Empty message requested pacing")

        var idle = VideoSendPacer(pacing, now: 0)
        _ = idle.next(remaining: slice, now: 0)
        var released = 0
        while idle.next(remaining: 1_000_000, now: 60).bytes > 0 { released += slice }
        try check(released == VideoSendPacing.burstBytes, "Idle or late wakeups released more than one burst")

        var frame = VideoSendPacer(pacing, now: 0)
        var remaining = 1_000_000, now = 0.0
        while remaining > 0 {
            let step = frame.next(remaining: remaining, now: now)
            if step.bytes > 0 { remaining -= step.bytes } else { now += step.delay }
        }
        let expected = Double(1_000_000 - VideoSendPacing.burstBytes) / pacing.bytesPerSecond
        try check(abs(now - expected) < 0.001, "A paced 1 MB frame took \(now) s instead of about \(expected) s")
    }

    if CommandLine.arguments.contains("--skip-network") { return }
    for videoKind: MessageKind in [.video, .mediaFrame] {
    run("Paced \(videoKind) keeps bytes and order, spreads large frames and completes once") {
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.video-pacing"))
        let server = Box<Peer?>(nil), received = Box<[(Message, TimeInterval)]>([])
        let done = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let completions = Box<[Bool]>([]), started = Box<TimeInterval>(0)
        var avcc = Data(); avcc.put(UInt32(524_288)); avcc.append(Data((0..<524_288).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        let video = try VideoPacket(sequence: 7, sps: Data(), pps: Data(), avcc: avcc).encode()
        let clipboard = Data(repeating: 0x5A, count: 1_500_000), acknowledgement = Data([0, 0, 0, 7])
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { message in
                received.update { $0.append((message, SessionClock.now)) }
                if received.read().count == 3 { done.signal() }
            }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No pacing test port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 100)
        defer { client.close(); server.read()?.close(); listener.cancel() }
        let pacing = VideoSendPacing(megabits: 8)
        client.setVideoPacing(pacing)
        client.onReady = {
            started.set(SessionClock.now)
            client.send(Message(videoKind, video)) { success in completions.update { $0.append(success) }; completed.signal() }
            client.send(Message(.clipboardChunk, clipboard))
            client.send(Message(.acknowledgement, acknowledgement))
        }
        client.start()
        try wait(done, "Paced messages were not delivered")
        try wait(completed, "Paced video did not complete")
        let messages = received.read()
        try check(messages.map(\.0.kind) == [videoKind, .clipboardChunk, .acknowledgement]
            && messages[0].0.payload == video && messages[1].0.payload == clipboard && messages[2].0.payload == acknowledgement,
            "Pacing changed message bytes or order")
        let minimum = Double(video.count + 5 - VideoSendPacing.burstBytes) / pacing.bytesPerSecond
        let elapsed = messages[0].1 - started.read()
        try check(elapsed >= minimum * 0.8, "A \(video.count)-byte video arrived after \(elapsed) s, faster than pacing allows (\(minimum) s)")
        // Pacing 1.5 MB at this rate would take about 0.3 s; other kinds must not wait for credit.
        try check(messages[1].1 - messages[0].1 < 0.15, "A large non-video message behind a paced frame was paced too")
        try check(completed.wait(timeout: .now() + 0.2) == .timedOut && completions.read() == [true],
            "Paced video completion was missing, failed or repeated")
        client.queue.sync {}
        try check(client.trafficMeter.snapshot().totals.sentBytes >= UInt64(video.count + clipboard.count),
            "Paced slices were not counted as sent traffic")
    }
    }

    run("Removing pacing flushes a waiting frame and closing fails unsent messages once") {
        let key = try PairingKey.generate()
        let listener = try makeListener(key, queue: DispatchQueue(label: "checks.video-pacing-close"))
        let server = Box<Peer?>(nil), arrivals = Box<[TimeInterval]>([]), arrived = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            let peer = Peer(connection: connection, heartbeatInterval: 100)
            server.set(peer)
            peer.onMessage = { message in
                if message.kind == .video { arrivals.update { $0.append(SessionClock.now) }; arrived.signal() }
            }
            peer.start()
        }
        guard let port = listener.port else { throw CheckFailure("No pacing close test port") }
        let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port,
            using: SecureTransport.parameters(key: key)), heartbeatInterval: 100)
        defer { client.close(); server.read()?.close(); listener.cancel() }
        let ready = DispatchSemaphore(value: 0)
        client.onReady = { ready.signal() }
        client.setVideoPacing(VideoSendPacing(megabits: 1))
        client.start()
        try wait(ready, "Pacing close client did not connect")
        // About 0.8 s at 40 Mbps; removing pacing should deliver it far sooner.
        let large = Data(repeating: 0x42, count: 4_000_000)
        let flushedAt = SessionClock.now
        client.send(Message(.video, large))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { client.setVideoPacing(nil) }
        try wait(arrived, "Unpaced remainder was not delivered")
        try check(arrivals.read()[0] - flushedAt < 0.5, "Removing pacing did not submit the rest of the frame")

        client.setVideoPacing(VideoSendPacing(megabits: 1))
        let results = Box<[Bool]>([]), finished = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            client.send(Message(.video, large)) { success in results.update { $0.append(success) }; finished.signal() }
        }
        client.send(Message(.acknowledgement, Data([0, 0, 0, 1]))) { success in results.update { $0.append(success) }; finished.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { client.close() }
        for _ in 0..<3 { try wait(finished, seconds: 5, "A message waiting for pacing never completed after close") }
        try check(finished.wait(timeout: .now() + 0.3) == .timedOut, "A paced message completed more than once")
        try check(results.read() == [false, false, false], "Messages that never fully left reported success: \(results.read())")
        try check(arrived.wait(timeout: .now() + 0.3) == .timedOut, "A partially paced frame was delivered after close")
    }
}
