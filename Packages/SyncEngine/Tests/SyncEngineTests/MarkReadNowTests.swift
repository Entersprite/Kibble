import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `ChatSessionModel.markRead(_:from:)` - the explicit mark, from a banner or
/// the sidebar's Mark as Read - which had no direct test. The minimal world's
/// `dm:1` has two messages; the newer is at 2026-08-31 09:03Z.
@MainActor
struct MarkReadNowTests {
    private let dm = Conversation.ID("dm:1")
    private let newest = Date(timeIntervalSince1970: 1_788_166_980)

    // A fourth call site would make a named type worse than the tuple it
    // would replace - same reasoning as `NotificationRulesWiringTests`.
    // swiftlint:disable:next large_tuple
    private func harness() async throws -> (ChatSessionModel, ChatStore, RecordingBackend) {
        let backend = RecordingBackend()
        try await backend.connect()
        await backend.acceptWithoutForwarding(true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        return (
            ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero),
            store,
            backend
        )
    }

    /// `@MainActor`, per `CLAUDE.md`: a nonisolated poll never lets the
    /// model's main-actor mark task run.
    private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Review Focus 6. Unread since before launch and never opened: nothing
    /// is stored, so the newest page is loaded first - or nothing would be
    /// published, silently. Both origins: a banner fetches only here.
    @Test(arguments: [MarkReadOrigin.notification, .conversationList])
    func aConversationWithNothingStoredLoadsItsNewestPageThenMarks(from origin: MarkReadOrigin) async throws {
        let (model, _, backend) = try await harness()
        model.markRead(dm, from: origin)
        #expect(await eventually { await backend.markReadCount == 1 })
        #expect(await backend.commands.last == .markRead(conversationID: dm, upTo: newest))
        #expect(await backend.loadMessagesCount == 1)
    }

    /// A banner's message arrived live and is stored: nothing is fetched.
    /// The banner's origin only - the sidebar's fetches anyway, below.
    @Test func aConversationWithMessagesStoredMarksWithoutFetching() async throws {
        let (model, store, backend) = try await harness()
        let stored = Date(timeIntervalSince1970: 1_788_170_000)
        try store.apply([.upsertMessage(Message(
            id: Message.ID("m:live"), conversationID: dm, threadID: MessageThread.ID("t"),
            sender: Member.ID("fixture-other"), text: "hi", createdAt: stored
        ))])
        model.markRead(dm, from: .notification)
        #expect(await eventually { await backend.markReadCount == 1 })
        #expect(await backend.commands.last == .markRead(conversationID: dm, upTo: stored))
        #expect(await backend.loadMessagesCount == 0)
    }

    /// The whole-branch review's Important. Launch reloads conversations
    /// only, so a conversation not opened since GChat was quit holds only
    /// what it held then. A sidebar mark naming that stored newest is
    /// accepted, clears the dot, and the next relaunch's `paginated_world`
    /// says unread again - the reported symptom. The fixture's newest page
    /// holds a newer message than the store does, and the mark must name it.
    @Test func aSidebarMarkNamesTheNewestPagesMessageOverAnOlderStoredOne() async throws {
        let (model, store, backend) = try await harness()
        try store.apply([.upsertMessage(storedBeforeQuit)])
        model.markRead(dm, from: .conversationList)
        #expect(await eventually { await backend.markReadCount == 1 })
        #expect(await backend.commands.last == .markRead(conversationID: dm, upTo: newest))
        #expect(await backend.loadMessagesCount == 1)
    }

    /// The fetch is an improvement, never a precondition: when it fails, the
    /// stored newest is still marked, as before the fetch existed.
    @Test func aSidebarMarkWhoseFetchFailsMarksTheStoredNewest() async throws {
        let (model, store, backend) = try await harness()
        await backend.failHistory(true)
        try store.apply([.upsertMessage(storedBeforeQuit)])
        model.markRead(dm, from: .conversationList)
        #expect(await eventually { await backend.markReadCount == 1 })
        #expect(await backend.commands.last
            == .markRead(conversationID: dm, upTo: storedBeforeQuit.createdAt))
        #expect(await backend.loadMessagesCount == 1)
    }

    /// Nothing stored and the fetch fails: nothing to name, so nothing is
    /// published - and the in-flight guard is released, so a later mark can.
    @Test func aSidebarMarkWithNothingStoredWhoseFetchFailsPublishesNothing() async throws {
        let (model, _, backend) = try await harness()
        await backend.failHistory(true)
        model.markRead(dm, from: .conversationList)
        #expect(await eventually {
            await backend.loadMessagesCount == 1 && model.markTasks[dm] == nil
        })
        #expect(await backend.markReadCount == 0)
    }

    /// Stored before GChat last quit: older than the fixture's newest.
    private var storedBeforeQuit: Message {
        Message(
            id: Message.ID("m:before-quit"), conversationID: dm, threadID: MessageThread.ID("t"),
            sender: Member.ID("fixture-other"), text: "hi",
            createdAt: Date(timeIntervalSince1970: 1_788_100_000)
        )
    }

    /// The layer that was wrong: the position comes from a message read back
    /// out of the store, and a millisecond store handed back `.128` for a
    /// message at `.128263`. The backend's `+1 µs` then published `.128001`,
    /// before the message itself, and Google kept the conversation unread.
    @Test func aMarkNamesTheStoredMessagesExactMicrosecond() async throws {
        let (model, store, backend) = try await harness()
        try store.apply([.upsertMessage(Message(
            id: Message.ID("m:live"), conversationID: dm, threadID: MessageThread.ID("t"),
            sender: Member.ID("fixture-other"), text: "hi",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000.128263)
        ))])
        model.markRead(dm, from: .notification)
        #expect(await eventually { await backend.markReadCount == 1 })
        guard case let .markRead(_, upTo)? = await backend.commands.last else {
            Issue.record("no mark was sent")
            return
        }
        #expect(microseconds(upTo) == 1_790_000_000_128_263)
    }

    /// The final review's C1, across the seam. A mark's position is the
    /// newest seen message's *own* time, and a `.read` then covered only
    /// `createdAt < upTo` (`findings.md` §36; equality too since §42.2). So a
    /// refused mark announcing that position unchanged withdrew every banner
    /// but the newest - usually the only one - with every test green, because
    /// the gate's own test holds no message to compare against.
    @Test func aRefusedMarkAnnouncesAPositionPastTheNewestStoredMessage() async throws {
        let (model, store, backend) = try await harness()
        let stored = Date(timeIntervalSince1970: 1_788_170_000)
        try store.apply([.upsertMessage(Message(
            id: Message.ID("m:live"), conversationID: dm, threadID: MessageThread.ID("t"),
            sender: Member.ID("fixture-other"), text: "hi", createdAt: stored
        ))])
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .conversation(dm), at: stored, by: "t")
        model.engine.readReceipts.set(.resolve(settings))

        model.markRead(dm, from: .notification)

        guard case let .read(conversation, upTo)? = await firstAnnouncement(of: model.engine) else {
            Issue.record("the refused mark announced no local read")
            return
        }
        #expect(conversation == dm)
        #expect(upTo > stored)
        #expect(await backend.markReadCount == 0)
    }
}
