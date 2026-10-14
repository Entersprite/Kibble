import Foundation

/// A callback, cancellation and timeout compete without a task group waiting
/// forever for an SDK callback. Once resolved, no continuation or timer remains.
final class NativeMediaDiagnosticWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var result: NativeAudioStatistics?
    private var continuation: CheckedContinuation<NativeAudioStatistics?, Never>?
    private var timeout: Task<Void, Never>?

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    func install(_ continuation: CheckedContinuation<NativeAudioStatistics?, Never>) {
        lock.lock()
        if finished {
            let result = result
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func armTimeout(_ duration: Duration) {
        let task = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.finish(nil)
        }
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            timeout = task
            lock.unlock()
        }
    }

    func finish(_ value: NativeAudioStatistics?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        result = value
        let continuation = continuation
        self.continuation = nil
        let timeout = timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: value)
    }
}
