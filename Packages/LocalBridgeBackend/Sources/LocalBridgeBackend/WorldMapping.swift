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
            title: title(for: item),
            avatarURL: item.avatarURL.isEmpty ? nil : URL(string: item.avatarURL),
            lastActivity: item.hasSortTimestamp
                ? Date(timeIntervalSince1970: Double(item.sortTimestamp) / 1_000_000)
                : nil,
            unreadCount: Int(item.readState.unreadMessageCount),
            hasUnread: hasUnread(item),
            members: memberIDs(for: item),
            isThreaded: isThreaded(item)
        )
    }

    /// Whether anything in the conversation is newer than the read position.
    ///
    /// `unread_message_count` (field 4) is **not** the answer, and the reason
    /// is worth stating because reading it looked correct for four sessions:
    /// it arrives on **every** conversation and is always **zero** - measured
    /// across all 220 on the real account (`findings.md` §37.8). So the
    /// sidebar's badge was rendering a number the server genuinely sends as 0,
    /// not a field this mapping failed to read.
    ///
    /// What Chat actually supplies is the pair the *publishing* side of read
    /// state already uses: a read position, and the newest message's create
    /// time. §36 established that Google's own read comparison is
    /// **strictly greater than** - which is why a client must publish one
    /// microsecond past the newest message it has seen - so the same
    /// comparison read in the other direction is what "unread" means here.
    ///
    /// Both fields absent means **not unread**, which is the claim that
    /// asserts least: 3 of the 220 carry no `last_head_message_create_time_usec`
    /// at all, presumably having no messages, and marking those unread would
    /// invent activity rather than report it.
    ///
    /// `[Verify]` - **why** the count is always zero. It may need a fetch
    /// option this request does not set (§20.1 established only the *minimum*
    /// viable `PaginatedWorldRequest`), or it may be dead server-side. Nothing
    /// here can tell those apart, and the timestamp pair makes the answer
    /// unnecessary rather than merely deferred.
    ///
    /// `[Verify]` - `has_unread_thread` (field 25) also arrives on all 220 and
    /// is **not** read. Purple names it; its values were never measured, and
    /// "thread" suggests threaded replies rather than general unread - every
    /// conversation on this account is flat. It is the first thing to try if
    /// the comparison below turns out to disagree with Chat's own UI.
    private static func hasUnread(_ item: WorldItemLite) -> Bool {
        let state = item.readState
        guard state.hasLastHeadMessageCreateTimeUsec, state.hasLastReadTime else {
            return false
        }
        return state.lastHeadMessageCreateTimeUsec > state.lastReadTime
    }

    /// The server's own title, or `nil` for a client to derive one.
    ///
    /// `Conversation.title`'s own doc comment draws a line the proto can
    /// actually express: `nil` means "no server title, derive from members";
    /// an empty string means "the server really sent one". `hasRoomName` is
    /// the wire's own presence bit, so it - not `roomName.isEmpty` - is what
    /// decides which side of that line an item falls on.
    ///
    /// `name_users.group_name` is consulted second. `NameUsers` carries one,
    /// and whether Chat ever populates it is **unobserved**: the six group
    /// chats on the real account carry field 20 at 77-127 bytes, which is
    /// about three to five `UserId`s and leaves little room for a name
    /// (`findings.md` §37.6). Reading it anyway costs one branch and removes
    /// the need to be right about that arithmetic - if it is never sent, this
    /// falls through exactly as before.
    ///
    /// `[Verify]`: whether `room_name` is ever sent **present-and-empty**.
    /// §37.3 settled that it is sent at all - 199 of 220 - and the same run
    /// reported `present-empty 0`, so on this account it is always either
    /// absent or non-empty. One account, so trusting the presence bit remains
    /// the conservative reading rather than a confirmed one.
    private static func title(for item: WorldItemLite) -> String? {
        if item.hasRoomName {
            return item.roomName
        }
        if item.hasNameUsers, item.nameUsers.hasGroupName {
            return item.nameUsers.groupName
        }
        return nil
    }

    /// Who is in the conversation - from `dm_members` for a DM, and from
    /// `name_users` for a group chat.
    ///
    /// `dm_members` was the only source until 2026-09-08, and it is **absent
    /// on a space** (`findings.md` §37.5's cross-tab: the 15 DMs have it and
    /// the 6 group chats do not). So a group chat arrived with no members at
    /// all, and `Display.title(of:directory:me:)` fell through both of its
    /// branches to the last one - `conversation.id.rawValue` - and rendered
    /// **`space/AAQARch4B7w`** in the sidebar. The name was not missing from
    /// the protocol; it was in the field this function did not read.
    ///
    /// `name_user_ids` is exactly the list a client is meant to build a title
    /// from, which is what `Display` already does once the ids resolve
    /// through `get_members` - and they do, because
    /// `resolveAndEmitMembers(for:using:)` collects
    /// `conversations.flatMap(\.members)`.
    ///
    /// `[Verify]`: `name_users.has_more_name_users` is **not** read. When it
    /// is set the id list is truncated, so a derived title names only some of
    /// the people present - Chat's own client renders "A, B and 2 others".
    /// Whether it is ever set here is unobserved, and honouring it needs a
    /// count `Conversation` does not currently carry.
    private static func memberIDs(for item: WorldItemLite) -> [ChatKit.Member.ID] {
        let direct = item.dmMembers.members
        if !direct.isEmpty {
            return direct.map { ChatKit.Member.ID($0.id) }
        }
        return item.nameUsers.nameUserIds.map { ChatKit.Member.ID($0.id) }
    }
}
