import ChatKit
import Foundation
import GChatBridgeCore

/// `.editMessage` and `.deleteMessage` through `edit_message` and
/// `delete_message`. Its own file for `file_length`, like `+Reactions.swift`,
/// which it mirrors.
///
/// **The response is not written anywhere.** The person's change is already
/// in the store (`ChatSessionModel.edit`/`delete`), and the server's version
/// arrives through the channel as `MESSAGE_UPDATED`, which `ChannelEventMapping`
/// already maps (`last_edit_time`, `delete_time`).
///
/// **An edit never invites** (edit spec §3): every mention goes as a plain
/// mention, whatever mode it arrived with. Adding people belongs to sends.
extension LocalBridgeBackend {
    func editMessage(
        id: ChatKit.Message.ID,
        text: String,
        conversationID: Conversation.ID?,
        threadID: MessageThread.ID?,
        mentions: [ChatKit.Mention], content: MessageContent? = nil
    ) async throws {
        let target = try address(id, conversationID, threadID, what: "an edit")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.unknown("an edit needs text; removing a message is a delete")
        }
        let generation = directoryGeneration
        let plain = mentions.map { ChatKit.Mention(target: $0.target, start: $0.start, length: $0.length) }
        let formats = try MessageContentMapping.annotations(content?.formatting ?? [], text: text)
            + MessageContentMapping.emojiAnnotations(content?.customEmoji ?? [], text: text)
        let annotations = await mentionAnnotations(plain, using: target.client) + formats
        let originalID = MessagePinRequests.address(
            group: target.group, topic: target.topic, message: id.rawValue
        )
        do {
            try checkManagementGeneration(generation)
            let reply = try await editReference(at: originalID, client: target.client, generation: generation)
            let request = MessageEditRequests.editMessage(
                group: target.group, topicID: target.topic, messageID: id.rawValue, text: text,
                annotations: annotations, replyTo: reply
            )
            _ = try await target.client.call(.editMessage, request)
        } catch let error as APIFailure {
            throw Self.chatError(fromAPI: error, call: "the /api/ edit_message call")
        }
    }

    /// A caption edit carries the reference from the addressed receiving
    /// message. Reading the source conversation is unnecessary.
    private func editReference(
        at address: MessageId, client: ProtoAPIClient, generation: Int
    ) async throws -> SendReplyTarget? {
        let response: GetMessageResponse
        do {
            response = try await client.call(.pinTarget, MessagePinRequests.message(address))
        } catch {
            throw Self.chatError(fromAPI: error, call: "reading the message before editing")
        }
        try checkManagementGeneration(generation)
        let existing = response.message
        guard response.hasMessage, existing.id == address, existing.deleteTime == 0,
              existing.messageType != .systemMessage,
              calendarPoll.me.map({ existing.creator.userID.id == $0.rawValue }) ?? true
        else { throw ChatError.decoding("The message could not be verified for editing.") }
        if !existing.hasReplyTo {
            guard !existing.annotations.contains(where: { $0.type == .replyReference })
            else { throw ChatError.unsupported(capability: "editing a message with an incomplete reference") }
            return nil
        }
        let reference = existing.replyTo
        guard [0, 1, 2].contains(reference.referenceType), reference.createTime > 0,
              !reference.id.messageID.isEmpty, !reference.id.parentID.topicID.topicID.isEmpty,
              ChannelEventMapping.conversationID(reference.id.parentID.topicID.groupID) != nil
        else { throw ChatError.unsupported(capability: "editing a message with an incomplete reference") }
        var target = SendReplyTarget()
        target.id = reference.id
        target.createTime = reference.createTime
        if reference.hasReferenceType {
            target.referenceType = reference.referenceType
        }
        return target
    }

    func deleteMessage(
        id: ChatKit.Message.ID,
        conversationID: Conversation.ID?,
        threadID: MessageThread.ID?
    ) async throws {
        let target = try address(id, conversationID, threadID, what: "a delete")
        let request = MessageEditRequests.deleteMessage(
            group: target.group, topicID: target.topic, messageID: id.rawValue
        )
        do {
            _ = try await target.client.call(.deleteMessage, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ delete_message call")
        }
    }

    /// Where one of the person's messages lives, and the client to reach it.
    private struct Target {
        let client: ProtoAPIClient
        let group: GroupId
        let topic: String
    }

    /// The client, group and topic, or a refusal before the network: an
    /// empty `MessageId` must never reach Google.
    private func address(
        _ id: ChatKit.Message.ID,
        _ conversationID: Conversation.ID?,
        _ threadID: MessageThread.ID?,
        what: String
    ) throws -> Target {
        guard let apiClient else {
            throw ChatError.unknown(
                "send(_:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let conversationID, let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown("\(what) needs its message's conversation, and this command has none "
                + "this backend can address")
        }
        guard let threadID, !threadID.rawValue.isEmpty else {
            throw ChatError.unknown("\(what) needs its message's topic, and this command has none")
        }
        guard !id.rawValue.isEmpty else {
            throw ChatError.unknown("\(what) needs its message's id, and this command has none")
        }
        return Target(client: apiClient, group: group, topic: threadID.rawValue)
    }
}
