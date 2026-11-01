import Foundation
import ScreenCaptureKit
import QuietDeskCore

protocol CaptureStreamControlling: AnyObject {
    func startCapture(completionHandler: (@Sendable (Error?) -> Void)?)
    func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?)
}

extension SCStream: CaptureStreamControlling {}

/// Owns only one stream. System callbacks must not retain the awaiting session when they never arrive.
final class CaptureLifecycle: @unchecked Sendable {
    private let stream: CaptureStreamControlling
    private let queue = DispatchQueue(label: "quietdesk.capture-lifecycle")
    private let startupTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private var started = false
    private var stopping = false
    private var stopped = false
    private var startReplied = false
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var startDeadline: DispatchWorkItem?
    private var stopDeadline: DispatchWorkItem?

    init(stream: CaptureStreamControlling, startupTimeout: TimeInterval = 30, shutdownTimeout: TimeInterval = 4) {
        self.stream = stream
        self.startupTimeout = startupTimeout
        self.shutdownTimeout = shutdownTimeout
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !started, !stopping else { continuation.resume(throwing: CancellationError()); return }
                    started = true
                    startContinuation = continuation
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, self.startContinuation != nil else { return }
                        self.finishStart(.failure(DeskError.invalid("屏幕采集启动超过 30 秒未完成")))
                        self.requestStop()
                    }
                    startDeadline = deadline
                    queue.asyncAfter(deadline: .now() + startupTimeout, execute: deadline)
                    stream.startCapture { [weak self, weak stream] error in
                        guard let self else {
                            if error == nil { stream?.stopCapture(completionHandler: nil) }
                            return
                        }
                        self.queue.async { [self] in
                            guard !self.startReplied else { return }
                            self.startReplied = true
                            if self.stopping {
                                // Stop may have completed before the abandoned start finally took effect.
                                if error == nil { self.stream.stopCapture(completionHandler: nil) }
                            } else {
                                self.finishStart(error.map { .failure($0) } ?? .success(()))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async { [self] in requestStop() }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if stopped { continuation.resume(); return }
                stopContinuations.append(continuation)
                requestStop()
            }
        }
    }

    private func requestStop() {
        guard !stopping else { return }
        stopping = true
        finishStart(.failure(CancellationError()))
        guard started else { finishStop(); return }
        let deadline = DispatchWorkItem { [weak self] in self?.finishStop() }
        stopDeadline = deadline
        queue.asyncAfter(deadline: .now() + shutdownTimeout, execute: deadline)
        stream.stopCapture { [weak self] _ in
            self?.queue.async { [weak self] in self?.finishStop() }
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        startDeadline?.cancel(); startDeadline = nil
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    private func finishStop() {
        guard !stopped else { return }
        stopped = true
        stopDeadline?.cancel(); stopDeadline = nil
        let continuations = stopContinuations
        stopContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    deinit { startDeadline?.cancel(); stopDeadline?.cancel() }
}
