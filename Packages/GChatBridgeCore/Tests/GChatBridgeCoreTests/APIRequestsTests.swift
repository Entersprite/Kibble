import Foundation
import SwiftProtobuf
import Testing
@testable import GChatBridgeCore

@Suite("APIRequests")
struct APIRequestsTests {
    private let requests = APIRequests(endpoints: ChatEndpoints())

    @Test func theURLIsPinnedExactly() {
        let request = requests.request(
            method: "get_self_user_status",
            counter: 1,
            body: Data(),
            xsrfToken: "tok"
        )
        #expect(request.url.absoluteString == "https://chat.google.com/u/0/api/get_self_user_status"
            + "?c=1&rt=b&alt=proto&key=AIzaSyD7InnYR3VKdb4j2rMUEbTCIr2VyEazl6k")
    }

    @Test func itIsAPost() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: nil)
        #expect(request.method == .post)
    }

    @Test func theThreeHeadersAreAllPresent() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: "tok")
        #expect(request.headers["content-type"] == "application/x-protobuf")
        #expect(request.headers["x-framework-xsrf-token"] == "tok")
        #expect(request.headers["X-Goog-Encode-Response-If-Executable"] == "base64")
    }

    /// Unlike `ChannelRequests` (the long-poll family), `findings.md` §3.6's
    /// captured `/api/` header list has no referer, and neither does
    /// `client.py:598-668`'s `_base_request`. A referer crept in here once by
    /// analogy with the channel; this pins its absence so it cannot return
    /// unnoticed.
    @Test func thereIsNoRefererUnlikeTheChannelFamily() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: nil)
        #expect(request.headers["referer"] == nil)
    }

    /// Chat answers a request without a browser User-Agent with HTTP 200 and its
    /// unsupported-browser page - authenticated, and non-functional, with no
    /// clue in the status. §15.3 says that applies to every later request, not
    /// just the bootstrap.
    @Test func everyRequestCarriesTheUserAgentChatGatesOn() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: nil)
        #expect(request.headers["User-Agent"] == ChatEndpoints.defaultUserAgent)
    }

    @Test func theXSRFHeaderIsAbsentRatherThanEmptyWhenThereIsNoToken() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: nil)
        #expect(request.headers["x-framework-xsrf-token"] == nil)
    }

    @Test func theAccountIndexIsConfigurationHereToo() {
        let none = APIRequests(endpoints: ChatEndpoints(account: .none))
        let request = none.request(method: "m", counter: 3, body: Data(), xsrfToken: nil)
        #expect(request.url.absoluteString.hasPrefix("https://chat.google.com/api/m?c=3"))
    }

    /// A long poll holds a response open for a minute; an /api/ call does not,
    /// and inheriting the channel's generous default would turn a dead endpoint
    /// into a 70-second stall.
    @Test func theTimeoutIsShorterThanTheLongPollDefault() {
        let request = requests.request(method: "m", counter: 1, body: Data(), xsrfToken: nil)
        #expect(request.timeout == .seconds(30))
    }

    @Test func theBodyIsCarriedVerbatim() {
        let body = Data([0x08, 0x03])
        let request = requests.request(method: "m", counter: 1, body: body, xsrfToken: nil)
        #expect(request.body == body)
    }
}

@Suite("APIRequestHeader")
struct APIRequestHeaderTests {
    @Test func itIsTheWebClientAtTheVersionTheReferenceSends() {
        let header = APIRequestHeader.make()
        #expect(header.clientType == .web)
        #expect(header.clientVersion == 2_440_378_181_258)
    }

    /// `request_header` is field **100** in GetSelfUserStatusRequest and field
    /// **1** in PaginatedWorldRequest. A helper that flattened it to one number
    /// would serialise one of them under a tag the server does not read - and
    /// the request would be accepted and answered with nothing useful.
    @Test func theHeaderSerialisesUnderTheFieldNumberEachMessageDeclares() throws {
        var selfStatus = GetSelfUserStatusRequest()
        selfStatus.requestHeader = APIRequestHeader.make()
        let selfBytes: Data = try selfStatus.serializedBytes()
        // Field 100, wire type 2 -> key = 100 << 3 | 2 = 802 -> varint 0xA2 0x06
        #expect(selfBytes.prefix(2) == Data([0xA2, 0x06]))

        var world = PaginatedWorldRequest()
        world.requestHeader = APIRequestHeader.make()
        let worldBytes: Data = try world.serializedBytes()
        // Field 1, wire type 2 -> key = 1 << 3 | 2 = 10 -> varint 0x0A
        #expect(worldBytes.prefix(1) == Data([0x0A]))
    }
}

@Suite("APIMethod")
struct APIMethodTests {
    @Test func theNamesAreTheEndpointPathsTheReferenceUses() {
        #expect(APIMethod.getSelfUserStatus.name == "get_self_user_status")
        #expect(APIMethod.paginatedWorld.name == "paginated_world")
        #expect(APIMethod.listTopics.name == "list_topics")
    }
}
