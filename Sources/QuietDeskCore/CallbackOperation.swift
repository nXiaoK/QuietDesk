import Foundation

/// Adapts a callback API that does not itself support Swift task cancellation.
/// Cancelling stops the await, not the underlying operation; its late result is discarded.
public enum CallbackOperation {
    public static func run<Value>(_ start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let operation = Pending<Value>()
        defer { withExtendedLifetime(operation) {} }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.install(continuation) else { return }
                start { [weak operation] result in operation?.finish(result) }
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    private final class Pending<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
            let accepted = lock.withLock {
                guard !finished else { return false }
                self.continuation = continuation
                return true
            }
            if !accepted { continuation.resume(throwing: CancellationError()) }
            return accepted
        }

        func finish(_ result: Result<Value, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard !finished else { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}
