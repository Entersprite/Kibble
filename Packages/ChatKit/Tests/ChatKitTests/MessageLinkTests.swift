import Foundation
import Testing
@testable import ChatKit

struct MessageLinkTests {
    private static let specs = URL(string: "https://acme.example/specs")!

    private func message(links: [MessageLink]) -> Message {
        Message(
            id: Fixture.messageID, conversationID: Fixture.spaceID, threadID: Fixture.threadID,
            sender: Fixture.humanID, text: "Specs: https://acme.example/specs and the doc",
            createdAt: Fixture.createdAt, links: links
        )
    }

    @Test func aMessageWithLinksMatchesItsGoldenFile() throws {
        try expectWireStable(message(links: [
            MessageLink(url: Self.specs, start: 7, length: 26, preview: LinkPreview(
                title: "Spring catalog specs", snippet: "Every size, one sheet",
                imageURL: URL(string: "https://lh3.googleusercontent.com/preview-1"),
                imageWidth: 1200, imageHeight: 630, domain: "acme.example"
            )),
            MessageLink(url: #require(URL(string: "https://acme.example/doc")), start: 42, length: 3),
            MessageLink(url: #require(URL(string: "https://media.acme.example/party.gif")))
        ]), golden: "message-links")
    }

    /// No key when empty, so every message golden written before links
    /// stays byte-identical; an absent key reads as none.
    @Test func noLinksOmitsTheKeyAndAnOldFrameReadsAsNone() throws {
        let encoded = try Wire.json(message(links: []))
        #expect(!encoded.contains("links"))
        #expect(try Wire.decode(Message.self, from: Golden.load("message")).links.isEmpty)
    }

    @Test func anUnanchoredLinkWritesNoSpan() throws {
        let encoded = try Wire.json(MessageLink(url: Self.specs))
        #expect(encoded == #"{"url":"https://acme.example/specs"}"#)
    }
}
