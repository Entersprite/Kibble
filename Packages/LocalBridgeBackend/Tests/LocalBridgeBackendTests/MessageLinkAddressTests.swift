import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessageLinkAddressTests {
    @Test(arguments: ["dm", "room"])
    func messageURLsBecomeOpaqueAddresses(_ kind: String) throws {
        let url = try #require(URL(string: "https://chat.google.com/\(kind)/group/thread/message?cls=10"))
        let address = try #require(MessageLinkAddressMapping.address(url))
        #expect(address.conversation == Conversation.ID("\(kind == "room" ? "space" : "dm")/group"))
        #expect(address.thread == MessageThread.ID("thread"))
        #expect(address.message == Message.ID("message"))
        let scoped = try #require(URL(string: "https://chat.google.com/u/2/\(kind)/group/thread/message"))
        #expect(MessageLinkAddressMapping.address(scoped) == address)
    }

    @Test(arguments: [
        "https://chat.google.com.evil.test/dm/group/thread/message",
        "https://evil.test/dm/group/thread/message", "http://chat.google.com/dm/group/thread/message",
        "https://chat.google.com/dm/group/thread", "https://chat.google.com/dm/group/thread/message/extra",
        "https://chat.google.com/dm/group/../message", "https://chat.google.com/dm/group/thread/%2f",
        "https://user@chat.google.com/dm/group/thread/message"
    ])
    func unknownOrForeignShapesGrantNoAddress(_ raw: String) throws {
        #expect(try MessageLinkAddressMapping.address(#require(URL(string: raw))) == nil)
    }

    @Test func rawTextAndAnnotationsUseTheSameTranslation() throws {
        let raw = "https://chat.google.com/dm/group/thread/message?cls=10"
        let text = "See \(raw)"
        let mapped = ChannelEventMapping.links([], text: text)
        let link = try #require(mapped.first)
        #expect(mapped.count == 1)
        #expect(link.start == 4)
        #expect(link.length == raw.utf16.count)
        #expect(link.messageAddress?.message == Message.ID("message"))
        var annotation = Annotation()
        annotation.startIndex = 4
        annotation.length = Int32(raw.utf16.count)
        annotation.urlMetadata.url.url = raw
        annotation.urlMetadata.title = "Original"
        let annotated = ChannelEventMapping.links([annotation], text: text)
        #expect(annotated.count == 1)
        #expect(annotated.first?.messageAddress == link.messageAddress)
        #expect(annotated.first?.preview?.title == "Original")
        let punctuated = ChannelEventMapping.links([], text: "See (\(raw)).")
        #expect(punctuated.first?.messageAddress == link.messageAddress)
        #expect(punctuated.first?.length == raw.utf16.count)
    }
}
