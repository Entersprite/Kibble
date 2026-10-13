import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetStreamClientMetadataTests {
    @Test func readsOnlyApplicationAndVersionFromTaggedConfiguration() {
        let fields = #"["hc:cc",3,"private-account",null,null,0,"public-build",["private]field"]]"#
        let html = "<script>data=[[]," + fields + "];</script>"
        let result = MeetStreamClientMetadata.extract(Data(html.utf8))
        #expect(result?.application == 3)
        #expect(result?.version == "public-build")
    }

    @Test func refusesAmbiguousInvalidOrAbsentMetadata() {
        for html in [
            #"["hc:cc",true,null,null,null,null,"build"]"#,
            #"["hc:cc",3,null,null,null,null,123]"#,
            #"["hc:cc",3,null,null,null,null,"line\nbreak"]"#,
            #"["hc:cc",3,null,null,null,null,"build"] ["hc:cc",4,null,null,null,null,"build"]"#,
            #"["hc:cc",3,null,null,null,null,"build""#,
            "<html>no configuration</html>"
        ] {
            #expect(MeetStreamClientMetadata.extract(Data(html.utf8))?.application == nil)
        }
    }

    @Test func headerUsesCurrentMetadataAndFreshInstanceOnly() throws {
        let referer = try #require(URL(string: "https://meet.google.com/call"))
        let config = try #require(MeetCallConfiguration(
            apiKey: "key", accountIndex: 0,
            referer: referer,
            userAgent: "Test", rtcClientID: "CAEQABgB", debugID: "fresh-instance",
            streamApplication: 3, streamClientVersion: "public-build"
        ))
        let cookies = try #require(SessionCookies(header: "SAPISID=private-cookie"))
        let client = MeetCallClient(
            transport: FakeHTTPTransport(responses: []),
            credentials: SessionCredentials(cookies),
            configuration: config,
            sha1: { _ in "synthetic" }
        )
        let header = try client.streamControlHeader()
        #expect(try MeetProto.value(1, MeetProto.payload(1, header)) == 3)
        let metadata = try MeetProto.payload(2, header)
        #expect(try MeetProto.text(1, metadata) == "public-build")
        #expect(try MeetProto.text(4, metadata) == "fresh-instance")
        #expect(try MeetProto.payload(7, header) == Data([0x08, 1, 0x10, 0, 0x18, 1]))
        #expect(header.range(of: Data("private-cookie".utf8)) == nil)
        #expect(client.streamHeaderSource == "current shell application metadata")
    }
}
