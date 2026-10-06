import ChatKit
import Testing
@testable import DesignSystem

/// The composer's draft, and the one decision about it worth testing.
///
/// A value type rather than a test against `Composer`'s own `@State`: this
/// package's tests drive decisions, not views - `ConnectionBanner`'s
/// `offersReconnect(for:)` and `SidebarSections` are the same shape. A
/// `@State String` inside a `View` is not reachable from a test, and pretending
/// otherwise would mean asserting on a copy of the logic rather than on the
/// logic.
struct ComposerDraftTests {
    /// The ordinary case, on every redraw where nothing failed.
    @Test func noRestoreValueLeavesTheDraftAlone() {
        var draft = ComposerDraft()
        draft.edit("half-typed")

        #expect(draft.adopt(nil) == false)
        #expect(draft.text == "half-typed")
    }

    @Test func aRestoreValueIsAdoptedAndReported() {
        var draft = ComposerDraft()

        #expect(draft.adopt(ComposedMessage(text: "came back")) == true)
        #expect(draft.text == "came back")
    }

    /// **The one that matters.** The host clears its own copy after adopting,
    /// but a redraw can arrive with the same value still in hand - and
    /// re-adopting it would overwrite whatever the user has typed since.
    @Test func theSameValueIsNotAdoptedTwice() {
        var draft = ComposerDraft()
        #expect(draft.adopt(ComposedMessage(text: "came back")) == true)
        draft.edit("and then I kept typing")

        #expect(draft.adopt(ComposedMessage(text: "came back")) == false)
        #expect(draft.text == "and then I kept typing")
    }

    /// Going back to `nil` forgets what was adopted, so the identical text
    /// failing a second time is offered again rather than silently dropped.
    @Test func aNilResetsSoTheSameTextCanFailAgain() {
        var draft = ComposerDraft()
        #expect(draft.adopt(ComposedMessage(text: "same words")) == true)
        #expect(draft.adopt(nil) == false)

        #expect(draft.adopt(ComposedMessage(text: "same words")) == true)
        #expect(draft.text == "same words")
    }

    @Test func anEmptyRestoreValueIsNotAdopted() {
        var draft = ComposerDraft()
        draft.edit("mine")

        #expect(draft.adopt(ComposedMessage(text: "")) == false)
        #expect(draft.text == "mine")
    }

    /// A failed upload's caption can come back minutes after Send, over the
    /// next message being typed (session 50's review, Important 1).
    @Test func aRestoreNeverOverwritesWhatWasTypedSince() {
        var draft = ComposerDraft()
        draft.edit("the next message")
        #expect(draft.adopt(ComposedMessage(text: "see attached")) == true)
        #expect(draft.text == "see attached\nthe next message")
    }

    // MARK: - Mention tokens (mention composer spec §3.4)

    private static let jane = Mention.Target.user(Member.ID("u-jane"))

    private func typed(_ text: String) -> ComposerDraft {
        var draft = ComposerDraft()
        draft.replace(location: 0, length: 0, with: text)
        return draft
    }

    @Test func anAtAtTheStartOpensAQuery() {
        #expect(typed("@ja").activeQuery == ComposerDraft.Query(location: 0, text: "ja"))
    }

    @Test func anAtAfterWhitespaceOrANewlineOpensAQuery() {
        #expect(typed("hi @ja").activeQuery?.location == 3)
        #expect(typed("hi\n@ja").activeQuery?.location == 3)
    }

    @Test func anAtInsideAWordDoesNot() {
        #expect(typed("a@b.com").activeQuery == nil)
    }

    @Test func aQueryMayContainSpacesButNotStartWithOne() {
        #expect(typed("@Jane Do").activeQuery?.text == "Jane Do")
        #expect(typed("@ Jane").activeQuery == nil)
    }

    @Test func movingTheCaretOutOfTheQueryClosesIt() {
        var draft = typed("hi @ja")
        draft.moveCaret(to: 1)
        #expect(draft.activeQuery == nil)
        draft.moveCaret(to: 3)
        #expect(draft.activeQuery == nil)
    }

    @Test func pickingReplacesTheQueryWithANameAndASpace() {
        var draft = typed("hi @ja")
        draft.pick(Self.jane, name: "Jane Doe")
        #expect(draft.text == "hi @Jane Doe ")
        #expect(draft.tokens == [ComposerDraft.Token(
            location: 3,
            length: 9,
            target: Self.jane,
            name: "Jane Doe"
        )])
        #expect(draft.caret == 13)
        #expect(draft.activeQuery == nil)
    }

    @Test func typingAfterATokenKeepsIt() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        draft.replace(location: draft.caret, length: 0, with: "hello")
        #expect(draft.tokens.count == 1)
        #expect(draft.composed().mentions == [Mention(target: Self.jane, start: 0, length: 5)])
    }

    @Test func typingBeforeATokenShiftsIt() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        draft.replace(location: 0, length: 0, with: "hey ")
        #expect(draft.tokens.first?.location == 4)
    }

    @Test func typingInsideATokenTurnsItIntoText() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        draft.replace(location: 2, length: 0, with: "x")
        #expect(draft.tokens.isEmpty)
        #expect(draft.composed().mentions.isEmpty)
    }

    @Test func pastingOverATokenDropsIt() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        draft.replace(location: 0, length: 3, with: "pasted")
        #expect(draft.tokens.isEmpty)
    }

    @Test func theTokenEndingAtTheCaretIsFoundForBackspace() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        #expect(draft.token(endingAt: 5)?.target == Self.jane)
        #expect(draft.token(endingAt: 6) == nil)
        #expect(draft.token(endingAt: 3) == nil)
    }

    @Test func anEmojiBeforeTheMentionCountsUTF16() {
        var draft = typed("👋🏽 @ja")
        draft.pick(Self.jane, name: "Jane")
        // 👋🏽 is 4 UTF-16 units, then a space: the @ is at 5 (findings.md §41.1).
        #expect(draft.composed().mentions == [Mention(target: Self.jane, start: 5, length: 5)])
    }

    @Test func trimmingShiftsTheSpans() {
        var draft = typed("  \n@ja")
        draft.pick(Self.jane, name: "Jane")
        let message = draft.composed()
        #expect(message.text == "@Jane")
        #expect(message.mentions == [Mention(target: Self.jane, start: 0, length: 5)])
    }

    @Test func aWholeTextEditKeepsOnlyTokensThatStillRead() {
        var draft = typed("@ja")
        draft.pick(Self.jane, name: "Jane")
        draft.edit("@Jane hi")
        #expect(draft.tokens.count == 1)
        draft.edit("@Jan hi")
        #expect(draft.tokens.isEmpty)
    }

    @Test func aRestoredDraftKeepsItsMentions() {
        var draft = ComposerDraft()
        let restored = ComposedMessage(
            text: "@Jane hi",
            mentions: [Mention(target: Self.jane, start: 0, length: 5)]
        )
        #expect(draft.adopt(restored) == true)
        #expect(draft.composed() == restored)
    }

    @Test func aRestoredDraftGoesBeforeNewerTextAndShiftsItsTokens() {
        var draft = typed("@bo")
        draft.pick(.user(Member.ID("u-bo")), name: "Bo")
        let restored = ComposedMessage(
            text: "@Jane",
            mentions: [Mention(target: Self.jane, start: 0, length: 5)]
        )
        #expect(draft.adopt(restored) == true)
        #expect(draft.text == "@Jane\n@Bo ")
        #expect(draft.composed().mentions == [
            Mention(target: Self.jane, start: 0, length: 5),
            Mention(target: .user(Member.ID("u-bo")), start: 6, length: 3)
        ])
    }
}
