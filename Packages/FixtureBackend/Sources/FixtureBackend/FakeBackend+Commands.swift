import ChatKit
import Foundation

// MARK: - ChatBackend

/// Declared here, in the file that completes the requirements, so that each
/// piece of this type could be built and tested on its own.
extension FakeBackend: ChatBackend {}

// MARK: - Commands

public extension FakeBackend {
    /// Submits a command.
    ///
    /// Throws only when the command could not be *submitted* - there is no
    /// connection, or `capabilities` says no - which is exactly what
    /// `ChatBackend.send(_:)` promises. Everything else is an event.
    ///
    /// The switch is exhaustive on purpose and must stay that way: it is the
    /// compiler-enforced half of "no `ChatCommand` case goes unhandled", and it
    /// is stronger than any list a test could keep.
    func send(_ command: ChatCommand) async throws {
        try requireConnected()
        switch command {
        case let .sendMessage(conversationID, threadID, text, localID):
            try sendMessage(in: conversationID, thread: threadID, text: text, localID: localID)
        case let .editMessage(id, text):
            try editMessage(id, text: text)
        case let .deleteMessage(id):
            try deleteMessage(id)
        case let .setReaction(messageID, emoji, add):
            try setReaction(on: messageID, emoji: emoji, add: add)
        case let .setTyping(conversationID, _, _):
            try setTyping(in: conversationID)
        case let .markRead(conversationID, upTo):
            try markRead(conversationID, upTo: upTo)
        case let .setNotificationLevel(conversationID, level):
            try require(capabilities.canSetNotificationLevel, "canSetNotificationLevel")
            try updateConversation(conversationID) { $0.notificationLevel = level }
        case .watchPresence:
            // Nothing to do: every fixture member already carries its
            // presence, and a script changes it with `.presence`.
            break
        case let .unknown(type, _):
            // A command from a newer client. Naming it back is the whole
            // point: the client learns precisely what could not be honoured
            // rather than watching a connection drop.
            throw ChatError.unsupported(capability: type)
        }
    }
}

// MARK: - One case each

private extension FakeBackend {
    func sendMessage(
        in conversationID: Conversation.ID,
        thread: MessageThread.ID?,
        text: String,
        localID: String?
    ) throws {
        try require(capabilities.canSendMessages, "canSendMessages")
        if thread != nil {
            try require(capabilities.supportsThreads, "supportsThreads")
        }
        guard world.conversation(conversationID) != nil else {
            throw ChatError.unknown("no conversation \(conversationID) in this fixture world")
        }

        let message = Message(
            id: Message.ID(nextIdentifier("fixture-msg")),
            conversationID: conversationID,
            // A message with no thread is not a state this protocol can be in:
            // in a flat conversation the message simply is its own topic.
            threadID: thread ?? MessageThread.ID(nextIdentifier("fixture-topic")),
            sender: world.me,
            text: text,
            createdAt: advance(),
            localID: localID
        )
        world.messages.append(message)
        emit(.messageReceived(message))
        // No event says "a conversation's last activity moved", so the whole
        // snapshot goes out. Where a specific event does exist, it is used
        // instead - see deleteMessage and markRead.
        try updateConversation(conversationID) { $0.lastActivity = message.createdAt }
    }

    func editMessage(_ id: Message.ID, text: String) throws {
        try require(capabilities.canEditMessages, "canEditMessages")
        let edited = try updateMessage(id) {
            $0.text = text
            $0.editedAt = advance()
        }
        emit(.messageUpdated(edited))
    }

    func deleteMessage(_ id: Message.ID) throws {
        try require(capabilities.canDeleteMessages, "canDeleteMessages")
        let deleted = try updateMessage(id) {
            $0.isDeleted = true
            // Cleared, not removed: the tombstone keeps its place in the
            // ordering, so paging does not develop a hole.
            $0.text = ""
        }
        emit(.messageDeleted(id: id, in: deleted.conversationID))
    }

    func setReaction(on id: Message.ID, emoji: String, add: Bool) throws {
        try require(capabilities.canReact, "canReact")
        let me = world.me
        let updated = try updateMessage(id) { message in
            Self.applyReaction(
                emoji: emoji,
                add: add,
                by: me,
                isLocalUser: true,
                to: &message.reactions
            )
        }
        // The complete set, not a diff: reaction counts are small, and a diff
        // would need ordering guarantees this protocol does not offer.
        emit(.reactionChanged(messageID: id, reactions: updated.reactions))
    }

    func setTyping(in conversationID: Conversation.ID) throws {
        try require(capabilities.canSendTypingState, "canSendTypingState")
        guard world.conversation(conversationID) != nil else {
            throw ChatError.unknown("no conversation \(conversationID) in this fixture world")
        }
        // Deliberately silent. A backend does not echo your own typing state
        // back at you, and a fake that did would teach the client to render it.
    }

    func markRead(_ conversationID: Conversation.ID, upTo: Date) throws {
        try require(capabilities.canMarkRead, "canMarkRead")
        // emitUpdate: false because readStateChanged is the specific event for
        // this, and sending both would make a client choose which to believe.
        try updateConversation(conversationID, emitUpdate: false) { $0.unreadCount = 0 }
        emit(.readStateChanged(conversationID: conversationID, lastReadAt: upTo, unread: 0))
    }
}

// MARK: - Reactions

extension FakeBackend {
    /// Adds or removes one person's reaction, in place.
    ///
    /// Idempotent in both directions: reacting twice is one reaction, and
    /// removing one that was never there changes nothing. The real protocol
    /// behaves that way because the client's button is a toggle over state it
    /// may not have seen yet. Delegates to `[Reaction].applying`, the fold the
    /// optimistic write uses.
    static func applyReaction(
        emoji: String,
        add: Bool,
        by _: Member.ID,
        isLocalUser: Bool,
        to reactions: inout [Reaction]
    ) {
        reactions = reactions.applying(ReactionChoice(emoji: emoji), add: add, isLocalUser: isLocalUser)
    }
}
