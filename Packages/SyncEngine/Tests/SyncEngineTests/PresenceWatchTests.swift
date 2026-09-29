import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Naming a conversation's stored senders to the backend when it is opened,
/// as `ChatCommand.watchPresence`. A backend only learns of senders on pages
/// it fetched this session, while the transcript shows every stored message.
@Suite(.timeLimit(.minutes(1)))
struct PresenceWatchTests {
    private let space = Conversation.ID("space:1")
    private let me = Member.ID("people/me")
    private let alice = Member.ID("people/alice")

    private func message(_ id: String, from sender: Member.ID, in conversation: Conversation.ID) -> Message {
        Message(
            id: Message.ID(id),
            conversationID: conversation,
            threadID: MessageThread.ID("t"),
            sender: sender,
            text: "hi",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// People only, with a member row (so `.setPresence` cannot drop the
    /// answer), who posted here, and never the local user.
    @Test func theCandidatesArePeopleWithARowWhoPostedHere() throws {
        let store = try ChatStore.inMemory()
        let bot = Member.ID("people/bot")
        let stranger = Member.ID("people/stranger")
        let elsewhere = Member.ID("people/elsewhere")
        try store.apply([
            .setLocalMember(me),
            .upsertMembers([
                Member(id: me, kind: .human),
                Member(id: alice, kind: .human),
                Member(id: bot, kind: .app),
                Member(id: elsewhere, kind: .human)
            ]),
            .upsertMessage(message("1", from: alice, in: space)),
            .upsertMessage(message("2", from: alice, in: space)),
            .upsertMessage(message("3", from: bot, in: space)),
            .upsertMessage(message("4", from: stranger, in: space)),
            .upsertMessage(message("5", from: me, in: space)),
            .upsertMessage(message("6", from: elsewhere, in: Conversation.ID("space:2")))
        ])

        #expect(try store.presenceCandidates(in: space) == [alice])
    }

    // MARK: - When the model sends it

    private struct Harness {
        let model: ChatSessionModel
        let store: ChatStore
        let backend: RecordingBackend
    }

    @MainActor
    private func harness() async throws -> Harness {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil, markReadDebounce: .zero)
        try await model.start()
        await settleAutoMarkRead()
        return Harness(model: model, store: store, backend: backend)
    }

    private var dm: Conversation.ID {
        FixtureWorld.minimal.messages[0].conversationID
    }

    private var other: Member.ID {
        FixtureWorld.minimal.messages[0].sender
    }

    /// Reopening a conversation names its stored senders. The first open has
    /// nothing stored yet - the backend learns that page's senders itself.
    /// Deleting the call in `select(_:)` turns this red.
    @MainActor
    @Test func openingAConversationNamesItsStoredSenders() async throws {
        let harness = try await harness()
        harness.model.select(dm)
        await settleAutoMarkRead()
        let space = try #require(harness.model.conversations.first { $0.id != dm }?.id)
        harness.model.select(space)
        await settleAutoMarkRead()

        harness.model.select(dm)
        await settleAutoMarkRead()

        #expect(await harness.backend.watches.last == [other])
        await harness.model.stop()
    }

    /// A watch sent while disconnected is dropped by the backend, so the
    /// connection coming back sends it again - which is what covers a
    /// conversation selected during launch. Deleting the call in the
    /// reconnect path turns this red.
    @MainActor
    @Test func theConnectionComingBackSendsItAgain() async throws {
        let harness = try await harness()
        harness.model.select(dm)
        await settleAutoMarkRead()
        let before = await harness.backend.watches.count

        try harness.store.apply([.setConnectionState(.reconnecting(attempt: 1, issue: nil, detail: nil))])
        await settleAutoMarkRead()
        try harness.store.apply([.setConnectionState(.connected)])
        await settleAutoMarkRead()

        let watches = await harness.backend.watches
        #expect(watches.count == before + 1)
        #expect(watches.last == [other])
        await harness.model.stop()
    }
}
