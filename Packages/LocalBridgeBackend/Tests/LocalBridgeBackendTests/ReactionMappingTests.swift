import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Field 21 becoming `[ChatKit.Reaction]`. Shapes from `findings.md` §53.1.
struct ReactionMappingTests {
    private func unicode(_ text: String, count: Int32, mine: Bool = false) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.unicode = text
        reaction.count = count
        reaction.currentUserParticipated = mine
        reaction.createTimestamp = 1_700_000_000_000_000
        return reaction
    }

    private func custom(uuid: String, shortcode: String, count: Int32) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji.uuid = uuid
        reaction.emoji.customEmoji.shortcode = shortcode
        reaction.count = count
        return reaction
    }

    @Test func unicodeReactionsKeepTheServersOrderCountAndMine() {
        let mapped = ReactionMapping.reactions([unicode("👍", count: 2, mine: true), unicode("🎉", count: 1)])
        #expect(mapped == [
            ChatKit.Reaction(emoji: "👍", count: 2, includesMe: true),
            ChatKit.Reaction(emoji: "🎉", count: 1)
        ])
    }

    /// `[Verify]`: §53.1 saw no custom emoji. Built through `CustomEmojiRef`,
    /// so `emoji` is its `displayText`, the invariant the row relies on.
    @Test func aCustomReactionCarriesItsIdentityAndShortcode() {
        let mapped = ReactionMapping.reactions([custom(uuid: "e-1", shortcode: ":parrot:", count: 3)])
        let ref = CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        #expect(mapped == [ChatKit.Reaction(emoji: ref.displayText, count: 3, customEmoji: ref)])
    }

    @Test func emptyOrCountlessReactionsAreDropped() {
        var neither = GChatBridgeCore.Reaction()
        neither.count = 1
        let mapped = ReactionMapping.reactions([
            neither,
            unicode("", count: 1),
            unicode("👍", count: 0),
            custom(uuid: "", shortcode: ":x:", count: 1),
            unicode("🎉", count: 1)
        ])
        #expect(mapped == [ChatKit.Reaction(emoji: "🎉", count: 1)])
    }

    @Test func domainMessageCarriesTheReactions() throws {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "m-1"
        message.id.parentID.topicID.topicID = "t-1"
        message.id.parentID.topicID.groupID.spaceID.spaceID = "s-1"
        message.creator.userID.id = "u-1"
        message.createTime = 1_700_000_000_000_000
        message.reactions = [unicode("👍", count: 2)]
        let mapped = try #require(ChannelEventMapping.domainMessage(message))
        #expect(mapped.reactions == [ChatKit.Reaction(emoji: "👍", count: 2)])
    }
}
