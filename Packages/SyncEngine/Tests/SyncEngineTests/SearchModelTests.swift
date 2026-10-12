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

    /// Return while a search is on the wire sends no second request.
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

    /// Newer text tears the older request down, and the older
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

    /// Typing away from an answered query and back
    /// returns to its answer, with nothing searching and nothing sent again.
    @Test func backToTheAnsweredQueryIsNotSearching() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .seconds(60))
        model.searchTextChanged("rows")
        model.submitSearch()
        await settleAutoMarkRead(until: "the answer lands") { model.search.answered != nil }
        model.searchTextChanged("rowsx")
        model.searchTextChanged("rows")
        #expect(!model.search.isSearching)
        let sent = await backend.messageSearches.count
        #expect(sent == 1)
        await model.stop()
    }

    static let other = Member.ID("fixture-other")

    @Test func knownPeopleMatchAtOnce() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend, debounce: .seconds(60))
        await settleAutoMarkRead(until: "the directory is observed") { model.directory[Self.other] != nil }
        model.searchTextChanged("oth")
        #expect(model.search.people.map(\.id) == [Self.other])
        await model.stop()
    }

    /// The directory's answer joins the known people: no one twice, never you.
    @Test func theDirectoryMergesWithoutDuplicatesOrMe() async throws {
        let outsider = Member(id: Member.ID("outsider"), kind: .human, displayName: "Out Person")
        let backend = RecordingBackend(directory: [
            Member(id: Self.other, kind: .human, displayName: "Other Person"),
            Member(id: FixtureWorld.minimal.me, kind: .human, displayName: "Fixture Person"),
            outsider
        ])
        let model = try await Self.model(backend)
        await settleAutoMarkRead(until: "the directory is observed") { model.directory[Self.other] != nil }
        model.searchTextChanged("person")
        await settleAutoMarkRead(until: "the directory answers") { model.search.people.count == 2 }
        await settleAutoMarkRead()
        #expect(model.search.people.map(\.id) == [Self.other, outsider.id])
        await model.stop()
    }

    @Test func withoutNonMemberMentionsTheDirectoryIsNotAsked() async throws {
        let backend = RecordingBackend(capabilities: Capabilities(
            canSendMessages: true,
            canSearchMessages: true
        ))
        let model = try await Self.model(backend)
        model.searchTextChanged("person")
        await settleAutoMarkRead(until: "the search answers") { model.search.answered != nil }
        await settleAutoMarkRead()
        let asked = await backend.searches
        #expect(asked.isEmpty)
        await model.stop()
    }

    @Test func aFailedSearchIsFailed() async throws {
        let backend = RecordingBackend()
        await backend.failMessageSearches(true)
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead(until: "the failure lands") { model.search.answered != nil }
        #expect(model.search.failed)
        #expect(model.search.hits.isEmpty)
        #expect(!model.search.isSearching)
        await model.stop()
    }

    @Test func stopTearsDownAHeldSearch() async throws {
        let backend = RecordingBackend()
        await backend.holdMessageSearches(true)
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead(until: "the search is held") {
            await backend.abortableMessageSearches.count == 1
        }
        await model.stop()
        #expect(model.search == SearchSessionState())
        await settleAutoMarkRead(until: "the hold is aborted") {
            await backend.abortableMessageSearches.aborted == 1
        }
    }

    /// The directory search for text typed away from
    /// an answered query never lands under that query when it comes back.
    @Test func aSupersededDirectorySearchNeverLands() async throws {
        let backend = RecordingBackend()
        await backend.echoQueries(true)
        let model = try await Self.model(backend)
        model.searchTextChanged("rows")
        await settleAutoMarkRead(until: "both sections answer") {
            model.search.answered != nil && model.search.people.map(\.id) == [Member.ID("rows")]
        }
        await backend.holdSearches(true)
        model.searchTextChanged("rowsx")
        await settleAutoMarkRead(until: "rowsx's directory search is held") {
            await backend.searches.count == 2
        }
        model.searchTextChanged("rows")
        await settleAutoMarkRead()
        await backend.holdSearches(false)
        await backend.releaseHeldSearch(at: 0)
        await backend.releaseHeldSearch(at: 0)
        await settleAutoMarkRead()
        #expect(model.search.query.text == "rows")
        #expect(!model.search.people.map(\.id).contains(Member.ID("rowsx")))
        await model.stop()
    }
}
