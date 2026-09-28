import Foundation
import Testing
@testable import ChatKit

struct MentionTests {
    private let me = Member.ID("users/me")
    private let alice = Member.ID("users/alice")

    private func message(from sender: Member.ID, mentions: [Mention]) -> Message {
        Message(
            id: Message.ID("m"), conversationID: Conversation.ID("space/s"), threadID: MessageThread.ID("t"),
            sender: sender, text: "@Me hi", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            mentions: mentions
        )
    }

    @Test func aMentionOfMeOrAllMentionsMeAndOneOfSomeoneElseDoesNot() {
        #expect(message(from: alice, mentions: [Mention(target: .user(me), start: 0, length: 3)])
            .mentionsMe(me))
        #expect(message(from: alice, mentions: [Mention(target: .all, start: 0, length: 4)]).mentionsMe(me))
        #expect(!message(from: alice, mentions: [Mention(target: .user(alice), start: 0, length: 6)])
            .mentionsMe(me))
        #expect(!message(from: alice, mentions: []).mentionsMe(me))
    }

    /// Review Focus 4.
    @Test func myOwnMessageNeverMentionsMeAndAnUnknownMeIsNeverMentioned() {
        #expect(!message(from: me, mentions: [Mention(target: .user(me), start: 0, length: 3)])
            .mentionsMe(me))
        #expect(!message(from: me, mentions: [Mention(target: .all, start: 0, length: 4)]).mentionsMe(me))
        #expect(!message(from: alice, mentions: [Mention(target: .all, start: 0, length: 4)]).mentionsMe(nil))
    }

    @Test func everyTargetMatchesItsGoldenFile() throws {
        try expectWireStable(Mention(target: .user(alice), start: 7, length: 6), golden: "mention-user")
        try expectWireStable(Mention(target: .all, start: 0, length: 4), golden: "mention-all")
    }

    @Test func anUnknownTargetDecodesAndReEncodesVerbatim() throws {
        // Keys sorted, as `Wire.json` writes them.
        let json = #"{"length":3,"start":1,"target":{"groupID":"g-1","type":"group"}}"#
        let decoded = try Wire.decode(Mention.self, from: json)
        guard case let .unknown(type, _) = decoded.target else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "group")
        #expect(try Wire.json(decoded) == json)
    }

    /// Ruling 2: no key when empty, so every message golden written before
    /// mentions stays byte-identical; and an absent key reads as none.
    @Test func aMessageWithoutMentionsOmitsTheKeyAndAMissingKeyReadsAsNone() throws {
        let plain = message(from: alice, mentions: [])
        let encoded = try Wire.json(plain)
        #expect(!encoded.contains("mentions"))
        #expect(try Wire.decode(Message.self, from: encoded).mentions.isEmpty)
    }
}
