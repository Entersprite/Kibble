import ChatKit
import Foundation
import GChatBridgeCore

/// `GetMembersResponse` becoming `[ChatKit.Member]`.
///
/// `findings.md` §20.4 found that a `WorldItemLite` carries no names at all -
/// `room_name`, `name_users` and `avatar_url` are all absent from a live
/// response - so names have to come from a separate call. `get_members` is
/// that call, the way the reference uses it (`client.py:691-697`), and this
/// is the one place its response becomes a domain `Member` - the same rule
/// `WorldMapping` follows for `PaginatedWorldResponse`.
///
/// **`get_members` has never been sent by this implementation.** Every field
/// read below is a field number confirmed against the vendored proto,
/// applied to a response shape nobody has observed - exactly the caveat
/// `APIMethod.getMembers`'s own doc comment carries, and the same posture
/// `WorldMapping` took toward `WorldItemLite` before §20.4's live run.
///
/// ## Nothing is silently dropped
///
/// A `Member` protobuf entry whose `user_id.id` is empty - because the wire
/// never set a profile at all, or set one with no id - is not a member this
/// mapping can place under any identity. It is still real data the server
/// sent, and folding it into a shorter list with no trace would be the same
/// kind of silent loss `WorldMapping.Result.skipped` exists to prevent.
public enum MemberMapping {
    /// A mapped member list, plus what could not be placed.
    public struct Result: Sendable, Hashable {
        public let members: [ChatKit.Member]

        /// How many `members` entries did not become a `ChatKit.Member`,
        /// counted separately from `members.count` for the same reason
        /// `WorldMapping.Result.skipped` is: a caller can tell "the server
        /// sent fewer" from "some were unplaceable".
        public let skipped: Int

        public init(members: [ChatKit.Member], skipped: Int) {
            self.members = members
            self.skipped = skipped
        }
    }

    public static func map(_ response: GetMembersResponse) -> Result {
        var members: [ChatKit.Member] = []
        var skipped = 0
        for wireMember in response.members {
            guard let member = domainMember(wireMember) else {
                skipped += 1
                continue
            }
            members.append(member)
        }
        return Result(members: members, skipped: skipped)
    }

    private static func domainMember(_ wireMember: GChatBridgeCore.Member) -> ChatKit.Member? {
        let user = wireMember.user
        let id = user.userID.id
        guard !id.isEmpty else { return nil }
        return ChatKit.Member(
            id: ChatKit.Member.ID(id),
            kind: kind(for: user.userID.type),
            // `Display.name` treats an empty name as absent and falls back to
            // the id, so an empty string here would be a silently useless
            // name rather than an honest "we do not have one" - same rule
            // for `email` and `avatarURL` below.
            displayName: user.name.isEmpty ? nil : user.name,
            email: user.email.isEmpty ? nil : user.email,
            avatarURL: user.avatarURL.isEmpty ? nil : URL(string: user.avatarURL)
            // presence: left at its default of `nil`. Nothing has observed
            // presence on this call, and `Presence` distinguishes "nobody
            // told us" from "a state we do not understand" - inventing
            // either would be wrong.
        )
    }

    /// `HUMAN` and `BOT`, and nothing else - `.unknown(String(describing:))`
    /// for anything the vendored `UserType` cannot name.
    ///
    /// Matched on `rawValue` rather than switching on `type` directly:
    /// `UserType` has exactly two cases in this vendored proto, so a plain
    /// `switch` covering both is already exhaustive and a trailing `default`
    /// would be flagged as dead code. Reading the raw value keeps the
    /// `.unknown` branch real Swift rather than something the compiler would
    /// prove can never run - the same posture `WorldMapping.kind(for:)` takes
    /// with its own "unreachable today" `default`, kept explicit because
    /// "unreachable today" is not a promise a future proto regeneration has
    /// to keep.
    private static func kind(for type: UserType) -> ChatKit.Member.Kind {
        switch type.rawValue {
        case UserType.human.rawValue: .human
        case UserType.bot.rawValue: .app
        default: .unknown(String(describing: type))
        }
    }
}
