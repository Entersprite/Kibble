import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// `SyncEngine.submit(_:undoing:)`, and the same cancellation trap
/// `requestMoreMessages` and `perform` already close - see their own comments
/// in `SyncEngine.swift`. Cancelling the `Task` a mark-read runs under does
/// not oblige `RecordingBackend.send(_:)` to throw `CancellationError`; a
/// `submit` that recorded anyway would write `.setLastError` into a store a
/// session no longer owns, exactly the shape `ChatSessionModel.markTasks`'
/// own doc comment says tracking and cancelling closes.
@Suite(.timeLimit(.minutes(1)))
struct SubmitCancellationTests {
    @MainActor
    @Test func aSubmitCancelledBeforeItFailsDoesNotRecord() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let conversation = Conversation.ID("space:1")

        await backend.holdSubmissions(true)
        let task = Task {
            await engine.submit(.markRead(conversationID: conversation, upTo: Date()))
        }

        // Gives the task a moment to actually reach `send(_:)` and block
        // inside it, so the cancellation below finds a genuinely in-flight
        // call rather than one that has not started.
        for _ in 0 ..< 50 {
            await Task.yield()
        }

        // The equivalent of `ChatSessionModel.stop()` cancelling `markTasks`:
        // this is our own task asking to stop, before the backend has
        // answered at all.
        task.cancel()

        // The backend "finally answers" only now - after our own
        // cancellation - and answers with a failure, the shape a cancelled
        // `/api/` call actually takes (`URLError(.cancelled)`, surfaced here
        // as `RecordingBackend.failSubmissions`).
        await backend.failSubmissions(true)
        await backend.releaseHeldSubmission()
        _ = await task.value

        for _ in 0 ..< 50 {
            await Task.yield()
        }

        #expect(try store.lastError() == nil)
    }

    /// The other half: a submit that is *not* cancelled must still record a
    /// real failure, so the fix above cannot have gone too far and started
    /// swallowing every error.
    @MainActor
    @Test func anUncancelledSubmitStillRecords() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let conversation = Conversation.ID("space:1")

        await backend.failSubmissions(true)
        let accepted = await engine.submit(.markRead(conversationID: conversation, upTo: Date()))
        #expect(!accepted)

        var lastError: ChatError?
        for _ in 0 ..< 200 {
            lastError = try store.lastError()
            if lastError != nil {
                break
            }
            await Task.yield()
        }
        #expect(lastError != nil)
    }
}
