import ChatKit
import Foundation
import GChatBridgeCore

/// `PaginatedWorldResponse` becoming `[Conversation]`.
///
/// The field numbers below are `findings.md` §20.1's table - the minimum
/// viable request (rung 2 of `WorldRequestLadder`) answered with four
/// `world_items` at **top level** (response field 4), and that table is what
/// was checked against the vendored proto. What §20.1 could **not** check is
/// which fields *inside* one `WorldItemLite` are actually populated - the scan
/// that ran was top-level only (§20.4's `[Verify]`). So every field read here
/// is a field number confirmed to exist in the proto, applied to a shape that
/// has not yet been observed on the wire.
///
/// ## Nothing is silently dropped
///
/// An item whose `group_id` cannot become a `Conversation.ID` -
/// `ChannelEventMapping.conversationID` returning `nil`, because it is neither
/// a non-empty `space_id` nor a non-empty `dm_id` - is not a conversation this
/// mapping can build. It is still real data the server sent, and folding it
/// into a shorter `conversations` array with no trace would be exactly the
/// kind of silent loss this project keeps writing findings about. `skipped`
/// is the count, so a caller can report it instead.
public enum WorldMapping {
    /// A mapped world, plus what could not be placed.
    public struct Result: Sendable, Hashable {
        public let conversations: [Conversation]

        /// How many `world_items` did not become a `Conversation`. Never
        /// folded into `conversations.count` going down - counted separately,
        /// so a caller can tell "the server sent fewer" from "some were
        /// unplaceable".
        public let skipped: Int

        public init(conversations: [Conversation], skipped: Int) {
            self.conversations = conversations
            self.skipped = skipped
        }
    }

    public static func map(_ response: PaginatedWorldResponse) -> Result {
        var conversations: [Conversation] = []
        var skipped = 0
        for item in response.worldItems {
            guard let conversation = conversation(from: item) else {
                skipped += 1
                continue
            }
            conversations.append(conversation)
        }
        return Result(conversations: conversations, skipped: skipped)
    }

    private static func conversation(from item: WorldItemLite) -> Conversation? {
        guard let id = ChannelEventMapping.conversationID(item.groupID) else { return nil }
        return Conversation(
            id: id,
            kind: kind(for: item),
            // An absent `room_name` and an empty one are the same fact on
            // this wire - Chat does not name most DMs - and `Conversation.title`'s
            // own doc comment draws the line here: `nil` means "derive from
            // members"; only a real, non-empty string may claim to be a
            // server-provided title.
            title: item.roomName.isEmpty ? nil : item.roomName,
            avatarURL: item.avatarURL.isEmpty ? nil : URL(string: item.avatarURL),
            lastActivity: item.hasSortTimestamp
                ? Date(timeIntervalSince1970: Double(item.sortTimestamp) / 1_000_000)
                : nil,
            unreadCount: Int(item.readState.unreadMessageCount),
            members: item.dmMembers.members.map { ChatKit.Member.ID($0.id) },
            isThreaded: isThreaded(item)
        )
    }

    /// Space, direct message, or group direct message.
    ///
    /// `[Verify]`: **cannot currently distinguish an app DM** from a human
    /// one - both arrive as `dm_id`, and nothing this project has observed
    /// tells them apart at this layer. Guessed by member count rather than
    /// reported as `.unknown`, because an app DM is a real, usable DM, and
    /// filing it under `.unknown` would hide it from the sidebar entirely -
    /// the worse of the two wrong answers.
    private static func kind(for item: WorldItemLite) -> Conversation.Kind {
        switch item.groupID.id {
        case .spaceID:
            .space
        case .dmID:
            item.dmMembers.members.count <= 2 ? .directMessage : .groupDirectMessage
        default:
            // Unreachable in practice: `conversation(from:)` only reaches
            // here once `ChannelEventMapping.conversationID` has already
            // succeeded, which requires `group.id` to be one of the two
            // cases above with a non-empty inner id. Kept explicit rather
            // than force-unwrapped, because "unreachable today" is not a
            // promise a future proto regeneration has to keep.
            .unknown("noGroupID")
        }
    }

    /// `threaded_group` present beats `flat_group` present beats
    /// `group_lite.is_flat`, inverted.
    ///
    /// The ladder run (`findings.md` §20.1) is why `group_lite` cannot be
    /// dropped from the request even though `EXCLUDE_GROUP_LITE` costs ~48
    /// bytes an item: it is the only place `is_flat` lives when neither
    /// oneof case is set.
    private static func isThreaded(_ item: WorldItemLite) -> Bool {
        if item.hasThreadedGroup {
            return true
        }
        if item.hasFlatGroup {
            return false
        }
        return !item.groupLite.isFlat
    }
}
