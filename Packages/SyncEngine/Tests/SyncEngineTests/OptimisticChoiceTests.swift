import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// A choice is drawn at once and springs back only when it is refused.
@Suite struct OptimisticChoiceTests {
    private let later = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aChoiceShowsAtOnce() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        _ = choice.choose(.away)
        #expect(choice.shown == .away)
        #expect(choice.isPending)
    }

    @Test func aRefusalRestoresTheStoredValue() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let token = choice.choose(.away)
        choice.settle(token, accepted: false)
        #expect(choice.shown == .automatic)
        #expect(!choice.isPending)
    }

    /// The answer can come back before its event: the old value must not
    /// flash in between, and a re-delivery of the old value is not that event.
    @Test func anAcceptedChoiceStaysUntilTheStoreChanges() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let token = choice.choose(.away)
        choice.settle(token, accepted: true)
        #expect(choice.shown == .away)
        choice.observe(.automatic)
        #expect(choice.shown == .away)
        #expect(choice.isPending)
        choice.observe(.away)
        #expect(choice.shown == .away)
        #expect(!choice.isPending)
    }

    @Test func theEventCanArriveBeforeTheAnswer() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let token = choice.choose(.away)
        choice.observe(.away)
        #expect(!choice.isPending)
        choice.settle(token, accepted: true)
        #expect(choice.shown == .away)
        #expect(!choice.isPending)
    }

    /// What the service stored wins once it has accepted, even when it is not
    /// exactly what was chosen (a normalized time, another device).
    @Test func anAcceptedChoiceGivesWayToTheNextStoredValue() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let token = choice.choose(.away)
        choice.settle(token, accepted: true)
        choice.observe(.doNotDisturb(until: later))
        #expect(choice.shown == .doNotDisturb(until: later))
        #expect(!choice.isPending)
    }

    @Test func anOlderStoredValueDoesNotMoveAChoiceInFlight() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let token = choice.choose(.away)
        choice.observe(.doNotDisturb(until: later))
        #expect(choice.shown == .away)
        choice.settle(token, accepted: false)
        #expect(choice.shown == .doNotDisturb(until: later))
    }

    @Test func anAnswerForAReplacedChoiceChangesNothing() {
        var choice = OptimisticChoice<Availability?>(observed: .automatic)
        let first = choice.choose(.away)
        let second = choice.choose(.doNotDisturb(until: later))
        choice.settle(first, accepted: false)
        #expect(choice.shown == .doNotDisturb(until: later))
        #expect(choice.isPending)
        choice.settle(second, accepted: false)
        #expect(choice.shown == .automatic)
    }

    @Test func choosingTheStoredValueSettlesAtOnceWhenAccepted() {
        var choice = OptimisticChoice<Availability?>(observed: .away)
        let token = choice.choose(.away)
        choice.settle(token, accepted: true)
        #expect(!choice.isPending)
        #expect(choice.shown == .away)
    }

    @Test func aRebaseForgetsTheChoiceAndALateAnswer() {
        var choice = OptimisticChoice<MemberStatus?>(observed: nil)
        let token = choice.choose(MemberStatus(emoji: "🏠", text: "Home"))
        let stored = MemberStatus(emoji: "📅", text: "In a meeting")
        choice.rebase(observed: stored)
        #expect(choice.shown == stored)
        let next = choice.choose(nil)
        choice.settle(token, accepted: false)
        #expect(choice.shown == nil)
        choice.settle(next, accepted: false)
        #expect(choice.shown == stored)
    }
}
