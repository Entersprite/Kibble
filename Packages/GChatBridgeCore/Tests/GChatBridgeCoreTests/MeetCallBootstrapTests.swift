import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCallBootstrapTests {
    @Test func bootstrapUsesTheShellsRTCClientProtobufInsteadOfRandomBytes() async throws {
        let key = "AIza" + String(repeating: "a", count: 35)
        let html = #"<script>window.WIZ_global_data={"JyGAEc":"tag:1,321,1,12,5,null,1]"};</script>"#
            + "\(key) \(key)"
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        ])
        let cookies = try #require(SessionCookies(header: "SAPISID=synthetic"))
        let config = try await MeetCallBootstrap(
            transport: transport, credentials: SessionCredentials(cookies)
        ).loadConfiguration(accountIndex: 0, userAgent: "TestBrowser")
        let expected = Data([0x08, 1, 0x10, 0xC1, 2, 0x18, 1, 0x20, 12, 0x28, 5, 0x38, 1])
        #expect(Data(base64Encoded: config.rtcClientID) == expected)
    }

    @Test func extractsOnlyTheUniquelyRepeatedKey() {
        let rpc = "AIza" + String(repeating: "a", count: 35)
        let other = "AIza" + String(repeating: "b", count: 35)
        let html = Data("<html>\(rpc) \(other) \(rpc)</html>".utf8)
        #expect(MeetCallPageKey.extract(from: html) == rpc)
        #expect(MeetCallPageKey.extract(from: Data("\(rpc) \(other)".utf8)) == nil)
        #expect(MeetCallPageKey.extract(from: Data("\(rpc) \(rpc) \(other) \(other)".utf8)) == nil)
    }

    @Test func bootstrapReadsAShellWithoutSendingAnyCallRPC() async throws {
        let key = "AIza" + String(repeating: "a", count: 35)
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 200, headers: HTTPHeaders([]),
                body: Data("<script>window.WIZ_global_data={};</script>\(key) \(key)".utf8)
            )
        ])
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "shared", domain: ".google.com", path: "/"),
            .init(name: "OSID", value: "chat-only", domain: "chat.google.com", path: "/")
        ]))
        let bootstrap = MeetCallBootstrap(transport: transport, credentials: SessionCredentials(cookies))
        let config = try await bootstrap.loadConfiguration(accountIndex: 0, userAgent: "TestBrowser")
        #expect(config.apiKey == key)
        #expect(Data(base64Encoded: config.rtcClientID) == Data([0x08, 1, 0x10, 0, 0x18, 1]))
        let sent = await transport.sent
        #expect(sent.count == 1)
        #expect(sent[0].method == .get)
        #expect(sent[0].url.path == "/call")
        #expect(sent[0].headers["Cookie"] == "SID=shared")
        #expect(sent[0].followsRedirects == false)
    }

    @Test func malformedRTCMetadataStopsBeforeAnyCallRPC() async throws {
        let key = "AIza" + String(repeating: "a", count: 35)
        let html = #"<script>window.WIZ_global_data={"JyGAEc":"tag:true,321,1]"};</script>"#
            + "\(key) \(key)"
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(status: 200, headers: HTTPHeaders([]), body: Data(html.utf8))
        ])
        let cookies = try #require(SessionCookies(header: "SAPISID=synthetic"))
        await #expect(throws: MeetCallBootstrapError.invalidRTCClientMetadata) {
            try await MeetCallBootstrap(
                transport: transport, credentials: SessionCredentials(cookies)
            ).loadConfiguration(accountIndex: 0, userAgent: "TestBrowser")
        }
        #expect(await transport.sent.count == 1)
    }

    @Test func redirectsAreClassifiedWithoutExposingTheirLocation() async throws {
        let secret = "one-time-secret"
        let transport = FakeHTTPTransport(responses: [
            HTTPResponse(
                status: 302,
                headers: HTTPHeaders([(
                    "Location",
                    "https://accounts.google.com/ServiceLogin?continue=https://meet.google.com/"
                        + "&token=\(secret)"
                )]),
                body: Data()
            )
        ])
        let cookies = try #require(SessionCookies(cookies: [
            .init(name: "SID", value: "shared", domain: ".google.com", path: "/")
        ]))
        let bootstrap = MeetCallBootstrap(transport: transport, credentials: SessionCredentials(cookies))
        do {
            _ = try await bootstrap.loadConfiguration(accountIndex: 0, userAgent: "TestBrowser")
            Issue.record("Expected the redirect to stop the shell fetch")
        } catch let error as MeetCallBootstrapError {
            #expect(error == .redirected(302, .accounts))
            #expect(!String(describing: error).contains(secret))
        }
        #expect(await (transport.sent).count == 1)
    }

    @Test func relativeRedirectIsRecognisedAsMeet() throws {
        let page = try #require(URL(string: "https://meet.google.com/call?mc=secret"))
        #expect(MeetCallBootstrap.redirect(
            in: HTTPHeaders([("Location", "/somewhere?one_time=secret")]), relativeTo: page
        ) == .meet)
        #expect(MeetCallBootstrap.redirect(
            in: HTTPHeaders([("Location", "https://example.com/path?secret=value")]), relativeTo: page
        ) == .elsewhere)
        #expect(MeetCallBootstrap.redirect(in: HTTPHeaders([]), relativeTo: page) == .unknown)
    }
}
