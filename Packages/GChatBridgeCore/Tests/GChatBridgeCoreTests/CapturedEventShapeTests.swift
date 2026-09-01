import Foundation
import Testing
@testable import GChatBridgeCore

/// `ChannelEvent` run over the **structure of real traffic**.
///
/// Every other test in this suite uses fixtures written by hand, and session 6
/// is the record of what that costs: 133 tests passed against a page shape
/// Google never sends, because the fixture was transcribed from the reference's
/// *regex* rather than from a response. The rule that came out of it — **a
/// fixture is not a capture** — is what these files are for.
///
/// `Fixtures/shape/` holds the 16 events from the §12 run with every string
/// replaced by its length, every id and timestamp by its digit count, and the
/// structure untouched. That is the two-tier scheme session 1 chose and nothing
/// had used until now: `Fixtures/raw/` is gitignored and stays outside the
/// repo; only the redacted form is committed.
///
/// So the **values** here are invented and the **syntax** is Google's. The
/// numbers below are the ones `findings.md` §12.1 recorded independently, from
/// a Python probe, on the day of the run — so a disagreement means one of the
/// two is wrong, which is the entire point of writing them down twice.
struct CapturedEventShapeTests {
    private static func fixtures() throws -> [(name: String, event: ChannelEvent)] {
        let urls = try #require(
            Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "shape")
        )
        return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let value = try PBLiteValue(json: Data(contentsOf: url))
                guard let event = ChannelEvent(payload: value) else { return nil }
                return (url.lastPathComponent, event)
            }
    }

    private static func allBodies() throws -> [ChannelEventBody] {
        try fixtures().flatMap(\.event.bodies)
    }

    @Test func everyCapturedPayloadIsRecognisedAsAnEvent() throws {
        #expect(try Self.fixtures().count == 16)
    }

    /// §12.1: "16 events, 33 tagged bodies, 0 chars unframed."
    @Test func theCaptureCarriesThirtyThreeBodies() throws {
        #expect(try Self.allBodies().count == 33)
    }

    /// Every one of them carried a readable tag. An untagged body would mean
    /// the tag lives somewhere this code does not look.
    @Test func everyBodyCarriesAReadableTag() throws {
        #expect(try Self.allBodies().allSatisfy { $0.typeTag != nil })
    }

    /// §12.1's table, reproduced from the fixtures rather than restated.
    @Test func theTypeHistogramMatchesTheOneRecordedOnTheDay() throws {
        var histogram: [Int: Int] = [:]
        for body in try Self.allBodies() {
            histogram[body.typeTag ?? -1, default: 0] += 1
        }
        #expect(histogram[6] == 4) // MESSAGE_POSTED — the gating criterion
        #expect(histogram[7] == 1) // MESSAGE_UPDATED
        #expect(histogram[20] == 4) // TOPIC_CREATED
        #expect(histogram[33] == 1) // SESSION_READY
        #expect(histogram[36] == 2) // READ_RECEIPT_CHANGED
        #expect(histogram[3] == 2) // GROUP_VIEWED
        #expect(histogram[9] == 3) // TOPIC_MUTE_CHANGED
        #expect(histogram[15] == 3) // MEMBERSHIP_CHANGED
        #expect(histogram[13] == 2) // GROUP_UNREAD_SUBSCRIBED_TOPIC_COUNT_UPDATED
        #expect(histogram[10] == 1) // USER_SETTINGS_CHANGED
        #expect(histogram[16] == 1) // GROUP_HIDE_CHANGED
        #expect(histogram[26] == 1) // GROUP_RETENTION_SETTINGS_UPDATED
        #expect(histogram[64] == 3)
        #expect(histogram[83] == 3)
        #expect(histogram[51] == 1)
        #expect(histogram[70] == 1)
    }

    /// **§12.1.1's rule, against the traffic that earned it.** The vendored
    /// proto's `EventType` stops at 50; the wire carried four values past it.
    /// They arrive as numbers and are not dropped.
    @Test func theFourTypesTheProtoCannotNameSurviveAsNumbers() throws {
        let unnameable = try Self.allBodies()
            .filter { $0.type == nil }
            .compactMap(\.typeTag)
        #expect(Set(unnameable) == [51, 64, 70, 83])
    }

    @Test func everyOtherTypeIsNamedByTheVendoredProto() throws {
        let named = try Self.allBodies().filter { $0.type != nil }
        #expect(named.count == 25)
        #expect(named.contains { $0.type == .messagePosted })
        #expect(named.contains { $0.type == .sessionReady })
    }

    /// §12.1.1: eight bodies put their fields in a trailing high-field-number
    /// dictionary instead of a padded array. A parser that read only the
    /// positional form would call a quarter of this traffic untagged — and
    /// these are the fixtures that would have caught it.
    @Test func eightBodiesUsedTheTrailingDictionaryEncoding() throws {
        let trailing = try Self.allBodies().filter { body in
            guard let fields = body.value.arrayValue else { return false }
            let positional = fields.count > 11 && fields[11].intValue != nil
            return !positional && fields.contains { $0.objectValue?["12"] != nil }
        }
        #expect(trailing.count == 8)
    }

    /// The redaction is part of the fixture's contract, not a one-off tidy-up:
    /// these files are committed, and a future capture added without redacting
    /// would put a colleague's message in the repository. Every string in them
    /// must be a shape token or a pblite field-number key.
    @Test func theCommittedFixturesCarryNoContent() throws {
        let allowed = /^(str|int)\([0-9]+\)$|^(bool|float)$|^[0-9]+$/
        for (name, event) in try Self.fixtures() {
            for string in event.bodies.flatMap({ Self.strings(in: $0.value) }) {
                #expect(string.wholeMatch(of: allowed) != nil, "\(name) carries \(string)")
            }
        }
    }

    private static func strings(in value: PBLiteValue) -> [String] {
        switch value {
        case let .string(text):
            [text]
        case let .array(items):
            items.flatMap { strings(in: $0) }
        case let .object(entries):
            entries.keys + entries.values.flatMap { strings(in: $0) }
        default:
            []
        }
    }
}
