import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Other people's Do not disturb end: read from `get_user_presence`, carried
/// on `.presenceChanged`, and emitted only when it changes.
@Suite(.timeLimit(.minutes(1)))
struct PresenceDoNotDisturbTests: PresencePollFixtures {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(dnd: Bool = true, expiry: Int64? = nil, remaining: Int64? = nil) -> UserPresence {
        var entry = UserPresence()
        entry.userID.id = "u-1"
        entry.presence = .active
        entry.userStatus.userID.id = "u-1"
        entry.userStatus.dndSettings.dndState = dnd ? .dnd : .available
        if let expiry {
            entry.userStatus.dndSettings.dndExpiryTimeUsec = expiry
        }
        if let remaining {
            entry.userStatus.dndSettings.stateRemainingDurationUsec = remaining
        }
        return entry
    }

    // MARK: - Mapping

    /// The absolute end wins over the remaining duration, so two answers
    /// about one Do not disturb name the same end.
    @Test func theExpiryIsTheEnd() {
        let end = PresenceMapping.doNotDisturbUntil(
            of: entry(expiry: 1_790_003_600_000_000, remaining: 60_000_000), now: now
        )
        #expect(end == Date(timeIntervalSince1970: 1_790_003_600))
    }

    @Test func aRemainingDurationAloneEndsThatFarFromNow() {
        let end = PresenceMapping.doNotDisturbUntil(of: entry(remaining: 1_800_000_000), now: now)
        #expect(end == now.addingTimeInterval(1800))
    }

    /// No end said is no end: the line then shows until presence changes.
    @Test func noEndIsNil() {
        #expect(PresenceMapping.doNotDisturbUntil(of: entry(), now: now) == nil)
        #expect(PresenceMapping.doNotDisturbUntil(of: entry(expiry: 0, remaining: 0), now: now) == nil)
    }

    /// An end is only ever beside a Do not disturb.
    @Test func noEndOutsideDoNotDisturb() {
        #expect(PresenceMapping.doNotDisturbUntil(
            of: entry(dnd: false, expiry: 1_790_003_600_000_000), now: now
        ) == nil)
    }

    /// An end already past is kept: it is how a client knows the claim ran
    /// out before the next answer arrives. Dropping it would show the line
    /// with no end at all.
    @Test func aPastEndIsKept() {
        let end = PresenceMapping.doNotDisturbUntil(of: entry(expiry: 1_789_999_000_000_000), now: now)
        #expect(end == Date(timeIntervalSince1970: 1_789_999_000))
    }

    // MARK: - The poll

    private func ends(in events: [ChatEvent]) -> [Date?] {
        events.compactMap { event in
            guard case let .presenceChanged(member, _, until) = event, member == ada else { return nil }
            return .some(until)
        }
    }

    /// The same end twice emits once; a moved end emits again; leaving Do
    /// not disturb emits a presence with no end, which clears the stored one.
    @Test func theEndIsEmittedWhenItChanges() async throws {
        let first: Int64 = 1_790_003_600_000_000
        let later: Int64 = 1_790_007_200_000_000
        let transport = try transport([
            .doNotDisturb(["u-1": first]),
            .doNotDisturb(["u-1": first]),
            .doNotDisturb(["u-1": later]),
            .people(["u-1": .active])
        ], dmMembers: ["u-1"])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(5, on: transport)
        let events = await log.settle()

        #expect(presences(in: events)[ada] == [.doNotDisturb, .doNotDisturb, .active])
        #expect(ends(in: events) == [
            Date(timeIntervalSince1970: 1_790_003_600), Date(timeIntervalSince1970: 1_790_007_200), nil
        ])
        await backend.disconnect()
    }

    /// Ends read from a remaining duration move with each answer's clock; a
    /// few seconds apart they are the same end, or every poll would emit.
    @Test func endsAFewSecondsApartAreTheSameEnd() {
        let end = Date(timeIntervalSince1970: 1_790_003_600)
        let emitted = LocalBridgeBackend.EmittedPresence(presence: .doNotDisturb, doNotDisturbUntil: end)
        let drifted = LocalBridgeBackend.EmittedPresence(
            presence: .doNotDisturb, doNotDisturbUntil: end.addingTimeInterval(2)
        )
        let moved = LocalBridgeBackend.EmittedPresence(
            presence: .doNotDisturb, doNotDisturbUntil: end.addingTimeInterval(600)
        )
        let open = LocalBridgeBackend.EmittedPresence(presence: .doNotDisturb, doNotDisturbUntil: nil)
        #expect(drifted.says(emitted))
        #expect(!moved.says(emitted))
        #expect(!open.says(emitted))
        #expect(!emitted.says(nil))
    }

    /// Opening a DM asks about its other person at once even when the poll
    /// already does, so the conversation opens on news from now. Polling
    /// only people new to the poll turns this red.
    @Test func aWatchedPersonAlreadyPolledIsAskedAboutAgain() async throws {
        let transport = try transport(
            [.people(["u-1": .active]), .doNotDisturb(["u-1": 1_790_003_600_000_000])],
            dmMembers: ["u-1"]
        )
        let backend = backend(transport)
        let log = SenderEventLog(backend)
        try await backend.connect()
        _ = try await backend.loadConversations()
        try await awaitPolls(1, on: transport)

        try await backend.send(.watchPresence(members: [ada]))
        try await awaitPolls(2, on: transport)
        try await awaitAnswered(2, on: transport)
        let events = await log.settle()

        #expect(await transport.polls.last?.userIds.map(\.id) == ["u-1"])
        #expect(presences(in: events)[ada] == [.active, .doNotDisturb])
        await backend.disconnect()
    }
}
