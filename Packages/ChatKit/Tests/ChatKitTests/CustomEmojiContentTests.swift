import Foundation
import Testing
@testable import ChatKit

struct CustomEmojiContentTests {
    let emoji = CustomEmojiRef(id: "custom-1", shortcode: "party__parrot", imageToken: "opaque")

    @Test func customSpansSurviveMarkupAndBothWireForms() throws {
        let text = "**😀** " + emoji.displayText
        let span = MessageCustomEmoji(emoji: emoji, start: 7, length: emoji.displayText.utf16.count)
        let parsed = MessageMarkup.parse(ComposedMessage(
            text: text,
            content: MessageContent(customEmoji: [span])
        ))
        #expect(parsed.text == "😀 " + emoji.displayText)
        #expect(parsed.content?.customEmoji.first?.start == 3)
        let edited = MessageMarkup.editable(parsed, showing: ["bold"])
        #expect(MessageMarkup.parse(edited).content?.customEmoji == parsed.content?.customEmoji)
        let content = try #require(parsed.content)
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(MessageContent.self, from: data) == content)
        #expect(try JSONDecoder().decode(MessageContent.self, from: Data("{}".utf8)).customEmoji.isEmpty)
        let command = ChatCommand.sendMessage(
            conversationID: .init("chat"),
            threadID: nil,
            text: parsed.text,
            localID: nil,
            content: content
        )
        #expect(try JSONDecoder().decode(ChatCommand.self, from: JSONEncoder().encode(command)) == command)
    }

    @Test func malformedHugeSpansRefuseWithoutOverflowing() {
        let content = MessageContent(customEmoji: [
            MessageCustomEmoji(emoji: emoji, start: Int.max, length: Int.max),
            MessageCustomEmoji(emoji: emoji, start: 0, length: 1)
        ])
        #expect(throws: ChatError.self) {
            try content.validate(
                text: emoji.displayText,
                conversation: .init("chat"),
                capabilities: Capabilities(extendedFlags: ["customEmojiMessages"])
            )
        }
    }

    @Test func invalidMetadataCannotCrashMarkupAndOffsetsCannotOverflow() {
        let span = MessageCustomEmoji(emoji: emoji, start: Int.max, length: Int.max)
        let malformed = MessageCustomEmoji(emoji: emoji, start: 1, length: Int.max)
        let message = ComposedMessage(text: "**text**", content: MessageContent(customEmoji: [malformed]))
        #expect(MessageMarkup.parse(message).text == "text")
        #expect((MessageMarkup.editable(message).content?.customEmoji ?? []).isEmpty)
        #expect((MessageMarkup.editable(message, showing: ["bold"]).content?.customEmoji ?? []).isEmpty)
        #expect(span.shifted(by: 1).start == -1)
        #expect(MessageCustomEmoji.replacing([span], location: 0, length: 0, inserted: 1).isEmpty)
    }

    @Test func forwardedSnapshotsKeepCustomMetadataThroughSerialization() throws {
        let span = MessageCustomEmoji(emoji: emoji, start: 0, length: emoji.displayText.utf16.count)
        let original = Message(
            id: .init("message"),
            conversationID: .init("source"),
            threadID: .init("thread"),
            sender: .init("sender"),
            text: emoji.displayText,
            createdAt: Date()
        )
        let forward = ForwardedMessage(source: MessageQuote(message: original), customEmoji: [span])
        let decoded = try JSONDecoder().decode(ForwardedMessage.self, from: JSONEncoder().encode(forward))
        #expect(decoded.message.content?.customEmoji == [span])
    }

    @Test func oldProvidersRefuseCustomContentAndInvalidUTF16NeverDispatches() throws {
        let span = MessageCustomEmoji(emoji: emoji, start: 0, length: emoji.displayText.utf16.count)
        let content = MessageContent(customEmoji: [span])
        #expect(throws: ChatError.self) { try content.validate(
            text: emoji.displayText,
            conversation: .init("chat"),
            capabilities: Capabilities()
        ) }
        try content.validate(
            text: emoji.displayText,
            conversation: .init("chat"),
            capabilities: Capabilities(extendedFlags: ["customEmojiMessages"])
        )
        #expect(MessageCustomEmoji(emoji: emoji, start: 1, length: 1).range(in: "😀") == nil)
        let status = MemberStatus(customEmoji: emoji)
        let command = ChatCommand.setStatus(status)
        #expect(throws: ChatError.self) { try command.validateMessageContent(capabilities: Capabilities()) }
        try command.validateMessageContent(capabilities: Capabilities(extendedFlags: ["customEmojiStatus"]))
        #expect(try JSONDecoder().decode(MemberStatus.self, from: JSONEncoder().encode(status)) == status)
    }
}
