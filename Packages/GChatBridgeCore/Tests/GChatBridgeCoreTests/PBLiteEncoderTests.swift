import Foundation
import Testing
@testable import GChatBridgeCore

/// `StreamEventsRequest` is the fixture throughout because it is a real message
/// off this wire and happens to exercise nearly every rule at once: string at 1,
/// message at 2, enum at 4, int64 at 6, repeated string at 7, and int64 at
/// **100** - a genuinely high field number, which is what the trailing-dictionary
/// optimisation exists for.
@Suite("pblite encoder")
struct PBLiteEncoderTests {
    @Test("field 1 lands at index 0")
    func oneBasedPositions() throws {
        var request = StreamEventsRequest()
        request.sampleID = "abc"
        #expect(try PBLiteEncoder.encode(request) == ["abc"])
    }

    @Test("a sparse message pads the gaps with null and stops at the highest field")
    func nullPadding() throws {
        var request = StreamEventsRequest()
        request.clientSessionID = 7
        #expect(try PBLiteEncoder.encode(request) == [nil, nil, nil, nil, nil, 7])
    }

    @Test("a message with nothing set encodes as an empty array")
    func emptyMessage() throws {
        #expect(try PBLiteEncoder.encode(StreamEventsRequest()) == .array([]))
    }

    @Test("presence, not value, decides what is encoded")
    func onlySetFields() throws {
        var request = StreamEventsRequest()
        // Assigning the zero value still *sets* the field, so it must be emitted.
        request.platform = .undefinedPlatform
        #expect(try PBLiteEncoder.encode(request) == [nil, nil, nil, 0])
        request.clearPlatform()
        #expect(try PBLiteEncoder.encode(request) == .array([]))
    }

    @Test("an enum encodes as its raw number")
    func enumAsNumber() throws {
        var request = StreamEventsRequest()
        request.platform = .webGmail
        #expect(try PBLiteEncoder.encode(request) == [nil, nil, nil, 8])
    }

    @Test("a repeated field encodes as one nested array, not repeated slots")
    func repeatedIsOneArray() throws {
        var request = StreamEventsRequest()
        request.sampleIds = ["a", "b", "c"]
        #expect(try PBLiteEncoder.encode(request) == [nil, nil, nil, nil, nil, nil, ["a", "b", "c"]])
    }

    @Test("bytes encode as a base64 string")
    func bytesAsBase64() throws {
        var info = MeetingSpace.CallInfo.CseInfo()
        info.wrappedKey = Data([0x00, 0x01, 0xFE, 0xFF])
        #expect(try PBLiteEncoder.encode(info) == ["AAH+/w=="])
    }

    @Test("int64 encodes as a JSON number even though decoding also accepts a string")
    func int64EncodesAsNumber() throws {
        var request = StreamEventsRequest()
        request.clientSessionID = 1_234_567_890_123
        let json = try PBLiteEncoder.encodeJSON(request)
        let text = try #require(String(bytes: json, encoding: .utf8))
        #expect(text == "[null,null,null,null,null,1234567890123]")
    }

    /// The deliberate asymmetry: upstream's decoder accepts a trailing
    /// `{fieldNumber: value}` dictionary for high field numbers
    /// (pblite.py:99-103) but its encoder has no counterpart and pads all the way
    /// out (pblite.py:172-175). Field 100 therefore costs 100 slots, and the
    /// output contains no object node at all.
    @Test("a high field number pads to a plain 100-element array, never a trailing dict")
    func highFieldNumberNeverEmitsDictionary() throws {
        var request = StreamEventsRequest()
        request.sampleID = "s"
        request.testUserGaiaID = 12345
        let encoded = try PBLiteEncoder.encode(request)
        let items = try #require(encoded.arrayValue)
        #expect(items.count == 100)
        #expect(items[0] == "s")
        #expect(items[99] == 12345)
        let paddingIsAllNull = items[1 ... 98].allSatisfy(\.isNull)
        #expect(paddingIsAllNull)
        #expect(items.allSatisfy { $0.objectValue == nil }, "encoder must not emit an object node")
        let json = try encoded.jsonString()
        #expect(json.hasPrefix(#"["s",null,"#))
        #expect(json.hasSuffix("null,12345]"))
        #expect(!json.contains("{"), "no dictionary anywhere in the encoded form")
    }

    @Test("a nested message encodes as a nested array")
    func nestedMessage() throws {
        var info = ClientInfo()
        info.platform = .web
        var request = StreamEventsRequest()
        request.clientInfo = info
        #expect(try PBLiteEncoder.encode(request) == [nil, nil, nil, nil, [1]])
    }

    /// `/api/` requests are sent as binary protobuf, never pblite
    /// (`APIRequests.swift:13-14`), so this is a structural check, not a wire
    /// check: it pins the field *positions* findings.md §65.9 found in 28
    /// captured `list_topics` requests - filter at 4 with its anchor at the
    /// filter's own field 5, sort_option at 11 - using pblite's index-is-
    /// field-number layout as a readable stand-in for protobuf's field
    /// numbering. The anchor's **value** matters too: 28 of 28 captures sent
    /// it as a JSON number, never a string, which is what `int64EncodesAsNumber`
    /// above already pins for int64 in general.
    @Test("ListTopicsRequest's filter and sort_option land at the positions findings.md §65.9 captured")
    func listTopicsFilterAndSortOption() throws {
        var request = ListTopicsRequest()
        request.filter.anchor.timeUsec = 1_790_000_000_000_000
        request.sortOption = 2
        let encoded = try PBLiteEncoder.encode(request)
        let items = try #require(encoded.arrayValue)
        #expect(items.count == 11)
        // index 3 == field 4 (filter); the filter's own index 4 == its field 5
        // (anchor), itself a one-element array holding time_usec (field 1).
        #expect(items[3] == [nil, nil, nil, nil, [1_790_000_000_000_000]])
        // index 10 == field 11 (sort_option).
        #expect(items[10] == 2)
    }
}
