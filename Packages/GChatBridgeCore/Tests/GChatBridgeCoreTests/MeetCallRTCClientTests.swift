import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallRTCClientTests {
    @Test func shellDescriptorIsEncodedByFieldPositionWithNullsOmitted() throws {
        let body = try shell("tag:1,321,1,12,5,null,1]")
        let header = try #require(MeetCallRTCClient.extract(from: body))
        let expected = Data([0x08, 1, 0x10, 0xC1, 2, 0x18, 1, 0x20, 12, 0x28, 5, 0x38, 1])
        #expect(Data(base64Encoded: header) == expected)
        #expect(MeetCallRTCClient.isValid(header))
        #expect(!header.contains("tag:"))
    }

    @Test func absentDescriptorUsesTheSourceDefinedDesktopWebDefault() {
        let body = Data(#"<script>window.WIZ_global_data={"other":"brace } inside a string"};</script>"#.utf8)
        let header = MeetCallRTCClient.extract(from: body)
        #expect(header == Data([0x08, 1, 0x10, 0, 0x18, 1]).base64EncodedString())
        #expect(MeetCallRTCClient.extract(from: Data("no parsed shell".utf8)) == nil)
    }

    @Test(arguments: [
        "bad", "tag:1,321,1", "tag:1,321]", "tag:1,null,1]", "tag:true,321,1]",
        "tag:1,321,1.5]", "tag:1,-1,1]", "tag:1,2147483648,1]", "tag:1,4294967296,1]",
        "tag:1,321,1,{}]",
        "tag:1,321,1,1,1,1,1,1]"
    ])
    func malformedDescriptorCannotBecomeAHeader(_ tagged: String) throws {
        let body = try shell(tagged)
        #expect(MeetCallRTCClient.extract(from: body) == nil)
    }

    @Test func validationRejectsOpaqueIDsAndInvalidProtobuf() {
        for bytes in [
            Data([0xFF, 0xFF, 0xFF]),
            Data([0x08, 1]),
            Data([0x08, 1, 0x10, 0, 0x18, 1, 0x08, 2]),
            Data([0x08, 1, 0x10, 0, 0x18, 1, 0x42, 0]),
            Data([0x08, 1, 0x10, 0, 0x18, 1, 0x20])
        ] {
            #expect(!MeetCallRTCClient.isValid(bytes.base64EncodedString()))
        }
        #expect(!MeetCallRTCClient.isValid("opaque-client-id"))
    }

    private func shell(_ descriptor: String) throws -> Data {
        let encoded = try JSONEncoder().encode(["JyGAEc": descriptor])
        return Data("<script>window.WIZ_global_data=".utf8) + encoded + Data(";</script>".utf8)
    }
}
