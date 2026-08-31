import Foundation
import Testing
@testable import GChatBridgeCore

/// Decoding is the permissive direction. Every test here that feeds the decoder
/// something wrong also asserts that a *neighbouring* field still decoded,
/// because "never abort" is the whole contract and a codec that silently
/// abandoned the rest of the message would otherwise pass.
@Suite("pblite decoder")
struct PBLiteDecoderTests {
    @Test("index 0 is field 1")
    func oneBasedPositions() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: ["abc"])
        #expect(decoded.message.sampleID == "abc")
        #expect(decoded.issues.isEmpty)
    }

    @Test("null means the field is absent, not zero")
    func nullSkipsTheField() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: [nil, nil, nil, nil, nil, 7])
        #expect(!decoded.message.hasSampleID)
        #expect(!decoded.message.hasPlatform)
        #expect(decoded.message.clientSessionID == 7)
        #expect(decoded.issues.isEmpty)
    }

    @Test("a value that is not an array decodes nothing and says so")
    func notAnArray() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: "nope")
        #expect(decoded.message == StreamEventsRequest())
        #expect(decoded.issues.map(\.kind) == [.notAnArray])
    }

    /// Rule 3: the trailing dictionary is an out-of-band `{fieldNumber: value}`
    /// carrier for high field numbers. Field 100 arrives in two characters
    /// instead of 99 nulls.
    @Test("a trailing high-field-number dictionary decodes")
    func trailingDictionary() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: .array([.string("s"), .object(["100": .string("12345")])])
        )
        #expect(decoded.message.sampleID == "s")
        #expect(decoded.message.testUserGaiaID == 12345)
        #expect(decoded.issues.isEmpty)
    }

    @Test("the dictionary is stripped from the positional list, not counted as a field")
    func dictionaryDoesNotShiftPositions() {
        // If the dict were left in place it would be read as field 2 (pingEvent).
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: .array([.string("s"), .object(["4": 1])])
        )
        #expect(decoded.message.sampleID == "s")
        #expect(decoded.message.platform == .web)
        #expect(!decoded.message.hasPingEvent)
        #expect(decoded.issues.isEmpty)
    }

    @Test("a non-numeric dictionary key is reported and skipped")
    func unparseableDictionaryKey() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: .array([.string("s"), .object(["oops": 1])])
        )
        #expect(decoded.message.sampleID == "s")
        #expect(decoded.issues.map(\.kind) == [.unparseableFieldNumberKey])
    }

    /// Rule 2: responses often begin with an abbreviation of the message name
    /// that is not part of the message (pblite.py:79-82).
    @Test("ignoreFirstItem shifts everything down by one")
    func ignoreFirstItem() {
        let payload: PBLiteValue = ["serp", "s"]
        let shifted = PBLiteDecoder.decode(StreamEventsRequest.self, from: payload, ignoreFirstItem: true)
        #expect(shifted.message.sampleID == "s")
        #expect(shifted.issues.isEmpty)

        // Without the flag the abbreviation is read as field 1 and the real
        // field 1 lands on field 2, which is a message - so it does not fit.
        let unshifted = PBLiteDecoder.decode(StreamEventsRequest.self, from: payload)
        #expect(unshifted.message.sampleID == "serp")
        #expect(unshifted.issues.map(\.kind) == [.malformedScalar])
    }

    @Test("ignoreFirstItem on an empty array is harmless")
    func ignoreFirstItemOnEmpty() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: [], ignoreFirstItem: true)
        #expect(decoded.message == StreamEventsRequest())
        #expect(decoded.issues.isEmpty)
    }

    /// Rule 6. Field 9 does not exist on StreamEventsRequest (it jumps 8 -> 100).
    @Test("an unknown field number is ignored, not an error")
    func unknownFieldIsIgnored() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: ["kept", nil, nil, nil, nil, nil, nil, nil, "who knows"]
        )
        #expect(decoded.message.sampleID == "kept")
        #expect(decoded.issues.map(\.kind) == [.unknownField])
        #expect(decoded.issues.first?.fieldNumber == 9)
    }

    @Test("a trivial value on an unknown field is not even worth reporting")
    func trivialUnknownFieldIsSilent() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: ["kept", nil, nil, nil, nil, nil, nil, nil, ""]
        )
        #expect(decoded.message.sampleID == "kept")
        #expect(decoded.issues.isEmpty)
    }

    /// Rule 7: int64 arrives as a JSON string *or* a number, and must be coerced
    /// either way (pblite.py:36-37).
    @Test("int64 decodes from a JSON string and from a JSON number", arguments: [
        PBLiteValue.string("1234567890123"),
        PBLiteValue.number(.integer(1_234_567_890_123))
    ])
    func int64FromStringOrNumber(_ raw: PBLiteValue) {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: .array([nil, nil, nil, nil, nil, raw])
        )
        #expect(decoded.message.clientSessionID == 1_234_567_890_123)
        #expect(decoded.issues.isEmpty)
    }

    @Test("bytes round-trip through base64")
    func bytesRoundTrip() throws {
        var info = MeetingSpace.CallInfo.CseInfo()
        info.wrappedKey = Data([0x00, 0x01, 0xFE, 0xFF])
        let encoded = try PBLiteEncoder.encode(info)
        #expect(encoded == ["AAH+/w=="])
        let decoded = PBLiteDecoder.decode(MeetingSpace.CallInfo.CseInfo.self, from: encoded)
        #expect(decoded.message == info)
        #expect(decoded.issues.isEmpty)
    }

    @Test("invalid base64 leaves the bytes field unset")
    func invalidBase64() {
        let decoded = PBLiteDecoder.decode(
            MeetingSpace.CallInfo.CseInfo.self,
            from: ["not base64 !!"]
        )
        #expect(!decoded.message.hasWrappedKey)
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
    }

    /// Rule 9, singular half: the bad field is dropped and the message survives.
    @Test("a malformed scalar leaves its field unset without aborting the message")
    func malformedScalarDoesNotAbort() {
        // 42 is a number where field 1 is a string; field 6 after it must survive.
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: [42, nil, nil, nil, nil, 7]
        )
        #expect(!decoded.message.hasSampleID)
        #expect(decoded.message.clientSessionID == 7)
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
        #expect(decoded.issues.first?.fieldNumber == 1)
    }

    @Test("an out-of-range enum leaves its field unset")
    func malformedEnum() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: ["s", nil, nil, 99])
        #expect(decoded.message.sampleID == "s")
        #expect(!decoded.message.hasPlatform)
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
    }

    @Test("a non-integral number is rejected rather than truncated")
    func nonIntegralNumber() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: ["s", nil, nil, nil, nil, 12.5]
        )
        #expect(decoded.message.sampleID == "s")
        #expect(!decoded.message.hasClientSessionID)
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
    }

    /// Rule 9, repeated half: one bad element clears the whole field rather than
    /// leaving it half-populated (pblite.py:69-70).
    @Test("a malformed repeated field is cleared entirely")
    func malformedRepeatedIsCleared() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: ["kept", nil, nil, nil, nil, nil, ["a", 5, "b"]]
        )
        #expect(decoded.message.sampleID == "kept")
        #expect(decoded.message.sampleIds.isEmpty, "no partial population")
        #expect(decoded.issues.map(\.kind) == [.malformedRepeated])
    }

    @Test("a repeated field whose value is not an array is cleared too")
    func repeatedFieldGivenAScalar() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: ["kept", nil, nil, nil, nil, nil, "not a list"]
        )
        #expect(decoded.message.sampleID == "kept")
        #expect(decoded.message.sampleIds.isEmpty)
        #expect(decoded.issues.map(\.kind) == [.malformedRepeated])
    }

    @Test("a well-formed repeated field decodes in order")
    func repeatedDecodes() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: [nil, nil, nil, nil, nil, nil, ["a", "b", "c"]]
        )
        #expect(decoded.message.sampleIds == ["a", "b", "c"])
        #expect(decoded.issues.isEmpty)
    }

    @Test("a nested message recurses into a nested array")
    func nestedMessage() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: [nil, nil, nil, nil, [1]]
        )
        #expect(decoded.message.clientInfo.platform == .web)
        #expect(decoded.issues.isEmpty)
    }

    @Test("an issue inside a nested message is reported against that message")
    func nestedIssueAttribution() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: [nil, nil, nil, nil, [99]]
        )
        #expect(!decoded.message.clientInfo.hasPlatform)
        #expect(decoded.issues.map(\.messageName) == ["ClientInfo"])
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
    }

    @Test("a nested message given a scalar leaves the field unset")
    func nestedMessageGivenAScalar() {
        let decoded = PBLiteDecoder.decode(StreamEventsRequest.self, from: [nil, nil, nil, nil, "x"])
        #expect(!decoded.message.hasClientInfo)
        #expect(decoded.issues.map(\.kind) == [.malformedScalar])
    }

    @Test("recursion is bounded")
    func depthLimit() {
        let decoded = PBLiteDecoder.decode(
            StreamEventsRequest.self,
            from: [nil, nil, nil, nil, [1]],
            depthLimit: 0
        )
        #expect(!decoded.message.clientInfo.hasPlatform)
        #expect(decoded.issues.map(\.kind) == [.depthLimitExceeded])
    }

    @Test("decoding straight from JSON bytes works")
    func fromJSON() throws {
        let decoded = try PBLiteDecoder.decode(
            StreamEventsRequest.self,
            fromJSON: Data(#"["s",null,null,null,null,"7"]"#.utf8)
        )
        #expect(decoded.message.sampleID == "s")
        #expect(decoded.message.clientSessionID == 7)
    }
}
