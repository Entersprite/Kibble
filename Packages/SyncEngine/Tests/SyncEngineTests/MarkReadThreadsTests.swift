import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// The sidebar's Mark as Read reads the conversation's unread threads too,
/// with the calls the panel makes (`markUnreadThreadsRead(in:)`): a
/// conversation's read does not read its threads (`findings.md` §64.5).
/// Every verdict is the whole list of thread commands, read once the mark
/// has finished.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MarkReadThreadsTests {
    private let conversation = ThreadFixture.conversation
    private let thread = ThreadFixture.messages(replies: 2)
    private let other = ThreadFixture.messages(in: ThreadFixture.otherThread, replies: 1, offset: 600)

    private var newest: Date {
        ThreadFixture.newest(replies: 2)
    }

    private func change(
        _ change: ThreadChange,
        in thread: MessageThread.ID = ThreadFixture.thread
    ) -> StoreWrite {
        .applyThreadChange(thread: thread, conversation: conversation, change: change)
    }

    /// Followed and never read, as a history page reports it: unread.
    private var neverRead: [StoreWrite] {
        [change(.followed(true)), change(.read(upTo: Date(timeIntervalSince1970: 0)))]
    }

    /// `other` followed and read up to its newest reply.
    private var otherRead: [StoreWrite] {
        [
            change(.followed(true), in: ThreadFixture.otherThread),
            change(.read(upTo: other[1].createdAt), in: ThreadFixture.otherThread)
        ]
    }

    /// The threads stored, and the newest page the sidebar's mark fetches
    /// first bringing the same messages, so the fetch leaves them as they are.
    private func harness(
        capabilities: Capabilities = .fixture, with writes: [StoreWrite]
    ) async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness(capabilities: capabilities)
        let messages = thread + other
        try harness.store.apply(messages.map { .upsertMessage($0) } + writes)
        await harness.backend.answerHistory(in: conversation, with: messages)
        return harness
    }

    private func markAndFinish(_ harness: AutoMarkReadHarness, from origin: MarkReadOrigin) async {
        harness.model.markRead(conversation, from: origin)
        await settleAutoMarkRead(until: "the mark has finished") {
            harness.model.markTasks[conversation] == nil
                && harness.model.threads.work.markTasks.isEmpty
        }
    }

    @Test func aSidebarMarkReadsEveryUnreadThreadUpToItsNewestReply() async throws {
        let harness = try await harness(with: neverRead + otherRead)
        #expect(try harness.store.thread(ThreadFixture.thread, in: conversation)?.hasUnread == true)
        await markAndFinish(harness, from: .conversationList)
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)])
        #expect(harness.model.threads.work.published[ThreadFixture.key] == newest)
        await harness.model.stop()
    }

    /// A banner names one message: it reads the conversation alone.
    @Test func aBannersMarkLeavesTheThreadsAlone() async throws {
        let harness = try await harness(with: neverRead)
        await markAndFinish(harness, from: .notification)
        #expect(await harness.backend.markReadCount == 1)
        #expect(await threadCommands(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    /// A manually unread thread is cleared first only where the provider
    /// advertises that a read does not clear it.
    @Test(arguments: [false, true])
    func aThreadMarkedUnreadHonorsTheAdvertisedPrerequisite(requiresClear: Bool) async throws {
        var capabilities = Capabilities.fixture
        capabilities.needsThreadUnreadClearBeforeRead = requiresClear
        let harness = try await harness(capabilities: capabilities, with: [
            change(.read(upTo: newest)), change(.markedUnread(at: thread[1].createdAt))
        ])
        await markAndFinish(harness, from: .conversationList)
        let expected = requiresClear
            ? [ThreadFixture.unreadMark(at: nil), ThreadFixture.read(upTo: newest)]
            : [ThreadFixture.read(upTo: newest)]
        #expect(await threadCommands(from: harness.backend) == expected)
        await harness.model.stop()
    }

    @Test func aRefusedClearSendsNoRead() async throws {
        var capabilities = Capabilities.fixture
        capabilities.needsThreadUnreadClearBeforeRead = true
        let harness = try await harness(capabilities: capabilities, with: [
            change(.markedUnread(at: thread[1].createdAt))
        ])
        await harness.backend.failSubmissions(true)
        await markAndFinish(harness, from: .conversationList)
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.unreadMark(at: nil)])
        #expect(harness.model.threads.work.published[ThreadFixture.key] == nil)
        await harness.model.stop()
    }

    /// The receipts gate refuses the thread reads at its one chokepoint, as
    /// it refuses the conversation's.
    @Test func receiptsOffSendNoThreadRead() async throws {
        let harness = try await harness(with: neverRead)
        var settings = NotificationSettings()
        settings.setRule(
            NotificationRule(readReceipts: false),
            for: .conversation(conversation),
            at: newest,
            by: "t"
        )
        harness.model.engine.readReceipts.set(.resolve(settings))
        await markAndFinish(harness, from: .conversationList)
        #expect(await threadCommands(from: harness.backend).isEmpty)
        #expect(harness.model.threads.work.published[ThreadFixture.key] == nil)
        await harness.model.stop()
    }

    /// The panel already published this thread's newest reply: the
    /// watermark keeps the sidebar's mark from sending it again.
    @Test func aThreadThePanelAlreadyMarkedIsNotMarkedAgain() async throws {
        let harness = try await harness(with: neverRead)
        harness.model.select(conversation)
        harness.model.openThread(ThreadFixture.thread)
        await settleAutoMarkRead(until: "the panel has marked the thread") {
            harness.model.threads.work.published[ThreadFixture.key] == newest
        }
        await markAndFinish(harness, from: .conversationList)
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)])
        await harness.model.stop()
    }

    @Test func withoutThreadsNothingIsSentForThem() async throws {
        var capabilities = Capabilities.fixture
        capabilities.supportsThreads = false
        let harness = try await harness(capabilities: capabilities, with: neverRead)
        await markAndFinish(harness, from: .conversationList)
        #expect(await threadCommands(from: harness.backend).isEmpty)
        await harness.model.stop()
    }
}
