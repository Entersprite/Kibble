import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MessageContentMappingTests {
    @Test func providerContentMapsThroughTheSharedHistoryAndEventMapper() throws {
        var message = GChatBridgeCore.Message()
        message.id.messageID = "reply"
        message.id.parentID.topicID.topicID = "reply-topic"
        message.id.parentID.topicID.groupID.dmID.dmID = "dm"
        message.creator.userID.id = "person"
        message.textBody = "hello 😀"
        message.createTime = 2_000_000
        var annotation = Annotation()
        annotation.type = .formatData
        annotation.startIndex = 6
        annotation.length = 2
        annotation.formatMetadata.formatType = .bold
        message.annotations = [annotation]
        message.replyTo.id.messageID = "original"
        message.replyTo.id.parentID.topicID.topicID = "original-topic"
        message.replyTo.id.parentID.topicID.groupID = message.id.parentID.topicID.groupID
        message.replyTo.senderID.id = "peer"
        message.replyTo.textBody = "quoted"
        message.replyTo.createTime = 1_000_000
        let mapped = try #require(ChannelEventMapping.domainMessage(message))
        #expect(mapped.content?.formatting == [MessageFormat(style: "bold", start: 6, length: 2)])
        let quote = try #require(mapped.content?.quote)
        #expect(quote.id == ChatKit.Message.ID("original"))
        #expect(quote.conversation == mapped.conversationID)
        let targetValue = try MessageContentMapping.target(quote, in: mapped.conversationID)
        let target = try #require(targetValue)
        #expect(target.id.messageID == "original")
        #expect(target.id.parentID.topicID.topicID == "original-topic")
        #expect(target.createTime == 1_000_000)
        let formats = try MessageContentMapping.annotations(
            mapped.content?.formatting ?? [],
            text: mapped.text
        )
        #expect(formats.first?.formatMetadata.formatType == .bold)
        let topic = SendRequests.createTopic(
            group: message.id.parentID.topicID.groupID,
            text: mapped.text,
            localID: "send",
            annotations: formats,
            quote: target
        )
        #expect(topic.messageInfo.replyTo == target)
        #expect(topic.annotations == formats)
        message.deleteTime = 3_000_000
        #expect(ChannelEventMapping.domainMessage(message)?.content == nil)
    }
}
