import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The dot on your own avatar in the sidebar footer: your setting where it
/// decides, otherwise what the presence poll says others see (the owner's
/// choice, set-your-status follow-up).
struct OwnPresenceTests {
    private let me = Member.ID("me")
    private let now = Date(timeIntervalSince1970: 1_791_383_400)

    private func shown(
        _ availability: Availability?,
        polled: Presence? = .active,
        connection: ConnectionState = .connected,
        me: Member.ID?? = .none
    ) -> Presence? {
        let directory = [self.me: Member(id: self.me, kind: .human, displayName: "Me", presence: polled)]
        return Display.ownPresence(
            availability: availability, directory: directory, me: me ?? self.me, connection: connection,
            now: now
        )
    }

    /// Do not disturb and Away show at once, whatever the last poll said.
    @Test func yourSettingWinsWhereItDecides() {
        #expect(shown(.doNotDisturb(until: now.addingTimeInterval(600))) == .doNotDisturb)
        #expect(shown(.away) == .inactive)
    }

    /// Automatic means Google decides, so the dot is what it told others,
    /// idle included.
    @Test func automaticShowsWhatOthersSee() {
        #expect(shown(.automatic, polled: .active) == .active)
        #expect(shown(.automatic, polled: .inactive) == .inactive)
        #expect(shown(.automatic, polled: .doNotDisturb) == .doNotDisturb)
    }

    /// Ruling 4's case: an ended Do not disturb is Automatic again.
    @Test func anEndedDoNotDisturbShowsWhatOthersSee() {
        #expect(shown(.doNotDisturb(until: now.addingTimeInterval(-1)), polled: .inactive) == .inactive)
    }

    /// Before connect has said, and before the first poll, nothing rather
    /// than a guess.
    @Test func nothingKnownDrawsNothing() {
        #expect(shown(nil, polled: .active) == .active)
        #expect(shown(.automatic, polled: nil) == nil)
        #expect(shown(.automatic, polled: .unknown("absent")) == nil)
    }

    /// A claim about now, like everyone else's dot.
    @Test func onlyWhileConnected() {
        #expect(shown(.away, connection: .idle) == nil)
        #expect(shown(.automatic, connection: .connecting) == nil)
        #expect(shown(.away, me: .some(nil)) == nil)
    }
}
