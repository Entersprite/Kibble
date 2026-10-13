import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetMediaSessionWireTests {
    @Test func requestWrapsClientConfigInFieldThree() throws {
        let config = MeetProto.bytes(1, MeetProto.number(2, 3))
        let body = try MeetMediaSessionWire.create(clientConfiguration: config)
        let session = try MeetProto.payload(1, body)
        #expect(try MeetProto.payload(3, session) == config)
        #expect(ProtoFieldScan.payloads(ofField: 2, in: session).isEmpty)
    }

    @Test func responseUsesServerConfigInsteadOfTheEchoedClientConfig() throws {
        let server = MeetProto.bytes(1, MeetProto.number(2, 2))
        let client = MeetProto.bytes(1, MeetProto.number(2, 3))
        let body = MeetProto.string(1, "mediasessions/synthetic")
            + MeetProto.bytes(2, server) + MeetProto.bytes(3, client)
        let session = try MeetMediaSessionWire.session(from: base64(body))
        #expect(session.name == "mediasessions/synthetic")
        #expect(session.serverConfiguration == server)
        #expect(session.serverConfiguration != client)
    }

    @Test func missingServerConfigDuplicateFieldsOrTruncatedNestedConfigFail() throws {
        let name = MeetProto.string(1, "mediasessions/synthetic")
        let config = MeetProto.bytes(1, MeetProto.number(2, 2))
        for body in [
            name + MeetProto.bytes(3, config),
            name + MeetProto.bytes(2, Data()),
            name + MeetProto.bytes(2, config) + MeetProto.bytes(2, config),
            name + MeetProto.bytes(2, Data([0x0A, 0x10, 0x01])),
            MeetProto.string(1, "mediasessions/id/extra") + MeetProto.bytes(2, config)
        ] {
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetMediaSessionWire.session(from: base64(body))
            }
        }
    }

    @Test func malformedClientConfigurationCannotBecomeAMediaRequest() throws {
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetMediaSessionWire.create(clientConfiguration: Data([0x0A, 0x10]))
        }
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try MeetMediaSessionWire.create(clientConfiguration: Data())
        }
    }

    private func base64(_ data: Data) -> Data {
        Data(data.base64EncodedString().utf8)
    }
}
