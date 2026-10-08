import ChatKit
import FixtureBackend
import Foundation
import Testing
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
        for _ in 0 ..< 500 where await backend.commands.count < 2 {
            await Task.yield()
        }
        let commands = await backend.commands
        #expect(commands.contains(.setStatus(status)))
        #expect(commands.contains(.setAvailability(.away)))
        await model.stop()
    }
}
