import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// The Calls list in the session model: pages through the backend's port,
/// cursors kept verbatim, and nothing written for a list nobody is looking
/// at or a session that ended.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallHistoryModelTests {
    private static let conversation = Conversation.ID("space:1")

    private static func record(_ id: String, _ status: MessageCallStatus = .ended) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation, threadID: MessageThread.ID("t-" + id),
            sender: FixtureWorld.minimal.me, text: "", createdAt: FixtureWorld.minimal.startedAt,
            callStatus: status
        )
    }

    private func running(
        capabilities: Capabilities = .fixture
    ) async throws -> (ChatSessionModel, CallHistoryTestBackend) {
        let backend = CallHistoryTestBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
        try await model.start()
        model.setActive(false)
        await settleAutoMarkRead(until: "conversations loaded") { !model.conversations.isEmpty }
        return (model, backend)
    }

    @Test func showingTheListLeavesTheConversationAndReadsTheFirstPage() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: [Self.record("c:2"), Self.record("c:1")]), after: nil)
        model.select(Self.conversation)
        model.showCallHistory()
        #expect(model.selected == nil)
        #expect(model.callHistory.showingList)
        #expect(model.callHistory.status == .loading)
        await settleAutoMarkRead(until: "first page") { model.callHistory.status == .loaded }
        #expect(model.callHistory.calls.map(\.id.rawValue) == ["c:2", "c:1"])
        #expect(!model.callHistory.hasMore)
        let queries = await backend.queries
        #expect(queries == [CallHistoryQuery(conversationID: nil, cursor: nil, limit: 50)])
        await model.stop()
    }

    @Test func laterPagesFollowTheBackendsCursorVerbatimAndAppend() async throws {
        let (model, backend) = try await running()
        let cursor = "opaque/+cursor=="
        await backend.answer(CallHistoryPage(messages: [Self.record("c:3")], nextCursor: cursor), after: nil)
        await backend.answer(
            CallHistoryPage(messages: [Self.record("c:2"), Self.record("c:1")]),
            after: cursor
        )
        model.showCallHistory()
        await settleAutoMarkRead(until: "first page") { model.callHistory.status == .loaded }
        #expect(model.callHistory.hasMore)
        model.loadMoreCallHistory()
        #expect(model.callHistory.isLoadingMore)
        // A second ask while one is on its way asks for nothing.
        model.loadMoreCallHistory()
        await settleAutoMarkRead(until: "second page") { model.callHistory.calls.count == 3 }
        #expect(model.callHistory.calls.map(\.id.rawValue) == ["c:3", "c:2", "c:1"])
        #expect(!model.callHistory.hasMore)
        #expect(!model.callHistory.isLoadingMore)
        let queries = await backend.queries
        #expect(queries.map(\.cursor) == [nil, cursor])
        // The last page has arrived: there is nothing more to ask for.
        model.loadMoreCallHistory()
        await settleAutoMarkRead()
        let after = await backend.queries
        #expect(after.count == 2)
        await model.stop()
    }

    @Test func anEmptyAccountIsLoadedWithNoRows() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: []), after: nil)
        model.showCallHistory()
        await settleAutoMarkRead(until: "empty page") { model.callHistory.status == .loaded }
        #expect(model.callHistory.calls.isEmpty)
        await model.stop()
    }

    @Test func aFailedFirstPageShowsTheFailureUntilARetryReadsIt() async throws {
        let (model, backend) = try await running()
        await backend.fail(after: nil)
        model.showCallHistory()
        await settleAutoMarkRead(until: "failure") { model.callHistory.status == .failed }
        #expect(model.callHistory.calls.isEmpty)
        await backend.answer(CallHistoryPage(messages: [Self.record("c:1", .missed)]), after: nil)
        model.retryCallHistory()
        #expect(model.callHistory.status == .loading)
        await settleAutoMarkRead(until: "retry") { model.callHistory.status == .loaded }
        #expect(model.callHistory.calls.first?.callStatus == .missed)
        await model.stop()
    }

    @Test func aFailedLaterPageKeepsTheRowsAndCanBeAskedForAgain() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: [Self.record("c:2")], nextCursor: "next"), after: nil)
        await backend.fail(after: "next")
        model.showCallHistory()
        await settleAutoMarkRead(until: "first page") { model.callHistory.status == .loaded }
        model.loadMoreCallHistory()
        await settleAutoMarkRead(until: "later failure") { model.callHistory.loadMoreFailed }
        #expect(model.callHistory.calls.map(\.id.rawValue) == ["c:2"])
        #expect(model.callHistory.status == .loaded)
        #expect(model.callHistory.hasMore)
        await backend.answer(CallHistoryPage(messages: [Self.record("c:1")]), after: "next")
        model.loadMoreCallHistory()
        await settleAutoMarkRead(until: "later retry") { model.callHistory.calls.count == 2 }
        #expect(!model.callHistory.loadMoreFailed)
        await model.stop()
    }

    /// A page that answers after the list was left, for a conversation, writes
    /// nothing: the generation moved on when it was left.
    @Test func aPageThatAnswersAfterTheListWasLeftWritesNothing() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: [Self.record("c:1")]), after: nil)
        await backend.hold()
        model.showCallHistory()
        await settleAutoMarkRead(until: "held") { await backend.heldCount == 1 }
        model.select(Self.conversation)
        #expect(!model.callHistory.showingList)
        await backend.release()
        await settleAutoMarkRead()
        #expect(model.callHistory.calls.isEmpty)
        #expect(model.callHistory.status == .loading)
        await model.stop()
    }

    /// The same, for a page that answers after the list was left and shown
    /// again: only the newer page lands.
    @Test func onlyTheNewestFirstPageLands() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: [Self.record("old")]), after: nil)
        await backend.hold()
        model.showCallHistory()
        await settleAutoMarkRead(until: "held") { await backend.heldCount == 1 }
        model.showMentions()
        #expect(!model.callHistory.showingList)
        await backend.answer(CallHistoryPage(messages: [Self.record("new")]), after: nil)
        model.showCallHistory()
        await settleAutoMarkRead(until: "both held") { await backend.heldCount == 2 }
        await backend.release()
        await settleAutoMarkRead(until: "newest page") { model.callHistory.status == .loaded }
        await settleAutoMarkRead()
        #expect(model.callHistory.calls.map(\.id.rawValue) == ["new"])
        await model.stop()
    }

    @Test func aPageThatAnswersAfterStopWritesNothing() async throws {
        let (model, backend) = try await running()
        await backend.answer(CallHistoryPage(messages: [Self.record("c:1")]), after: nil)
        await backend.hold()
        model.showCallHistory()
        await settleAutoMarkRead(until: "held") { await backend.heldCount == 1 }
        await model.stop()
        await backend.release()
        await settleAutoMarkRead()
        #expect(model.callHistory.calls.isEmpty)
        // Not even its failure: the session it was asked for has ended.
        #expect(model.callHistory.status == .loading)
    }

    @Test func aBackendWithoutCallHistoryOffersNoList() async throws {
        var capabilities = Capabilities.fixture
        capabilities.extendedFlags.remove("callHistory")
        let (model, backend) = try await running(capabilities: capabilities)
        model.showCallHistory()
        #expect(!model.callHistory.showingList)
        await settleAutoMarkRead()
        let queries = await backend.queries
        #expect(queries.isEmpty)
        await #expect(throws: ChatError.self) {
            try await model.engine.callHistory(CallHistoryQuery())
        }
        await model.stop()
    }
}
