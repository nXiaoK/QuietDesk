import Foundation
import Network
import QuietDeskCore

func runRelayNodeProbeChecks() {
    run("Relay nodes rank by delay with failed attempts penalised, unreachable and unmeasured last") {
        let a = try RelayEndpoint(address: "tls://a.example:7443"), b = try RelayEndpoint(address: "tls://b.example:7443")
        let c = try RelayEndpoint(address: "tls://c.example:7443"), d = try RelayEndpoint(address: "tls://d.example:7443")
        let measured: [RelayEndpoint: RelayNodeProbe.Measurement] = [
            a: .init(milliseconds: 30, attempts: 3, failures: 1),   // 230
            b: .init(milliseconds: 80, attempts: 3, failures: 0),   // 80
            c: .init(milliseconds: nil, attempts: 3, failures: 3)]
        try check(RelayNodeProbe.ordered([d, c, a, b], by: measured) == [b, a, c, d], "Nodes ranked in the wrong order")
        try check(RelayNodeProbe.ordered([a, b], by: [:]) == [a, b], "Unmeasured nodes lost their configured order")
        let tie: [RelayEndpoint: RelayNodeProbe.Measurement] = [a: .init(milliseconds: 40, attempts: 3, failures: 0),
                                                                 b: .init(milliseconds: 40, attempts: 3, failures: 0)]
        try check(RelayNodeProbe.ordered([b, a], by: tie) == [b, a], "Equal nodes were reordered")
    }

    run("A relay probe times a local TCP accept and reports a closed port as unreachable") {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: DispatchQueue(label: "relay-probe-check"))
        defer { listener.cancel() }
        try wait(ready, "Probe listener did not start")
        guard let port = listener.port?.rawValue else { throw CheckFailure("Probe listener has no port") }
        let open = try RelayEndpoint(address: "tls://127.0.0.1:\(port)")
        let result = Box<RelayNodeProbe.Measurement?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task { result.set(await RelayNodeProbe.measure(open, attempts: 2, timeout: 2)); done.signal() }
        try wait(done, "Probe of an open port did not finish")
        let measured = result.read()
        try check(measured?.failures == 0 && (measured?.milliseconds ?? -1) >= 0 && (measured?.milliseconds ?? 9_999) < 2_000,
                  "Open port was not measured: \(String(describing: measured))")
        listener.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        let closed = try RelayEndpoint(address: "tls://127.0.0.1:\(port)")
        let started = Date()
        Task { result.set(await RelayNodeProbe.measure(closed, attempts: 1, timeout: 2)); done.signal() }
        try wait(done, "Probe of a closed port did not finish")
        try check(result.read()?.milliseconds == nil && result.read()?.failures == 1, "Closed port was reported reachable")
        try check(Date().timeIntervalSince(started) < 2.5, "Closed port probe outlived its timeout")
    }
}
