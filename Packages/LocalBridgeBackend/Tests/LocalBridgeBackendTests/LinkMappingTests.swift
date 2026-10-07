import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Link annotations to `MessageLink` (links spec §4.1). Shapes from the proto
/// and the references; `findings.md` §60's measured shapes are `[Verify]`
/// until the owner's probe run.
struct LinkMappingTests {
    private func link(
        start: Int32? = nil, length: Int32? = nil, url: String = "https://acme.example/doc",
        title: String? = "Spring catalog", image: String? = nil, width: Int32? = nil, height: String? = nil,
        hidden: Bool? = nil, byOneof: Bool = true
    ) -> GChatBridgeCore.Annotation {
        var metadata = UrlMetadata()
        metadata.url.url = url
        if let title {
            metadata.title = title
        }
        if let image {
            metadata.imageURL = image
        }
        if let width {
            metadata.intImageWidth = width
        }
        if let height {
            metadata.imageHeight = height
        }
        if let hidden {
            metadata.shouldNotRender = hidden
        }
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = byOneof ? .formatData : .url
        if let start {
            annotation.startIndex = start
        }
        if let length {
            annotation.length = length
        }
        if byOneof {
            annotation.urlMetadata = metadata
        }
        return annotation
    }

    @Test func anAnchoredLinkWithAPreviewMaps() throws {
        let mapped = ChannelEventMapping.links([link(
            start: 9, length: 3, image: "https://lh3.googleusercontent.com/p", width: 1200, height: "630"
        )], text: "read the doc")
        #expect(try mapped == [MessageLink(
            url: #require(URL(string: "https://acme.example/doc")), start: 9, length: 3,
            preview: LinkPreview(
                title: "Spring catalog", imageURL: URL(string: "https://lh3.googleusercontent.com/p"),
                imageWidth: 1200, imageHeight: 630
            )
        )])
    }

    @Test func theOneofDecidesNotTheType() {
        #expect(ChannelEventMapping.links([link(byOneof: false)], text: "x").isEmpty)
        #expect(ChannelEventMapping.links([link(byOneof: true)], text: "x").count == 1)
    }

    /// Review Focus 3.
    @Test(arguments: ["javascript:alert(1)", "file:///etc/hosts", "mailto:ops@acme.example", "", "not a url"])
    func onlyWebURLsBecomeLinks(_ raw: String) {
        #expect(ChannelEventMapping.links([link(url: raw)], text: "x").isEmpty)
    }

    @Test func badSpansBecomeUnanchoredNotDropped() {
        let text = "read the doc"
        for annotation in [
            link(),
            link(start: 0, length: 0),
            link(start: 9, length: 30),
            link(start: -1, length: 3)
        ] {
            let mapped = ChannelEventMapping.links([annotation], text: text)
            #expect(mapped.count == 1)
            #expect(mapped.first?.start == nil)
            #expect(mapped.first?.length == nil)
        }
    }

    @Test func aHiddenPreviewKeepsAnAnchoredLinkAndDropsAnUnanchoredOne() {
        let anchored = ChannelEventMapping.links(
            [link(start: 9, length: 3, hidden: true)],
            text: "read the doc"
        )
        #expect(anchored.count == 1)
        #expect(anchored.first?.preview == nil)
        #expect(ChannelEventMapping.links([link(hidden: true)], text: "read the doc").isEmpty)
    }

    @Test func noTitleNoPreviewAndAnHTTPImageIsDropped() {
        #expect(ChannelEventMapping.links([link(title: nil)], text: "x").first?.preview == nil)
        #expect(ChannelEventMapping.links([link(title: "  ")], text: "x").first?.preview == nil)
        let insecure = ChannelEventMapping.links([link(image: "http://acme.example/p.png")], text: "x")
        #expect(insecure.first?.preview?.imageURL == nil)
        #expect(insecure.first?.preview?.title == "Spring catalog")
    }

    @Test func domainMessageCarriesTheLinks() throws {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "m-1"
        message.id.parentID.topicID.topicID = "t-1"
        message.id.parentID.topicID.groupID = try #require(
            ChannelEventMapping.groupID(for: Conversation.ID("space/s-1"))
        )
        message.textBody = "read the doc"
        message.annotations = [link(start: 9, length: 3)]
        let mapped = try #require(ChannelEventMapping.domainMessage(message))
        #expect(mapped.links.count == 1)
    }
}
