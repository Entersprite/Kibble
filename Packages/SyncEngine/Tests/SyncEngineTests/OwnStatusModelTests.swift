import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// The model shows your availability and sends what you set (spec §4).
@Suite(.timeLimit(.minutes(1)))
struct OwnStatusModelTests {
    @MainActor
    @Test func yourAvailabilityIsObserved() async throws {
        let backend = FailingBackend()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), markReadDebounce: .zero
        )
        try await model.start()
        await backend.emit(.availabilityChanged(.away))
        for _ in 0 ..< 500 where model.availability == nil {
            await Task.yield()
        }
        #expect(model.availability == .away)
        await model.stop()
    }

    /// `RecordingBackend` records a command before forwarding it, so this
    /// holds whatever the fixture does with it.
    @MainActor
    @Test func settingSendsTheCommands() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), markReadDebounce: .zero
        )
        try await model.start()
        let status = MemberStatus(emoji: "🏠", text: "Working remotely")
        model.setStatus(status)
        model.setAvailability(.away)
        model.reportActivity(false)
        for _ in 0 ..< 500 where await backend.commands.count < 3 {
            await Task.yield()
        }
        let commands = await backend.commands
        #expect(commands.contains(.setStatus(status)))
        #expect(commands.contains(.setAvailability(.away)))
        #expect(commands.contains(.reportActivity(active: false)))
        await model.stop()
    }

    /// Drawn before the backend has even answered, and kept once it accepts.
    @MainActor
    @Test func availabilityShowsBeforeTheAnswer() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await startedModel(backend)
        await backend.holdSubmissions(true)
        model.setAvailability(.away)
        #expect(model.availability == .away)
        for _ in 0 ..< 500 where await backend.heldSubmissionCount == 0 {
            await Task.yield()
        }
        #expect(model.availability == .away)
        await backend.releaseHeldSubmission()
        for _ in 0 ..< 500 where !model.sendTasks.isEmpty {
            await Task.yield()
        }
        #expect(model.availability == .away)
        await model.stop()
    }

    @MainActor
    @Test func aRefusedAvailabilityPutsThePreviousBack() async throws {
        let backend = RecordingBackend()
        let (model, _) = try await startedModel(backend)
        model.setAvailability(.automatic)
        for _ in 0 ..< 500 where !model.sendTasks.isEmpty || model.ownStatusWork.availability.isPending {
            await Task.yield()
        }
        #expect(model.availability == .automatic)
        await backend.failSubmissions(true)
        model.setAvailability(.away)
        #expect(model.availability == .away)
        for _ in 0 ..< 500 where !model.sendTasks.isEmpty {
            await Task.yield()
        }
        #expect(model.availability == .automatic)
        // The refusal's reason reaches the model through the store, after the answer.
        for _ in 0 ..< 500 where model.lastError == nil {
            await Task.yield()
        }
        #expect(model.lastError != nil)
        await model.stop()
    }

    @MainActor
    @Test func yourStatusShowsAtOnceAndARefusalPutsItBack() async throws {
        let backend = RecordingBackend()
        let (model, me) = try await startedModel(backend)
        let status = MemberStatus(emoji: "🏠", text: "Working remotely")
        await backend.failSubmissions(true)
        model.setStatus(status)
        #expect(model.directory[me]?.status == status)
        for _ in 0 ..< 500 where !model.sendTasks.isEmpty {
            await Task.yield()
        }
        #expect(model.directory[me]?.status == nil)
        await model.stop()
    }

    /// A write to someone else's row re-delivers the whole directory; the
    /// choice in flight is drawn over it again rather than lost.
    @MainActor
    @Test func aDirectoryDeliveryKeepsYourChoiceInFlight() async throws {
        let backend = RecordingBackend()
        let (model, me) = try await startedModel(backend)
        let status = MemberStatus(emoji: "📅", text: "In a meeting")
        await backend.holdSubmissions(true)
        model.setStatus(status)
        for _ in 0 ..< 500 where await backend.heldSubmissionCount == 0 {
            await Task.yield()
        }
        let other = Member(id: Member.ID("someone-else"), kind: .human, displayName: "Someone Else")
        try model.store.apply([.upsertMembers([other])])
        for _ in 0 ..< 500 where model.directory[other.id] == nil {
            await Task.yield()
        }
        #expect(model.directory[other.id] != nil)
        #expect(model.directory[me]?.status == status)
        await backend.failSubmissions(true)
        await backend.releaseHeldSubmission()
        for _ in 0 ..< 500 where !model.sendTasks.isEmpty {
            await Task.yield()
        }
        #expect(model.directory[me]?.status == nil)
        await model.stop()
    }

    @MainActor
    private func startedModel(_ backend: RecordingBackend) async throws -> (ChatSessionModel, Member.ID) {
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), markReadDebounce: .zero
        )
        try await model.start()
        for _ in 0 ..< 500 where model.me.flatMap({ model.directory[$0] }) == nil {
            await Task.yield()
        }
        let me = try #require(model.me)
        #expect(model.directory[me] != nil)
        return (model, me)
    }
}
