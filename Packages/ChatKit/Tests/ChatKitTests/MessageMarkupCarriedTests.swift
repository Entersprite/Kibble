import Foundation
import Testing
@testable import ChatKit

/// Spans a composer sends as spans rather than as markup: they move with the
/// markup read around them, carried code is never read as markup, and a sent
/// message comes back for editing as the same spans over the same text.
struct MessageMarkupCarriedTests {
    private static func message(
        _ text: String,
        _ formats: [MessageFormat] = [],
        mentions: [Mention] = []
    ) -> ComposedMessage {
        ComposedMessage(text: text, mentions: mentions, content: MessageContent(formatting: formats))
    }

    @Test func carriedSpansMoveWithTheMarkupReadAroundThem() {
        // "**a** 😀 b": the italic over "b" is after a removed "**…**" pair
        // and a two-unit emoji.
        let text = "**a** 😀 b"
        let italic = MessageFormat(
            style: "italic",
            start: (text as NSString).range(of: "b").location,
            length: 1
        )
        let parsed = MessageMarkup.parse(Self.message(text, [italic]))
        #expect(parsed.text == "a 😀 b")
        #expect(parsed.content?.formatting == [
            MessageFormat(style: "bold", start: 0, length: 1),
            MessageFormat(style: "italic", start: 5, length: 1)
        ])
    }

    @Test func aCarriedSpanAroundMarkupKeepsOnlyTheText() {
        let parsed = MessageMarkup.parse(Self.message(
            "x **y** z",
            [MessageFormat(style: "underline", start: 0, length: 9)]
        ))
        #expect(parsed.text == "x y z")
        #expect(parsed.content?.formatting
            .contains(MessageFormat(style: "underline", start: 0, length: 5)) == true)
        #expect(parsed.content?.formatting
            .contains(MessageFormat(style: "bold", start: 2, length: 1)) == true)
    }

    @Test func carriedCodeIsNeverReadAsMarkup() {
        let code = "def f(*args, **kwargs): return a_b_c \\ `x`"
        for style in ["code", "codeBlock"] {
            let span = MessageFormat(style: style, start: 4, length: code.utf16.count)
            let parsed = MessageMarkup.parse(Self.message("see " + code + " *now*", [span]))
            #expect(parsed.text == "see " + code + " now")
            #expect(parsed.content?.formatting.contains(span) == true)
            #expect(parsed.content?.formatting
                .contains(MessageFormat(style: "italic", start: 5 + code.utf16.count, length: 3)) == true)
        }
    }

    /// A list item typed at the start of a carried code line is code.
    @Test func carriedCodeStartingALineIsNotAListItem() {
        let parsed = MessageMarkup.parse(Self.message("- not a list", [
            MessageFormat(style: "codeBlock", start: 0, length: 12)
        ]))
        #expect(parsed.text == "- not a list")
        #expect(parsed.content?.formatting == [MessageFormat(style: "codeBlock", start: 0, length: 12)])
    }

    @Test func aMentionInsideACarriedSpanKeepsItsAddress() {
        let text = "hi @Jane *x*"
        let mention = Mention(target: .user(Member.ID("jane")), start: 3, length: 5)
        let parsed = MessageMarkup.parse(Self.message(
            text,
            [MessageFormat(style: "bold", start: 0, length: 8)],
            mentions: [mention]
        ))
        #expect(parsed.text == "hi @Jane x")
        #expect(parsed.mentions == [mention])
        #expect(parsed.content?.formatting
            .contains(MessageFormat(style: "bold", start: 0, length: 8)) == true)
    }

    // MARK: - Editing without markup

    private static let shown: Set<String> = [
        "bold",
        "italic",
        "underline",
        "strikethrough",
        "code",
        "codeBlock"
    ]

    private static func roundTrips(_ original: ComposedMessage) -> ComposedMessage {
        let editable = MessageMarkup.editable(original, showing: shown)
        let parsed = MessageMarkup.parse(editable)
        #expect(parsed.text == original.text)
        #expect(parsed.mentions == original.mentions)
        #expect(MessageMarkup.merged(parsed.content?.formatting ?? [])
            == MessageMarkup.merged(original.content?.formatting ?? []))
        return editable
    }

    @Test func ordinaryTextComesBackWithItsSpansAndNoMarkup() {
        let text = "Hello 😀 @Reader, see you at 5"
        let mention = Mention(target: .user(Member.ID("reader")), start: 9, length: 7)
        let formats = [
            MessageFormat(style: "bold", start: 0, length: 5),
            MessageFormat(style: "italic", start: 6, length: 10),
            MessageFormat(style: "strikethrough", start: 18, length: 3),
            MessageFormat(style: "code", start: 29, length: 1)
        ]
        let editable = Self.roundTrips(Self.message(text, formats, mentions: [mention]))
        #expect(editable.text == text)
        #expect(editable.mentions == [mention])
        #expect(MessageMarkup.merged(editable.content?.formatting ?? []) == MessageMarkup.merged(formats))
    }

    /// Text that would read as markup is escaped, so saving an edit cannot
    /// turn a sent `*literal*` into italics.
    @Test func textThatWouldReadAsMarkupIsEscaped() {
        let editable = Self.roundTrips(Self.message(
            "a *literal* b",
            [MessageFormat(style: "bold", start: 0, length: 1)]
        ))
        #expect(editable.text == "a \\*literal\\* b")
        #expect(editable.content?.formatting == [MessageFormat(style: "bold", start: 0, length: 1)])
    }

    @Test func aLoneMarkerCharacterNeedsNoEscape() {
        #expect(Self.roundTrips(Self.message("5 * 3 = 15, snake_case, C:\\Users")).text
            == "5 * 3 = 15, snake_case, C:\\Users")
    }

    @Test func listItemsComeBackAsTypedItemsWithTheirSpansAfterThem() {
        let text = "one\ntwo"
        let editable = Self.roundTrips(Self.message(text, [
            MessageFormat(style: "bulletItem", start: 0, length: 3),
            MessageFormat(style: "bulletItem", start: 4, length: 3),
            MessageFormat(style: "bold", start: 4, length: 3)
        ]))
        #expect(editable.text == "- one\n- two")
        #expect(editable.content?.formatting == [MessageFormat(style: "bold", start: 8, length: 3)])
    }

    @Test func codeComesBackVerbatim() {
        let text = "run `a*b*c` now"
        let editable = Self.roundTrips(Self.message(text, [
            MessageFormat(style: "code", start: 4, length: 7),
            MessageFormat(style: "codeBlock", start: 0, length: 3)
        ]))
        #expect(editable.text == text)
    }

    @Test func mergingJoinsTouchingAndOverlappingSpansOfOneStyle() {
        #expect(MessageMarkup.merged([
            MessageFormat(style: "bold", start: 4, length: 2),
            MessageFormat(style: "bold", start: 0, length: 2),
            MessageFormat(style: "bold", start: 2, length: 3),
            MessageFormat(style: "italic", start: 9, length: 1),
            MessageFormat(style: "bulletItem", start: 0, length: 3),
            MessageFormat(style: "bulletItem", start: 3, length: 3)
        ]) == [
            MessageFormat(style: "bold", start: 0, length: 6),
            MessageFormat(style: "bulletItem", start: 0, length: 3),
            MessageFormat(style: "bulletItem", start: 3, length: 3),
            MessageFormat(style: "italic", start: 9, length: 1)
        ])
    }
}
