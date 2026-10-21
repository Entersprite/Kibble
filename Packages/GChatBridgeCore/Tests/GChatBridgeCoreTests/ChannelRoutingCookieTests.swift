import Foundation
import Testing
@testable import GChatBridgeCore

@Suite(.timeLimit(.minutes(1)))
struct ChannelRoutingCookieTests {
    private func cookies() -> SessionCookies {
        SessionCookies(cookies: [
            .init(name: "SID", value: "account", domain: ".google.com", path: "/"),
            .init(name: "COMPASS", value: "retired", domain: "chat.google.com", path: "/"),
            .init(name: "COMPASS", value: "other-retired", domain: ".chat.google.com", path: "/")
        ])!
    }

    @Test func channelFilteringPreservesTheAccountCredentialAndOtherRequestCookies() async throws {
        let credentials = SessionCredentials(cookies())
        let url = try #require(URL(string: "https://chat.google.com/u/0/webchannel/events"))
        let request = HTTPRequest(url: url)
        let filtered = await credentials.authorisingChannel(request)
        #expect(filtered.headers["Cookie"] == "SID=account")
        let ordinary = await credentials.authorising(request)
        #expect(ordinary.headers["Cookie"] == "SID=account; COMPASS=retired; COMPASS=other-retired")
        #expect(await credentials.snapshot == cookies())
    }

    @Test func everyChannelRequestFiltersRoutingCookiesIncludingRotations() async {
        let rotated = HTTPHeaders([("Set-Cookie", "COMPASS=new-routing; Path=/; Secure")])
        let transport = FakeHTTPTransport(
            responses: [
                .init(status: 200, headers: rotated, body: Data()),
                .init(status: 200, headers: rotated, body: Data()),
                .init(status: 200, headers: rotated, body: Data())
            ],
            streams: [
                .init(
                    headers: .init([("X-HTTP-Initial-Response", #"[[0,["c","fixture","",8,12,30000]]]"#)]),
                    chunks: []
                ),
                .init(status: 403, chunks: [])
            ]
        )
        let session = ChannelSession(cookies: cookies(), transport: transport)
        var group = GroupId()
        var space = SpaceId(); space.spaceID = "fixture"
        group.spaceID = space
        await session.watchGroup(group)
        await session.start()
        let sent = await transport.sent
        #expect(sent.map(\.traceLabel) == ["register", "handshake", "ping", "groupSubscription", "reopen"])
        for request in sent {
            #expect(request.headers["Cookie"] == "SID=account")
        }
    }
}
