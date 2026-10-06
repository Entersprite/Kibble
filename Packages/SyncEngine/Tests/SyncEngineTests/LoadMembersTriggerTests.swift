import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoadMembersTriggerTests {
    private static func model(_ backend: RecordingBackend) async throws -> ChatSessionModel {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        try await model.start()
        await settleAutoMarkRead()
        return model
    }

    private static func loads(_ backend: RecordingBackend) async -> [Conversation.ID] {
        await backend.commands.compactMap {
            if case let .loadMembers(id) = $0 {
                id
            } else {
                nil
            }
        }
    }

    @Test func selectingASpaceLoadsItsMembersOnce() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        model.select(Conversation.ID("dm:1"))
        await settleAutoMarkRead()
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        #expect(await Self.loads(backend) == [Conversation.ID("space:1")])
        await model.stop()
    }

    @Test func aDirectMessageLoadsNothing() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.select(Conversation.ID("dm:1"))
        await settleAutoMarkRead()
        #expect(await Self.loads(backend).isEmpty)
        await model.stop()
    }

    /// A refused load is forgotten, so the next selection asks again (spec §4).
    @Test func aFailedLoadIsRetriedOnTheNextSelection() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        await backend.failSubmissions(true)
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        await backend.failSubmissions(false)
        model.select(Conversation.ID("dm:1"))
        await settleAutoMarkRead()
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        #expect(await Self.loads(backend).count == 2)
        await model.stop()
    }

    @Test func theCandidatesFollowTheSelection() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead(until: "candidates arrive") { !model.mentionCandidates.isEmpty }
        #expect(!model.mentionCandidates.contains { $0.id == FixtureWorld.minimal.me })
        await model.stop()
    }
}
