import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct CustomEmojiContentMappingTests {
    let emoji = CustomEmojiRef(id: "custom-1", shortcode: "parrot", imageToken: "opaque")

    @Test func customEmojiUsesItsTypedAnnotationAndImageTokenReturnsOnlyFromTheProvider() throws {
        let text = "😀 " + emoji.displayText
        let span = MessageCustomEmoji(emoji: emoji, start: 3, length: emoji.displayText.utf16.count)
        var annotation = try #require(try MessageContentMapping.emojiAnnotations([span], text: text).first)
        #expect(annotation.type.rawValue == 25)
        #expect(annotation.customEmojiMetadata.customEmoji.uuid == emoji.id)
        #expect(!annotation.customEmojiMetadata.customEmoji.hasReadToken)
        annotation.customEmojiMetadata.customEmoji.readToken = "provider-token"
        var message = GChatBridgeCore.Message()
        message.textBody = text
        message.annotations = [annotation]
        let mapped = try #require(MessageContentMapping.content(message)?.customEmoji.first)
        #expect(mapped.start == 3)
        #expect(mapped.emoji.imageToken == "provider-token")
        let bytes = try annotation.serializedData()
        #expect(try Annotation(serializedBytes: bytes).customEmojiMetadata.customEmoji.uuid == emoji.id)
        message.deleteTime = 1
        #expect(MessageContentMapping.content(message) == nil)
    }

    @Test func statusSubmitsTheCustomIdentityAndNeverMistakesItForUnicode() {
        let status = MemberStatus(customEmoji: emoji)
        let request = OwnStatusRequests.setCustomStatus(status)
        #expect(request.customStatus.emoji.customEmoji.uuid == emoji.id)
        #expect(!request.customStatus.emoji.hasUnicode)
        #expect(OwnStatusRequests.sent(status)?.customEmoji == emoji)
    }
}
