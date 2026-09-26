import ChatKit
import Testing
@testable import DesignSystem

struct MentionHighlightTests {
    private let me = Member.ID("u-me")

    private func texts(_ text: String, _ mentions: [Mention]) -> [String] {
        MentionHighlight.ranges(in: text, mentions: mentions, me: me).map { String(text[$0.range]) }
    }

    @Test func aSpanOnAnAtIsHighlightedAndMarkedMineWhenItNamesMeOrAll() {
        let ranges = MentionHighlight.ranges(
            in: "@Me and @Alice", mentions: [
                Mention(target: .user(me), start: 0, length: 3),
                Mention(target: .user(Member.ID("u-a")), start: 8, length: 6)
            ], me: me
        )
        #expect(ranges.map(\.isMe) == [true, false])
        #expect(texts("@all hands", [Mention(target: .all, start: 0, length: 4)]) == ["@all"])
    }

    /// Review Focus 3: two UTF-16 units of emoji, then a space. The UTF-16
    /// offset (3) lands on "@"; a Character offset (2) lands on the space and
    /// is dropped rather than drawn in the wrong place.
    @Test func anEmojiBeforeTheMentionSeparatesTheTwoUnits() {
        let text = "👋 @Alice hi"
        #expect(texts(text, [Mention(target: .user(Member.ID("u-a")), start: 3, length: 6)]) == ["@Alice"])
        #expect(texts(text, [Mention(target: .user(Member.ID("u-a")), start: 2, length: 6)]).isEmpty)
    }

    @Test func aSpanOutsideTheTextOrNotOnAnAtIsDropped() {
        #expect(texts("hi @A", [Mention(target: .all, start: 3, length: 9)]).isEmpty)
        #expect(texts("hi @A", [Mention(target: .all, start: -1, length: 2)]).isEmpty)
        #expect(texts("hi @A", [Mention(target: .all, start: 0, length: 2)]).isEmpty)
        #expect(texts("hi @A", [Mention(target: .all, start: 3, length: 0)]).isEmpty)
    }

    @Test func aMentionOfMeGetsABackgroundAndInMyOwnBubbleOnlyBold() {
        let mention = [Mention(target: .user(me), start: 0, length: 3)]
        let theirs = MentionHighlight.attributed("@Me hi", mentions: mention, me: me, inOwnBubble: false)
        let mine = MentionHighlight.attributed("@Me hi", mentions: mention, me: me, inOwnBubble: true)
        #expect(theirs.runs.first?.backgroundColor != nil)
        #expect(mine.runs.first?.backgroundColor == nil)
    }
}
