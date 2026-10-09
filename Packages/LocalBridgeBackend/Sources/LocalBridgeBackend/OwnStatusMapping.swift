import ChatKit
import Foundation
import GChatBridgeCore

/// What a `UserStatus` says your availability is (set-your-status spec §3).
enum AvailabilityMapping {
    /// Do not disturb with an end still ahead wins; then presence not shared
    /// is away; anything else is automatic. A Do not disturb with only a
    /// remaining duration ends that far from `now` (`[Verify]`).
    static func availability(of status: UserStatus, now: Date) -> Availability {
        if let end = doNotDisturbEnd(status.dndSettings, now: now) {
            return .doNotDisturb(until: end)
        }
        if status.hasPresenceShared, !status.presenceShared {
            return .away
        }
        return .automatic
    }

    /// After a set call: the answer's availability when it carries both
    /// parts that decide it, Do not disturb and presence sharing; otherwise
    /// `requested`, which the server has just accepted (review finding 1).
    static func availability(
        answering requested: Availability,
        with status: UserStatus,
        now: Date
    ) -> Availability {
        let decides = status.hasDndSettings && status.dndSettings.hasDndState && status.hasPresenceShared
        return decides ? availability(of: status, now: now) : requested
    }

    private static func doNotDisturbEnd(_ dnd: DndSettings, now: Date) -> Date? {
        guard dnd.hasDndState, dnd.dndState == .dnd else { return nil }
        if dnd.hasDndExpiryTimeUsec, dnd.dndExpiryTimeUsec > 0 {
            let end = Date(timeIntervalSince1970: Double(dnd.dndExpiryTimeUsec) / 1_000_000)
            return end > now ? end : nil
        }
        if dnd.hasStateRemainingDurationUsec, dnd.stateRemainingDurationUsec > 0 {
            return now.addingTimeInterval(Double(dnd.stateRemainingDurationUsec) / 1_000_000)
        }
        return nil
    }
}

/// What each setting sends (spec §1). Every shape is `[Verify]` until the
/// owner's first use.
enum OwnStatusRequests {
    /// Unicode emoji and text, and the end as a timestamp; "Don't clear"
    /// sends no timing. `nil`, or a status with neither emoji nor text,
    /// clears: no status and a remaining duration of zero, as purple does.
    static func setCustomStatus(_ status: MemberStatus?) -> SetCustomStatusRequest {
        var request = SetCustomStatusRequest()
        request.requestHeader = APIRequestHeader.make()
        guard let status, status.emoji != nil || status.text != nil else {
            request.customStatusRemainingDurationUsec = 0
            return request
        }
        var custom = CustomStatus()
        if let text = status.text {
            custom.statusText = text
        }
        if let emoji = status.emoji {
            custom.emoji.unicode = emoji
        }
        request.customStatus = custom
        if let expiresAt = status.expiresAt {
            request.customStatusExpiryTimestampUsec = microseconds(expiresAt)
        }
        return request
    }

    /// What `setCustomStatus(_:)` sends, as a status: Unicode emoji and text
    /// with the end, never a shortcode; `nil` for a clear.
    static func sent(_ status: MemberStatus?) -> MemberStatus? {
        guard let status, status.emoji != nil || status.text != nil else { return nil }
        return MemberStatus(emoji: status.emoji, text: status.text, expiresAt: status.expiresAt)
    }

    static func setPresenceShared(_ shared: Bool) -> SetPresenceSharedRequest {
        var request = SetPresenceSharedRequest()
        request.requestHeader = APIRequestHeader.make()
        request.presenceShared = shared
        return request
    }

    /// Ends Do not disturb: no time at all, from the state you are in.
    static func doNotDisturbOff(current: Availability?, now: Date = Date()) -> SetDndDurationRequest {
        var request = SetDndDurationRequest()
        request.requestHeader = APIRequestHeader.make()
        request.currentDndState = dndState(of: current, now: now)
        request.newDndDurationUsec = 0
        return request
    }

    /// How long, from `now`, in `new_dnd_duration_usec`: the field ending Do
    /// not disturb already uses. An end already past asks for no time.
    static func doNotDisturb(
        until end: Date,
        now: Date = Date(),
        current: Availability?
    ) -> SetDndDurationRequest {
        var request = SetDndDurationRequest()
        request.requestHeader = APIRequestHeader.make()
        request.currentDndState = dndState(of: current, now: now)
        request.newDndDurationUsec = Int64((max(0, end.timeIntervalSince(now)) * 1_000_000).rounded())
        return request
    }

    /// `current_dnd_state` is the state you are in, not the one you want.
    /// The only call Google took said "available" while you were; Do not
    /// disturb saying "DND" from Automatic was refused with a 400, with an
    /// end time (`dnd_expiry_timestamp_usec`) and with a duration alike
    /// (session 62, live). `[Verify]` live. A Do not disturb whose end has
    /// passed is over, as `AvailabilityMapping` reads it.
    static func dndState(of current: Availability?, now: Date) -> SetDndDurationRequest.State {
        if case let .doNotDisturb(until) = current, until > now {
            return .dnd
        }
        return .available
    }

    private static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}
