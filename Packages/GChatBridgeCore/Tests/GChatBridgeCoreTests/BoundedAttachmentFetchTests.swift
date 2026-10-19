import Foundation
import Testing
@testable import GChatBridgeCore

struct BoundedAttachmentFetchTests {
    @Test func everyImageRedirectRetainsItsCeilingAndCredentialScope() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife), AttachmentFetchTests.image("four")
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "opaque", contentType: "image/png", variant: .preview, maximumBytes: 4
        )
        #expect(fetched.body == Data("four".utf8))
        let sent = await transport.sent
        #expect(sent.map(\.maxBodyBytes) == [4, 4])
        #expect(sent[0].headers["Cookie"] != nil)
        #expect(sent[1].headers["Cookie"] == nil)
    }

    @Test func oversizedImageAndEmojiAreRefusedEvenByAWholeBodyFake() async throws {
        for emoji in [false, true] {
            let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image("large")])
            do {
                if emoji {
                    _ = try await AttachmentFetchTests.fetch(transport).customEmojiImage(
                        readToken: "opaque",
                        maximumBytes: 4
                    )
                } else {
                    _ = try await AttachmentFetchTests.fetch(transport).fetch(
                        token: "opaque", contentType: "image/png", variant: .preview, maximumBytes: 4
                    )
                }
                Issue.record("An oversized media response was accepted")
            } catch let failure { #expect(failure.reason == .tooLarge) }
        }
    }

    @Test func aRedirectedDownloadUsesTheOwnedDestinationAndCeilingOnEveryHop() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            AttachmentFetchTests.image("file", contentType: "application/octet-stream")
        ])
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloaded = try await AttachmentFetchTests.fetch(transport).download(
            token: "opaque", contentType: "application/octet-stream", destination: destination,
            maximumBytes: 4,
            progress: { _, _ in }
        )
        #expect(downloaded.file == destination)
        #expect(downloaded.byteCount == 4)
        #expect(try Data(contentsOf: destination) == Data("file".utf8))
        #expect(await transport.sent.map(\.maxBodyBytes) == [4, 4])
    }

    @Test func remoteImagesCanLowerTheExistingLimitWithoutAddingCredentials() async throws {
        let transport = FakeHTTPTransport(responses: [AttachmentFetchTests.image("large")])
        await #expect(throws: RemoteImageFetch.Failure.tooLarge) {
            try await RemoteImageFetch(transport: transport).image(
                at: #require(URL(string: "https://image.example/a")),
                maximumBytes: 4
            )
        }
        let request = try #require(await transport.sent.first)
        #expect(request.maxBodyBytes == 4)
        #expect(request.headers["Cookie"] == nil)
    }
}
