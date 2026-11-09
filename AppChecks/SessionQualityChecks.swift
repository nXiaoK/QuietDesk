import Foundation
import QuietDeskCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message) }
}

func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message)
}

func wait(_ semaphore: DispatchSemaphore, seconds: Double = 10, _ message: String) throws {
    try check(semaphore.wait(timeout: .now() + seconds) == .success, message)
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

private var successes = 0, failures = 0
func run(_ name: String, _ body: () throws -> Void) {
    do { try body(); successes += 1; print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}

@main
private struct SessionQualityChecks {
    static func main() {
        print("Quality checks use synthetic states, JSON and generated video frames; no connections, capture, credentials, clipboard or permission changes.")
        let initial = VideoStreamState(settings: .init(), width: 1920, height: 1080)
        let low = StreamSettings(longestEdge: 1280, framesPerSecond: 10, megabits: 1)
        let high = StreamSettings.highest
        func presentation(_ tuning: VideoTuningSession?, applied: VideoStreamState? = initial, status: String = "") -> SessionQualityPresentation {
            SessionQualityPresentation(connected: true, supportsLiveSettings: true, applied: applied, tuning: tuning, status: status)
        }

        run("Disconnected quality never presents a stale applied state, request or error") {
            var tuning = try VideoTuningSession(applied: initial, preferred: high)
            _ = tuning.nextRequest()
            let value = SessionQualityPresentation(connected: false, supportsLiveSettings: true, applied: initial,
                                                   tuning: tuning, status: "调整失败：旧连接")
            try check(value.availability == .disconnected && value.applied == nil && value.update == .idle && value.message == nil,
                      "Disconnected quality showed the previous connection's state")
        }
        run("Older hosts show their actual quality without suggesting live adjustment is available") {
            let value = SessionQualityPresentation(connected: true, supportsLiveSettings: false, applied: initial,
                                                   tuning: nil, status: "主机需更新到 0.4.0 才能动态调整画质")
            try check(value.availability == .unsupported && value.applied == initial && value.update == .idle && value.message == nil,
                      "An older host lost its actual state or appeared adjustable")
        }
        run("Missing stream state is not fabricated from defaults or a status string") {
            let value = presentation(nil, applied: nil, status: "已生效：\(high.summary)")
            try check(value.applied == nil && value.update == .idle && value.message == nil, "A status string fabricated applied quality")
        }
        run("A debounced choice remains preparing until a real request exists") {
            var tuning = try VideoTuningSession(applied: initial)
            try tuning.choose(high)
            let value = presentation(tuning, status: "当前生效：\(initial.settings.summary)")
            try check(value.update == .preparing(high) && value.applied == initial && tuning.pending == nil,
                      "A local choice was presented as a sent request or applied state")
        }
        run("Sent requests, coalesced latest choices and actual settings stay distinct") {
            var tuning = try VideoTuningSession(applied: initial, preferred: low)
            let first = tuning.nextRequest()!
            try check(presentation(tuning).update == .awaiting(low, latest: nil), "Sent request not shown")
            try tuning.choose(high)
            let value = presentation(tuning, status: "正在应用：\(low.summary)")
            try check(value.update == .awaiting(low, latest: high) && value.applied == initial && value.message == nil,
                      "Latest choice replaced the in-flight request or applied state")
            try check(tuning.pending?.id == first.id && tuning.desired == high && tuning.applied == initial,
                      "Presentation mutated the quality transaction")
            try tuning.choose(initial.settings)
            try check(presentation(tuning).update == .awaiting(low, latest: initial.settings),
                      "Choosing the current value hid the queued correction")
        }
        run("Matched replies update actual quality without claiming the newer choice has applied") {
            var tuning = try VideoTuningSession(applied: initial, preferred: low)
            let first = tuning.nextRequest()!
            try tuning.choose(high)
            let actual = VideoStreamState(settings: low, width: 1280, height: 720)
            _ = try tuning.receive(StreamSettingsResult(id: first.id, state: actual))
            let value = presentation(tuning, applied: actual, status: "已生效：\(low.summary)")
            try check(value.applied == actual && value.update == .preparing(high) && value.message == nil,
                      "An earlier reply appeared to confirm the newer choice")
        }
        run("Codec-only updates also wait for a real acknowledgement") {
            var tuning = try VideoTuningSession(applied: initial)
            tuning.chooseCodec(.hevc)
            try check(presentation(tuning).update == .preparing(initial.settings), "Codec preparation appeared idle")
            let request = tuning.nextRequest()!
            try check(presentation(tuning).update == .awaiting(initial.settings, latest: nil), "Codec request appeared applied")
            _ = try tuning.receive(StreamSettingsResult(id: request.id, state: initial, codec: .hevc))
            try check(presentation(tuning).update == .idle, "Confirmed codec stayed pending")
        }
        run("Rejected requests keep the actual state and the full failure message") {
            var tuning = try VideoTuningSession(applied: initial, preferred: high)
            let request = tuning.nextRequest()!
            _ = try tuning.receive(StreamSettingsResult(id: request.id, state: initial, error: "合成编码失败"))
            let value = presentation(tuning, status: "调整失败：合成编码失败")
            try check(value.update == .idle && value.applied == initial && value.message == "调整失败：合成编码失败",
                      "A rejection was hidden or presented as applied")
        }
        run("Presentation retains a supplied save failure alongside preparing state") {
            var tuning = try VideoTuningSession(applied: initial)
            let status = "画质已生效，但保存记录失败：合成写入失败"
            try check(presentation(tuning, status: status).message == status, "Applied quality hid a save failure")
            try tuning.choose(high)
            try check(presentation(tuning, status: status).message == status, "Preparing another setting hid a save failure")
        }
        run("Automatic reductions can be settled below the selected ceiling without changing the preference") {
            var policy = ViewerQualityPolicy(preferred: high)
            _ = policy.settingsForConnection(hostDefault: initial.settings, supportsExtended: true, supportsHighRefresh: true)
            let actual = VideoStreamState(settings: low, width: 1280, height: 720)
            let tuning = try VideoTuningSession(applied: actual)
            try check(!policy.confirm(low, maySave: false) && policy.preferred == high, "Automatic reduction replaced saved choice")
            let value = presentation(tuning, applied: actual, status: "已生效：\(low.summary)")
            try check(value.update == .idle && value.applied == actual && value.message == nil,
                      "A lower settled automatic setting was mistaken for a pending manual choice")
            try check(policy.settingsForConnection(hostDefault: low, supportsExtended: true, supportsHighRefresh: true) == high,
                      "Reconnect did not restore the selected ceiling")
        }
        run("Protocol success strings never claim a durable save or measured throughput") {
            for status in ["", "当前生效：\(high.summary)", "正在应用：\(high.summary)", "已生效：\(high.summary)"] {
                let value = presentation(try VideoTuningSession(applied: initial), status: status)
                try check(value.applied == initial && value.update == .idle && value.message == nil,
                          "Status text changed actual quality or implied a separate success state")
            }
            let status = "超过 60 fps 的档位需两端更新后使用"
            try check(presentation(nil, status: status).message == status, "Compatibility error was discarded")
        }

        runLiveSettingsChecks()
        print("\(successes) passed, \(failures) failed")
        if failures != 0 { exit(1) }
    }
}
