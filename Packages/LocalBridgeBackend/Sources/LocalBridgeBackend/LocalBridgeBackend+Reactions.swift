import ChatKit
import Foundation
import GChatBridgeCore

/// `.setReaction` through `update_reaction`. Its own file for the same
/// `file_length` reason `+Send.swift` has one.
///
/// **The response is not written anywhere.** It carries a write revision and
/// nothing about reactions; the person's own toggle is already in the store
/// (`ChatSessionModel.react`), and the server's complete set arrives through
/// the channel (reactions spec §2.2, plan 1b).
///
/// `conversationID`, `threadID` and `customEmoji` default to `nil`, mirroring
/// `ChatCommand.setReaction`'s own defaults for the same three parameters -
/// `+Send.swift`'s one call site still names every argument, and the default
/// is what keeps six labelled parameters under swiftlint's
/// `function_parameter_count`.
extension LocalBridgeBackend {
    func setReaction(
        messageID: ChatKit.Message.ID,
        emoji: String,
        add: Bool,
        conversationID: Conversation.ID? = nil,
        threadID: MessageThread.ID? = nil,
        customEmoji: CustomEmojiRef? = nil
    ) async throws {
        guard let apiClient else {
            throw ChatError.unknown(
                "send(_:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let conversationID, let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown("a reaction needs its message's conversation, and this command has none "
                + "this backend can address")
        }
        guard let threadID, !threadID.rawValue.isEmpty else {
            throw ChatError.unknown("a reaction needs its message's topic, and this command has none")
        }
        let request = ReactionRequests.updateReaction(
            group: group,
            topicID: threadID.rawValue,
            messageID: messageID.rawValue,
            unicode: customEmoji == nil ? emoji : nil,
            customEmojiID: customEmoji?.id,
            add: add
        )
        do {
            _ = try await apiClient.call(.updateReaction, request)
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ update_reaction call")
        }
    }
}
