import ChatKit
import Foundation
import Testing
@testable import DesignSystem

struct MeetingLinkPresentationTests {
    private let hosts: Set<String> = ["meet.example"]
    private let url = URL(string: "https://meet.example/abc-defg-hij")!

    private func message(_ text: String, links: [MessageLink] = []) -> Message {
        Message(
            id: .init("row"), conversationID: .init("chat"), threadID: .init("thread"),
            sender: .init("author"), text: text, createdAt: Date(timeIntervalSince1970: 1), links: links
        )
    }

    @Test func bareURLBecomesOneMeetingWithoutChangingTheStoredMessage() {
        let original = message(url.absoluteString)
        let result = MessageLinkPresentation(original, internalHosts: [], meetingHosts: hosts)
        #expect(result.message.text.isEmpty && result.message.links.isEmpty)
        #expect(result.meetings.map(\.url) == [url])
        #expect(result.references.isEmpty)
        #expect(original.text == url.absoluteString && original.links.isEmpty)
    }

    @Test func replacementPreservesUnicodeMentionsFormattingAndOtherURLs() throws {
        let text = "👋 \(url) Alex https://other.example/page"
        let name = (text as NSString).range(of: "Alex")
        let external = (text as NSString).range(of: "https://other.example/page")
        var original = try message(text, links: [MessageLink(
            url: #require(URL(string: "https://other.example/page")), start: external.location,
            length: external.length
        )])
        original.mentions = [Mention(target: .user(.init("alex")), start: name.location, length: name.length)]
        original.content = MessageContent(formatting: [MessageFormat(
            style: "bold", start: name.location, length: name.length
        )])
        let result = MessageLinkPresentation(original, internalHosts: [], meetingHosts: hosts)
        #expect(result.message.text == "👋  Alex https://other.example/page")
        #expect(result.message.mentions.first?.start == name.location - url.absoluteString.utf16.count)
        #expect(result.message.content?.formatting.first?.range(in: result.message.text) != nil)
        let link = try #require(result.message.links.first)
        #expect(link.start == external.location - url.absoluteString.utf16.count)
        #expect(result.meetings.count == 1)
    }

    @Test func repeatedURLsAndAnUnanchoredPreviewProduceOnlyOneNamedCard() {
        let preview = MessageLink(url: url, preview: LinkPreview(title: "Weekly planning"))
        let original = message("Join \(url) or \(url)", links: [preview])
        let result = MessageLinkPresentation(original, internalHosts: [], meetingHosts: hosts)
        #expect(result.message.text == "Join  or ")
        #expect(result.message.links.isEmpty)
        #expect(result.meetings == [preview])
        #expect(MeetingLinkCard.title(for: preview, in: original.text) == "Weekly planning")
    }

    @Test func namedLinkAndMissingMetadataHaveHonestTitles() {
        let link = MessageLink(url: url, start: 0, length: 11)
        #expect(MeetingLinkCard.title(for: link, in: "Weekly sync") == "Weekly sync")
        #expect(MeetingLinkCard.title(for: MessageLink(url: url), in: "") == "Meeting")
        #expect(MeetingLinkCard.title(for: MessageLink(
            url: url, preview: LinkPreview(title: url.absoluteString)
        ), in: "") == "Meeting")
    }

    @Test(arguments: [
        "https://meet.example.evil/abc-defg-hij", "http://meet.example/abc-defg-hij",
        "https://user@meet.example/abc-defg-hij", "https://meet.example:8443/abc-defg-hij",
        "https://meet.example/", "https://meet.example/abc-defg-hij#fragment"
    ])
    func ordinaryOrUnsafeLinksKeepTheirExistingPresentation(_ raw: String) {
        let original = message(raw)
        let result = MessageLinkPresentation(original, internalHosts: [], meetingHosts: hosts)
        #expect(result.message.text == raw && result.meetings.isEmpty)
    }

    @Test func unavailableHostsAndInternalReferencesNeverBecomeMeetingCards() {
        let original = message(url.absoluteString)
        let unavailable = MessageLinkPresentation(original, internalHosts: [])
        #expect(unavailable.meetings.isEmpty && unavailable.message.text == original.text)
        let internalLink = MessageLinkPresentation(original, internalHosts: hosts, meetingHosts: hosts)
        #expect(internalLink.meetings.isEmpty && internalLink.references.count == 1)
    }
}
