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
    }

    /// A negative offset must be reported, never crash the probe on
    /// `index(_:offsetBy:)`.
    @Test func aNegativeSpanResolvesUnderNoReading() {
        let counted = shapes(text: wave, spanAt: -1)
        #expect(counted.spans == 1)
        #expect(counted.spansInRange == 0)
        #expect(counted.spansAtUTF16 + counted.spansAtScalar + counted.spansAtCharacter == 0)
        #expect(counted.discriminating == 1)
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
                Fixture.mention(.invite, user: "u-3", start: 0, length: 5),
                link
            ]),
            Fixture.reply()
        ])
        #expect(counted.messages == 2)
        #expect(counted.withAnnotations == 1)
        #expect(counted.annotationTypes == [1: 1, 6: 2])
        #expect(counted.userMentions == 2)
        #expect(counted.mentionKinds == [1: 1, 3: 1])
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
            "  mention kinds: 3×1; presence absent 1 (raw: 7×1)",
            "  USER_MENTION annotations: 2, mapped to mentions: 1",
            "  mention spans: 2, in range (UTF-16) 2; on \"@\": UTF-16 1/2, scalar 0/2, "
                + "Character 0/2; discriminating 1"
        ])
        let joined = lines.joined(separator: "\n")
        for leak in ["SENTINEL", wave, "@A"] {
            #expect(!joined.contains(leak))
        }
    }

    @Test func emptyTalliesRenderAsNone() {
        let lines = APIProbeReport.mentionShapesLines(MentionShapes())
        #expect(lines.contains("  annotation types: none"))
        #expect(lines.contains("  mention kinds: none; presence absent 0 (raw: none)"))
    }
}
