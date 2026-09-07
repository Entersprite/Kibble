import ChatKit
import Foundation
import GChatBridgeCore

/// Posting a message - `send(_:)`.
///
/// Its own file for the same reason `+History.swift` and `+Directory.swift`
/// are: swiftlint's `file_length`, and this is a coherent concern rather than
/// an arbitrary cut.
public extension LocalBridgeBackend {
    /// Submits one command.
    ///
    /// **Throws only when the command could not be submitted**, which is
    /// `ChatBackend.send(_:)`'s stated contract. The message that results
    /// arrives through the event stream like any other, because that is the
    /// only path a hosted backend would have - a local one returning it
    /// directly would give the two seams different shapes.
    ///
    /// `[Verify]`: `create_topic` has never been sent by this implementation.
    /// See `SendRequests`' own doc comment for why there is no ladder behind
    /// this and why that is a deliberate departure from every other `/api/`
    /// family in this package.
    func send(_ command: ChatCommand) async throws {
        switch command {
        case let .sendMessage(conversationID, threadID, text, localID):
            try await sendMessage(
                conversationID: conversationID,
                threadID: threadID,
                text: text,
                localID: localID
            )
        case let .markRead(conversationID, upTo):
            try await markRead(conversationID, upTo: upTo)
        // Exhaustive with no `default`, the same idiom `ConnectionIssueMapping`
        // and `SyncReducer` use: a new `ChatCommand` case stops this compiling
        // until someone decides whether this backend can honour it.
        case .editMessage, .deleteMessage, .setReaction, .setTyping,
             .setNotificationLevel, .unknown:
            throw ChatError.unsupported(capability: Self.commandName(command))
        }
    }

    private func sendMessage(
        conversationID: Conversation.ID,
        threadID: MessageThread.ID?,
        text: String,
        localID: String?
    ) async throws {
        guard let apiClient else {
            throw ChatError.unknown(
                "send(_:) requires connect() to succeed first - "
                    + "there is no verified session or xsrf token yet"
            )
        }
        guard let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown(
                "\(conversationID.rawValue) has neither the space/ nor the dm/ prefix "
                    + "this backend produces, so no send request can be built for it"
            )
        }
        // Generated here when the caller supplied none, rather than left empty:
        // the server echoes this back on the resulting message and it is the
        // only thing that marks the echo as ours.
        let identifier = localID ?? SendRequests.makeLocalID()
        // `threadID` is never `nil` for a message this backend produced itself
        // (`ChannelEventMapping.swift` always fills it in from the topic a
        // message was posted in), so the emptiness check - not just the
        // `nil` check - is what keeps a round-tripped id from a flat
        // conversation out of the threaded branch. Without it, an empty but
        // non-`nil` `threadID` would still route here and post a
        // `create_message` carrying an empty topic id.
        if let threadID, !threadID.rawValue.isEmpty {
            let response: CreateMessageResponse
            do {
                response = try await apiClient.call(.createMessage, SendRequests.createMessage(
                    group: group, topicID: threadID.rawValue, text: text, localID: identifier
                ))
            } catch {
                throw Self.chatError(fromAPI: error, call: "the /api/ create_message call")
            }
            try Self.requireAccepted(
                response.hasMessage && !response.message.id.messageID.isEmpty,
                call: "create_message",
                field: "message (field 1)"
            )
        } else {
            let response: CreateTopicResponse
            do {
                response = try await apiClient.call(.createTopic, SendRequests.createTopic(
                    group: group, text: text, localID: identifier
                ))
            } catch {
                throw Self.chatError(fromAPI: error, call: "the /api/ create_topic call")
            }
            try Self.requireAccepted(
                response.hasTopic && !response.topic.id.topicID.isEmpty,
                call: "create_topic",
                field: "topic (field 1)"
            )
        }
    }

    /// **HTTP 200 is not acceptance on this protocol.** Auth failure returns
    /// 200, so a send that threw nothing has only ever proved the HTTP call
    /// did not fail outright - and the optimistic row is already on screen by
    /// then, so a silent rejection is indistinguishable from a success.
    ///
    /// Deliberately shallow: the message is present and its id is not empty,
    /// nothing finer. The evidence is `1:2:NNN|2:2:18` on seven of seven live
    /// sends (session 19 §8), which supports "field 1 is populated" and
    /// supports nothing more than that.
    ///
    /// **The response is not written to the store.** The channel echoes the
    /// message back carrying the client's `local_id`, `ChatStore` deletes any
    /// row sharing it, and §23's "no duplicate messages" is the live evidence
    /// that the echo arrives. A second write path from here is how that
    /// becomes two messages.
    ///
    /// Reports field *numbers*, never content.
    private static func requireAccepted(
        _ accepted: Bool,
        call: String,
        field: String
    ) throws {
        guard !accepted else { return }
        throw ChatError.unknown(
            "the /api/ \(call) call answered 200 with no \(field), so nothing "
                + "confirms the message was accepted"
        )
    }

    /// What to call a command that this backend cannot honour, for the
    /// `unsupported(capability:)` it throws.
    private static func commandName(_ command: ChatCommand) -> String {
        switch command {
        case .sendMessage: "canSendMessages"
        case .editMessage: "canEditMessages"
        case .deleteMessage: "canDeleteMessages"
        case .setReaction: "canReact"
        case .setTyping: "canSendTypingState"
        case .markRead: "canMarkRead"
        case .setNotificationLevel: "canSetNotificationLevel"
        case let .unknown(type, _): type
        }
    }
}
