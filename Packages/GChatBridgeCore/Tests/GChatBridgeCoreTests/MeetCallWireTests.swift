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

    private func encodedAnswer(_ protobuf: Data) -> Data {
        Data(protobuf.base64EncodedString().utf8)
    }
}
