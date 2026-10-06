import Foundation
import Testing
@testable import ChatKit

/// How a mention treats someone outside the space (mention non-members spec
/// §3.1): encoded only when it is not a plain mention, so no frame from before
/// it changes.
struct MentionModeTests {
    private let user = Mention.Target.user(Member.ID("users/alice"))

    @Test func aPlainMentionEncodesNoMode() throws {
        let data = try JSONEncoder().encode(Mention(target: user, start: 0, length: 6))
        #expect(!String(decoding: data, as: UTF8.self).contains("mode"))
    }

    @Test func aMissingModeIsAPlainMention() throws {
        let json = #"{"length":6,"start":0,"target":{"id":"users/alice","type":"user"}}"#
        #expect(try JSONDecoder().decode(Mention.self, from: Data(json.utf8)).mode == .mention)
    }

    @Test func inviteAndWithoutAddingRoundTrip() throws {
        for mode in [Mention.Mode.invite, .withoutAdding] {
            let mention = Mention(target: user, start: 0, length: 6, mode: mode)
            let decoded = try JSONDecoder().decode(Mention.self, from: JSONEncoder().encode(mention))
            #expect(decoded == mention)
        }
    }

    @Test func anUnknownModeSurvivesVerbatim() throws {
        let json = #"{"length":6,"mode":"somethingNewer","start":0,"target":{"id":"u","type":"user"}}"#
        let decoded = try JSONDecoder().decode(Mention.self, from: Data(json.utf8))
        #expect(decoded.mode == .unknown("somethingNewer"))
        #expect(try String(decoding: JSONEncoder().encode(decoded), as: UTF8.self).contains("somethingNewer"))
    }

    @Test func anInviteOfMeStillMentionsMe() {
        let me = Member.ID("me")
        let message = Message(
            id: Message.ID("m"), conversationID: Conversation.ID("space/s"), threadID: MessageThread.ID("t"),
            sender: Member.ID("other"), text: "@Me", createdAt: Date(timeIntervalSince1970: 0),
            mentions: [Mention(target: .user(me), start: 0, length: 3, mode: .invite)]
        )
        #expect(message.mentionsMe(me))
    }

    @Test func inviteMatchesItsGoldenFile() throws {
        try expectWireStable(
            Mention(target: user, start: 0, length: 6, mode: .invite),
            golden: "mention-invite"
        )
    }

    @Test func withoutAddingMatchesItsGoldenFile() throws {
        try expectWireStable(
            Mention(target: user, start: 0, length: 6, mode: .withoutAdding),
            golden: "mention-withoutAdding"
        )
    }
}
