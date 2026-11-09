import Foundation

private struct RecoveryCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct ConnectionRecoveryChecks {
    static func main() {
        var passed = 0, failed = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw RecoveryCheckFailure(message) }
        }
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func presentation(reconnecting: Bool = true, paused: Bool = false, wait: ReconnectWait? = nil,
                          status: String = "正在建立加密连接…", now: TimeInterval = 100) -> ConnectionRecoveryPresentation {
            ConnectionRecoveryPresentation(reconnecting: reconnecting, paused: paused, wait: wait, status: status, now: now)
        }
        print("Recovery checks use supplied monotonic times and pure presentation only; no model, connection, permissions or global input.")
        run("The displayed deadline is made from the same supplied delay as the retry task") {
            let wait = ReconnectWait(attempt: 4, delay: 8, reason: "合成网络中断", now: 100)
            try require(wait.deadline == 108 && wait.delay == 8 && wait.attempt == 4, "Wait differs from scheduled retry")
            try require(wait.remainingSeconds(at: 100) == 8, "Initial wait missing")
        }
        run("Remaining wait counts down and rounds up rather than announcing the retry early") {
            let wait = ReconnectWait(attempt: 3, delay: 4, reason: "测试", now: 100)
            for (now, expected) in [(100.0, 4), (100.01, 4), (101, 3), (102.75, 2), (103.99, 1), (104, 0), (110, 0)] {
                try require(wait.remainingSeconds(at: now) == expected, "Incorrect countdown at \(now)")
            }
        }
        run("A late UI tick reports imminent retry without claiming a connection started") {
            let wait = ReconnectWait(attempt: 2, delay: 2, reason: "测试", now: 100)
            let value = presentation(wait: wait, now: 110)
            try require(value.state == .waiting && !value.showsActivity, "A late tick fabricated a started task")
            try require(value.detail == "即将开始第 2 次重连", "Expired wait became a negative or perpetual zero countdown")
        }
        run("A time before scheduling never increases the displayed delay") {
            let wait = ReconnectWait(attempt: 6, delay: 30, reason: "测试", now: 100)
            try require(wait.remainingSeconds(at: 90) == 30, "Displayed wait exceeded the actual scheduled delay")
        }
        run("Waiting keeps its attempt and exact failure reason separate from countdown text") {
            let wait = ReconnectWait(attempt: 7, delay: 30, reason: "合成中继节点未接通\n请检查网络", now: 100)
            let value = presentation(wait: wait, now: 111)
            try require(value.title == "连接中断，等待自动重连" && value.detail == "19 秒后第 7 次重连", "Waiting phases conflated")
            try require(value.reason == wait.reason, "Real reason replaced or parsed")
        }
        run("Status strings outside the ticking panel never retain a fixed seconds claim") {
            let wait = ReconnectWait(attempt: 4, delay: 8, reason: "原始失败原因", now: 100)
            try require(wait.status == "等待第 4 次重连 · 原始失败原因", "Static status contains a stale delay")
        }
        run("Clearing the wait switches to the actual connection attempt and preserves transport status") {
            let value = presentation(status: "正在通过合成节点接通目标设备…")
            try require(value.state == .connecting && value.showsActivity && value.reason == nil, "Attempt kept waiting presentation")
            try require(value.detail == "正在通过合成节点接通目标设备…", "Actual operation status replaced")
        }
        run("Idle pause overrides a previous wait and never displays activity or a countdown") {
            let wait = ReconnectWait(attempt: 2, delay: 2, reason: "旧失败", now: 100)
            let value = presentation(paused: true, wait: wait, status: "空闲暂停期间不在后台重连")
            try require(value.state == .paused && !value.showsActivity && value.reason == nil, "Paused session implies background work")
            try require(value.detail == "空闲暂停期间不在后台重连" && value.actionTitle == "停止重连", "Pause recovery or cancellation changed")
        }
        run("A disconnected session ignores stale wait and pause and offers only return") {
            let wait = ReconnectWait(attempt: 2, delay: 2, reason: "旧失败", now: 100)
            let value = presentation(reconnecting: false, paused: true, wait: wait)
            try require(value.state == .disconnected && !value.showsActivity && value.reason == nil, "Disconnected view still implies retry")
            try require(value.title == "尚未连接" && value.actionTitle == "返回连接", "Disconnected return changed")
        }
        run("Waiting, connecting and paused phases keep the existing stop-reconnect action") {
            let wait = ReconnectWait(attempt: 1, delay: 1, reason: "测试", now: 100)
            for value in [presentation(wait: wait), presentation(), presentation(paused: true)] {
                try require(value.actionTitle == "停止重连" && !value.symbol.isEmpty, "Cancellation unavailable")
            }
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
