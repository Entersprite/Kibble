import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The sequences the whole-change review of the debounce set out to settle,
/// each of which crosses a suspension point no single-step test can reach.
///
/// Separate from `MarkReadDebounceTests` because these are a different kind of
/// test. That file is the feature's own suite, one behaviour per test, written
/// alongside the wait. Every test here instead drives two or three interleaved
/// events on purpose, because `findings.md` §25.10 is a Critical in this repo
/// that passed every test written for it: each of those called the thing
/// exactly once, and the defect only existed on the second call. This slice's
/// own re-arm fix reintroduced its own finding the same way.
///
/// The harness, the interval and the token counter are shared through
/// `Support/AutoMarkReadHarness.swift`; `markReadSequenceInterval`'s doc
/// comment records why the interval here is larger than the feature suite's.
///
/// Three of these six hold the submit open with
/// `RecordingBackend.holdSubmissions(_:)` rather than relying on the wait
/// still being in progress. That is not just belt and braces: a held submit
/// keeps the tracking entry installed for as long as the test wants, which
/// makes the sequence happen by construction instead of by winning a race
/// against the interval.
@Suite(.timeLimit(.minutes(1)))
struct MarkReadDebounceSequenceTests {
    // MARK: - Sequence 1: a suppressed trigger's message

    /// Two triggers milliseconds apart, one scheduling and one declined as
    /// `already-in-flight`: the second one's message must still be published,
    /// by the first mark's coalescing.
    ///
    /// This is the sequence that makes the in-flight guard safe. Before the
    /// wait, a declined trigger's message was only ever recovered by the
    /// re-arm, and the re-arm cannot run until a mark has been sent. Now the
    /// recomputation at the end of the wait covers it instead, and the proof
    /// has to be the *value* published: a call count cannot tell coalescing
    /// from dropping the second message.
    ///
    /// The two `sink` assertions are what stop this passing for the wrong
    /// reason. Without them a version where the second trigger scheduled a
    /// second mark of its own would also end with one position published, if
    /// the first mark happened to lose a race.
    @MainActor
    @Test func aSuppressedTriggersMessageIsStillPublishedByTheFirstMark() async throws {
        let harness = try await makeTracedMarkReadHarness()
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        #expect(markReadTriggerCount(.scheduled, in: harness) == 1)
        #expect(await markReadPositions(from: harness.backend).isEmpty)

        try landAutoMarkReadMessage(
            in: harness.store, id: "srv-second-trigger", secondsAfterFixture: 10
        )
        await settleAutoMarkRead()
        // The second trigger really did reach the in-flight guard and stop
        // there, rather than scheduling a mark of its own.
        #expect(markReadTriggerCount(.alreadyInFlight, in: harness) == 1)
        #expect(markReadTriggerCount(.scheduled, in: harness) == 1)

        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        let expected = try autoMarkReadFixtureNewest.addingTimeInterval(10)
        #expect(await markReadPositions(from: harness.backend) == [expected])
        await harness.model.stop()
    }

    // MARK: - Sequence 2: a burst spanning the end of the wait

    /// One message before the wait ends and one after it, while the submit is
    /// still in flight: one coalesced mark, then a *second* mark from the
    /// re-arm - and the second goes through its own full wait rather than
    /// resubmitting at once.
    ///
    /// This is the boundary where the wait stops helping and the re-arm takes
    /// over, and the answer is that both mechanisms are load-bearing: the
    /// wait covers what arrives before it ends, the re-arm covers what
    /// arrives during the submit. The submit is held open so the second
    /// message lands in a window the test controls rather than one it hopes
    /// for.
    ///
    /// `scheduled` twice is the assertion that the re-arm went back through
    /// the scheduling path, and therefore through the wait, rather than
    /// publishing a young position directly - which would be the very defect
    /// this whole change exists to fix, reintroduced one level down. It is
    /// asserted on the trace rather than by timing the second call, because
    /// "the second mark had not landed yet" would measure this machine's
    /// scheduler and not the code.
    @MainActor
    @Test func aBurstSpanningTheEndOfTheWaitIsOneMarkThenAReArm() async throws {
        let harness = try await makeTracedMarkReadHarness()
        await harness.backend.holdSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        try landAutoMarkReadMessage(
            in: harness.store, id: "srv-before-wait-end", secondsAfterFixture: 10
        )
        await settleAutoMarkRead()
        // Declined on its way in, which is what leaves the coalescing as the
        // only thing that can cover it.
        #expect(markReadTriggerCount(.alreadyInFlight, in: harness) == 1)

        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        // The wait has ended and the one coalesced mark is blocked in flight.
        #expect(await harness.backend.markReadCount == 1)
        #expect(await harness.backend.heldSubmissionCount == 1)

        // This one lands after the wait ended, inside the submit, so the
        // in-flight guard declines it too and only the re-arm can recover it.
        try landAutoMarkReadMessage(
            in: harness.store, id: "srv-after-wait-end", secondsAfterFixture: 20
        )
        await settleAutoMarkRead()
        #expect(await harness.backend.markReadCount == 1)
        #expect(markReadTriggerCount(.alreadyInFlight, in: harness) == 2)

        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        let newest = try autoMarkReadFixtureNewest
        #expect(await markReadPositions(from: harness.backend) == [
            newest.addingTimeInterval(10),
            newest.addingTimeInterval(20)
        ])
        #expect(markReadTriggerCount(.scheduled, in: harness) == 2)
        await harness.model.stop()
    }

    // MARK: - Sequence 3: away and back inside one wait

    /// `select(_:)` away and back during a single wait: each conversation's
    /// mark must carry its own newest position, against its own id.
    ///
    /// Three interleaved events, and the middle one is the trap. Selecting
    /// away schedules a second wait for the other conversation; selecting back
    /// finds the first conversation's entry still installed and is declined.
    /// When the two waits end, one of them ends with `selected` naming the
    /// *other* conversation, which is exactly the state where recomputing
    /// from `messages` would publish the wrong conversation's timestamp.
    ///
    /// The submit is held for the whole interleaving, so "the first
    /// conversation's entry is still installed when we come back" is true by
    /// construction rather than by the wait outlasting two settles. Both
    /// positions are asserted, not only the one for the conversation selected
    /// at the end, because the fixture's other conversation is the *newer* of
    /// the two: `max` therefore hides a defect on one of the branches and
    /// exposes it on the other. The order the two waits wake in is not
    /// asserted, because nothing in the design promises one.
    @MainActor
    @Test func selectingAwayAndBackInOneWaitPublishesEachOwnPosition() async throws {
        let harness = try await makeTracedMarkReadHarness()
        await harness.backend.holdSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let generation = try #require(harness.model.markGeneration[autoMarkReadConversation])
        let other = try #require(
            harness.model.conversations.first { $0.id != autoMarkReadConversation }
        )

        harness.model.select(other.id)
        await settleAutoMarkRead()
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        // Coming back was declined rather than starting a third mark: two
        // schedulings in total, one per conversation, and the first
        // conversation's entry is still the generation it was installed as.
        //
        // The declines are counted as "at least one" rather than exactly one
        // because selecting a conversation refetches its history, and that
        // write re-delivers through the same observation that already
        // delivered the rows, so the trigger runs more than once per
        // selection. An exact count here would pin how many times GRDB
        // happened to notify.
        #expect(markReadTriggerCount(.scheduled, in: harness) == 2)
        #expect(markReadTriggerCount(.alreadyInFlight, in: harness) >= 1)
        #expect(harness.model.markGeneration[autoMarkReadConversation] == generation)

        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()
        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()

        let marks = await markReads(from: harness.backend)
        let forOriginal = marks.filter { $0.conversation == autoMarkReadConversation }
        let forOther = marks.filter { $0.conversation == other.id }
        #expect(forOriginal.count == 1)
        #expect(forOther.count == 1)
        #expect(try forOriginal.first?.position == autoMarkReadFixtureNewest)
        #expect(try forOther.first?.position == autoMarkReadFixtureNewest(in: other.id))
        await harness.model.stop()
    }
}
