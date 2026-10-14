import ChatKit
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct ForegroundReadRetryTests {
    @MainActor
    @Test func completedQuietFocusRefreshRetriesAReadThatFailedWhileItWasWaiting() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .zero)
        await harness.backend.failSubmissions(true)
        await harness.backend.holdSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the first read is held on the wire") {
            await harness.backend.heldSubmissionCount == 1
        }
        try #require(harness.model.markTasks[autoMarkReadConversation] != nil)
        await harness.backend.holdHistory(true)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead(until: "the foreground history reconciliation is held") {
            await harness.backend.abortableHistory.count == 1
        }
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the failed read has settled") {
            harness.model.markTasks[autoMarkReadConversation] == nil
        }
        #expect(harness.model.published[autoMarkReadConversation] == nil)
        #expect(await harness.backend.markReadCount == 1)
        await harness.backend.failSubmissions(false)
        await harness.backend.holdSubmissions(false)
        await harness.backend.holdHistory(false)
        await harness.backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the quiet foreground refresh explicitly re-evaluates the read") {
            await harness.backend.markReadCount == 2
        }
        #expect(await harness.backend.markReadCount == 2)
        await harness.model.stop()
    }
}
