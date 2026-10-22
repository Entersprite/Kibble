import ChatKit

extension FakeBackend {
    func resolvedForward(_ body: ComposedMessage) throws -> ComposedMessage {
        guard let reference = body.content?.forwardSource else { return body }
        guard let original = world.message(reference.id), original.conversationID == reference.conversation,
              original.threadID == reference.thread, !original.isDeleted, original.callStatus == nil else {
            throw ChatError.decoding("The original message is unavailable.")
        }
        var source = MessageQuote(message: original)
        source.text = original.text
        let author = world.member(original.sender)
        var result = body
        result.content?.forwardSource = nil
        result.content?.forwarded = ForwardedMessage(
            source: source, senderName: author?.displayName, senderAvatarURL: author?.avatarURL,
            mentions: original.mentions, formatting: original.content?.formatting ?? [],
            customEmoji: original.content?.customEmoji ?? [],
            attachments: original.attachments, links: original.links
        )
        return result
    }
}
