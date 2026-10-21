import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Formatting in the draft, kept as runs the way tokens are kept: moved by
/// every edit, chosen the way Notes chooses them, and sent as the same
/// spans Google receives.
struct ComposerDraftRunsTests {
    typealias Run = ComposerDraft.Run

    private static func run(_ style: ComposerDraft.Style, _ location: Int, _ length: Int) -> Run {
        Run(style: style, location: location, length: length)
    }

    /// `text` typed, then `style` on over `range`.
    private static func draft(
        _ text: String,
        _ style: ComposerDraft.Style = .bold,
        over range: NSRange? = nil
    ) -> ComposerDraft {
        var draft = ComposerDraft()
        draft.replace(location: 0, length: 0, with: text)
        if let range {
            draft.toggle(style, in: range)
        }
        return draft
    }

    // MARK: - Run maintenance

    @Test func typingInsideARunTakesItsStyle() {
        var draft = Self.draft("hello", over: NSRange(location: 0, length: 5))
        draft.replace(location: 2, length: 0, with: "X")
        #expect(draft.text == "heXllo")
        #expect(draft.runs == [Self.run(.bold, 0, 6)])
    }

    @Test func typingAtTheEndOfARunContinuesIt() {
        var draft = Self.draft("plain bold", over: NSRange(location: 6, length: 4))
        draft.moveCaret(to: 10)
        #expect(draft.typingStyles == [.bold])
        draft.replace(location: 10, length: 0, with: "er")
        #expect(draft.runs == [Self.run(.bold, 6, 6)])
    }

    /// Mid-line, the character before decides: typing just before a bold
    /// word, after a plain letter, is plain, and the word moves.
    @Test func typingBeforeARunMidLineIsPlainAndMovesIt() {
        var draft = Self.draft("ab cd", over: NSRange(location: 3, length: 2))
        draft.replace(location: 3, length: 0, with: "x")
        #expect(draft.text == "ab xcd")
        #expect(draft.runs == [Self.run(.bold, 4, 2)])
    }

    /// At the start of a line, the line's first character decides, as in
    /// AppKit: typing before a bold first word is bold.
    @Test func typingAtTheStartOfALineTakesItsFirstCharactersStyle() {
        var draft = Self.draft("one\ntwo", over: NSRange(location: 4, length: 3))
        draft.moveCaret(to: 4)
        #expect(draft.typingStyles == [.bold])
        draft.replace(location: 4, length: 0, with: "x")
        #expect(draft.runs == [Self.run(.bold, 4, 4)])
        var first = Self.draft("word", over: NSRange(location: 0, length: 4))
        first.moveCaret(to: 0)
        #expect(first.typingStyles == [.bold])
    }

    /// Cmd-B with nothing selected at the end of a bold word: what is typed
    /// next is plain, and the word stays as it was.
    @Test func turningAStyleOffAtTheCaretTypesPlain() {
        var draft = Self.draft("bold", over: NSRange(location: 0, length: 4))
        draft.moveCaret(to: 4)
        let changed = draft.toggle(.bold, in: NSRange(location: 4, length: 0))
        #expect(changed == nil)
        #expect(draft.typingStyles.isEmpty)
        draft.replace(location: 4, length: 0, with: " then plain")
        #expect(draft.runs == [Self.run(.bold, 0, 4)])
        #expect(draft.typingOverride == nil)
    }

    /// Cmd-B, then typing: the typed text is bold, letter after letter, and
    /// no markup goes into the text.
    @Test func turningAStyleOnAtTheCaretTypesStyledText() {
        var draft = Self.draft("say ")
        draft.toggle(.bold, in: NSRange(location: 4, length: 0))
        #expect(draft.typingStyles == [.bold])
        draft.replace(location: 4, length: 0, with: "h")
        draft.replace(location: 5, length: 0, with: "i")
        #expect(draft.text == "say hi")
        #expect(draft.runs == [Self.run(.bold, 4, 2)])
    }

    @Test func movingTheCaretForgetsTheChosenTypingStyle() {
        var draft = Self.draft("abc")
        draft.toggle(.italic, in: NSRange(location: 3, length: 0))
        draft.moveCaret(to: 3)
        #expect(draft.typingStyles == [.italic])
        draft.moveCaret(to: 1)
        draft.moveCaret(to: 3)
        #expect(draft.typingStyles.isEmpty)
    }

    /// "aaBBcc" with bold on "BB" and italic on "Bcc": deleting "Bc" leaves
    /// each run what remains of it, at the right place.
    @Test func deletingAcrossRunBoundariesShrinksEachRun() {
        var draft = Self.draft("aaBBcc", over: NSRange(location: 2, length: 2))
        draft.toggle(.italic, in: NSRange(location: 3, length: 3))
        draft.replace(location: 3, length: 2, with: "")
        #expect(draft.text == "aaBc")
        #expect(draft.runs == [Self.run(.bold, 2, 1), Self.run(.italic, 3, 1)])
    }

    /// Typing over a selection takes its first character's styles, as in a
    /// Mac text view; a token it touches becomes text, and runs after move.
    @Test func replacingASpanOfRunsAndATokenTakesTheFirstCharactersStyles() {
        var draft = ComposerDraft()
        draft.replace(location: 0, length: 0, with: "hi @ja")
        draft.pick(.user(Member.ID("u-1")), name: "Jane")
        draft.replace(location: draft.caret, length: 0, with: "end")
        // "hi @Jane end": bold over "hi @J", underline over "end".
        draft.toggle(.bold, in: NSRange(location: 0, length: 5))
        draft.toggle(.underline, in: NSRange(location: 9, length: 3))
        draft.replace(location: 1, length: 7, with: "ey")
        #expect(draft.text == "hey end")
        #expect(draft.tokens.isEmpty)
        #expect(draft.runs == [Self.run(.bold, 0, 3), Self.run(.underline, 4, 3)])
    }

    /// A rewrite seen only as new text keeps the styles of what it left
    /// alone at each end and brings what it rewrote in plain: "middl"
    /// became "centr", and the "e" the two words share keeps its underline.
    @Test func aWholeTextEditKeepsTheEndsItShares() {
        var draft = Self.draft("Bold middle tail", over: NSRange(location: 0, length: 4))
        draft.toggle(.italic, in: NSRange(location: 12, length: 4))
        draft.toggle(.underline, in: NSRange(location: 5, length: 6))
        draft.edit("Bold centre tail")
        #expect(draft.runs == [Self.run(.bold, 0, 4), Self.run(.underline, 10, 1), Self.run(.italic, 12, 4)])
    }

    // MARK: - Toggling (Notes' rules)

    @Test func aSelectionAllInTheStyleLosesIt() {
        var draft = Self.draft("hello", over: NSRange(location: 0, length: 5))
        let changed = draft.toggle(.bold, in: NSRange(location: 1, length: 3))
        #expect(changed == NSRange(location: 1, length: 3))
        #expect(draft.runs == [Self.run(.bold, 0, 1), Self.run(.bold, 4, 1)])
    }

    @Test func aSelectionPartlyInTheStyleGainsItThroughout() {
        var draft = Self.draft("hello", over: NSRange(location: 0, length: 2))
        draft.toggle(.bold, in: NSRange(location: 1, length: 4))
        #expect(draft.runs == [Self.run(.bold, 0, 5)])
    }

    /// Two bold lines selected together are bold, so Cmd-B takes it off,
    /// although the line break between them was never bold.
    @Test func lineBreaksDoNotDecideWhetherASelectionHasTheStyle() {
        var draft = Self.draft("one\ntwo", over: NSRange(location: 0, length: 3))
        draft.toggle(.bold, in: NSRange(location: 4, length: 3))
        draft.toggle(.bold, in: NSRange(location: 0, length: 7))
        #expect(draft.runs.isEmpty)
    }

    @Test func aCodeBlockTakesTheCaretsWholeLine() {
        var draft = Self.draft("one\ntwo\nthree")
        draft.moveCaret(to: 5)
        let line = draft.toggle(.codeBlock, in: NSRange(location: 5, length: 0))
        #expect(line == NSRange(location: 4, length: 4))
        #expect(draft.runs == [Self.run(.codeBlock, 4, 4)])
        // The next line joins the same block.
        draft.toggle(.codeBlock, in: NSRange(location: 9, length: 1))
        #expect(draft.runs == [Self.run(.codeBlock, 4, 9)])
        // On an empty line it is a typing style.
        var empty = Self.draft("one\n")
        let typing = empty.toggle(.codeBlock, in: NSRange(location: 4, length: 0))
        #expect(typing == nil)
        #expect(empty.typingStyles == [.codeBlock])
    }

    @Test func activeStylesAreTheCaretsOrThoseTheWholeSelectionHas() {
        var draft = Self.draft("hello", over: NSRange(location: 0, length: 5))
        draft.toggle(.italic, in: NSRange(location: 2, length: 3))
        #expect(draft.activeStyles(in: NSRange(location: 0, length: 5)) == [.bold])
        #expect(draft.activeStyles(in: NSRange(location: 2, length: 2)) == [.bold, .italic])
        draft.moveCaret(to: 5)
        #expect(draft.activeStyles(in: NSRange(location: 5, length: 0)) == [.bold, .italic])
    }

    // MARK: - Sending

    @Test func runsAreSentInTheTrimmedTextsUTF16Offsets() {
        var draft = ComposerDraft()
        draft.replace(location: 0, length: 0, with: "  👋🏽 @ja")
        draft.pick(.user(Member.ID("u-1")), name: "Jane")
        draft.replace(location: draft.caret, length: 0, with: "hi  ")
        // "  👋🏽 @Jane hi  ": the emoji is 4 units; bold on "@Jane", italic on "hi".
        draft.toggle(.bold, in: NSRange(location: 7, length: 5))
        draft.toggle(.italic, in: NSRange(location: 13, length: 2))
        let sent = draft.composed(formatting: true)
        #expect(sent.text == "👋🏽 @Jane hi")
        #expect(sent.mentions == [Mention(target: .user(Member.ID("u-1")), start: 5, length: 5)])
        #expect(sent.content?.formatting == [
            MessageFormat(style: "bold", start: 5, length: 5),
            MessageFormat(style: "italic", start: 11, length: 2)
        ])
    }

    @Test func aRunCutByTheTrimIsSentCut() {
        let draft = Self.draft("  hi  ", over: NSRange(location: 0, length: 6))
        #expect(draft.composed(formatting: true).content?.formatting == [MessageFormat(
            style: "bold",
            start: 0,
            length: 2
        )])
    }

    /// Markup typed by hand still works beside the runs, at the right
    /// offsets once the markers are gone, and touching spans of a style
    /// are sent as one.
    @Test func typedMarkupAndRunsCombine() {
        var draft = Self.draft("**a** b c", .italic, over: NSRange(location: 6, length: 1))
        draft.toggle(.bold, in: NSRange(location: 5, length: 3))
        let sent = draft.composed(formatting: true)
        #expect(sent.text == "a b c")
        // The typed bold "a" and the run's bold " b " touch once the
        // markers are gone, and go as one span.
        #expect(sent.content?.formatting == [
            MessageFormat(style: "bold", start: 0, length: 4),
            MessageFormat(style: "italic", start: 2, length: 1)
        ])
    }

    /// Code is sent as typed: no asterisk or underscore in it is markup.
    @Test func codeIsSentVerbatim() {
        let draft = Self.draft("call f(*args, **kw)", .code, over: NSRange(location: 5, length: 14))
        let sent = draft.composed(formatting: true)
        #expect(sent.text == "call f(*args, **kw)")
        #expect(sent.content?.formatting == [MessageFormat(style: "code", start: 5, length: 14)])
    }

    @Test func aCodeBlockIsSentWithoutTheLineBreaksAtItsEnds() {
        var draft = Self.draft("look\nlet x = 1\nnice")
        draft.toggle(.codeBlock, in: NSRange(location: 6, length: 0))
        #expect(draft.runs == [Self.run(.codeBlock, 5, 10)])
        #expect(draft.composed(formatting: true).content?.formatting == [
            MessageFormat(style: "codeBlock", start: 5, length: 9)
        ])
    }

    /// A style that changes inside a character (an accent typed with bold
    /// off) is sent over the whole character: a span inside one is refused.
    @Test func aSpanIsWidenedToWholeCharacters() throws {
        var draft = Self.draft("cafe", over: NSRange(location: 0, length: 4))
        draft.toggle(.bold, in: NSRange(location: 4, length: 0))
        draft.replace(location: 4, length: 0, with: "\u{301}")
        let sent = draft.composed(formatting: true)
        #expect(sent.content?.formatting == [MessageFormat(style: "bold", start: 0, length: 5)])
        let content = try #require(sent.content)
        #expect(throws: Never.self) {
            try content.validate(
                text: sent.text, conversation: Conversation.ID("c"),
                capabilities: Capabilities(extendedFlags: ["formattedMessages"])
            )
        }
    }

    @Test func withoutFormattingNoSpansAreSent() {
        let draft = Self.draft("hello", over: NSRange(location: 0, length: 5))
        #expect(draft.composed().content == nil)
    }

    // MARK: - Editing and restoring

    private static let formatted = ComposedMessage(
        text: "Hello 😀 @Jane, run x*y now",
        mentions: [Mention(target: .user(Member.ID("u-jane")), start: 9, length: 5)],
        content: MessageContent(formatting: [
            MessageFormat(style: "bold", start: 0, length: 5),
            MessageFormat(style: "italic", start: 6, length: 8),
            MessageFormat(style: "underline", start: 16, length: 3),
            MessageFormat(style: "strikethrough", start: 24, length: 3),
            MessageFormat(style: "code", start: 20, length: 3)
        ])
    )

    /// An edit loads the formatting as runs over the words as sent, with no
    /// markup in the field, and saving unchanged sends the same spans.
    @Test func editingLoadsFormattingAsRunsAndSavesItUnchanged() throws {
        var draft = ComposerDraft()
        draft.beginEditing(Message.ID("m"), with: Self.formatted, formatting: true)
        #expect(draft.text == Self.formatted.text)
        #expect(draft.runs.count == 5)
        #expect(draft.tokens.count == 1)
        let result = draft.endEditing(formatting: true)
        let ended = try #require(result)
        #expect(ended.message.text == Self.formatted.text)
        #expect(ended.message.mentions == Self.formatted.mentions)
        #expect(ended.message.content?.formatting
            == MessageMarkup.merged(Self.formatted.content?.formatting ?? []))
    }

    @Test func aRestoredFailedSendComesBackStyled() {
        var draft = ComposerDraft()
        let adopted = draft.adopt(Self.formatted, formatting: true)
        #expect(adopted)
        #expect(draft.text == Self.formatted.text)
        #expect(draft.composed(formatting: true).content?.formatting
            == MessageMarkup.merged(Self.formatted.content?.formatting ?? []))
    }

    /// A list keeps its typed `- ` and the styles inside it are runs.
    @Test func aListComesBackTypedWithItsStylesAsRuns() {
        var draft = ComposerDraft()
        draft.beginEditing(Message.ID("m"), with: ComposedMessage(
            text: "one\ntwo",
            content: MessageContent(formatting: [
                MessageFormat(style: "bulletItem", start: 0, length: 3),
                MessageFormat(style: "bulletItem", start: 4, length: 3),
                MessageFormat(style: "bold", start: 4, length: 3)
            ])
        ), formatting: true)
        #expect(draft.text == "- one\n- two")
        #expect(draft.runs == [Self.run(.bold, 8, 3)])
    }

    /// A restore over newer text goes first, and the newer text's runs move
    /// after it.
    @Test func aRestoreGoesFirstAndMovesTheNewerRuns() {
        var draft = Self.draft("newer", over: NSRange(location: 0, length: 5))
        _ = draft.adopt(ComposedMessage(
            text: "old",
            content: MessageContent(formatting: [MessageFormat(style: "italic", start: 0, length: 3)])
        ), formatting: true)
        #expect(draft.text == "old\nnewer")
        #expect(draft.runs == [Self.run(.italic, 0, 3), Self.run(.bold, 4, 5)])
    }

    /// The draft an edit puts aside comes back with its runs.
    @Test func theSetAsideDraftKeepsItsRuns() {
        var draft = Self.draft("mine", .underline, over: NSRange(location: 0, length: 4))
        draft.beginEditing(Message.ID("m"), with: ComposedMessage(text: "sent"), formatting: true)
        #expect(draft.runs.isEmpty)
        _ = draft.adopt(ComposedMessage(text: "failed"), formatting: true)
        _ = draft.endEditing(formatting: true)
        #expect(draft.text == "failed\nmine")
        #expect(draft.runs == [Self.run(.underline, 7, 4)])
    }

    // MARK: - Saved drafts

    @Test func aSavedDraftKeepsItsRuns() {
        let draft = Self.draft("keep this", .strikethrough, over: NSRange(location: 5, length: 4))
        let snapshot = draft.snapshot(at: ComposerDraftAddress(conversation: Conversation.ID("c")))
        #expect(snapshot.formatting == [MessageFormat(style: "strikethrough", start: 5, length: 4)])
        #expect(ComposerDraft(snapshot: snapshot).runs == draft.runs)
    }

    /// A draft saved before the composer drew styles has no formatting key.
    @Test func aDraftSavedBeforeFormattingStillLoads() throws {
        let json = #"{"conversation":"c","text":"plain","mentions":[],"caret":2}"#
        let snapshot = try JSONDecoder().decode(ComposerSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.formatting.isEmpty)
        let draft = ComposerDraft(snapshot: snapshot)
        #expect(draft.text == "plain")
        #expect(draft.runs.isEmpty)
        #expect(draft.caret == 2)
        // And an unformatted draft is written exactly as before.
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try !String(decoding: encoded, as: UTF8.self).contains("formatting"))
    }
}
