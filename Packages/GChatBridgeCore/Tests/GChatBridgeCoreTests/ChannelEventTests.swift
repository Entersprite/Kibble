import Foundation
import Testing
@testable import GChatBridgeCore

/// Finding the event inside a delivered array, and its bodies' type tags.
///
/// Every shape here comes from `findings.md` §12 — a run that carried 16 events
/// and 33 tagged bodies. Two of them are the reasons this layer exists at all:
/// the nesting depth that a previous probe got wrong, and the trailing-dictionary
/// encoding that eight of those 33 bodies arrived in.
struct ChannelEventTests {
    /// A body as a padded positional array with its type tag at index 11
    /// (field 12).
    private func positionalBody(type: Int) -> String {
        let padding = Array(repeating: "null", count: 11).joined(separator: ",")
        return "[\(padding),\(type)]"
    }

    /// The same body as a trailing high-field-number dictionary, which is how
    /// pblite encodes a message whose set fields are all high-numbered.
    private func dictionaryBody(type: Int) -> String {
        #"{"12":\#(type)}"#
    }

    /// `payload[0][0]` is the event; `payload[0]` is a wrapper holding it plus a
    /// 36-character id. Bodies live at the event's index 7.
    private func payload(bodies: [String]) -> String {
        let padding = Array(repeating: "null", count: 7).joined(separator: ",")
        return "[[[\(padding),[\(bodies.joined(separator: ","))]],\"a-36-character-identifier-goes-here\"]]"
    }

    private func array(_ json: String) throws -> ChannelArray {
        try ChannelArray(aid: 1, data: PBLiteValue(json: Data(json.utf8)))
    }

    private func event(bodies: [String]) throws -> ChannelEvent? {
        try ChannelEvent(array(payload(bodies: bodies)))
    }

    // MARK: - Finding the event

    @Test func anEventIsFoundAtTheRightDepth() throws {
        let subject = try #require(try event(bodies: [positionalBody(type: 6)]))
        #expect(subject.bodies.count == 1)
    }

    /// The bug that made a run carrying four `MESSAGE_POSTED` events report
    /// `NOT PROVEN` (§12.2). Reading the wrapper as the event finds no bodies,
    /// and the failure is silent — a wrapper is a perfectly good array.
    @Test func theWrapperIsNotTheEvent() throws {
        // The event one level too shallow: bodies hung off the wrapper.
        let padding = Array(repeating: "null", count: 7).joined(separator: ",")
        let shallow = "[[\(padding),[\(positionalBody(type: 6))]]]"
        #expect(try ChannelEvent(array(shallow))?.bodies.isEmpty ?? true)
    }

    @Test func severalBodiesInOneEventAreAllKept() throws {
        let subject = try #require(try event(bodies: [
            positionalBody(type: 6),
            positionalBody(type: 20),
            positionalBody(type: 36)
        ]))
        #expect(subject.bodies.map(\.typeTag) == [6, 20, 36])
    }

    @Test func aKeepaliveCarriesNoEvent() throws {
        #expect(try ChannelEvent(array(#"["noop"]"#)) == nil)
    }

    @Test func anEventWithNoBodiesIsStillAnEvent() throws {
        let subject = try #require(try event(bodies: []))
        #expect(subject.bodies.isEmpty)
    }

    @Test func aShortOrEmptyPayloadCarriesNoEvent() throws {
        #expect(try ChannelEvent(array("[]")) == nil)
        #expect(try ChannelEvent(array("[[]]")) == nil)
        #expect(try ChannelEvent(array(#"{"a":1}"#)) == nil)
    }

    // MARK: - Reading the type tag, in both encodings

    @Test func aPositionalBodyCarriesItsTagAtIndexEleven() throws {
        let subject = try #require(try event(bodies: [positionalBody(type: 6)]))
        #expect(subject.bodies.first?.typeTag == 6)
    }

    /// Eight of the 33 bodies in the first successful run arrived like this.
    /// A parser that only read the positional form would have called them
    /// untagged and dropped a quarter of the traffic.
    @Test func aDictionaryBodyCarriesItsTagUnderKeyTwelve() throws {
        let subject = try #require(try event(bodies: [dictionaryBody(type: 6)]))
        #expect(subject.bodies.first?.typeTag == 6)
    }

    @Test func bothEncodingsCanAppearInOneEvent() throws {
        let subject = try #require(try event(bodies: [
            positionalBody(type: 6),
            dictionaryBody(type: 33)
        ]))
        #expect(subject.bodies.map(\.typeTag) == [6, 33])
    }

    /// A positional body can also carry a trailing dictionary for its
    /// high-numbered fields, which is where the tag then lives.
    @Test func aTagInATrailingDictionaryOnAPositionalBodyIsFound() throws {
        let subject = try #require(try event(bodies: [#"[null,null,{"12":7}]"#]))
        #expect(subject.bodies.first?.typeTag == 7)
    }

    /// **The body is kept.** An untagged body is not a reason to drop the
    /// event: §12.1.1's rule is to route what is not understood, never to
    /// discard it.
    @Test func anUntaggedBodyIsKeptWithNoTag() throws {
        let subject = try #require(try event(bodies: ["[null,null]"]))
        #expect(subject.bodies.count == 1)
        #expect(subject.bodies.first?.typeTag == nil)
    }

    @Test func aNonIntegerTagIsNotATag() throws {
        let subject = try #require(try event(bodies: [#"{"12":"six"}"#]))
        #expect(subject.bodies.first?.typeTag == nil)
    }

    // MARK: - Naming what the vendored proto knows

    @Test func aKnownTagIsNamed() throws {
        let subject = try #require(try event(bodies: [positionalBody(type: 6)]))
        #expect(subject.bodies.first?.type == .messagePosted)
    }

    @Test func theObservedVocabularyIsNamed() throws {
        // §12.1's table, as tags.
        let observed = [6, 7, 20, 33, 36, 3, 9, 15, 13, 10, 16, 26]
        let subject = try #require(try event(bodies: observed.map { positionalBody(type: $0) }))
        #expect(subject.bodies.allSatisfy { $0.type != nil })
        #expect(subject.bodies.first?.type == .messagePosted)
        #expect(subject.bodies.map(\.type).contains(.sessionReady))
    }

    /// **The rule §12.1.1 exists for.** The vendored proto's `EventType` stops
    /// at 50 and live traffic carried 51, 64, 70 and 83. Those must arrive as
    /// numbers rather than vanishing: regenerating from a newer proto would
    /// shrink the unknown set and never empty it.
    @Test func aTagTheVendoredProtoHasNeverHeardOfSurvivesAsANumber() throws {
        let subject = try #require(try event(bodies: [51, 64, 70, 83].map {
            positionalBody(type: $0)
        }))
        #expect(subject.bodies.map(\.typeTag) == [51, 64, 70, 83])
        #expect(subject.bodies.allSatisfy { $0.type == nil })
    }

    /// The body's own value is retained whether or not the type is known, so a
    /// later mapping can be written against a capture rather than a guess.
    @Test func theBodyValueIsRetained() throws {
        let subject = try #require(try event(bodies: [dictionaryBody(type: 64)]))
        #expect(subject.bodies.first?.value.objectValue?["12"] == .number(.integer(64)))
    }
}
