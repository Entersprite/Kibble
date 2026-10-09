import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The thread trigger's sequences, `MarkReadDebounceTests`' kind: each
/// places an event inside a real wait (`markReadSequenceInterval`) or a held
/// submission. `.serialized` for that suite's reason.
@Suite(.timeLimit(.minutes(1)), .serialized)
@MainActor
struct ThreadAutoMarkReadSequenceTests {
    private let messages = ThreadFixture.messages(replies: 2)

    @Test func nothingIsScheduledInTheBackgroundAndComingToTheFrontMarks() async throws {
        let harness = try await makeThreadHarness(markReadDebounce: markReadSequenceInterval)
        let model = harness.model
        model.setActive(false)
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the thread reaches the panel") { model.threads.messages.count == 3 }
        #expect(model.threads.work.markTasks[ThreadFixture.key] == nil)
        model.setActive(true)
        #expect(model.threads.work.markTasks[ThreadFixture.key] != nil)
        await settleAutoMarkRead(until: "the thread is marked") {
            await threadCommands(from: harness.backend).count == 1
        }
        await model.stop()
    }

    @Test func losingFocusDuringTheWaitPublishesNothing() async throws {
        let harness = try await makeThreadHarness(markReadDebounce: markReadSequenceInterval)
        let model = harness.model
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the mark is waiting") {
            model.threads.work.markTasks[ThreadFixture.key] != nil
        }
        model.setActive(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await threadCommands(from: harness.backend).isEmpty)
        await model.stop()
    }

    /// The in-flight guard, the re-check after a submit, and the generation:
    /// `AutoMarkReadReArmTests`' sequence, for a thread. A reply landing while
    /// a mark is in flight starts no second one; the completed mark re-arms
    /// for it; and the first mark's own clean-up must not erase the re-armed
    /// one's entry, or a third reply would start a mark beside it.
    @Test func aReplyDuringAMarkIsMarkedAfterItAndNeverConcurrently() async throws {
        let harness = try await makeThreadHarness()
        let backend = harness.backend
        let model = harness.model
        let replies = ThreadFixture.messages(replies: 4)
        await backend.holdSubmissions(true)
        try openStoredThread(Array(replies[0 ... 2]), in: harness)
        await settleAutoMarkRead(until: "the first mark is in flight") {
            await backend.heldSubmissionCount == 1
        }

        try harness.store.apply([.upsertMessage(replies[3])])
        await settleAutoMarkRead(until: "the third reply reaches the panel") {
            model.threads.messages.count == 4
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await backend.heldSubmissionCount == 1)

        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the re-armed mark is in flight") {
            let held = await backend.heldSubmissionCount
            let sent = await threadCommands(from: backend).count
            return held == 1 && sent == 2
        }

        try harness.store.apply([.upsertMessage(replies[4])])
        await settleAutoMarkRead(until: "the fourth reply reaches the panel") {
            model.threads.messages.count == 5
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await backend.heldSubmissionCount == 1)

        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the last mark is in flight") {
            let held = await backend.heldSubmissionCount
            let sent = await threadCommands(from: backend).count
            return held == 1 && sent == 3
        }
        await backend.releaseHeldSubmission()
        #expect(await threadCommands(from: backend) == [
            ThreadFixture.read(upTo: replies[2].createdAt),
            ThreadFixture.read(upTo: replies[3].createdAt),
            ThreadFixture.read(upTo: replies[4].createdAt)
        ])
        await model.stop()
    }

    /// `publishReadPosition`'s rule, for threads: a mark whose wait ends after
    /// the panel moved publishes its own thread's position, never the newly
    /// shown thread's.
    @Test func aSwitchDuringTheWaitPublishesTheFirstThreadsOwnPosition() async throws {
        let harness = try await makeThreadHarness(markReadDebounce: markReadSequenceInterval)
        let model = harness.model
        let other = ThreadFixture.messages(in: ThreadFixture.otherThread, replies: 3, offset: 600)
        try harness.store.apply(other.map { .upsertMessage($0) })
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the first thread's mark is waiting") {
            model.threads.work.markTasks[ThreadFixture.key] != nil
        }
        model.openThread(ThreadFixture.otherThread)
        // The precondition, asserted: the other thread is in the panel and
        // nothing has been sent, so the first mark's wait ends after the switch.
        await settleAutoMarkRead(until: "the other thread reaches the panel") {
            model.threads.messages.first?.threadID == ThreadFixture.otherThread
        }
        #expect(await threadCommands(from: harness.backend).isEmpty)

        await settleAutoMarkRead(until: "both threads are marked") {
            await threadCommands(from: harness.backend).count == 2
        }
        let commands = await threadCommands(from: harness.backend)
        #expect(commands.contains(ThreadFixture.read(upTo: ThreadFixture.newest(replies: 2))))
        #expect(commands.contains(ThreadFixture.read(
            ThreadFixture.otherThread, upTo: ThreadFixture.newest(replies: 3, offset: 600)
        )))
        await model.stop()
    }

    /// A mark answering after the panel moved re-checks only its own thread
    /// (review M6). Seen through the newly shown thread's refused read, which
    /// only that thread's own triggers may try again.
    @Test func aMarkAnsweringAfterASwitchReArmsNothingForTheNewThread() async throws {
        let harness = try await makeThreadHarness()
        let model = harness.model
        let backend = harness.backend
        let other = ThreadFixture.messages(in: ThreadFixture.otherThread, replies: 3, offset: 600)
        try harness.store.apply(other.map { .upsertMessage($0) })
        await backend.holdSubmissions(true)
        try openStoredThread(messages, in: harness)
        // The history page, so no later message write redelivers a panel.
        await settleAutoMarkRead(until: "the conversation's page and the first read are in") {
            let held = await backend.heldSubmissionCount
            return held == 1 && model.messages.contains { $0.id == FixtureWorld.minimal.messages[0].id }
        }
        await backend.holdSubmissions(false)
        await backend.holdSubmissionsAbortably(true)
        model.openThread(ThreadFixture.otherThread)
        await settleAutoMarkRead(until: "the other thread's read is on the wire") {
            await backend.abortableSubmissions.count == 1
        }
        let otherKey = ThreadKey(conversation: ThreadFixture.conversation, thread: ThreadFixture.otherThread)
        await backend.failSubmissions(true)
        await backend.abortableSubmissions.release()
        await settleAutoMarkRead(until: "the other thread's read is refused") {
            model.threads.work.markTasks[otherKey] == nil
        }
        await backend.failSubmissions(false)
        await backend.holdSubmissionsAbortably(false)
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the first thread's read answers") {
            model.threads.work.markTasks[ThreadFixture.key] == nil
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: backend) == [
            ThreadFixture.read(upTo: ThreadFixture.newest(replies: 2)),
            ThreadFixture.read(ThreadFixture.otherThread, upTo: ThreadFixture.newest(replies: 3, offset: 600))
        ])
        await model.stop()
    }

    @Test func stopCancelsAWaitingThreadMark() async throws {
        let harness = try await makeThreadHarness(markReadDebounce: markReadSequenceInterval)
        let model = harness.model
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the mark is waiting") {
            model.threads.work.markTasks[ThreadFixture.key] != nil
        }
        await model.stop()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await threadCommands(from: harness.backend).isEmpty)
    }
}
