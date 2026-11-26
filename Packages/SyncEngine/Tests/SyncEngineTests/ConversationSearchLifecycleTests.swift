import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationSearchLifecycleTests {
    @Test(arguments: [ConversationAction.hide, .delete])
    func aRemovedDMCanBeOpenedAgainFromItsPerson(_ action: ConversationAction) async throws {
        let world = FixtureWorld.minimal
        let dm = try #require(world.conversations.first { $0.kind == .directMessage })
        let person = try #require(dm.members.first { $0 != world.me })
        let backend = RecordingBackend(world: world)
        let model = try await SearchModelTests.model(backend)
        await settleAutoMarkRead(until: "DM loaded") { model.conversations.contains { $0.id == dm.id } }
        model.perform(action, in: dm.id)
        await settleAutoMarkRead(until: "DM removed") { !model.conversations.contains { $0.id == dm.id } }
        model.showSearch()
        model.openSearchPerson(person)
        await settleAutoMarkRead(until: "DM reopened") {
            model.selected == dm.id && model.conversations.contains { $0.id == dm.id }
        }
        #expect(!model.search.isShown)
        #expect(try await backend.loadConversations().contains { $0.id == dm.id })
        if action == .delete {
            #expect(try model.store.messages(in: dm.id).isEmpty)
            #expect(try model.store.conversations().first { $0.id == dm.id }?.historyClearedBefore != nil)
        }
        await model.stop()
    }

    @Test func aNewPersonOpensANewDM() async throws {
        let model = try await SearchModelTests.model(RecordingBackend())
        model.showSearch()
        let person = Member.ID("new-person")
        model.openSearchPerson(person)
        await settleAutoMarkRead(until: "new DM selected") { model.selected != nil }
        #expect(try model.store.conversations()
            .contains { $0.id == model.selected && $0.members.contains(person) })
        #expect(!model.search.isShown)
        await model.stop()
    }

    @Test func removalPrunesAlreadyDisplayedSearchSnapshots() async throws {
        let hit = SearchOpenTests.hit(1)
        let (model, _) = try await SearchOpenTests.searched([MessageSearchPage(hits: [hit])])
        model.search.conversations = model.conversations
        model.openSearchResult(hit.id)
        try model.store.apply([.removeConversation(
            conversation: hit.conversationID,
            historyBefore: hit.createdAt
        )])
        await settleAutoMarkRead(until: "search pruned") {
            model.search.hits.isEmpty && model.search.bar == nil
        }
        #expect(!model.search.conversations.contains { $0.id == hit.conversationID })
        await model.stop()
    }

    @Test func searchLandingAfterDeletionOmitsItsOldHitsAndKeepsTheCursor() async throws {
        let old = SearchOpenTests.hit(1)
        var unrelated = old
        unrelated.id = Message.ID("unrelated")
        unrelated.conversationID = Conversation.ID("another-conversation")
        let backend = RecordingBackend()
        await backend.scriptMessageSearch([MessageSearchPage(
            hits: [old, unrelated],
            next: MessageSearchCursor("1")
        )])
        await backend.holdMessageSearches(true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let task = Task { try await engine.searchMessages(MessageSearchQuery(text: "deploy"), after: nil) }
        await settleAutoMarkRead(until: "search held") { await backend.abortableMessageSearches.count == 1 }
        try store.apply([.removeConversation(conversation: old.conversationID, historyBefore: old.createdAt)])
        await backend.abortableMessageSearches.release()
        let page = try await task.value
        #expect(page.hits == [unrelated])
        #expect(page.next == MessageSearchCursor("1"))
        // A replacement engine has no provider-side deletion cache.
        await backend.holdMessageSearches(false)
        let replacement = SyncEngine(backend: backend, store: store)
        #expect(try await replacement.searchMessages(MessageSearchQuery(text: "deploy"), after: nil)
            .hits == [unrelated])
        var reopened = Conversation(id: old.conversationID, kind: .directMessage)
        reopened.historyClearedBefore = nil
        try store.apply([.restoreConversation(reopened)])
        var fresh = old
        fresh.id = Message.ID("fresh")
        fresh.createdAt = old.createdAt.addingTimeInterval(1)
        #expect(try store.searchableMessages([old, fresh]) == [fresh])
    }
}

extension ConversationSearchLifecycleTests {
    @Test func stoppingCancelsAPendingPersonOpen() async throws {
        let backend = RecordingBackend()
        await backend.holdDirectOpens(true)
        let model = try await SearchModelTests.model(backend)
        let before = try model.store.conversations()
        model.openSearchPerson(Member.ID("new-person"))
        await settleAutoMarkRead(until: "open held") { await backend.abortableDirectOpens.count == 1 }
        await model.stop()
        await settleAutoMarkRead(until: "open canceled") { await backend.abortableDirectOpens.aborted == 1 }
        #expect(try model.store.conversations() == before)
        #expect(model.selected == nil)
    }

    @Test func aDelayedPersonOpenDoesNotStealANewerSelection() async throws {
        let backend = RecordingBackend()
        await backend.holdDirectOpens(true)
        let model = try await SearchModelTests.model(backend)
        let id = FixtureWorld.minimal.conversations[0].id
        model.openSearchPerson(Member.ID("new-person"))
        await settleAutoMarkRead(until: "open held") { await backend.abortableDirectOpens.count == 1 }
        model.select(id)
        await backend.abortableDirectOpens.release()
        await settleAutoMarkRead(until: "new DM stored") {
            model.conversations.contains { $0.members.contains(Member.ID("new-person")) }
        }
        #expect(model.selected == id)
        await model.stop()
    }
}
