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
