import ChatKit
import Foundation

/// The state a `FakeBackend` serves: who exists, what conversations there are,
/// and every message in all of them.
///
/// A value type, deliberately. The backend holds one and replaces parts of it
/// as commands and script steps arrive, so a test can build a world, hand a
/// copy to two backends and know they started identical - which is what the
/// determinism test rests on.
///
/// ## No clock in here
///
/// `startedAt` is a literal instant, and every timestamp in a world is derived
/// from it. Nothing in this package reads the wall clock; the scan in
/// scripts/test.sh is the authoritative list of what that forbids. A fixture
/// whose timestamps moved between runs would make every golden comparison above
/// the seam a coin toss, and the failure would look like a bug in the code being
/// tested.
public struct FixtureWorld: Sendable, Hashable {
    /// The local user - the "me" whose messages render as outgoing, and whose
    /// reactions set `Reaction.includesMe`.
    public var me: Member.ID

    public var members: [Member]
    public var conversations: [Conversation]

    /// Every message in the world, oldest to newest. Flat rather than keyed by
    /// conversation because paging, ordering and "the last thing that happened"
    /// are all easier to keep honest in one ordered sequence, and the worlds
    /// here are small enough that filtering costs nothing.
    public var messages: [Message]

    /// The instant the world begins. A backend's clock starts here and advances
    /// by a fixed tick; see the type's note above.
    public var startedAt: Date

    /// What the server knows about each thread beyond its messages
    /// (`FixtureThreadState`), keyed by thread id, which is unique across a
    /// fixture world. Empty unless a world sets it, so `minimal` and every
    /// test counting it are unchanged. Never iterated unsorted: a
    /// dictionary's order changes from launch to launch.
    public var threadStates: [MessageThread.ID: FixtureThreadState] = [:]

    public init(
        me: Member.ID,
        members: [Member],
        conversations: [Conversation],
        messages: [Message],
        startedAt: Date
    ) {
        self.me = me
        self.members = members
        self.conversations = conversations
        self.messages = messages
        self.startedAt = startedAt
    }
}

// MARK: - Lookups

public extension FixtureWorld {
    /// One conversation's messages, oldest to newest.
    func messages(in conversation: Conversation.ID) -> [Message] {
        messages.filter { $0.conversationID == conversation }
    }

    func member(_ id: Member.ID) -> Member? {
        members.first { $0.id == id }
    }

    /// The member records a conversation's identifiers point at, in the
    /// conversation's own order. Unresolvable identifiers are dropped here and
    /// reported by `inconsistencies()`; this accessor is not the place to
    /// discover that a world is broken.
    func members(in conversation: Conversation) -> [Member] {
        conversation.members.compactMap(member)
    }

    func conversation(_ id: Conversation.ID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func message(_ id: Message.ID) -> Message? {
        messages.first { $0.id == id }
    }
}

// MARK: - Validity

public extension FixtureWorld {
    /// Everything wrong with this world, one human-readable line each. Empty
    /// means consistent.
    ///
    /// Worth having as shipped code rather than a test helper: the app can
    /// assert on it at launch in Debug, and a demo world that references a
    /// member who does not exist would otherwise surface as a blank name in the
    /// UI - a bug that looks like it belongs to the view.
    func inconsistencies() -> [String] {
        let memberIDs = Set(members.map(\.id))
        let conversationIDs = Set(conversations.map(\.id))
        var problems: [String] = []

        if !memberIDs.contains(me) {
            problems.append("the local user \(me) is not in members")
        }
        for conversation in conversations {
            for id in conversation.members where !memberIDs.contains(id) {
                problems.append("conversation \(conversation.id) lists member \(id), who does not exist")
            }
        }
        for message in messages {
            if !conversationIDs.contains(message.conversationID) {
                problems.append("message \(message.id) is in \(message.conversationID), which does not exist")
            }
            if !memberIDs.contains(message.sender) {
                problems.append("message \(message.id) was sent by \(message.sender), who does not exist")
            }
        }
        return problems + threadInconsistencies()
    }
}
