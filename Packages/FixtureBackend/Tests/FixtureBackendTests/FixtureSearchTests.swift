import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The fake's search (search spec §2): every filter, pages of five,
/// deterministic.
struct FixtureSearchTests {
    static let base = FixtureWorld.minimal
    static let space = base.conversations[0].id
    static let other = base.members.first { $0.id != base.me }!.id

    /// A world of twelve messages, two of which carry a link, one a reply,
    /// one a mention of me, spread one minute apart.
    static func message(_ index: Int) -> Message {
        let threadID = MessageThread.ID(index == 11 ? "t0" : "t\(index)")
        let sender: Member.ID = index.isMultiple(of: 2) ? base.me : other
        let text: String = index == 3 ? "Unrelated" : "Deploy number \(index)"
        let createdAt = base.startedAt.addingTimeInterval(Double(index) * 60)
        let mentions: [Mention] = index == 5 ? [Mention(target: .user(base.me), start: 0, length: 6)] : []
        let link = MessageLink(url: URL(string: "https://example.com")!, start: 0, length: 6)
        let links: [MessageLink] = index == 7 || index == 9 ? [link] : []
        return Message(
            id: Message.ID("m\(index)"), conversationID: space,
            threadID: threadID,
            sender: sender,
            text: text,
            createdAt: createdAt,
            mentions: mentions,
            links: links,
            isReply: index == 11
        )
    }

    static var world: FixtureWorld {
        var world = base
        world.messages = (0 ..< 12).map(message)
        return world
    }

    static func connected() async throws -> FakeBackend {
        let backend = FakeBackend(world: world)
        try await backend.connect()
        return backend
    }

    @Test func wordsMatchIgnoringCaseAndAccents() {
        let hits = FakeBackend.matches(MessageSearchQuery(text: "DÉPLOY"), in: Self.world)
        #expect(hits.count == 11)
    }

    @Test func noWordsAndNoFiltersFindNothing() {
        #expect(FakeBackend.matches(MessageSearchQuery(text: "  "), in: Self.world).isEmpty)
    }

    @Test func eachFilterNarrows() {
        let world = Self.world
        func count(_ query: MessageSearchQuery) -> Int {
            FakeBackend.matches(query, in: world).count
        }
        #expect(count(MessageSearchQuery(text: "deploy", from: Self.other)) == 5)
        #expect(count(MessageSearchQuery(hasLink: true)) == 2)
        #expect(count(MessageSearchQuery(mentionsMe: true)) == 1)
        #expect(count(MessageSearchQuery(olderThan: world.startedAt.addingTimeInterval(120))) == 2)
        #expect(count(MessageSearchQuery(newerThan: world.startedAt.addingTimeInterval(600))) == 2)
        #expect(count(MessageSearchQuery(text: "deploy", conversation: Conversation.ID("nowhere"))) == 0)
    }

    @Test func newestComesFirstWhenAsked() {
        let hits = FakeBackend.matches(MessageSearchQuery(text: "deploy", order: .newest), in: Self.world)
        #expect(hits.first?.id == Message.ID("m11"))
        #expect(hits.map(\.createdAt) == hits.map(\.createdAt).sorted(by: >))
    }

    @Test func aReplyIsAHit() {
        let hits = FakeBackend.matches(MessageSearchQuery(text: "number 11"), in: Self.world)
        #expect(hits.map(\.isReply) == [true])
    }

    @Test func pagesAreFiveWithAnOpaqueCursor() async throws {
        let backend = try await Self.connected()
        let query = MessageSearchQuery(text: "deploy", order: .newest)
        let first = try await backend.searchMessages(query, after: nil)
        #expect(first.hits.count == 5)
        let second = try await backend.searchMessages(query, after: first.next)
        let third = try await backend.searchMessages(query, after: second.next)
        #expect(third.hits.count == 1)
        #expect(third.next == nil)
        #expect(Set((first.hits + second.hits + third.hits).map(\.id)).count == 11)
    }

    @Test func itRefusesWhenDisconnected() async {
        let backend = FakeBackend(world: Self.world)
        await #expect(throws: ChatError.self) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "deploy"), after: nil)
        }
    }

    @Test func itRefusesWithoutTheCapability() async throws {
        let backend = FakeBackend(world: Self.world, capabilities: Capabilities(canSendMessages: true))
        try await backend.connect()
        await #expect(throws: ChatError.unsupported(capability: "canSearchMessages")) {
            _ = try await backend.searchMessages(MessageSearchQuery(text: "deploy"), after: nil)
        }
    }
}
