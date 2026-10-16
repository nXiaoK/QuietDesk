import Foundation
import Network
import QuietDeskCore

func runConnectionMetricsChecks() {
    run("Round-trip probes reject legacy, stale, duplicate and malformed responses") {
        var probe = RoundTripProbe()
        guard let first = probe.begin(at: 10) else { throw CheckFailure("No first probe") }
        try check(probe.begin(at: 11) == nil, "Pending sample was replaced")
        try check(probe.complete(Data(), at: 11) == nil, "Legacy empty pong produced a measurement")
        try check(probe.complete(Data([1]), at: 11) == nil, "Malformed pong produced a measurement")
        try check(probe.complete(first, at: .nan) == nil && probe.complete(first, at: 9) == nil, "Invalid timestamp accepted")
        guard let milliseconds = probe.complete(first, at: 10.032) else { throw CheckFailure("Valid echo not measured") }
        try check(abs(milliseconds - 32) < 0.0001, "RTT unit is not milliseconds")
        try check(probe.complete(first, at: 11) == nil, "Duplicate pong measured twice")
        guard let second = probe.begin(at: 12), let replacement = probe.begin(at: 43) else { throw CheckFailure("Expired sample was not replaced") }
        try check(probe.complete(second, at: 43.1) == nil, "Expired echo matched new request")
        try check(probe.complete(replacement, at: 43.1) != nil, "Replacement sample lost")
        try check(probe.begin(at: .infinity) == nil, "Infinite timestamp accepted")
    }

    if !CommandLine.arguments.contains("--skip-network") {
        run("RTT is measured over authenticated TLS without delivering heartbeat messages to the app") {
            let key = try PairingKey.generate()
            let listener = try makeListener(key, queue: DispatchQueue(label: "checks.rtt"))
            let server = Box<Peer?>(nil), measurement = Box<Double?>(nil), unexpected = Box(false)
            let received = DispatchSemaphore(value: 0)
            listener.newConnectionHandler = { connection in
                let peer = Peer(connection: connection)
                peer.onMessage = { _ in unexpected.set(true) }
                server.set(peer)
                peer.start()
            }
            guard let port = listener.port else { throw CheckFailure("No RTT test port") }
            let client = Peer(connection: NWConnection(host: "127.0.0.1", port: port, using: SecureTransport.parameters(key: key)))
            client.onMessage = { _ in unexpected.set(true) }
            client.onRoundTripMilliseconds = { value in measurement.set(value); received.signal() }
            defer { client.close(); server.read()?.close(); listener.cancel() }
            client.start()
            try wait(received, "No authenticated RTT sample")
            try check(measurement.read().map { $0.isFinite && $0 >= 0 && $0 < 30_000 } == true, "Invalid RTT measurement")
            try check(!unexpected.read(), "Heartbeat leaked into application messages")
        }
    }
}
