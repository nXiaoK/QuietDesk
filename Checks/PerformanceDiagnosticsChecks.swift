import Foundation
import QuietDeskCore

func runPerformanceDiagnosticsChecks() {
    run("Performance collection is opt-in and ignores invalid measurements") {
        let time = Box<TimeInterval>(10)
        let diagnostics = PerformanceDiagnostics(clock: { time.read() })
        try check(diagnostics.start() == nil, "Default diagnostics were enabled")
        diagnostics.recordValue(.encodedBytes, 100)
        try check(diagnostics.drain().isEmpty, "Disabled diagnostics retained values")
        diagnostics.setEnabled(true)
        let token = diagnostics.start()
        time.set(9)
        diagnostics.record(.encode, since: token)
        time.set(.infinity)
        diagnostics.record(.encode, since: token)
        diagnostics.recordValue(.encodedBytes, -1)
        try check(diagnostics.drain().isEmpty, "Invalid durations or negative counts were recorded")
    }

    run("Performance windows summarize units, bounded percentile buckets and worst frame identifiers") {
        let time = Box<TimeInterval>(10)
        let diagnostics = PerformanceDiagnostics(enabled: true, clock: { time.read() })
        let token = diagnostics.start()
        time.set(10.5)
        diagnostics.record(.encode, since: token, kind: .video, identifier: 42)
        for _ in 0..<95 { diagnostics.recordValue(.encodedBytes, 1, kind: .video, identifier: 1) }
        for _ in 0..<5 { diagnostics.recordValue(.encodedBytes, 1000, kind: .video, identifier: 2) }
        time.set(15)
        let summaries = diagnostics.drain()
        guard let encode = summaries.first(where: { $0.metric == .encode }),
              let bytes = summaries.first(where: { $0.metric == .encodedBytes }) else { throw CheckFailure("Missing summaries") }
        try check(encode.unit == .microseconds && encode.maximum == 500_000 && encode.worstIdentifier == 42
                  && encode.windowMilliseconds == 5000, "Duration units, window or frame association changed")
        try check(bytes.count == 100 && bytes.minimum == 1 && bytes.maximum == 1000 && bytes.mean == 51
                  && bytes.p95UpperBound == 1 && bytes.worstIdentifier == 2 && bytes.messageKind == MessageKind.video.rawValue,
                  "Histogram, mean or worst identifier was incorrect")
        try check(diagnostics.drain().isEmpty, "A window was emitted twice")
        time.set(16)
        diagnostics.recordValue(.encodedBytes, Int.max)
        let large = diagnostics.drain().first!
        try check(large.maximum == Int.max && large.p95UpperBound == Int.max && large.windowMilliseconds == 1000,
                  "Large values overflowed the histogram")
    }

    run("Performance tokens cannot cross enable generations or connection recorders") {
        let time = Box<TimeInterval>(10)
        let first = PerformanceDiagnostics(enabled: true, clock: { time.read() })
        let second = PerformanceDiagnostics(enabled: true, clock: { time.read() })
        let old = first.start()
        first.setEnabled(false); first.setEnabled(true)
        time.set(11)
        first.record(.decode, since: old)
        second.record(.decode, since: old)
        try check(first.drain().isEmpty && second.drain().isEmpty, "Old tokens crossed an enable boundary or connection")
        let current = first.start()
        first.setEnabled(true)
        time.set(11.25)
        first.record(.decode, since: current)
        try check(first.drain().first?.maximum == 250_000, "An unchanged switch invalidated active measurement")
    }

    run("Concurrent performance recording and draining preserve every sample") {
        let diagnostics = PerformanceDiagnostics(enabled: true)
        let drained = Box(0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for index in 0..<1000 {
                diagnostics.recordValue(.encodedBytes, index)
                if index % 97 == 0 {
                    let count = diagnostics.drain().reduce(0) { $0 + $1.count }
                    drained.update { $0 += count }
                }
            }
        }
        let remaining = diagnostics.drain().reduce(0) { $0 + $1.count }
        try check(drained.read() + remaining == 8000, "Concurrent recording lost or duplicated samples")
    }

    run("Performance storage is bounded by metric and protocol kind rather than identifiers") {
        let diagnostics = PerformanceDiagnostics(enabled: true)
        let kinds = (0...255).compactMap { MessageKind(rawValue: UInt8($0)) }
        for metric in PerformanceMetric.allCases {
            for kind in kinds {
                for identifier in UInt64(0)..<100 { diagnostics.recordValue(metric, 1, kind: kind, identifier: identifier) }
            }
        }
        let summaries = diagnostics.drain()
        try check(summaries.count == PerformanceMetric.allCases.count * kinds.count && summaries.allSatisfy { $0.count == 100 },
                  "Sample or frame IDs created unbounded aggregation keys")
    }
}
