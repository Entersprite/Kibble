import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `APIProbeReport.mentionShapes(_:)` and `mentionShapesLines(_:)` - the
/// counts the owner's staged probe run will read to settle the mentions
/// spec's two `[Verify]`s: whether `list_topics` pages carry annotations at
/// all, and which unit a span's `start_index` counts in.
///
/// **Fixtures built from the vendored proto's field numbers, not from a
/// capture** - see `MentionFixture`. Both functions are pure, so every case
/// is an invented message with no network and no account.
///
/// The text is written with escapes so no editor can normalise it:
/// `"\u{1F44B}\u{1F3FD} @A"` is a waving hand and a skin-tone modifier - two
/// scalars, four UTF-16 units, one Character - then a space, so "@" sits at
/// UTF-16 offset 5, scalar offset 3 and Character offset 2. A span at any one
/// of those lands on "@" under that reading and no other.
struct MentionShapesTests {
    private typealias Fixture = MentionFixture

    private let wave = "\u{1F44B}\u{1F3FD} @A"

    /// Ruling 8's real shape, where most offsets resolve under all three
    /// readings, just to different characters. "@" is UTF-16 5, scalar 3 and
    /// Character 2. UTF-16 5 reads scalar 5 as "l" and Character 5 as "e";
    /// UTF-16 6 is "A", scalar 6 "e", Character 6 "x". UTF-16 3 and 2 fall
    /// inside the emoji and resolve to no Character, so the scalar-3 and
    /// Character-2 cases each have one nil reading.
    private let waveAlex = "\u{1F44B}\u{1F3FD} @Alex test"

    private func shapes(text: String, spanAt start: Int32, length: Int32 = 2) -> MentionShapes {
        APIProbeReport.mentionShapes([
            Fixture.reply(
                text: text,
                annotations: [Fixture.mention(.mention, user: "u-2", start: start, length: length)]
            )
        ])
    }

    // MARK: - The unit a span counts in

    @Test func aSpanAtTheUTF16OffsetLandsOnlyUnderUTF16() {
        let counted = shapes(text: wave, spanAt: 5)
        #expect(counted.spans == 1)
        #expect(counted.spansInRange == 1)
        #expect(counted.spansAtUTF16 == 1)
        #expect(counted.spansAtScalar == 0)
        #expect(counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 1)
    }

    @Test func aSpanAtTheScalarOffsetLandsOnlyUnderScalars() {
        let counted = shapes(text: wave, spanAt: 3)
        #expect(counted.spansAtScalar == 1)
        #expect(counted.spansAtUTF16 == 0)
        #expect(counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 1)
    }

    @Test func aSpanAtTheCharacterOffsetLandsOnlyUnderCharacters() {
        let counted = shapes(text: wave, spanAt: 2)
        #expect(counted.spansAtCharacter == 1)
        #expect(counted.spansAtUTF16 == 0)
        #expect(counted.spansAtScalar == 0)
        #expect(counted.discriminating == 1)
    }

    /// Offset 0 is "@" under every reading, so it says nothing about the unit -
    /// which is exactly what `discriminating` exists to report.
    @Test func aSpanAtOffsetZeroLandsUnderEveryReadingAndDiscriminatesNothing() {
        let counted = shapes(text: "@A hello", spanAt: 0)
        #expect(counted.spansAtUTF16 == 1)
        #expect(counted.spansAtScalar == 1)
        #expect(counted.spansAtCharacter == 1)
        #expect(counted.discriminating == 0)
    }

    @Test func aSpanPastTheEndOfTheTextIsCountedButNotInRange() {
        let counted = shapes(text: wave, spanAt: 6, length: 5)
        #expect(counted.spans == 1)
        #expect(counted.spansInRange == 0)
        #expect(counted.spansAtUTF16 == 0)
        #expect(counted.discriminating == 0)
    }

    /// A negative offset must be reported, never crash the probe on
    /// `index(_:offsetBy:)`. It lands on "@" under no reading, so it says
    /// nothing about the unit and is not discriminating.
    @Test func aNegativeSpanResolvesUnderNoReading() {
        let counted = shapes(text: wave, spanAt: -1)
        #expect(counted.spans == 1)
        #expect(counted.spansInRange == 0)
        #expect(counted.spansAtUTF16 + counted.spansAtScalar + counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 0)
    }

    // MARK: - The unit, on a text where the readings name different characters

    @Test func onRealShapeTextTheUTF16OffsetLandsOnlyUnderUTF16() {
        let counted = shapes(text: waveAlex, spanAt: 5, length: 5)
        #expect(counted.spansAtUTF16 == 1)
        #expect(counted.spansAtScalar == 0)
        #expect(counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 1)
    }

    @Test func onRealShapeTextTheScalarOffsetLandsOnlyUnderScalars() {
        let counted = shapes(text: waveAlex, spanAt: 3, length: 5)
        #expect(counted.spansAtScalar == 1)
        #expect(counted.spansAtUTF16 == 0)
        #expect(counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 1)
    }

    @Test func onRealShapeTextTheCharacterOffsetLandsOnlyUnderCharacters() {
        let counted = shapes(text: waveAlex, spanAt: 2, length: 5)
        #expect(counted.spansAtCharacter == 1)
        #expect(counted.spansAtUTF16 == 0)
        #expect(counted.spansAtScalar == 0)
        #expect(counted.discriminating == 1)
    }

    /// Three readings that all resolve, to three different characters, none
    /// of them "@": the readings disagree, but nothing says which is right.
    @Test func readingsThatDisagreeWithoutLandingOnAtDiscriminateNothing() {
        let counted = shapes(text: waveAlex, spanAt: 6, length: 4)
        #expect(counted.spansInRange == 1)
        #expect(counted.spansAtUTF16 + counted.spansAtScalar + counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 0)
    }

    // MARK: - Whether annotations arrive at all

    @Test func aMessageWithNoAnnotationsIsCountedAsZeroOfOne() {
        let counted = APIProbeReport.mentionShapes([Fixture.reply()])
        #expect(counted == MentionShapes(messages: 1))
        #expect(APIProbeReport.mentionShapesLines(counted).first == "  messages with annotations: 0/1")
    }

    @Test func typesKindsAndMappedAreCountedPerAnnotation() {
        var link = GChatBridgeCore.Annotation()
        link.type = .url
        let counted = APIProbeReport.mentionShapes([
            Fixture.reply(annotations: [
                Fixture.mention(.mention, user: "u-2", start: 0, length: 5),
                Fixture.mention(.uninvite, user: "u-3", start: 0, length: 5),
                link
            ]),
            Fixture.reply()
        ])
        #expect(counted.messages == 2)
        #expect(counted.withAnnotations == 1)
        #expect(counted.annotationTypes == [1: 1, 6: 2])
        #expect(counted.userMentions == 2)
        #expect(counted.mentionKinds == [2: 1, 3: 1])
        #expect(counted.mentionKindsAbsent == 0)
        #expect(counted.mapped == 1)
    }

    // MARK: - The typed-decode trap, in both enums

    /// A kind outside the vendored proto2 enum clears `hasType`. Counting
    /// `metadata.type` anyway would file it under `0` (`unspecified`); the
    /// walk of `unknownFields` is what says what was actually sent.
    @Test func aKindTheProtoCannotNameIsCountedAsAbsentWithItsRawValue() throws {
        let counted = try APIProbeReport.mentionShapes([
            Fixture.reply(annotations: [Fixture.mentionWithRawKind(7, start: 0, length: 5)])
        ])
        #expect(counted.userMentions == 1)
        #expect(counted.mentionKinds.isEmpty)
        #expect(counted.mentionKindsAbsent == 1)
        #expect(counted.mentionKindsRaw == [7: 1])
        #expect(counted.mapped == 0)
    }

    /// The same trap one level up: an `AnnotationType` the vendored enum does
    /// not name would otherwise be counted as `0` (`ANNOTATION_TYPE_UNKNOWN`).
    @Test func anAnnotationTypeTheProtoCannotNameIsCountedByItsRawValue() throws {
        var bytes: Data = try GChatBridgeCore.Annotation().serializedBytes()
        bytes.append(contentsOf: [0x08, 99]) // field 1, wire type 0, value 99
        let unnamed = try GChatBridgeCore.Annotation(serializedBytes: bytes)
        #expect(!unnamed.hasType) // positive control on the fixture
        let counted = APIProbeReport.mentionShapes([Fixture.reply(annotations: [unnamed])])
        #expect(counted.annotationTypes == [99: 1])
        #expect(counted.userMentions == 0)
    }

    // MARK: - A USER_MENTION with no metadata at all

    /// `annotation.userMentionMetadata` hands back a default
    /// `UserMentionMetadata()` when the oneof is unset or holds another case,
    /// which would read as "kind absent". Counted apart instead, so "the kind
    /// was outside the enum" and "there was no metadata" stay two numbers.
    @Test func aUserMentionWithoutMentionMetadataIsCountedApartFromAnAbsentKind() {
        var unset = GChatBridgeCore.Annotation()
        unset.type = .userMention
        unset.startIndex = 0
        unset.length = 1
        var otherCase = unset
        otherCase.urlMetadata = UrlMetadata()
        let counted = APIProbeReport.mentionShapes([Fixture.reply(annotations: [unset, otherCase])])
        #expect(counted.userMentions == 2)
        #expect(counted.metadataAbsent == 2)
        #expect(counted.mentionKindsAbsent == 0)
        #expect(counted.mentionKinds.isEmpty)
        #expect(counted.spans == 2)
        #expect(APIProbeReport.mentionShapesLines(counted).contains(
            "  mention kinds: none; presence absent 0 (raw: none); no metadata 2"
        ))
    }

    // MARK: - The rendered lines

    @Test func theLinesRenderEveryCountAndNothingElse() throws {
        let counted = try APIProbeReport.mentionShapes([
            Fixture.reply(
                id: "SENTINEL-MESSAGE-ID",
                senderID: "SENTINEL-SENDER-ID",
                text: wave,
                annotations: [
                    Fixture.mention(.mention, user: "SENTINEL-MENTIONED-ID", start: 5, length: 2),
                    Fixture.mentionWithRawKind(7, start: 0, length: 1)
                ]
            ),
            Fixture.reply()
        ])
        let lines = APIProbeReport.mentionShapesLines(counted)
        #expect(lines == [
            "  messages with annotations: 1/2",
            "  annotation types: 6×2",
            "  mention kinds: 3×1; presence absent 1 (raw: 7×1); no metadata 0",
            "  USER_MENTION annotations: 2, mapped to mentions: 1",
            "  mention spans: 2, in range (UTF-16) 2; on \"@\": UTF-16 1/2, scalar 0/2, "
                + "Character 0/2; discriminating 1",
            "  span 1: start 5, length 2; text UTF-16 7, scalar 5, Character 4; "
                + "\"@\" at UTF-16 [5], scalar [3], Character [2]",
            "  span 2: start 0, length 1; text UTF-16 7, scalar 5, Character 4; "
                + "\"@\" at UTF-16 [5], scalar [3], Character [2]"
        ])
        let joined = lines.joined(separator: "\n")
        for leak in ["SENTINEL", wave, "@A"] {
            #expect(!joined.contains(leak))
        }
    }

    @Test func emptyTalliesRenderAsNone() {
        let lines = APIProbeReport.mentionShapesLines(MentionShapes())
        #expect(lines.contains("  annotation types: none"))
        #expect(lines.contains("  mention kinds: none; presence absent 0 (raw: none); no metadata 0"))
    }

    // MARK: - Per-span offsets

    /// The brief's own worked example, on `waveAlex`. Its own doc comment
    /// gives "@" at UTF-16 5, scalar 3, Character 2; the counts below are
    /// this test's own arithmetic, not copied from the brief: the emoji plus
    /// modifier is one Character (4 UTF-16 units, 2 scalars), and the eleven
    /// remaining Characters (" @Alex test") are each one UTF-16 unit and one
    /// scalar - 4 + 11 = 15 UTF-16, 2 + 11 = 13 scalar, 1 + 11 = 12 Character.
    /// That matches the brief's 15/13/12 exactly.
    @Test func theSpanLineRendersStartLengthTextCountsAndAtOffsets() {
        let counted = shapes(text: waveAlex, spanAt: 5, length: 5)
        let lines = APIProbeReport.mentionShapesLines(counted)
        #expect(lines.contains(
            "  span 1: start 5, length 5; text UTF-16 15, scalar 13, Character 12; "
                + "\"@\" at UTF-16 [5], scalar [3], Character [2]"
        ))
    }

    @Test func aTextWithNoAtRendersEmptyBracketsUnderEveryReading() {
        let counted = APIProbeReport.mentionShapes([
            Fixture.reply(
                text: "no at signs here",
                annotations: [Fixture.mention(.mention, user: "u-2", start: 0, length: 2)]
            )
        ])
        let lines = APIProbeReport.mentionShapesLines(counted)
        #expect(lines.contains(
            "  span 1: start 0, length 2; text UTF-16 16, scalar 16, Character 16; "
                + "\"@\" at UTF-16 [], scalar [], Character []"
        ))
    }

    @Test func sevenAtsRenderFiveOffsetsThenAnEllipsis() {
        let counted = APIProbeReport.mentionShapes([
            Fixture.reply(
                text: "@@@@@@@",
                annotations: [Fixture.mention(.mention, user: "u-2", start: 0, length: 1)]
            )
        ])
        let lines = APIProbeReport.mentionShapesLines(counted)
        #expect(lines.contains(
            "  span 1: start 0, length 1; text UTF-16 7, scalar 7, Character 7; "
                + "\"@\" at UTF-16 [0, 1, 2, 3, 4, …], scalar [0, 1, 2, 3, 4, …], "
                + "Character [0, 1, 2, 3, 4, …]"
        ))
    }

    @Test func elevenSpansRenderTenLinesPlusAnOverflowLine() {
        let annotations = (0 ..< 11).map { _ in
            Fixture.mention(.mention, user: "u-2", start: 0, length: 1)
        }
        let counted = APIProbeReport.mentionShapes([Fixture.reply(text: "@x", annotations: annotations)])
        let lines = APIProbeReport.mentionShapesLines(counted)
        #expect(lines.filter { $0.hasPrefix("  span ") }.count == 10)
        #expect(lines.contains("  span 10: start 0, length 1; text UTF-16 2, scalar 2, Character 2; "
                + "\"@\" at UTF-16 [0], scalar [0], Character [0]"))
        #expect(!lines.contains { $0.hasPrefix("  span 11:") })
        #expect(lines.last == "  … 1 more spans not listed")
    }

    /// A leak sentinel for the span lines specifically: a distinctive word in
    /// the message text must never appear in a rendered span line, only the
    /// counts and offsets it produced. Follows the leak check already in
    /// `theLinesRenderEveryCountAndNothingElse` below, aimed at this section.
    @Test func aSpanLineNeverLeaksTheMessageText() {
        let sentinelText = "SPAN-LEAK-SENTINEL @word"
        let counted = APIProbeReport.mentionShapes([
            Fixture.reply(
                text: sentinelText,
                annotations: [Fixture.mention(.mention, user: "u-2", start: 0, length: 2)]
            )
        ])
        let lines = APIProbeReport.mentionShapesLines(counted)
        let spanLine = lines.first { $0.hasPrefix("  span 1:") }
        #expect(spanLine != nil)
        #expect(!(spanLine ?? "").contains("SPAN-LEAK-SENTINEL"))
        #expect(!(spanLine ?? "").contains(sentinelText))
    }
}
