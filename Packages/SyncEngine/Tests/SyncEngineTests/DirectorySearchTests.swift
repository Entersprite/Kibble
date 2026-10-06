import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The `@` list's directory section (mention non-members spec §3.4).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DirectorySearchTests {
    static let outsider = Member(id: Member.ID("outsider"), kind: .human, displayName: "Out Sider")

    static func model(
        _ backend: RecordingBackend,
        select: String = "space:1"
    ) async throws -> ChatSessionModel {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store, engine: engine, me: FixtureWorld.minimal.me, markReadDebounce: .zero,
            directoryDebounce: .zero, membershipWait: .milliseconds(50)
        )
        try await model.start()
        await settleAutoMarkRead()
        model.select(Conversation.ID(select))
        await settleAutoMarkRead()
        return model
    }

    @Test func aQueryPublishesTheDirectoryResults() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await Self.model(backend)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        #expect(model.directoryResults.map(\.id) == [Self.outsider.id])
        await model.stop()
    }

    @Test func aNilQueryClearsThem() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await Self.model(backend)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        model.directoryQuery(nil)
        #expect(model.directoryResults.isEmpty)
        await model.stop()
    }

    /// Review Focus 2: "o" answers after "ou", and must not replace it.
    @Test func aLateAnswerForAnOlderQueryIsDiscarded() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        await backend.echoQueries(true)
        await backend.holdSearches(true)
        model.directoryQuery("o")
        await settleAutoMarkRead(until: "the first search is held") { await backend.heldSearchCount == 1 }
        model.directoryQuery("ou")
        await settleAutoMarkRead(until: "both searches are held") { await backend.heldSearchCount == 2 }
        await backend.releaseHeldSearch(at: 1)
        await settleAutoMarkRead(until: "the newer answer lands") { !model.directoryResults.isEmpty }
        await backend.releaseHeldSearch(at: 0)
        await settleAutoMarkRead()
        #expect(model.directoryResults.map(\.id) == [Member.ID("ou")])
        await model.stop()
    }

    @Test func aFailedSearchRaisesNoBanner() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await Self.model(backend)
        await backend.failSearches(true)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "the search ran") { await backend.searches == ["out"] }
        await settleAutoMarkRead()
        #expect(model.directoryResults.isEmpty)
        #expect(model.lastError == nil)
        await model.stop()
    }

    @Test func noSearchInADirectMessage() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await Self.model(backend, select: "dm:1")
        model.directoryQuery("out")
        await settleAutoMarkRead()
        #expect(await backend.searches.isEmpty)
        await model.stop()
    }

    @Test func meIsNeverADirectoryResult() async throws {
        let me = Member(id: FixtureWorld.minimal.me, kind: .human, displayName: "Out Me")
        let backend = RecordingBackend(directory: [me, Self.outsider])
        let model = try await Self.model(backend)
        model.directoryQuery("out")
        await settleAutoMarkRead(until: "results arrive") { !model.directoryResults.isEmpty }
        #expect(model.directoryResults.map(\.id) == [Self.outsider.id])
        await model.stop()
    }
}
