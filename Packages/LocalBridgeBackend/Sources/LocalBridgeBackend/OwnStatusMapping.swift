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

    static func setPresenceShared(_ shared: Bool) -> SetPresenceSharedRequest {
        var request = SetPresenceSharedRequest()
        request.requestHeader = APIRequestHeader.make()
        request.presenceShared = shared
        return request
    }

    static func doNotDisturbOff() -> SetDndDurationRequest {
        var request = SetDndDurationRequest()
        request.requestHeader = APIRequestHeader.make()
        request.currentDndState = .available
        request.newDndDurationUsec = 0
        return request
    }

    /// A real end time: purple writes a 48-hour duration into this
    /// timestamp field, which looks like its bug (spec §1).
    static func doNotDisturb(until end: Date) -> SetDndDurationRequest {
        var request = SetDndDurationRequest()
        request.requestHeader = APIRequestHeader.make()
        request.currentDndState = .dnd
        request.dndExpiryTimestampUsec = microseconds(end)
        return request
    }

    private static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}
