import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `ChatSessionModel.me`, which session 9 slice 3 turned from an injected
/// constant into something watched from the store - the same shape
/// `conversations` and `connectionState` already had. `FakeBackend` is what
/// makes this testable without a live account: it now emits
/// `.selfIdentified` on `connect()` the same way a real bridge does, so this
/// suite exercises the one path both backends share rather than a fixture
/// only code path.
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionModelTests {
    /// The store-driven value, arriving once `start()` has run the backend's
    /// `connect()` through to `SyncReducer`. `me: nil` at init is the case a
    /// real bridge is in: nothing is known synchronously, so this is the
    /// general path rather than the fixture's shortcut.
    @MainActor
    @Test func meIsObservedFromTheStoreOnceTheBackendIdentifiesItself() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: nil)

        try await model.start()

        for _ in 0 ..< 200 where model.me == nil {
            await Task.yield()
        }
        #expect(model.me == FixtureWorld.minimal.me)
        await model.stop()
    }

    /// The `me:` initialiser parameter is a starting value, not deleted: a
    /// backend that already knows its local user synchronously - `FakeBackend`
    /// today, via the world it was built with - should be able to render
    /// correctly before `start()` has reached the store at all.
    @MainActor
    @Test func meStartsAtTheInjectedValueBeforeStartIsCalled() throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)

        #expect(model.me == FixtureWorld.minimal.me)
    }

    /// The store-driven value replaces the injected one rather than fighting
    /// it: once `start()` runs, the observation's own read of the (still
    /// correct) store value lands on top of the starting value and agrees
    /// with it, rather than the two racing to different answers.
    @MainActor
    @Test func aStoreDrivenValueReplacesTheStartingValueWithoutDisagreeing() async throws {
        let backend = FakeBackend(world: .minimal)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, me: FixtureWorld.minimal.me)
        #expect(model.me == FixtureWorld.minimal.me)

        try await model.start()
        // Gives the watch a chance to deliver the store's own read, which
        // should confirm the starting value rather than contradict it.
        for _ in 0 ..< 200 {
            await Task.yield()
        }

        #expect(model.me == FixtureWorld.minimal.me)
        await model.stop()
    }
}
