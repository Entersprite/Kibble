import ChatKit
import Foundation

// MARK: - Playing the server's half

public extension FakeBackend {
    /// The world's current state. For assertions and for a demo host that wants
    /// to know what it is showing; the client learns everything through events.
    var currentWorld: FixtureWorld {
        world
    }

    /// How many events this backend has emitted since it was created.
    ///
    /// Exposed so a test can wait for exactly the events a script produced
    /// instead of hardcoding a count that goes stale - and so a hang shows up
    /// as a wrong number rather than a minute of silence.
    var emittedCount: Int {
        emitted
    }

    /// Runs every step in order.
    ///
    /// `.delay` steps are **ignored** here. A test must never wait: playing a
    /// ten-minute demo script has to take microseconds, and the waiting is
    /// `FixtureDemoDriver`'s job.
    func play(_ script: FixtureScript) throws {
        for step in script.steps {
            try apply(step)
        }
    }

    /// Reports something that went wrong outside a command - a broken script,
    /// or whatever a host wants a client to see. It reaches the client as
    /// `backendError`, which by design does not end the stream.
    func report(_ error: any Error) {
        emit(.backendError(error as? ChatError ?? .unknown(String(describing: error))))
    }

    /// Applies one step.
    ///
    /// Throws when the step names something the world does not contain. That is
    /// a bug in the script rather than a condition a client could hit, and
    /// silently skipping it would leave a demo mysteriously missing a message.
    ///
    /// The routing switch below is exhaustive and that is the point: a new
    /// `FixtureStep` case stops this file compiling until someone decides which
    /// family it belongs to. The three functions it dispatches to are partial
    /// by construction, which is why each ends in an unreachable `default`.
    func apply(_ step: FixtureStep) throws {
        switch step {
        case .incomingMessage, .editMessage, .deleteMessage, .reaction:
            try applyContentStep(step)
        case .typing, .presence, .readState:
            try applyStateStep(step)
        case .gap, .drop, .reconnecting, .error, .delay:
            applyChannelStep(step)
        }
    }
}

// MARK: - The three families

private extension FakeBackend {
    /// Messages and the things attached to them.
    func applyContentStep(_ step: FixtureStep) throws {
        switch step {
        case let .incomingMessage(conversation, from, text, thread):
            try receive(in: conversation, from: from, text: text, thread: thread)
        case let .editMessage(id, text):
            let edited = try updateMessage(id) {
                $0.text = text
                $0.editedAt = advance()
            }
            emit(.messageUpdated(edited))
        case let .deleteMessage(id):
            let deleted = try updateMessage(id) {
                $0.isDeleted = true
                $0.text = ""
            }
            emit(.messageDeleted(id: id, in: deleted.conversationID))
        case let .reaction(messageID, emoji, by, add):
            try react(to: messageID, emoji: emoji, by: by, add: add)
        default:
            break
        }
    }

    /// Ephemeral state about people and conversations.
    func applyStateStep(_ step: FixtureStep) throws {
        switch step {
        case let .typing(conversation, member, isTyping):
            try requireExists(conversation)
            try requireExists(member)
            emit(.typingChanged(conversationID: conversation, member: member, isTyping: isTyping))
        case let .presence(member, presence):
            try setPresence(of: member, to: presence)
        case let .readState(conversation, unread):
            try updateConversation(conversation, emitUpdate: false) { $0.unreadCount = unread }
            emit(.readStateChanged(conversationID: conversation, lastReadAt: now, unread: unread))
        default:
            break
        }
    }

    /// The connection itself. None of these can fail, because none of them
    /// names anything in the world.
    func applyChannelStep(_ step: FixtureStep) {
        switch step {
        case let .gap(scope, reason):
            emit(.gap(scope: scope, reason: reason))
        case let .drop(reason):
            // The state moves as well as being announced. A fake that only said
            // it had dropped would keep accepting commands the client has been
            // told cannot arrive.
            isConnected = false
            emit(.connectionStateChanged(.disconnected(reason: reason, issue: nil)))
        case let .reconnecting(attempt):
            emit(.connectionStateChanged(.reconnecting(attempt: attempt, issue: nil, detail: nil)))
        case let .error(error):
            emit(.backendError(error))
        case .delay:
            // The demo driver's business, not a test's.
            break
        default:
            break
        }
    }
}

// MARK: - Steps that touch the world

private extension FakeBackend {
    func receive(
        in conversation: Conversation.ID,
        from sender: Member.ID,
        text: String,
        thread: MessageThread.ID?
    ) throws {
        try requireExists(conversation)
        try requireExists(sender)
        if let thread {
            try requireThread(thread, in: conversation)
        }

        let message = Message(
            id: Message.ID(nextIdentifier("fixture-msg")),
            conversationID: conversation,
            threadID: thread ?? MessageThread.ID(nextIdentifier("fixture-topic")),
            sender: sender,
            text: text,
            createdAt: advance(),
            isReply: thread != nil
        )
        world.messages.append(message)
        emit(.messageReceived(message))

        let isMine = sender == world.me
        try updateConversation(conversation) {
            $0.lastActivity = message.createdAt
            // Our own message arriving from another device is already read,
            // and a reply counts against its thread, never its conversation
            // (threads spec §4.3).
            if !isMine, !message.isReply {
                $0.unreadCount += 1
            }
        }
        if message.isReply {
            announceReply(message)
        }
    }

    func react(to id: Message.ID, emoji: String, by member: Member.ID, add: Bool) throws {
        try requireExists(member)
        let isLocalUser = member == world.me
        let updated = try updateMessage(id) { message in
            Self.applyReaction(
                emoji: emoji,
                add: add,
                by: member,
                isLocalUser: isLocalUser,
                to: &message.reactions
            )
        }
        emit(.reactionChanged(messageID: id, reactions: updated.reactions))
    }

    func setPresence(of member: Member.ID, to presence: Presence) throws {
        guard let index = world.members.firstIndex(where: { $0.id == member }) else {
            throw ChatError.unknown("no member \(member) in this fixture world")
        }
        world.members[index].presence = presence
        emit(.presenceChanged(member: member, presence: presence))
    }

    func requireExists(_ conversation: Conversation.ID) throws {
        guard world.conversation(conversation) != nil else {
            throw ChatError.unknown("no conversation \(conversation) in this fixture world")
        }
    }

    func requireExists(_ member: Member.ID) throws {
        guard world.member(member) != nil else {
            throw ChatError.unknown("no member \(member) in this fixture world")
        }
    }
}
