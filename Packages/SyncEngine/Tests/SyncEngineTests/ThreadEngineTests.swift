import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The engine's thread calls (threads spec §4.3): each files its answer, a
/// failure is recorded rather than thrown, a world load fetches the Threads
/// list, and nothing lands once its caller has stopped.
@Suite(.timeLimit(.minutes(1)))
struct ThreadEngineTests {
    private let conversation = ThreadFixture.conversation
    private let thread = ThreadFixture.thread

    private func eventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
        for _ in 0 ..< 400 {
            if try await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try await condition()
    }

    @Test func aThreadPageIsFiled() async throws {
        let backend = RecordingBackend()
        let page = ThreadFixture.messages(replies: 2)
        await backend.answerThread(thread, with: page)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.loadThread(thread, in: conversation)
        #expect(try page.map { try store.message($0.id)?.id } == page.map(\.id))
        #expect(try store.message(page[1].id)?.isReply == true)
        #expect(await backend.threadLoads == [thread])
    }

    /// Filed by the engine once the backend accepts, not only by the
    /// backend's later event; and a refusal throws and files nothing.
    @Test func followingIsFiledOnceTheBackendAccepts() async throws {
        let backend = RecordingBackend()
        let store = try ChatStore.inMemory()
        try store.apply(ThreadFixture.messages(replies: 1).map { .upsertMessage($0) })
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.setThreadFollowed(true, thread: thread, in: conversation)
        #expect(try store.thread(thread, in: conversation)?.isFollowed == true)

        await backend.failThreadCalls(true)
        await #expect(throws: ChatError.self) {
            try await engine.setThreadFollowed(false, thread: thread, in: conversation)
        }
        #expect(try store.thread(thread, in: conversation)?.isFollowed == true)
        #expect(await backend.followRequests == [true, false])
    }

    /// For a view, which has nowhere to put a thrown error. Never started, so
    /// no event can supersede the error before it is read.
    @Test func aFailedThreadCallIsRecordedNotThrown() async throws {
        let backend = RecordingBackend()
        await backend.failThreadCalls(true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let failure = ChatError.server(status: 500, message: "the thread call failed")

        await engine.requestThread(thread, in: conversation)
        #expect(try store.lastError() == failure)
        try store.apply([.setLastError(nil)])
        await engine.requestThreadFollowed(true, thread: thread, in: conversation)
        #expect(try store.lastError() == failure)
        try store.apply([.setLastError(nil)])
        await engine.requestFollowedThreads()
        #expect(try store.lastError() == failure)
    }

    /// `loadMoreMessages`' rule: a page answering after its caller stopped
    /// caring (a closed panel, a sign-out) writes nothing and records nothing.
    @Test func aThreadPageAnsweringAfterItsCallerStoppedWritesNothing() async throws {
        let backend = RecordingBackend()
        let page = ThreadFixture.messages(replies: 1)
        await backend.answerThread(thread, with: page)
        await backend.holdThreadCalls(true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let load = Task { [conversation, thread] in await engine.requestThread(thread, in: conversation) }
        #expect(await eventually { await backend.heldThreadCallCount == 1 })
        load.cancel()
        await backend.releaseHeldThreadCall()
        await load.value
        #expect(try store.message(page[1].id) == nil)
        #expect(try store.lastError() == nil)
    }

    /// The badge's number before the pane is ever opened (spec §4.3).
    @Test func aWorldLoadFetchesAndFilesTheThreadsList() async throws {
        let backend = RecordingBackend()
        let list = ThreadFixture.messages(replies: 1)
        await backend.answerFollowedThreads(with: list)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        #expect(try await eventually { try store.message(list[1].id) != nil })
        #expect(await backend.followedThreadLoads == 1)
        await engine.stop()
    }

    @Test func aBackendWithoutThreadsIsNeverAskedForTheList() async throws {
        var capabilities = Capabilities.fixture
        capabilities.supportsThreads = false
        let backend = RecordingBackend(capabilities: capabilities)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        // The positive control: the world load this would follow has happened.
        #expect(try await eventually {
            try store.conversations().count == FixtureWorld.minimal.conversations.count
        })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await backend.followedThreadLoads == 0)
        await engine.stop()
    }

    /// `stop()` cancels the world load's fetch, and its late answer is refused.
    @Test func aListAnsweringAfterStopWritesNothing() async throws {
        let backend = RecordingBackend()
        let list = ThreadFixture.messages(replies: 1)
        await backend.answerFollowedThreads(with: list)
        await backend.holdThreadCalls(true)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        try await engine.start()
        #expect(await eventually { await backend.heldThreadCallCount == 1 })
        await engine.stop()
        await backend.releaseHeldThreadCall()
        try await Task.sleep(for: .milliseconds(150))
        #expect(try store.message(list[1].id) == nil)
    }
}
