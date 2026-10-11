import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The search's query half (search spec §3).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SearchModelTests {
    static func model(
        _ backend: RecordingBackend, debounce: Duration = .zero, historyPages: Int = 20
    ) async throws -> ChatSessionModel {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store, engine: engine, me: FixtureWorld.minimal.me, markReadDebounce: .zero,
            directoryDebounce: .zero, membershipWait: .milliseconds(50),
            searchDebounce: debounce, searchHistoryPages: historyPages
        )
        try await model.start()
        await settleAutoMarkRead()
        return model
    }

    /// The minimal world's second message reads "It did. 41k rows, nothing flagged."
    @Test func typingSearchesOnceAfterThePause() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .milliseconds(50))
        model.searchTextChanged("r")
        model.searchTextChanged("ro")
        model.searchTextChanged("row")
        #expect(await backend.messageSearches.isEmpty)
        await settleAutoMarkRead(until: "the answer lands") { model.search.answered != nil }
        #expect(await backend.messageSearches.map(\.query.text) == ["row"])
        #expect(model.search.hits.map(\.text).contains { $0.contains("rows") })
        await model.stop()
    }

    @Test func oneCharacterSearchesNothing() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.searchTextChanged("r")
        await settleAutoMarkRead()
        #expect(await backend.messageSearches.isEmpty)
        #expect(model.search.hits.isEmpty)
        #expect(!model.search.isSearching)
        await model.stop()
    }

    /// A filter, the order and Return search at once: the debounce is a minute.
    @Test func aFilterSearchesAtOnce() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .seconds(60))
        model.setSearchQuery(MessageSearchQuery(from: FixtureWorld.minimal.me))
        await settleAutoMarkRead(until: "the filter's search runs") {
            await backend.messageSearches.count == 1
        }
        await model.stop()
    }

    @Test func returnSearchesAtOnce() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .seconds(60))
        model.searchTextChanged("rows")
        model.submitSearch()
        await settleAutoMarkRead(until: "Return's search runs") { await backend.messageSearches.count == 1 }
        await model.stop()
    }

    /// Review Focus 1.
    @Test func returnDuringAnInFlightSearchSendsNoSecond() async throws {
        let backend = RecordingBackend()
        await backend.holdMessageSearches(true)
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead(until: "the search is on the wire") {
            await backend.abortableMessageSearches.count == 1
        }
        model.submitSearch()
        await settleAutoMarkRead()
        let sent = await backend.messageSearches.count
        #expect(sent == 1)
        await backend.abortableMessageSearches.release()
        await settleAutoMarkRead(until: "the answer lands") { model.search.answered != nil }
        await model.stop()
    }

    /// Review Focus 2: newer text tears the older request down, and the older
    /// answer never replaces the newer one.
    @Test func aSupersededSearchIsTornDown() async throws {
        let backend = RecordingBackend()
        await backend.holdMessageSearches(true)
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead(until: "the first is held") {
            await backend.abortableMessageSearches.count == 1
        }
        model.searchTextChanged("nothing")
        await settleAutoMarkRead(until: "the first is torn down") {
            await backend.abortableMessageSearches.aborted == 1
        }
        await settleAutoMarkRead(until: "the second is held") {
            await backend.abortableMessageSearches.count == 1
        }
        await backend.abortableMessageSearches.release()
        await settleAutoMarkRead(until: "the answer lands") { model.search.answered != nil }
        #expect(model.search.answered?.text == "nothing")
        await model.stop()
    }

    @Test func conversationsMatchByNameAtOnce() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .seconds(60))
        let title = try #require(model.conversations.first { $0.title != nil }?.title)
        model.searchTextChanged(String(title.prefix(3)))
        #expect(model.search.conversations.contains { $0.title == title })
        await model.stop()
    }

    @Test func withoutTheCapabilityNothingIsAsked() async throws {
        let backend = RecordingBackend(capabilities: Capabilities(canSendMessages: true))
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead()
        // Without the capability nothing is asked at all.
        #expect(await backend.messageSearches.isEmpty)
        #expect(!model.search.failed)
        await model.stop()
    }

    @Test func theNextPageAppends() async throws {
        let backend = RecordingBackend()
        let messages = FixtureWorld.minimal.messages
        await backend.scriptMessageSearch([
            MessageSearchPage(hits: [messages[0]], next: MessageSearchCursor("1")),
            MessageSearchPage(hits: [messages[1], messages[0]])
        ])
        let model = try await Self.model(backend)
        model.searchTextChanged("anything")
        await settleAutoMarkRead(until: "page one") { model.search.hits.count == 1 }
        model.loadMoreSearchResults()
        await settleAutoMarkRead(until: "page two") { model.search.hits.count == 2 }
        #expect(model.search.next == nil)
        #expect(await backend.messageSearches.last?.cursor == MessageSearchCursor("1"))
        await model.stop()
    }
}
