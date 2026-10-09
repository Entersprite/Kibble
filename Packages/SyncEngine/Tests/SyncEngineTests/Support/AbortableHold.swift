import Foundation

/// A hold that a canceled caller tears down: a held call whose task is
/// canceled resumes at once by throwing `CancellationError`.
///
/// The wire's shape. `URLSessionTransport` reads through
/// `URLSession.bytes(for:)`, which cancels its request when the Swift task is
/// canceled, so a mark on the wire that is canceled never reaches the server,
/// or reaches it while the client has stopped listening.
/// `RecordingBackend.holdSubmissions` ignores cancellation, and a test built
/// on it cannot tell "waited for the answer" from "tore the request down".
actor AbortableHold {
    private var held: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    /// How many held calls were torn down by their task's cancellation.
    private(set) var aborted = 0

    var count: Int {
        held.count
    }

    /// Waits for `release()`, or throws once the calling task is canceled.
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                held.append((id: id, continuation: continuation))
            }
        } onCancel: {
            // Runs off this actor, and after the append whenever the task was
            // canceled before the wait began, because the append runs on the
            // actor before the call suspends.
            Task { await self.abort(id) }
        }
    }

    /// Answers the oldest held call, if any.
    func release() {
        guard !held.isEmpty else { return }
        held.removeFirst().continuation.resume()
    }

    private func abort(_ id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        aborted += 1
        held.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
