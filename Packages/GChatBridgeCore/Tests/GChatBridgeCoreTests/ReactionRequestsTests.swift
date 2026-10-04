import Foundation
import Testing
@testable import GChatBridgeCore

/// `update_reaction`'s shape, pinned field by field. A write, so no ladder:
/// `maugclib/client.py:338-365` is the one worked example.
struct ReactionRequestsTests {
    private func space(_ id: String) -> GroupId {
        var group = GroupId()
        group.spaceID.spaceID = id
        return group
    }

    @Test func aUnicodeAddNamesTheMessageByGroupTopicAndID() {
        let request = ReactionRequests.updateReaction(
            group: space("s-1"), topicID: "t-1", messageID: "m-1",
            emoji: .unicode("👍"), add: true
        )
        #expect(request.hasRequestHeader)
        #expect(request.messageID.parentID.topicID.groupID.spaceID.spaceID == "s-1")
        #expect(request.messageID.parentID.topicID.topicID == "t-1")
        #expect(request.messageID.messageID == "m-1")
        #expect(request.emoji.unicode == "👍")
        #expect(!request.emoji.hasCustomEmoji)
        #expect(request.type == .add)
    }

    @Test func aCustomRemoveSendsOnlyTheUUID() {
        let request = ReactionRequests.updateReaction(
            group: space("s-1"), topicID: "t-1", messageID: "m-1",
            emoji: .custom(id: "e-1"), add: false
        )
        #expect(!request.emoji.hasUnicode)
        #expect(request.emoji.customEmoji.uuid == "e-1")
        #expect(!request.emoji.customEmoji.hasShortcode)
        #expect(request.type == .remove)
    }

    @Test func itRoundTripsThroughSerialisation() throws {
        let request = ReactionRequests.updateReaction(
            group: space("s-1"), topicID: "t-1", messageID: "m-1",
            emoji: .unicode("🎉"), add: true
        )
        let bytes: Data = try request.serializedBytes()
        let decoded = try UpdateReactionRequest(serializedBytes: bytes)
        #expect(decoded.emoji.unicode == "🎉")
        #expect(decoded.messageID.messageID == "m-1")
    }
}
