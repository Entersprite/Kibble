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
    /// only empty strings - maps to `nil`, which is "cleared".
    public static func statuses(_ response: GetUserPresenceResponse) -> [ChatKit.Member.ID: MemberStatus?] {
        var result: [ChatKit.Member.ID: MemberStatus?] = [:]
        for entry in response.userPresences where entry.hasUserStatus {
            let id = entry.userID.id
            guard !id.isEmpty else { continue }
            result[ChatKit.Member.ID(id)] = status(of: entry.userStatus)
        }
        return result
    }

    /// `Emoji.custom_emoji` (2) and its `shortcode` (3): purple's proto names
    /// them, the vendored one does not, so they are read from the bytes.
    private static let customEmojiField = 2
    private static let shortcodeField = 3

    static func status(of userStatus: UserStatus) -> MemberStatus? {
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
        return status.isEmpty ? nil : status
    }

    private static func customEmojiShortcode(in emoji: Emoji) -> String? {
        guard let custom = ProtoFieldScan.payloads(ofField: customEmojiField, in: emoji.unknownFields.data)
            .first,
            let bytes = ProtoFieldScan.payloads(ofField: shortcodeField, in: custom).first,
            !bytes.isEmpty
        else { return nil }
        return String(decoding: bytes, as: UTF8.self)
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
