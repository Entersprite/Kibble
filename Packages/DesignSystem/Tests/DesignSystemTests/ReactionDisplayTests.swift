import ChatKit
import Testing
@testable import DesignSystem

struct ReactionDisplayTests {
    @Test func aReactionOfMineSaysSo() {
        let label = ReactionDisplay.accessibilityLabel(for: Reaction(emoji: "👍", count: 2, includesMe: true))
        #expect(label == "👍, 2, you reacted")
    }

    @Test func someoneElsesReactionIsTheEmojiAndTheCount() {
        #expect(ReactionDisplay.accessibilityLabel(for: Reaction(emoji: "🎉", count: 1)) == "🎉, 1")
    }

    @Test func aCustomEmojiIsReadByItsShortcode() {
        let parrot = Reaction(
            emoji: ":parrot:",
            count: 3,
            customEmoji: CustomEmojiRef(id: "e-1", shortcode: ":parrot:")
        )
        #expect(ReactionDisplay.accessibilityLabel(for: parrot) == ":parrot:, 3")
    }

    @Test func theQuickSetIsSixDistinctEmoji() {
        #expect(QuickReactions.defaults == ["👍", "❤️", "😂", "😮", "😢", "🎉"])
    }

    /// Review Focus 5: choosing one already mine removes it.
    @Test func aQuickEmojiAlreadyMineIsRemoved() {
        let mine = [Reaction(emoji: "👍", count: 2, includesMe: true)]
        #expect(!QuickReactions.adds(ReactionChoice(emoji: "👍"), to: mine))
        #expect(QuickReactions.adds(ReactionChoice(emoji: "🎉"), to: mine))
        #expect(QuickReactions.adds(ReactionChoice(emoji: "👍"), to: [Reaction(emoji: "👍", count: 2)]))
    }
}
