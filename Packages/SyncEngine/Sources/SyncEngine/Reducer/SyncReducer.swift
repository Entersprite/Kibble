import ChatKit
import Foundation

/// What each event means for the store.
///
/// Pure, and takes **no prior state** - which is a property of `ChatKit`'s event
/// design rather than a simplification here. `conversationsChanged` carries the
/// whole list, `reactionChanged` the complete reaction set, `readStateChanged`
/// the count after the change. The events were built to be applied without
/// knowing what came before, so there is nothing to diff against.
///
/// **This file must not import a database.** It is the half of the sync layer
/// that a bridge server runs verbatim, and the moment it knows about GRDB the
/// server needs its own copy - which is how read state and history end up with
/// two sources of truth. `scripts/test.sh` enforces the import ban.
public enum SyncReducer {
    /// The writes and effects one event implies.
    ///
    /// Routed by family rather than written as one switch, because fourteen
    /// cases exceed swiftlint's complexity limit. The routing switch is
    /// exhaustive on purpose: a new `ChatEvent` case stops this compiling until
    /// someone decides what it means for the store.
    public static func reduce(_ event: ChatEvent) -> Reduction {
        switch event {
        case .messageReceived, .messageUpdated, .messageDeleted, .reactionChanged:
            reduceMessageEvent(event)
        case .conversationsChanged, .conversationUpdated, .membersChanged,
             .readStateChanged, .typingChanged, .presenceChanged:
            reduceConversationEvent(event)
        case .connectionStateChanged, .backendError, .gap, .unknown:
            reduceSessionEvent(event)
        }
    }

    private static func reduceMessageEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .messageReceived(message), let .messageUpdated(message):
            // Identical on purpose: the store's job is to end up holding the
            // message, and an upsert already says exactly that.
            Reduction(writes: [.upsertMessage(message)])
        case let .messageDeleted(id, conversationID):
            Reduction(writes: [.markMessageDeleted(id: id, in: conversationID)])
        case let .reactionChanged(messageID, reactions):
            Reduction(writes: [.setReactions(messageID: messageID, reactions: reactions)])
        default:
            Reduction()
        }
    }

    private static func reduceConversationEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .conversationsChanged(conversations):
            Reduction(writes: [.replaceConversations(conversations)])
        case let .conversationUpdated(conversation):
            Reduction(writes: [.upsertConversation(conversation)])
        case let .membersChanged(conversationID, members):
            Reduction(writes: [
                .upsertMembers(members),
                .setMembership(conversation: conversationID, members: members.map(\.id))
            ])
        case let .readStateChanged(conversationID, lastReadAt, unread):
            Reduction(writes: [
                .setReadState(conversation: conversationID, lastReadAt: lastReadAt, unread: unread)
            ])
        case let .typingChanged(conversationID, member, isTyping):
            Reduction(writes: [
                .setTyping(conversation: conversationID, member: member, isTyping: isTyping)
            ])
        case let .presenceChanged(member, presence):
            Reduction(writes: [.setPresence(member: member, presence: presence)])
        default:
            Reduction()
        }
    }

    private static func reduceSessionEvent(_ event: ChatEvent) -> Reduction {
        switch event {
        case let .connectionStateChanged(state):
            Reduction(writes: [.setConnectionState(state)])
        case let .backendError(error):
            Reduction(writes: [.setLastError(error)])
        case let .gap(scope, _):
            switch scope {
            case .everything:
                Reduction(effects: [.reloadConversations])
            case let .conversation(id):
                Reduction(effects: [.reloadMessages(id)])
            }
        case .unknown:
            // Deliberately nothing. A client built before a feature ignores it
            // rather than failing; that is what forward compatibility buys, and
            // a test asserts this stays intentional.
            Reduction()
        default:
            Reduction()
        }
    }
}
