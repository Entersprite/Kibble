import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// History pages by topic and reports each thread with a reply as it loads,
/// as the bridge does (threads spec §2.2).
@Suite(.timeLimit(.minutes(1)))
struct FixtureThreadHistoryTests {
    private let sync = MessageThread.ID("topic:sync")
    private let variance = MessageThread.ID("topic:variance")

    private func connected() async throws -> (FakeBackend, EventCollector) {
        let backend = FakeBackend(world: .acme)
        let collector = EventCollector(backend.events)
        try await backend.connect()
        _ = await collector.next(backend.emittedCount)
        return (backend, collector)
    }

    /// A page of two topics brings the long thread whole, first message
    /// included, rather than thirty replies and no first message.
    @Test func aPageCarriesWholeThreads() async throws {
        let backend = FakeBackend(world: .acme, pageSize: 2)
        let page = try await backend.loadMessages(in: Acme.catalog, before: nil)
        #expect(page.count == 32)
        #expect(page.first?.id == Message.ID("msg:fd-6"))
        #expect(page.dropFirst().first?.id == Message.ID("msg:trim-root"))
        #expect(page == page.sorted { $0.createdAt < $1.createdAt })
    }

    @Test func theNextPageEndsBeforeItsCursor() async throws {
        let backend = FakeBackend(world: .acme, pageSize: 2)
        let page = try await backend.loadMessages(in: Acme.catalog, before: Message.ID("msg:fd-6"))
        #expect(page.map(\.id.rawValue) == ["msg:fd-4", "msg:fd-5"])
    }

    @Test func aPageReportsEachThreadWithReplies() async throws {
        let (backend, collector) = try await connected()
        _ = try await backend.loadMessages(in: Acme.priceEngine, before: nil)
        #expect(await collector.next(5) == [
            changed(sync, .counted(messages: 2, unread: 0)),
            changed(sync, .markedUnread(at: nil)),
            changed(variance, .counted(messages: 5, unread: 3)),
            changed(variance, .read(upTo: Acme.at(34))),
            changed(variance, .markedUnread(at: nil))
        ])
        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    @Test func aConversationWithoutRepliesReportsNoThreads() async throws {
        let (backend, collector) = try await connected()
        _ = try await backend.loadMessages(in: Acme.storefront, before: nil)
        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    @Test func aBackendWithoutThreadsReportsNone() async throws {
        let backend = FakeBackend(world: .acme, capabilities: Capabilities())
        let collector = EventCollector(backend.events)
        _ = try await backend.loadMessages(in: Acme.priceEngine, before: nil)
        try await backend.apply(.gap(scope: .everything, reason: "sentinel"))
        #expect(await collector.nextOne() == .gap(scope: .everything, reason: "sentinel"))
    }

    private func changed(_ thread: MessageThread.ID, _ change: ThreadChange) -> ChatEvent {
        .threadChanged(threadID: thread, conversationID: Acme.priceEngine, change: change)
    }
}
