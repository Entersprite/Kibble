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
        mentions: [ChatKit.Mention]
    ) async throws {
        let target = try address(id, conversationID, threadID, what: "an edit")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.unknown("an edit needs text; removing a message is a delete")
        }
        let plain = mentions.map { ChatKit.Mention(target: $0.target, start: $0.start, length: $0.length) }
        let annotations = await mentionAnnotations(plain, using: target.client)
        let request = MessageEditRequests.editMessage(
            group: target.group, topicID: target.topic, messageID: id.rawValue, text: text,
            annotations: annotations
        )
        do {
            _ = try await target.client.call(.editMessage, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ edit_message call")
        }
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
