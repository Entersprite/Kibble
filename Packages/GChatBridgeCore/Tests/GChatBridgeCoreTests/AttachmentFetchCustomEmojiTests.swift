import Foundation
import Testing
@testable import GChatBridgeCore

/// `customEmojiImage(readToken:)`: the call Chat on the web makes for a custom
/// emoji (`findings.md` §54.4), walked under every attachment fetch's rules.
@Suite("Attachment fetch - custom emoji image")
struct AttachmentFetchCustomEmojiTests {
    /// Review Focus 4: the live token has `+`, `=` and `_`; `/` is added so
    /// every reserved character a base64 alphabet uses is pinned.
    @Test func theFirstHopNamesTheTokenUnderTheAccount() async throws {
        let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image()])
        _ = try await AttachmentFetchTests.fetch(transport).customEmojiImage(readToken: "tok/+=en_x")
        let sent = try #require(await transport.sent.first)
        #expect(sent.method == .get)
        #expect(sent.followsRedirects == false)
        #expect(sent.url.host() == "chat.google.com")
        #expect(sent.url.path() == "/u/0/api/get_custom_emoji_image")
        #expect(sent.url.query(percentEncoded: true) == "custom_emoji_read_token=tok%2F%2B%3Den_x")
        #expect(sent.headers["Cookie"]?.contains(AttachmentFetchTests.cookieSecret) == true)
    }

    @Test func theRedirectToLh3IsFollowedWithNoCredentials() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            AttachmentFetchTests.image()
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport).customEmojiImage(readToken: "t")
        #expect(fetched.body == Data("PNGBYTES".utf8))
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(sent.last?.url.host() == "lh3.googleusercontent.com")
        let lh3 = try #require(sent.last)
        #expect(!lh3.headers.fields.contains { field in
            field.value.contains(AttachmentFetchTests.cookieSecret)
        })
    }
}
