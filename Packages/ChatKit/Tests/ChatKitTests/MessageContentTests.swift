import Foundation
import Testing
@testable import ChatKit

struct MessageContentTests {
    @Test func nestedFormattingAndMentionsKeepUTF16Addresses() throws {
        let input = "**Hello *😀*** @Reader `*literal*`"
        let mention = (input as NSString).range(of: "@Reader")
        let parsed = MessageMarkup.parse(ComposedMessage(text: input, mentions: [
            Mention(target: .user(Member.ID("reader")), start: mention.location, length: mention.length)
        ]))
        #expect(parsed.text == "Hello 😀 @Reader *literal*")
        #expect(parsed.content?.formatting
            .contains(MessageFormat(style: "bold", start: 0, length: 8)) == true)
        #expect(parsed.content?.formatting
            .contains(MessageFormat(style: "italic", start: 6, length: 2)) == true)
        let mapped = try #require(parsed.mentions.first)
        #expect((parsed.text as NSString).substring(with: NSRange(
            location: mapped.start,
            length: mapped.length
        )) == "@Reader")
        let decoded = MessageMarkup.parse(MessageMarkup.editable(parsed))
        #expect(decoded.text == parsed.text)
        #expect(decoded.mentions == parsed.mentions)
    }

    @Test func codeEscapesListsAndMentionNamesAreNotReinterpreted() {
        let text = "- **one**\n- `two`\n\\*literal\\* @A*B"
        let span = (text as NSString).range(of: "@A*B")
        let parsed = MessageMarkup.parse(ComposedMessage(text: text, mentions: [
            Mention(target: .user(Member.ID("person")), start: span.location, length: span.length)
        ]))
        #expect(parsed.text == "one\ntwo\n*literal* @A*B")
        #expect(parsed.content?.formatting.filter { $0.style == "bulletItem" }.count == 2)
        #expect(parsed.mentions.count == 1)
    }

    @Test func contentCrossesCommandsAndMessagesWithBackwardCompatibleDefaults() throws {
        let original = Message(
            id: Message.ID("m"), conversationID: Conversation.ID("c"), threadID: MessageThread.ID("t"),
            sender: Member.ID("s"), text: "quoted", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let content = MessageContent(
            formatting: [MessageFormat(style: "future-style", start: 0, length: 2)],
            quote: MessageQuote(message: original)
        )
        let command = ChatCommand.sendMessage(
            conversationID: original.conversationID, threadID: nil, text: "hi", localID: nil, content: content
        )
        let encoded = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(ChatCommand.self, from: encoded) == command)
        var message = original
        message.content = content
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(Message.self, from: data) == message)
        #expect(try JSONDecoder().decode(MessageContent.self, from: Data("{}".utf8)).isEmpty)
        #expect(MessageFormat(style: "bold", start: 1, length: 1).range(in: "😀") == nil)
    }

    @Test func olderProvidersAndForeignQuotesAreRefusedBeforeDispatch() throws {
        let format = MessageContent(formatting: [MessageFormat(style: "bold", start: 0, length: 1)])
        #expect(throws: ChatError.self) {
            try format.validate(text: "x", conversation: Conversation.ID("a"), capabilities: Capabilities())
        }
        let quote = MessageQuote(message: Message(
            id: Message.ID("m"), conversationID: Conversation.ID("other"), threadID: MessageThread.ID("t"),
            sender: Member.ID("s"), text: "text", createdAt: Date(timeIntervalSince1970: 1)
        ))
        #expect(throws: ChatError.self) {
            try MessageContent(quote: quote).validate(
                text: "x", conversation: Conversation.ID("a"),
                capabilities: Capabilities(extendedFlags: ["quotedMessages"])
            )
        }
    }
}
