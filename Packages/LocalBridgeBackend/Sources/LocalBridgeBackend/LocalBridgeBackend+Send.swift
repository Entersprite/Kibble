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
        guard case let .sendMessage(conversationID, threadID, text, localID) = command else {
            // Named rather than swallowed. A caller learns precisely what could
            // not be honoured instead of watching a message vanish.
            throw ChatError.unsupported(capability: Self.commandName(command))
        }
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
            do {
                _ = try await apiClient.call(.createMessage, SendRequests.createMessage(
                    group: group, topicID: threadID.rawValue, text: text, localID: identifier
                ))
            } catch {
                throw Self.chatError(fromAPI: error, call: "the /api/ create_message call")
            }
        } else {
            do {
                _ = try await apiClient.call(.createTopic, SendRequests.createTopic(
                    group: group, text: text, localID: identifier
                ))
            } catch {
                throw Self.chatError(fromAPI: error, call: "the /api/ create_topic call")
            }
        }
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
