import Foundation
import Testing
@testable import GChatBridgeCore

/// The end-to-end direction: message -> pblite -> JSON -> pblite -> message.
///
/// The `PingEvent` case is the one that must definitely work. It is the message
/// the client sends immediately after registering, and until the server has seen
/// it no events arrive on the long-poll at all (`channel.py`'s initial ping,
/// documented in section 2.5 of docs/protocol/maugclib-call-sequence.md).
@Suite("pblite round trip")
struct PBLiteRoundTripTests {
    /// The exact bytes the probe needs. `state` is field 1,
    /// `application_focus_state` field 3, `client_interactive_state` field 5 and
    /// `client_notifications_enabled` field 6, so fields 2 and 4 show up as the
    /// nulls that prove positional padding is doing its job.
    @Test("PingEvent encodes to [1,null,1,null,1,true]")
    func pingEventShape() throws {
        let encoded = try PBLiteEncoder.encode(Self.ping)
        #expect(encoded == [1, nil, 1, nil, 1, true])
        #expect(try encoded.jsonString() == "[1,null,1,null,1,true]")
    }

    @Test("a StreamEventsRequest carrying a PingEvent round-trips")
    func streamEventsRequestWithPing() throws {
        var request = StreamEventsRequest()
        request.pingEvent = Self.ping

        let encoded = try PBLiteEncoder.encode(request)
        #expect(encoded == [nil, [1, nil, 1, nil, 1, true]])
        #expect(try encoded.jsonString() == "[null,[1,null,1,null,1,true]]")

        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: encoded)
        #expect(decoded.issues.isEmpty)
        #expect(decoded.message == request)
        #expect(decoded.message.pingEvent.state == .active)
        #expect(decoded.message.pingEvent.applicationFocusState == .focusStateForeground)
        #expect(decoded.message.pingEvent.clientInteractiveState == .interactive)
        #expect(decoded.message.pingEvent.clientNotificationsEnabled)
        // Unset neighbours must stay unset, not become their zero value.
        #expect(!decoded.message.pingEvent.hasLastInteractiveTimeMs)
        #expect(!decoded.message.hasSampleID)
    }

    @Test("the ping survives a trip through JSON bytes")
    func pingThroughJSON() throws {
        var request = StreamEventsRequest()
        request.pingEvent = Self.ping
        let json = try PBLiteEncoder.encodeJSON(request)
        let decoded = try PBLiteDecoder.decode(StreamEventsRequest.self, fromJSON: json)
        #expect(decoded.message == request)
        #expect(decoded.issues.isEmpty)
    }

    /// Requirement in its own right: the gaps are not incidental, they carry the
    /// field numbering, so a round trip that closed them up would silently
    /// renumber every field after the first hole.
    @Test("a sparse message round-trips with its gaps intact")
    func gapsSurviveRoundTrip() throws {
        var request = StreamEventsRequest()
        request.sampleID = "s"
        request.platform = .web
        request.clientSessionID = 99
        request.sampleIds = ["x", "y"]

        let encoded = try PBLiteEncoder.encode(request)
        #expect(encoded == ["s", nil, nil, 1, nil, 99, ["x", "y"]])

        let reparsed = try PBLiteValue(json: encoded.jsonData())
        #expect(reparsed == encoded)
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: reparsed)
        #expect(decoded.message == request)
        #expect(try PBLiteEncoder.encode(decoded.message) == encoded)
    }

    /// The asymmetry, end to end: a payload that used the dictionary optimisation
    /// decodes correctly, and re-encoding the same message emits the long plain
    /// array instead. Both forms mean the same message; only one is ever sent.
    @Test("a dictionary payload decodes but re-encodes as a plain array")
    func dictionaryInPlainArrayOut() throws {
        let fromServer: PBLiteValue = .array([.string("s"), .object(["100": .string("12345")])])
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: fromServer)
        #expect(decoded.issues.isEmpty)
        #expect(decoded.message.sampleID == "s")
        #expect(decoded.message.testUserGaiaID == 12345)

        let reencoded = try PBLiteEncoder.encode(decoded.message)
        #expect(reencoded != fromServer, "the encoder must not reproduce the dictionary")
        let items = try #require(reencoded.arrayValue)
        #expect(items.count == 100)
        #expect(items[99] == 12345)

        // And the long form decodes back to the same message, so the two wire
        // forms really are interchangeable on input.
        let again = PBLiteDecoder.decode(StreamEventsRequest.self, from: reencoded)
        #expect(again.message == decoded.message)
        #expect(again.issues.isEmpty)
    }

    /// `ListTopicsRequest.filter.anchor` is this schema's first depth-2
    /// nesting (`ListTopicsRequest` -> `TopicsFilter` -> `TimeAnchor`), added
    /// for the field findings.md §65.9 found the web client sends with every
    /// `list_topics` call. The shape itself is pinned by
    /// `PBLiteEncoderTests.listTopicsFilterAndSortOption`; this is the round
    /// trip, which is what actually exercises `PBLiteFieldSource
    /// .decodeNested`'s recursion at that depth - nothing else in the schema
    /// reaches two levels down.
    @Test("a ListTopicsRequest with a nested filter round-trips through pblite and JSON")
    func listTopicsFilterRoundTrips() throws {
        var request = ListTopicsRequest()
        request.filter.anchor.timeUsec = 1_790_000_000_000_000
        request.sortOption = 2

        let encoded = try PBLiteEncoder.encode(request)
        let decoded = PBLiteDecoder.decode(ListTopicsRequest.self, from: encoded)
        #expect(decoded.issues.isEmpty)
        #expect(decoded.message == request)
        #expect(decoded.message.filter.anchor.timeUsec == 1_790_000_000_000_000)
        #expect(decoded.message.sortOption == 2)

        let json = try PBLiteEncoder.encodeJSON(request)
        let decodedFromJSON = try PBLiteDecoder.decode(ListTopicsRequest.self, fromJSON: json)
        #expect(decodedFromJSON.issues.isEmpty)
        #expect(decodedFromJSON.message == request)
    }

    /// `/api/` sends `list_topics` as binary protobuf, never pblite
    /// (`APIRequests.swift:13-14`), so this is the round trip that matches
    /// what actually goes on the wire - the pblite trip above is a structural
    /// check of the same field positions, not a claim about their wire form.
    @Test("the same request round-trips through binary protobuf, the form /api/ actually sends")
    func listTopicsFilterRoundTripsThroughBinaryProtobuf() throws {
        var request = ListTopicsRequest()
        request.filter.anchor.timeUsec = 1_790_000_000_000_000
        request.sortOption = 2

        let bytes: Data = try request.serializedBytes()
        let decoded = try ListTopicsRequest(serializedBytes: bytes)
        #expect(decoded == request)
        #expect(decoded.filter.anchor.timeUsec == 1_790_000_000_000_000)
        #expect(decoded.sortOption == 2)
    }

    private static var ping: PingEvent {
        var event = PingEvent()
        event.state = .active
        event.applicationFocusState = .focusStateForeground
        event.clientInteractiveState = .interactive
        event.clientNotificationsEnabled = true
        return event
    }
}
