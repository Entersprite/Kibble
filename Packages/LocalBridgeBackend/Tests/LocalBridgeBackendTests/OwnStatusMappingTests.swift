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

    /// How long, in field 1, the field ending it already uses. An end
    /// already past asks for no time at all.
    @Test func doNotDisturbSendsHowLong() {
        let on = OwnStatusRequests.doNotDisturb(
            until: now.addingTimeInterval(1800),
            now: now,
            current: .automatic
        )
        #expect(on.dndExpiry == .newDndDurationUsec(1_800_000_000))
        let past = OwnStatusRequests.doNotDisturb(
            until: now.addingTimeInterval(-5),
            now: now,
            current: .automatic
        )
        #expect(past.dndExpiry == .newDndDurationUsec(0))
        let off = OwnStatusRequests.doNotDisturbOff(current: .automatic, now: now)
        #expect(off.dndExpiry == .newDndDurationUsec(0))
    }

    /// `current_dnd_state` is the state you are in, not the one you want:
    /// the only call Google took said "available" while you were, and Do not
    /// disturb saying "DND" was refused with a 400, end time or duration
    /// (session 62, live). A Do not disturb whose end has passed is over.
    @Test func theCurrentStateIsTheOneYouAreIn() {
        let ahead = Availability.doNotDisturb(until: now.addingTimeInterval(600))
        let ended = Availability.doNotDisturb(until: now.addingTimeInterval(-60))
        let end = now.addingTimeInterval(1800)
        #expect(OwnStatusRequests.doNotDisturb(until: end, now: now, current: .automatic)
            .currentDndState == .available)
        #expect(OwnStatusRequests.doNotDisturb(until: end, now: now, current: .away)
            .currentDndState == .available)
        #expect(OwnStatusRequests.doNotDisturb(until: end, now: now, current: nil)
            .currentDndState == .available)
        #expect(OwnStatusRequests.doNotDisturb(until: end, now: now, current: ahead).currentDndState == .dnd)
        #expect(OwnStatusRequests.doNotDisturb(until: end, now: now, current: ended)
            .currentDndState == .available)
        #expect(OwnStatusRequests.doNotDisturbOff(current: ahead, now: now).currentDndState == .dnd)
        #expect(OwnStatusRequests.doNotDisturbOff(current: .away, now: now).currentDndState == .available)
    }

    @Test func presenceSharedCarriesItsFlag() {
        let request = OwnStatusRequests.setPresenceShared(false)
        #expect(request.hasPresenceShared)
        #expect(request.presenceShared == false)
    }
}
