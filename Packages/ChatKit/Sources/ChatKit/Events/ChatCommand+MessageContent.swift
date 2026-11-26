import Foundation

public extension ChatCommand {
    func validateMessageContent(capabilities: Capabilities) throws {
        switch self {
        case let .sendMessage(conversation, _, text, _, _, _, content):
            try content?.validate(text: text, conversation: conversation, capabilities: capabilities)
        case let .editMessage(_, text, conversation, _, _, content):
            guard let content, !content.isEmpty else { return }
            guard content.forwardSource == nil
            else { throw ChatError.unsupported(capability: "editing forwards") }
            guard let conversation
            else { throw ChatError.decoding("Formatted edits need their conversation") }
            try content.validate(text: text, conversation: conversation, capabilities: capabilities)
        case let .setStatus(status):
            guard status?.customEmoji == nil || capabilities.canSetCustomEmojiStatus else {
                throw ChatError.unsupported(capability: "customEmojiStatus")
            }
            if let emoji = status?.customEmoji {
                guard !emoji.id.isEmpty, !emoji.shortcode.isEmpty, status?.emoji == nil else {
                    throw ChatError.decoding("Invalid custom status emoji")
                }
            }
        default: break
        }
    }
}
