import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The fixture echoes a sent message's mentions, so `--backend=fixture` shows
/// the whole mention flow (mention composer spec §3.5).
@Suite(.timeLimit(.minutes(1)))
struct FixtureMentionSendTests {
    @Test func aSentMessageEchoesItsMentions() async throws {
        let backend = FakeBackend(world: .minimal)
        try await backend.connect()
        var iterator = backend.events.makeAsyncIterator()
        let mention = Mention(target: .user(Member.ID("fixture-other")), start: 0, length: 6)
        try await backend.send(.sendMessage(
            conversationID: Conversation.ID("space:1"), threadID: nil, text: "@Other hi", localID: "l-1",
            mentions: [mention]
        ))
        var echoed: Message?
        for _ in 0 ..< 50 {
            guard let event = await iterator.next() else { break }
            if case let .messageReceived(message) = event, message.localID == "l-1" {
                echoed = message
                break
            }
        }
        #expect(try #require(echoed).mentions == [mention])
    }

    @Test func loadMembersIsAcceptedAndDoesNothing() async throws {
        let backend = FakeBackend(world: .minimal)
        try await backend.connect()
        try await backend.send(.loadMembers(conversationID: Conversation.ID("space:1")))
    }

    @Test func theFixtureAdvertisesMentions() {
        #expect(FakeBackend(world: .minimal).capabilities.canMention)
    }
}
