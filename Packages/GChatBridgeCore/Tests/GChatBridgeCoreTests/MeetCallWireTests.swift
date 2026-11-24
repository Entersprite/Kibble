import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallWireTests {
    @Test func quietConversationResolveIsDistinctFromDirectedDMResolution() throws {
        let body = try MeetCallWire.resolveConversation(groupID: "synthetic-group")
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: body) == [0])
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: body) == [2])
        #expect(ProtoFieldScan.payloads(ofField: 7, in: body) == [Data("synthetic-group".utf8)])
        #expect(try body != (MeetCallWire.resolve(dmID: "synthetic-group")))
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetCallWire.resolveConversation(groupID: "space/prefixed")
        }
    }

    @Test func resolveRequestHasTheCapturedFieldOrderAndValues() throws {
        let body = try MeetCallWire.resolve(dmID: "dm_123")
        #expect(body == Data([0x08, 0x02, 0x10, 0x01, 0x3A, 0x06]) + Data("dm_123".utf8))
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetCallWire.resolve(dmID: "dm:123")
        }
    }

    @Test func inviteRequestHasTheCapturedEnvelope() throws {
        let id = try #require(UUID(uuidString: "0000ABCD-0000-4000-8000-000000000001"))
        let body = try MeetCallWire.invite(spaceName: "spaces/abc", calleeID: "123", requestID: id)
        var expected = Data([0x0A, 0x0A]) + Data("spaces/abc".utf8)
        expected += Data([0x12, 0x05, 0x12, 0x03]) + Data("123".utf8)
        expected += Data([0x18, 0x02, 0x20, 0x01, 0x62, 0x24])
        expected += Data("0000ABCD-0000-4000-8000-000000000001".utf8)
        #expect(body == expected)
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetCallWire.invite(spaceName: "spaces/abc", calleeID: "person:123", requestID: id)
        }
    }

    @Test func resolvedSpaceRequiresAMatchingMeetLink() throws {
        let good = encodedAnswer(
            Data([0x0A, 0x0A]) + Data("spaces/abc".utf8)
                + Data([0x12, 0x0C]) + Data("abc-defg-hij".utf8)
                + Data([0x1A, 0x24]) + Data("https://meet.google.com/abc-defg-hij".utf8)
        )
        let space = try MeetCallWire.resolvedSpace(from: good)
        #expect(space.name == "spaces/abc")
        #expect(space.code == "abc-defg-hij")
        #expect(space.url.absoluteString == "https://meet.google.com/abc-defg-hij")

        let wrongHost = encodedAnswer(
            Data([0x0A, 0x0A]) + Data("spaces/abc".utf8)
                + Data([0x12, 0x0C]) + Data("abc-defg-hij".utf8)
                + Data([0x1A, 0x22]) + Data("https://evil.example/abc-defg-hij".utf8)
        )
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetCallWire.resolvedSpace(from: wrongHost)
        }
    }

    @Test func inviteAcceptanceNeedsAnIntactIdentifierField() throws {
        #expect(try MeetCallWire.acceptedInvite(from: encodedAnswer(Data([0x0A, 0x02, 0x61, 0x62]))))
        #expect(try !MeetCallWire.acceptedInvite(from: encodedAnswer(Data([0x10, 0x01]))))
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetCallWire.acceptedInvite(from: encodedAnswer(Data([0x0A, 0x03, 0x61])))
        }
    }

    @Test func resolvedSpaceProjectsOnlyTheFormattedPhoneAndValidPIN() throws {
        let space = MeetProto.string(1, "spaces/synthetic")
            + MeetProto.string(2, "abc-defg-hij")
            + MeetProto.string(3, "https://meet.google.com/abc-defg-hij")
        let us = MeetProto.string(1, "ignored-raw-number") + MeetProto.string(2, "012 345 678")
            + MeetProto.string(3, "US") + MeetProto.string(5, "+1 (202) 555-0142")
        let gb = MeetProto.string(2, "987654321")
            + MeetProto.string(3, "GB") + MeetProto.string(5, "+44 20 7946 0958")
        let wrongField = MeetProto.string(1, "+1 202-555-0110") + MeetProto.string(2, "123")
        let ambiguousPIN = us + MeetProto.number(2, 123)
        let duplicate = MeetProto.string(2, "012345678") + MeetProto.string(5, "+1 202-555-0142")
            + MeetProto.string(3, "us")
        let ca = MeetProto.string(2, "012345678") + MeetProto.string(5, "+1 202-555-0142")
            + MeetProto.string(3, "CA")
        let malformedPhone = MeetProto.string(5, "+1 202-555-0101;ext=3") + MeetProto.string(2, "123")
        let response = [wrongField, ambiguousPIN, malformedPhone, us, duplicate, ca, gb]
            .reduce(space) { $0 + MeetProto.bytes(5, $1) }

        let rows = try MeetCallWire.resolvedSpace(from: encodedAnswer(response)).dialIn
        #expect(rows.map(\.phoneNumber) == ["+1 (202) 555-0142", "+1 202-555-0142", "+44 20 7946 0958"])
        #expect(rows.map(\.pin) == ["012345678", "012345678", "987654321"])
        #expect(rows.map(\.region) == ["US", "CA", "GB"])
        #expect(try MeetCallWire.resolvedSpace(from: encodedAnswer(space)).dialIn.isEmpty)
    }

    @Test func sharedPINAdvertisesADirectoryEvenWithoutInlineNumbers() throws {
        let space = MeetProto.string(1, "spaces/synthetic")
            + MeetProto.string(2, "abc-defg-hij")
            + MeetProto.string(3, "https://meet.google.com/abc-defg-hij")
        let valid = space + MeetProto.bytes(8, MeetProto.string(1, "012 345 678"))
        let resolved = try MeetCallWire.resolvedSpace(from: encodedAnswer(valid))
        #expect(resolved.dialIn.isEmpty)
        #expect(resolved.phoneDirectory?.absoluteString == "https://tel.meet/abc-defg-hij?hs=5")

        let invalid = space + MeetProto.bytes(8, MeetProto.string(1, "PIN required"))
        #expect(try MeetCallWire.resolvedSpace(from: encodedAnswer(invalid)).phoneDirectory == nil)
        #expect(try MeetCallWire.resolvedSpace(from: encodedAnswer(space)).phoneDirectory == nil)
    }

    private func encodedAnswer(_ protobuf: Data) -> Data {
        Data(protobuf.base64EncodedString().utf8)
    }
}
