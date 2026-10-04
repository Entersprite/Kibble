import Foundation
import Testing
@testable import ChatKit

/// `[Reaction].applying`: the one fold the optimistic write and the fixture
/// share, so they cannot disagree.
struct ReactionFoldTests {
    private let thumbs = ReactionChoice(emoji: "👍")
    private let parrot = ReactionChoice(customEmoji: CustomEmojiRef(id: "e-1", shortcode: ":parrot:"))

    @Test func addingANewEmojiAppendsItAsMine() {
        let result = [Reaction(emoji: "🎉", count: 1)].applying(thumbs, add: true)
        #expect(result == [Reaction(emoji: "🎉", count: 1), Reaction(emoji: "👍", count: 1, includesMe: true)])
    }

    @Test func addingToSomeoneElsesCountsMeIn() {
        let result = [Reaction(emoji: "👍", count: 2)].applying(thumbs, add: true)
        #expect(result == [Reaction(emoji: "👍", count: 3, includesMe: true)])
    }

    @Test func addingWhenAlreadyMineChangesNothing() {
        let reactions = [Reaction(emoji: "👍", count: 2, includesMe: true)]
        #expect(reactions.applying(thumbs, add: true) == reactions)
    }

    @Test func removingWhenNotMineChangesNothing() {
        let reactions = [Reaction(emoji: "👍", count: 2)]
        #expect(reactions.applying(thumbs, add: false) == reactions)
    }

    @Test func removingMyOnlyReactionDropsTheEntry() {
        let result = [Reaction(emoji: "👍", count: 1, includesMe: true)].applying(thumbs, add: false)
        #expect(result.isEmpty)
    }

    @Test func removingMineLeavesTheOthers() {
        let result = [Reaction(emoji: "👍", count: 3, includesMe: true)].applying(thumbs, add: false)
        #expect(result == [Reaction(emoji: "👍", count: 2)])
    }

    /// Someone else, as the fixture's scripted reactions are: their add always
    /// counts and never makes it mine.
    @Test func anotherPersonsAddAlwaysCounts() {
        let reactions = [Reaction(emoji: "👍", count: 1, includesMe: true)]
        let result = reactions.applying(thumbs, add: true, isLocalUser: false)
        #expect(result == [Reaction(emoji: "👍", count: 2, includesMe: true)])
    }

    /// A custom emoji is matched by id, never by its shortcode text: two
    /// workspaces' `:parrot:` are different emoji.
    @Test func customEmojiMatchByIDNotText() {
        let other = Reaction(
            emoji: ":parrot:",
            count: 1,
            customEmoji: CustomEmojiRef(id: "e-2", shortcode: ":parrot:")
        )
        let result = [other].applying(parrot, add: true)
        #expect(result.count == 2)
        #expect(result[1].customEmoji?.id == "e-1")
        #expect(result[1].includesMe)
    }

    @Test func aUnicodeEmojiNeverMatchesACustomOneWithTheSameText() {
        let custom = Reaction(emoji: "👍", count: 1, customEmoji: CustomEmojiRef(id: "👍", shortcode: "👍"))
        #expect([custom].applying(thumbs, add: true).count == 2)
    }

    @Test(arguments: [("parrot", ":parrot:"), (":parrot:", ":parrot:"), ("", "::")])
    func displayTextIsColonWrappedOnce(_ shortcode: String, _ expected: String) {
        #expect(CustomEmojiRef(id: "e", shortcode: shortcode).displayText == expected)
    }

    @Test func aCustomChoiceShowsItsShortcode() {
        #expect(parrot.emoji == ":parrot:")
        #expect(Reaction(emoji: ":parrot:", count: 1, customEmoji: parrot.customEmoji).choice == parrot)
    }
}
