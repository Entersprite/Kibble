import Foundation
import Testing
@testable import GChatBridgeCore

/// `fetch(url:)`: an address Google handed out, such as a custom emoji's
/// `ephemeral_url`, walked under the same rules as every attachment fetch.
@Suite("Attachment fetch - any URL")
struct AttachmentFetchURLTests {
    @Test func aGoogleusercontentHostIsSentNoCredentials() async throws {
        let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image()])
        let fetched = try await AttachmentFetchTests.fetch(transport)
            .fetch(url: #require(URL(string: AttachmentFetchTests.fife)))
        let sent = try #require(await transport.sent.first)
        #expect(sent.url.absoluteString == AttachmentFetchTests.fife)
        #expect(!sent.headers.fields.contains { $0.value.contains(AttachmentFetchTests.cookieSecret) })
        #expect(fetched.body == Data("PNGBYTES".utf8))
        #expect(fetched.hops.map(\.carriedCredentials) == [false])
    }

    @Test func theChatHostIsSentTheSession() async throws {
        let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image()])
        _ = try await AttachmentFetchTests.fetch(transport)
            .fetch(url: #require(URL(string: "https://chat.google.com/api/get_custom_emoji_image?x=1")))
        let sent = try #require(await transport.sent.first)
        #expect(sent.headers["Cookie"]?.contains(AttachmentFetchTests.cookieSecret) == true)
    }

    @Test func aSignInRedirectIsAFailureOfItsOwn() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://accounts.google.com/ServiceLogin")
        ])
        await #expect {
            _ = try await AttachmentFetchTests.fetch(transport)
                .fetch(url: #require(URL(string: AttachmentFetchTests.fife)))
        } throws: { error in
            (error as? AttachmentFetchFailure)?.reason == .signInRedirect
        }
    }
}
