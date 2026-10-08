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
        case let .sendMessage(conversationID, threadID, text, localID, attachments, mentions):
            try sendMessage(
                in: conversationID, thread: threadID, body: ComposedMessage(text: text, mentions: mentions),
                localID: localID, attachments: attachments
            )
        case let .editMessage(id, text, _, _, mentions):
            try editMessage(id, text: text, mentions: mentions)
        case let .deleteMessage(id, _, _):
            try deleteMessage(id)
        case let .setReaction(messageID, emoji, add, _, _, customEmoji):
            let choice = customEmoji.map(ReactionChoice.init(customEmoji:)) ?? ReactionChoice(emoji: emoji)
            try setReaction(on: messageID, choice: choice, add: add)
        case let .setTyping(conversationID, _, _):
            try setTyping(in: conversationID)
        case let .markRead(conversationID, upTo):
            try markRead(conversationID, upTo: upTo)
        case let .setNotificationLevel(conversationID, level):
            try require(capabilities.canSetNotificationLevel, "canSetNotificationLevel")
            try updateConversation(conversationID) { $0.notificationLevel = level }
        case .watchPresence, .loadMembers, .reportActivity:
            // Nothing to do: every fixture member already carries its
            // presence, and a script changes it with `.presence`; every
            // fixture conversation already lists its members, which the
            // world load emits; and the fixture has no presence to keep active.
            // One case for all three, for `cyclomatic_complexity`.
            break
        case .setStatus, .setAvailability:
            try applyOwnStatus(command)
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
        body: ComposedMessage,
        localID: String?,
        attachments: [Attachment]
    ) throws {
        try require(capabilities.canSendMessages, "canSendMessages")
        if thread != nil {
            try require(capabilities.supportsThreads, "supportsThreads")
        }
        if !attachments.isEmpty {
            try require(capabilities.canSendAttachments, "canSendAttachments")
        }
        guard attachments.allSatisfy({ uploaded[$0.id] != nil }) else {
            throw ChatError.unknown("an attachment this fixture never uploaded was sent")
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
            text: body.text,
            createdAt: advance(),
            attachments: attachments,
            localID: localID,
            mentions: body.mentions
        )
        world.messages.append(message)
        emit(.messageReceived(message))
        // No event says "a conversation's last activity moved", so the whole
        // snapshot goes out. Where a specific event does exist, it is used
        // instead - see deleteMessage and markRead.
        try updateConversation(conversationID) { $0.lastActivity = message.createdAt }
        try addInvited(body.mentions, to: conversationID)
    }

    /// An `.invite` mention of a directory person adds them, the way Chat's
    /// "Add and send" does (`findings.md` §58.1). `.withoutAdding` adds no one.
    func addInvited(_ mentions: [Mention], to conversationID: Conversation.ID) throws {
        for mention in mentions where mention.mode == .invite {
            guard case let .user(id) = mention.target,
                  let person = directory.first(where: { $0.id == id }),
                  world.conversation(conversationID)?.members.contains(id) == false
            else { continue }
            if world.member(id) == nil {
                world.members.append(person)
            }
            let updated = try updateConversation(conversationID, emitUpdate: false) { $0.members.append(id) }
            emit(.membersChanged(conversationID: conversationID, members: world.members(in: updated)))
        }
    }

    func editMessage(_ id: Message.ID, text: String, mentions: [Mention] = []) throws {
        try require(capabilities.canEditMessages, "canEditMessages")
        let edited = try updateMessage(id) {
            $0.text = text
            $0.mentions = mentions
            // Spans into the old text no longer mean anything (review finding 1).
            $0.links = $0.links.filter { $0.start == nil }
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

    func setReaction(on id: Message.ID, choice: ReactionChoice, add: Bool) throws {
        try require(capabilities.canReact, "canReact")
        let updated = try updateMessage(id) { message in
            message.reactions = message.reactions.applying(choice, add: add)
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

extension FakeBackend {
    /// Your status and availability, applied to the world and reported back
    /// the way the bridge reports its server's answer (set-your-status spec
    /// §3). Availability is not kept: nothing in the world reads it.
    func applyOwnStatus(_ command: ChatCommand) throws {
        try require(capabilities.canSetStatus, "canSetStatus")
        switch command {
        case let .setStatus(status):
            if let index = world.members.firstIndex(where: { $0.id == world.me }) {
                world.members[index].status = status
            }
            emit(.statusChanged(member: world.me, status: status))
        case let .setAvailability(availability):
            emit(.availabilityChanged(availability))
        default:
            break
        }
    }
}
