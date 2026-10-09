import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Mark as Unread on a reply (threads spec §4.3, §5.2): sent with the reply's
/// own time, and auto-mark-read stays off for that thread until the panel
/// closes or shows another. `.serialized`, because one test waits for real.
@Suite(.timeLimit(.minutes(1)), .serialized)
@MainActor
struct ThreadMarkUnreadTests {
    private let messages = ThreadFixture.messages(replies: 2)

    private var newest: Date {
        ThreadFixture.newest(replies: 2)
    }

    private func openedAndRead() async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness()
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the thread is read") {
            await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)]
        }
        return harness
    }

    private func unreadMarkDone(_ harness: AutoMarkReadHarness, sent count: Int) async {
        await settleAutoMarkRead(until: "the unread mark is sent and finished") {
            let sent = await threadCommands(from: harness.backend).count
            return sent == count && harness.model.threads.work.markTasks[ThreadFixture.key] == nil
        }
    }

    /// The disarm (seen red with its guard deleted), and nothing for a reply
    /// still sending, which has no server time.
    @Test func markingAReplyUnreadSendsItsTimeAndHoldsTheThreadUnread() async throws {
        let harness = try await openedAndRead()
        let model = harness.model
        var sending = messages[1]
        sending.id = Message.ID("local/sending")
        sending.createdAt = Date()
        model.markThreadUnread(from: sending)
        // Waited out before the real mark, whose `previous?.cancel()` would
        // otherwise cancel this one before it ran, with or without its guard.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)])
        model.markThreadUnread(from: messages[1])
        await unreadMarkDone(harness, sent: 2)

        try harness.store.apply([.upsertMessage(ThreadFixture.messages(replies: 3)[3])])
        await settleAutoMarkRead(until: "the new reply reaches the panel") {
            model.threads.messages.count == 4
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: newest), ThreadFixture.unreadMark(at: messages[1].createdAt)
        ])
        await model.stop()
    }

    /// The hold ends with the panel: reopened, the thread is cleared and read again.
    @Test func reopeningAThreadMarkedUnreadClearsTheMarkAndMarksItRead() async throws {
        let harness = try await openedAndRead()
        let model = harness.model
        model.markThreadUnread(from: messages[1])
        // What the backend's answer files; these suites never forward a command.
        try harness.store.apply([.applyThreadChange(
            thread: ThreadFixture.thread, conversation: ThreadFixture.conversation,
            change: .markedUnread(at: messages[1].createdAt)
        )])
        await unreadMarkDone(harness, sent: 2)
        model.closeThread()
        model.openThread(ThreadFixture.thread)
        await settleAutoMarkRead(until: "the reopened thread is cleared and read") {
            await threadCommands(from: harness.backend).count == 4
        }
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: newest), ThreadFixture.unreadMark(at: messages[1].createdAt),
            ThreadFixture.unreadMark(at: nil), ThreadFixture.read(upTo: newest)
        ])
        await model.stop()
    }

    @Test func aWaitingMarkIsCanceledByMarkingUnread() async throws {
        let harness = try await makeThreadHarness(markReadDebounce: markReadSequenceInterval)
        let model = harness.model
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the mark is waiting") {
            model.threads.work.markTasks[ThreadFixture.key] != nil
        }
        model.markThreadUnread(from: messages[1])
        await settleAutoMarkRead(until: "the unread mark is sent") {
            await threadCommands(from: harness.backend).count == 1
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.unreadMark(at: messages[1].createdAt)
        ])
        await model.stop()
    }

    /// The server sees the two in the order the person acted.
    @Test func anUnreadMarkWaitsForAReadAlreadyInFlight() async throws {
        let harness = try await makeThreadHarness()
        let backend = harness.backend
        await backend.holdSubmissions(true)
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the read is in flight") { await backend.heldSubmissionCount == 1 }
        harness.model.markThreadUnread(from: messages[1])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: backend) == [ThreadFixture.read(upTo: newest)])
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the unread mark follows the read") {
            await threadCommands(from: backend).count == 2
        }
        await backend.releaseHeldSubmission()
        #expect(await threadCommands(from: backend) == [
            ThreadFixture.read(upTo: newest), ThreadFixture.unreadMark(at: messages[1].createdAt)
        ])
        await harness.model.stop()
    }

    @Test func withoutThreadsNothingIsMarkedUnread() async throws {
        var capabilities = ThreadFixture.capabilities
        capabilities.supportsThreads = false
        let harness = try await makeThreadHarness(capabilities: capabilities)
        harness.model.markThreadUnread(from: messages[1])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend).isEmpty)
        await harness.model.stop()
    }
}
