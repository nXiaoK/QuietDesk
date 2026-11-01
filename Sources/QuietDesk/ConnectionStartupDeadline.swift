import Foundation

/// A separate deadline can end connection setup even while a system API is not returning.
@MainActor
final class ConnectionStartupDeadline {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var isArmed: Bool { task != nil }

    func arm(after delay: Duration = .seconds(30), onTimeout: @escaping @MainActor () -> Void) {
        cancel()
        let token = generation
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.task = nil
            onTimeout()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
