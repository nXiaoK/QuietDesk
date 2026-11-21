import Foundation
import QuietDeskCore

@MainActor
private final class FakeTextKeys: TextKeyTyping {
    enum Event: Equatable {
        case char(Character)
        case tab
        case ret
    }

    var preparedCount = 0
    var events: [Event] = []
    var rendered = ""
    var afterEvent: ((Int) -> Void)?

    func prepareLayout() {
        preparedCount += 1
    }

    func typeCharacter(_ character: Character) -> Bool {
        events.append(.char(character))
        rendered.append(character)
        afterEvent?(events.count)
        return true
    }

    func pressReturn() -> Bool {
        events.append(.ret)
        rendered.append("\n")
        afterEvent?(events.count)
        return true
    }

    func pressTab() -> Bool {
        events.append(.tab)
        rendered.append("\t")
        afterEvent?(events.count)
        return true
    }
}

@main
enum TextTypingChecks {
    @MainActor static func main() async {
        var failures = 0
        var passedCount = 0
        func report(_ passed: Bool, _ name: String) {
            if passed {
                passedCount += 1
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name)")
            }
        }
        let noPause: (Duration) async -> Void = { _ in await Task.yield() }

        do {
            let keys = FakeTextKeys()
            let typer = HostTextTyper(
                isLocked: { false },
                isTrusted: { true },
                canInject: { true },
                keys: keys,
                pause: noPause
            )
            let request = try TypeTextRequest(text: "sudo\tpw中文\r\n2", submitReturn: true)
            let result = await typer.type(request)
            report(
                result.error == nil
                    && !result.cancelled
                    && result.typedCount == request.text.count
                    && keys.preparedCount == 1
                    && keys.rendered == "sudo\tpw中文\n2\n"
                    && keys.events.filter({ $0 == .tab }).count == 1
                    && keys.events.filter({ $0 == .ret }).count == 2
                    && !typer.typing,
                "HostTextTyper types ASCII, CJK, Tab, LF, and trailing Return in exact sequence without touching pasteboard"
            )
        } catch {
            failures += 1
            print("FAIL basic typing setup: \(error)")
        }

        do {
            var locked = false
            let keys = FakeTextKeys()
            keys.afterEvent = { count in
                if count == 3 { locked = true }
            }
            let typer = HostTextTyper(
                isLocked: { locked },
                isTrusted: { true },
                canInject: { true },
                keys: keys,
                pause: noPause
            )
            let result = await typer.type(try TypeTextRequest(text: "abcdef", submitReturn: true))
            report(
                result.typedCount == 3
                    && result.error != nil
                    && keys.rendered == "abc"
                    && !keys.events.contains(.ret),
                "HostTextTyper aborts immediately if the host Mac locks mid-typing and suppresses trailing Return"
            )
        } catch {
            failures += 1
            print("FAIL lock abort setup: \(error)")
        }

        do {
            let keys = FakeTextKeys()
            let lockedTyper = HostTextTyper(isLocked: { true }, isTrusted: { true }, canInject: { true }, keys: keys, pause: noPause)
            let untrustedTyper = HostTextTyper(isLocked: { false }, isTrusted: { false }, canInject: { true }, keys: keys, pause: noPause)
            let viewOnlyTyper = HostTextTyper(isLocked: { false }, isTrusted: { true }, canInject: { false }, keys: keys, pause: noPause)
            let req = try TypeTextRequest(text: "secret")
            let r1 = await lockedTyper.type(req)
            let r2 = await untrustedTyper.type(req)
            let r3 = await viewOnlyTyper.type(req)
            report(
                r1.typedCount == 0 && r1.error != nil
                    && r2.typedCount == 0 && r2.error != nil
                    && r3.typedCount == 0 && r3.error != nil
                    && keys.events.isEmpty,
                "HostTextTyper refuses locked, untrusted-AX, and view-only sessions before posting any key event"
            )
        } catch {
            failures += 1
            print("FAIL refusal setup: \(error)")
        }

        do {
            var release: CheckedContinuation<Void, Never>?
            let keys = FakeTextKeys()
            let typer = HostTextTyper(
                isLocked: { false },
                isTrusted: { true },
                canInject: { true },
                keys: keys,
                pause: { _ in await withCheckedContinuation { release = $0 } }
            )
            let running = Task { @MainActor in
                await typer.type(try! TypeTextRequest(text: "12345", submitReturn: true))
            }
            while release == nil { await Task.yield() }
            let overlap = await typer.type(try TypeTextRequest(text: "zzz"))
            running.cancel()
            release?.resume()
            release = nil
            var steps = 0
            while typer.typing, steps < 1000 {
                if let pending = release { release = nil; pending.resume() }
                await Task.yield()
                steps += 1
            }
            let cancelledResult = await running.value
            report(
                overlap.typedCount == 0 && overlap.error != nil && !keys.rendered.contains("z")
                    && cancelledResult.cancelled && cancelledResult.typedCount == 1
                    && keys.rendered == "1" && !keys.events.contains(.ret),
                "HostTextTyper rejects overlapping requests and stops mid-stream on cancellation without pressing Return"
            )
        } catch {
            failures += 1
            print("FAIL cancellation setup: \(error)")
        }

        print("\(passedCount) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
