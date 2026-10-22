import ChatKit
import Foundation
import GChatBridgeCore

/// `GetUserPresenceResponse` becoming one `ChatKit.Presence` per person.
///
/// The one place a wire presence becomes a domain one, the rule `MemberMapping`
/// follows for `GetMembersResponse`. The wire has two axes and the domain has
/// one: `presence` (ACTIVE, INACTIVE, and three values this seam does not
/// model) and `dnd_state`. Do not disturb wins, because it is the thing a
/// person chose to say.
///
/// **`get_user_presence` has never been sent by this implementation**
/// (`APIMethod.getUserPresence`). The field numbers below agree across all
/// three vendored protos; the response shape is `[Verify]` until a probe run.
public enum PresenceMapping {
    /// `UserPresence.presence`'s field number, for the byte walk.
    private static let presenceField = 2

    public static func map(_ response: GetUserPresenceResponse) -> [ChatKit.Member.ID: ChatKit.Presence] {
        var result: [ChatKit.Member.ID: ChatKit.Presence] = [:]
        for entry in response.userPresences {
            let id = entry.userID.id
            guard !id.isEmpty, let presence = presence(of: entry) else { continue }
            result[ChatKit.Member.ID(id)] = presence
        }
        return result
    }

    /// Each answered person's status, from `user_status.custom_status`.
    ///
    /// The key is present only when the entry carries a `user_status`: one
    /// without it says nothing ("nobody told us"), which must not clear a
    /// status. A `user_status` with nothing to show - no custom status, or
    /// only empty strings - maps to `nil`, which is "cleared". So does one
    /// already past its expiry at `now`, whatever the server still sends: the
    /// poll then clears it within one interval, where a render-time check
    /// alone would leave it until the row happened to redraw.
    public static func statuses(
        _ response: GetUserPresenceResponse,
        now: Date
    ) -> [ChatKit.Member.ID: MemberStatus?] {
        var result: [ChatKit.Member.ID: MemberStatus?] = [:]
        for entry in response.userPresences where entry.hasUserStatus {
            let id = entry.userID.id
            guard !id.isEmpty else { continue }
            result[ChatKit.Member.ID(id)] = status(of: entry.userStatus, now: now)
        }
        return result
    }

    static func status(of userStatus: UserStatus, now: Date) -> MemberStatus? {
        guard userStatus.hasCustomStatus else { return nil }
        let custom = userStatus.customStatus
        let unicode = custom.hasEmoji ? custom.emoji.unicode : ""
        let legacy = custom.hasStatusEmoji ? custom.statusEmoji : ""
        let shortcode = custom.hasEmoji ? customEmojiShortcode(in: custom.emoji) : nil
        let expiry = custom.hasStateExpiryTimestampUsec && custom.stateExpiryTimestampUsec > 0
            ? Date(timeIntervalSince1970: Double(custom.stateExpiryTimestampUsec) / 1_000_000)
            : nil
        let status = MemberStatus(
            emoji: [unicode, legacy].first { !$0.isEmpty },
            customEmojiShortcode: shortcode,
            text: custom.hasStatusText && !custom.statusText.isEmpty ? custom.statusText : nil,
            expiresAt: expiry
        )
        if status.isEmpty {
            return nil
        }
        if let expiry, expiry <= now {
            return nil
        }
        return status
    }

    /// `Emoji.custom_emoji.shortcode`. Named since the reactions slice merged
    /// purple's `Emoji` (it used to be read out of `unknownFields`).
    private static func customEmojiShortcode(in emoji: Emoji) -> String? {
        guard emoji.hasCustomEmoji, emoji.customEmoji.hasShortcode,
              !emoji.customEmoji.shortcode.isEmpty
        else { return nil }
        return emoji.customEmoji.shortcode
    }

    /// Each answered person's Do not disturb end, for those in Do not
    /// disturb whose end the answer says (`doNotDisturbUntil(of:now:)`).
    public static func doNotDisturbEnds(
        _ response: GetUserPresenceResponse,
        now: Date
    ) -> [ChatKit.Member.ID: Date] {
        var result: [ChatKit.Member.ID: Date] = [:]
        for entry in response.userPresences where !entry.userID.id.isEmpty {
            result[ChatKit.Member.ID(entry.userID.id)] = doNotDisturbUntil(of: entry, now: now)
        }
        return result
    }

    /// When the entry's Do not disturb ends, for an entry in Do not disturb
    /// whose `user_status.dnd_settings` says: `dnd_expiry_time_usec`, or else
    /// `now` plus `state_remaining_duration_usec`. The live poll carried both,
    /// agreeing to the second. An end already past is kept,
    /// not dropped: it is what tells a client the claim has run out.
    static func doNotDisturbUntil(of entry: UserPresence, now: Date) -> Date? {
        guard presence(of: entry) == .doNotDisturb, entry.hasUserStatus, entry.userStatus.hasDndSettings
        else { return nil }
        let dnd = entry.userStatus.dndSettings
        if dnd.hasDndExpiryTimeUsec, dnd.dndExpiryTimeUsec > 0 {
            return Date(timeIntervalSince1970: Double(dnd.dndExpiryTimeUsec) / 1_000_000)
        }
        if dnd.hasStateRemainingDurationUsec, dnd.stateRemainingDurationUsec > 0 {
            return now.addingTimeInterval(Double(dnd.stateRemainingDurationUsec) / 1_000_000)
        }
        return nil
    }

    /// `nil` when the entry says nothing about presence at all - "nobody told
    /// us", which `Member.presence` keeps distinct from `.unknown`.
    static func presence(of entry: UserPresence) -> ChatKit.Presence? {
        // Both places DND can be carried. Which one a poll fills is
        // `[Verify]`; the channel's `USER_STATUS_UPDATED_EVENT` uses the
        // nested one, and purple's poll reads the top-level one.
        let topLevelDnd = entry.hasDndState && entry.dndState == .dnd
        let statusDnd = entry.hasUserStatus && entry.userStatus.hasDndSettings
            && entry.userStatus.dndSettings.hasDndState && entry.userStatus.dndSettings.dndState == .dnd
        if topLevelDnd || statusDnd {
            return .doNotDisturb
        }
        if entry.hasPresence {
            return switch entry.presence {
            case .active: .active
            case .inactive: .inactive
            case .undefinedPresence: .unknown("UNDEFINED_PRESENCE")
            case .unknown: .unknown("UNKNOWN")
            case .sharingDisabled: .unknown("SHARING_DISABLED")
            }
        }
        // A value outside the vendored proto2 enum clears the presence bit and
        // keeps its bytes in `unknownFields` (`CLAUDE.md`, the typed decode
        // rule). Believe the walk: it is an answer, just not one this build
        // can name.
        if let raw = ProtoFieldScan.varintValues(ofField: presenceField, in: entry.unknownFields.data).last {
            return .unknown("presence=\(raw)")
        }
        return nil
    }
}
