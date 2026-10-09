import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The three thread requests and the two marks: kept in the world and
/// reported the way the bridge reports its server's answers (threads spec §3).
@Suite(.timeLimit(.minutes(1)))
struct FixtureThreadCallTests {
    private let sync = MessageThread.ID("topic:sync")
    private let variance = MessageThread.ID("topic:variance")
    private let trim = MessageThread.ID("topic:trim")
    private let dmDan = MessageThread.ID("topic:dm-dan")
    private let pe = Acme.priceEngine

    private func connected(
        capabilities: Capabilities = .fixture
    ) async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: .acme, capabilities: capabilities)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(backend.emittedCount)
        return (backend, collector)
    }

    // MARK: - loadThread

    @Test func aThreadLoadsOldestFirstAndSaysItIsFollowed() async throws {
        let (backend, collector) = try await connected()
        let thread = try await backend.loadThread(variance, in: pe)
        #expect(thread.map(\.id.rawValue) == [
            "msg:pe-3", "msg:pe-4", "msg:pe-5", "msg:pe-6", "msg:pe-mention"
        ])
        #expect(thread.map(\.isReply) == [false, true, true, true, true])
        #expect(await collector.nextOne() == changed(variance, .followed(true)))
    }

    @Test func aThreadNobodyFollowsSaysSo() async throws {
        let (backend, collector) = try await connected()
        _ = try await backend.loadThread(sync, in: pe)
        #expect(await collector.nextOne() == changed(sync, .followed(false)))
    }

    @Test func aThreadTheWorldDoesNotHoldIsRefused() async throws {
        let backend = FakeBackend(world: .acme)
        await #expect(throws: ChatError.self) {
            _ = try await backend.loadThread(MessageThread.ID("topic:nowhere"), in: pe)
        }
    }

    // MARK: - setThreadFollowed

    @Test func followingIsKeptAndReported() async throws {
        let (backend, collector) = try await connected()
        try await backend.setThreadFollowed(true, thread: sync, in: pe)
        #expect(await collector.nextOne() == changed(sync, .followed(true)))
        #expect(await backend.currentWorld.threadState(sync).isFollowed)
        try await backend.setThreadFollowed(false, thread: sync, in: pe)
        #expect(await collector.nextOne() == changed(sync, .followed(false)))
        #expect(await backend.currentWorld.threadState(sync).isFollowed == false)
    }

    /// Unfollowing the only unread thread clears the conversation's flag, as
    /// push 53 would.
    @Test func unfollowingTheUnreadThreadClearsTheConversationsFlag() async throws {
        let (backend, collector) = try await connected()
        try await backend.setThreadFollowed(false, thread: variance, in: pe)
        #expect(await collector.next(2) == [
            changed(variance, .followed(false)),
            .unreadThreadsChanged(conversationID: pe, hasUnread: false)
        ])
        #expect(await backend.currentWorld.conversation(pe)?.hasUnreadThread == false)
    }

    @Test func followingNeedsAConnection() async throws {
        let backend = FakeBackend(world: .acme)
        await #expect(throws: ChatError.transport("not connected")) {
            try await backend.setThreadFollowed(true, thread: sync, in: pe)
        }
    }

    // MARK: - loadFollowedThreads

    @Test func theThreadsListIsEveryFollowedThreadNewestFirst() async throws {
        let (backend, collector) = try await connected()
        let list = try await backend.loadFollowedThreads()
        #expect(list.map(\.id.rawValue) == [
            "msg:pe-3", "msg:pe-mention", "msg:trim-root", "msg:trim-30", "msg:dd-1", "msg:dd-3"
        ])
        #expect(await collector.next(6) == [
            changed(variance, .followed(true)),
            changed(variance, .counted(messages: 5, unread: 3)),
            .threadChanged(threadID: trim, conversationID: Acme.catalog, change: .followed(true)),
            .threadChanged(
                threadID: trim, conversationID: Acme.catalog, change: .counted(messages: 31, unread: 0)
            ),
            .threadChanged(threadID: dmDan, conversationID: Acme.danDM, change: .followed(true)),
            .threadChanged(
                threadID: dmDan, conversationID: Acme.danDM, change: .counted(messages: 3, unread: 0)
            )
        ])
    }

    @Test func withoutTheCapabilityEveryThreadRequestIsRefused() async throws {
        let backend = FakeBackend(world: .acme, capabilities: Capabilities())
        try await backend.connect()
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            _ = try await backend.loadThread(variance, in: pe)
        }
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            try await backend.setThreadFollowed(true, thread: variance, in: pe)
        }
        await #expect(throws: ChatError.unsupported(capability: "supportsThreads")) {
            _ = try await backend.loadFollowedThreads()
        }
    }

    // MARK: - The two marks

    @Test func markingAThreadReadMovesItsPositionAndTheConversationsFlag() async throws {
        let (backend, collector) = try await connected()
        try await backend.send(.markThreadRead(conversationID: pe, threadID: variance, upTo: Acme.at(44)))
        #expect(await collector.next(2) == [
            changed(variance, .read(upTo: Acme.at(44))),
            .unreadThreadsChanged(conversationID: pe, hasUnread: false)
        ])
        #expect(await backend.currentWorld.threadState(variance).readPosition == Acme.at(44))
    }

    @Test func markingAThreadUnreadSetsTheMarkAndClearingItRemovesIt() async throws {
        let (backend, collector) = try await connected()
        try await backend.send(.markThreadRead(conversationID: pe, threadID: variance, upTo: Acme.at(44)))
        _ = await collector.next(2)

        try await backend.send(.setThreadUnreadMark(conversationID: pe, threadID: variance, at: Acme.at(40)))
        #expect(await collector.next(2) == [
            changed(variance, .markedUnread(at: Acme.at(40))),
            .unreadThreadsChanged(conversationID: pe, hasUnread: true)
        ])

        try await backend.send(.setThreadUnreadMark(conversationID: pe, threadID: variance, at: nil))
        #expect(await collector.next(2) == [
            changed(variance, .markedUnread(at: nil)),
            .unreadThreadsChanged(conversationID: pe, hasUnread: false)
        ])
    }

    @Test func aMarkOnAThreadTheWorldDoesNotHoldIsRefused() async throws {
        let (backend, _) = try await connected()
        await #expect(throws: ChatError.self) {
            try await backend.send(.markThreadRead(
                conversationID: pe, threadID: MessageThread.ID("topic:nowhere"), upTo: Acme.at(1)
            ))
        }
    }

    private func changed(_ thread: MessageThread.ID, _ change: ThreadChange) -> ChatEvent {
        .threadChanged(threadID: thread, conversationID: pe, change: change)
    }
}
