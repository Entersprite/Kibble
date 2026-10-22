import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct MessageLinkPresentationTests {
    private let address = MessageAddress(
        conversation: .init("source"),
        thread: .init("thread"),
        message: .init("original")
    )

    private func message(_ text: String, links: [MessageLink] = []) -> Message {
        Message(
            id: .init("row"),
            conversationID: .init("chat"),
            threadID: .init("thread"),
            sender: .init("author"),
            text: text,
            createdAt: Date(timeIntervalSince1970: 1),
            links: links
        )
    }

    @Test func addressedURLBecomesAQuoteWhileUnicodeMentionsFormattingAndOtherLinksKeepTheirOffsets() throws {
        let raw = "https://internal.example/original"
        let text = "👋 See \(raw) Alex https://external.example/"
        let ns = text as NSString
        let range = ns.range(of: raw)
        let alex = ns.range(of: "Alex")
        let external = ns.range(of: "https://external.example/")
        var original = try message(text, links: [
            MessageLink(
                url: #require(URL(string: raw)),
                start: range.location,
                length: range.length,
                messageAddress: address
            ),
            MessageLink(
                url: #require(URL(string: "https://external.example/")),
                start: external.location,
                length: external.length
            )
        ])
        original.mentions = [Mention(target: .user(.init("alex")), start: alex.location, length: alex.length)]
        original.content = MessageContent(formatting: [MessageFormat(
            style: "bold",
            start: 0,
            length: text.utf16.count
        )])
        let result = MessageLinkPresentation(original, internalHosts: ["internal.example"])
        #expect(result.references.count == 1)
        #expect(result.references.first?.messageAddress == address)
        #expect(result.message.text == "👋 See  Alex https://external.example/")
        #expect(result.message.mentions.first?.start == alex.location - raw.utf16.count)
        #expect(result.message.links.first?.start == external.location - raw.utf16.count)
        #expect(result.message.content?.formatting.first?.length == result.message.text.utf16.count)
        #expect(original.text == text)
    }

    @Test func legacyInternalURLsProduceInertReferencesAndCannotOpenInTheBrowser() throws {
        let raw = "https://internal.example/unknown-shape"
        let result = MessageLinkPresentation(message(raw), internalHosts: ["internal.example"])
        #expect(result.message.text.isEmpty)
        #expect(result.references.count == 1)
        #expect(result.references.first?.messageAddress == nil)
        #expect(try !LinkPolicy.canOpen(#require(URL(string: raw)), blocking: ["internal.example"]))
        #expect(try LinkPolicy.canOpen(
            #require(URL(string: "https://external.example/")),
            blocking: ["internal.example"]
        ))
    }

    @Test func malformedUTF16RangesCannotRemoveAdjacentText() throws {
        let link = try MessageLink(
            url: #require(URL(string: "https://internal.example/")),
            start: 1,
            length: 1,
            messageAddress: address
        )
        let result = MessageLinkPresentation(message("👋 text", links: [link]), internalHosts: [])
        #expect(result.message.text == "👋 text")
        #expect(result.references.count == 1)
    }
}
