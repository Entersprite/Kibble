import ChatKit
import Testing

struct MessageMarkupLiteralTests {
    @Test func editingPlainListsAndCodeWithBackticksPreservesTheActualText() {
        for text in ["- literal line", "path C:\\Users\\example", "a ` b", "a ``` b \\ c"] {
            for style in ["code", "codeBlock"] {
                let source = ComposedMessage(text: text, content: MessageContent(formatting: [
                    MessageFormat(style: style, start: 0, length: text.utf16.count)
                ]))
                let restored = MessageMarkup.parse(MessageMarkup.editable(source))
                #expect(restored.text == source.text)
                #expect(restored.content == source.content)
            }
            let plain = ComposedMessage(text: text)
            #expect(MessageMarkup.parse(MessageMarkup.editable(plain)).text == text)
        }
        #expect(MessageMarkup.parse(ComposedMessage(text: "C:\\Users\\example")).text == "C:\\Users\\example")
    }

    @Test func aMentionContainingSyntaxKeepsItsExactNameAndAddress() {
        let name = "@Team\\*name"
        let mention = Mention(target: .user(.init("person")), start: 2, length: name.utf16.count)
        let parsed = MessageMarkup.parse(ComposedMessage(text: "**" + name + "**", mentions: [mention]))
        #expect(parsed.text == name)
        #expect(parsed.mentions.first?.start == 0)
        #expect(parsed.mentions.first?.length == name.utf16.count)
    }

    @Test func formattedEditsCannotBypassValidationByOmittingTheirAddress() {
        let command = ChatCommand.editMessage(
            id: .init("message"),
            text: "text",
            content: MessageContent(formatting: [
                MessageFormat(style: "bold", start: 0, length: 4)
            ])
        )
        #expect(throws: ChatError.self) { try command.validateMessageContent(capabilities: Capabilities()) }
    }
}
