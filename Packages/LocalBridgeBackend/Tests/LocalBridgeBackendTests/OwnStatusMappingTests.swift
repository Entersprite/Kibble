import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Your status, both ways: what a `UserStatus` says your availability is,
/// and what each setting sends (set-your-status spec §1, §3). The shapes are
/// `[Verify]` until the owner's first use.
struct OwnStatusMappingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usec(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    private func status(
        dnd: DndSettings.DndState_State? = nil, expiry: Date? = nil,
        remaining: Int64? = nil, shared: Bool? = nil
    ) -> UserStatus {
        var status = UserStatus()
        if let dnd {
            status.dndSettings.dndState = dnd
        }
        if let expiry {
            status.dndSettings.dndExpiryTimeUsec = usec(expiry)
        }
        if let remaining {
            status.dndSettings.stateRemainingDurationUsec = remaining
        }
        if let shared {
            status.presenceShared = shared
        }
        return status
    }

    @Test func doNotDisturbWithAFutureEndWinsOverAway() {
        let end = now.addingTimeInterval(1800)
        #expect(AvailabilityMapping.availability(of: status(dnd: .dnd, expiry: end, shared: false), now: now)
            == .doNotDisturb(until: end))
    }

    @Test func doNotDisturbThatHasEndedIsNot() {
        let ended = now.addingTimeInterval(-60)
        #expect(AvailabilityMapping
            .availability(of: status(dnd: .dnd, expiry: ended), now: now) == .automatic)
    }

    /// Ten minutes, in microseconds.
    @Test func doNotDisturbWithOnlyARemainingDurationEndsThatFarFromNow() {
        #expect(AvailabilityMapping.availability(of: status(dnd: .dnd, remaining: 600_000_000), now: now)
            == .doNotDisturb(until: now.addingTimeInterval(600)))
    }

    @Test func presenceNotSharedIsAwayAndOtherwiseAutomatic() {
        #expect(AvailabilityMapping.availability(of: status(shared: false), now: now) == .away)
        #expect(AvailabilityMapping.availability(of: status(shared: true), now: now) == .automatic)
        #expect(AvailabilityMapping.availability(of: UserStatus(), now: now) == .automatic)
    }

    @Test func aStatusSendsTextEmojiAndItsEnd() {
        let end = now.addingTimeInterval(3600)
        let request = OwnStatusRequests.setCustomStatus(
            MemberStatus(emoji: "🏠", text: "Working remotely", expiresAt: end)
        )
        #expect(request.customStatus.statusText == "Working remotely")
        #expect(request.customStatus.emoji.unicode == "🏠")
        #expect(request.customStatusTiming == .customStatusExpiryTimestampUsec(usec(end)))
        #expect(request.hasRequestHeader)
    }

    /// "Don't clear": no timing at all (`[Verify]`). A shortcode is never sent.
    @Test func aStatusThatNeverClearsSendsNoTiming() {
        let request = OwnStatusRequests.setCustomStatus(
            MemberStatus(customEmojiShortcode: ":party:", text: "Heads down")
        )
        #expect(request.customStatusTiming == nil)
        #expect(!request.customStatus.hasEmoji)
    }

    /// purple's clear: no status, and a remaining duration of zero.
    @Test func clearingSendsNoStatusAndZeroRemaining() {
        let request = OwnStatusRequests.setCustomStatus(nil)
        #expect(!request.hasCustomStatus)
        #expect(request.customStatusTiming == .customStatusRemainingDurationUsec(0))
    }

    @Test func doNotDisturbSendsItsEndAndOffSendsAvailableNow() {
        let end = now.addingTimeInterval(1800)
        let on = OwnStatusRequests.doNotDisturb(until: end)
        #expect(on.currentDndState == .dnd)
        #expect(on.dndExpiry == .dndExpiryTimestampUsec(usec(end)))
        let off = OwnStatusRequests.doNotDisturbOff()
        #expect(off.currentDndState == .available)
        #expect(off.dndExpiry == .newDndDurationUsec(0))
    }

    @Test func presenceSharedCarriesItsFlag() {
        let request = OwnStatusRequests.setPresenceShared(false)
        #expect(request.hasPresenceShared)
        #expect(request.presenceShared == false)
    }
}
