import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The debounce sequences about what must **not** happen: a cancelled mark
/// that must publish nothing, a post-wait early return that must still clear
/// its tracking entry, a refocus that must not mint a second mark, and a
/// generation that must outlive `stop()`.
///
/// Split from `MarkReadDebounceSequenceTests` on swiftlint's `file_length`
/// ceiling, which the combined file crossed at 403 lines - the same reason
/// `AutoMarkReadReArmTests` was split out of `AutoMarkReadTests`, and
/// `CLAUDE.md`'s stated preference over trimming a doc comment to fit. The
/// division is the natural one: that file asserts which position gets
/// published, this one asserts that nothing gets published and nothing gets
/// wedged.
///
/// Everything in that file's header applies here too - the shared harness in
/// `Support/AutoMarkReadHarness.swift`, why the interval is larger than the
/// feature suite's, and why the submit is held rather than raced.
@Suite(.timeLimit(.minutes(1)))
struct MarkReadDebounceGuardSequenceTests {
    // MARK: - Sequence 4: cancellation racing the submit

    /// `stop()` landing between the wait ending and the submit returning,
    /// with the request accepted anyway: the watermark must stay put, the
    /// tracking entry must be gone, and nothing must be re-armed.
    ///
    /// This is the one window where a cancelled task has already passed every
    /// guard and holds a position it fully intended to publish. The submit is
    /// held open to put `stop()` inside that window on purpose.
    ///
    /// **`acceptWithoutForwarding(true)` is what gives this test any teeth,
    /// and its absence is a finding this review made.** `FakeBackend.send(_:)`
    /// throws once disconnected and `stop()` disconnects, so a mark released
    /// after `stop()` otherwise fails for *that* reason, `accepted` is
    /// `false`, and nothing would have written the watermark even with
    /// `publishReadPosition`'s `Task.isCancelled` guard deleted. The version
    /// of this test without the knob passes with that guard removed. The knob
    /// models the case the guard actually exists for, which `stop()`'s own doc
    /// comment names: cancelling a task does not oblige the request underneath
    /// it to abort, so a `mark_group_readstate` already in flight can be
    /// accepted by the server after sign-out.
    ///
    /// `published` is asserted after the resumed task has had its chance to
    /// run, not merely after `stop()`: `stop()` clears `published` itself, so
    /// checking it any earlier would prove nothing.
    @MainActor
    @Test func stopBetweenTheWaitAndAnAcceptedSubmitAdvancesNothing() async throws {
        let harness = try await makeTracedMarkReadHarness()
        await harness.backend.holdSubmissions(true)
        await harness.backend.acceptWithoutForwarding(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        // The wait is over and the submit is in flight, with the watermark
        // still where it was.
        #expect(markReadTriggerCount(.submitted, in: harness) == 1)
        #expect(await harness.backend.heldSubmissionCount == 1)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await harness.model.stop()
        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        #expect(harness.model.published[autoMarkReadConversation] == nil)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
        #expect(await harness.backend.markReadCount == 1)
    }

    // MARK: - Sequence 5: a post-wait guard's early return

    /// Focus lost during the wait, then regained: the entry the wait installed
    /// must have been cleared, so the next trigger can mark.
    ///
    /// The post-wait `guard isActive` returns *after* the tracking entry was
    /// installed, and the task's `defer` is the only thing that clears it on
    /// that path. An early return that skipped the clear would leave this
    /// conversation unmarkable for the life of the session - the badge never
    /// clearing again, which is worse than the defect the wait exists to fix.
    ///
    /// The regained-focus half is the part a single-step test cannot see.
    /// `MarkReadDebounceTests.losingFocusDuringTheWaitPublishesNothing`
    /// asserts that nothing was published, which stays true whether the entry
    /// was cleared or wedged; only a *second* trigger tells the two apart.
    /// Deleting the `defer` leaves that test green and fails this one.
    @MainActor
    @Test func focusLostDuringTheWaitLeavesTheConversationMarkable() async throws {
        let harness = try await makeTracedMarkReadHarness()
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)

        harness.model.setActive(false)
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        // The wait ended, the post-wait focus guard declined, and the entry
        // it left behind was cleared.
        #expect(markReadTriggerCount(.notFrontmost, in: harness) == 1)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
        #expect(await harness.backend.markReadCount == 0)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        harness.model.setActive(true)
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        #expect(await harness.backend.markReadCount == 1)
        #expect(try harness.model.published[autoMarkReadConversation] == autoMarkReadFixtureNewest)
        await harness.model.stop()
    }

    // MARK: - Sequence 6: refocusing inside one wait

    /// Focus dropped and regained *inside* one wait: one mark, and the
    /// generation still names the entry the original wait installed.
    ///
    /// `setActive(true)` is a trigger path in its own right, so regaining
    /// focus calls straight into the trigger while the first wait is still
    /// running. It must be declined by the in-flight guard rather than mint a
    /// second generation: a second generation would make the *original*
    /// task's `defer` decline to clear, leaving the replacement's own clear as
    /// the only one, which is the shape of the re-arm corruption
    /// `markGeneration` was introduced to close.
    ///
    /// `markGeneration` is asserted directly rather than through a
    /// consequence, because this is the one sequence where the number of marks
    /// is the same whether the guard held or not.
    @MainActor
    @Test func refocusingInsideOneWaitProducesOneMark() async throws {
        let harness = try await makeTracedMarkReadHarness()
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let generation = try #require(harness.model.markGeneration[autoMarkReadConversation])

        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead()

        #expect(harness.model.markGeneration[autoMarkReadConversation] == generation)
        #expect(markReadTriggerCount(.scheduled, in: harness) == 1)
        #expect(markReadTriggerCount(.alreadyInFlight, in: harness) == 1)

        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()

        #expect(await harness.backend.markReadCount == 1)
        #expect(try harness.model.published[autoMarkReadConversation] == autoMarkReadFixtureNewest)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
        await harness.model.stop()
    }

    // MARK: - Sequence 7: a generation that must outlive stop()

    /// A mark held in flight across `stop()`, with a second mark scheduled
    /// for the same conversation before the first one returns: the first
    /// one's clear must not erase the second one's entry.
    ///
    /// **This sequence is why `stop()` does not reset `markGeneration`, and
    /// nothing tested it.** Adding `markGeneration = [:]` to `stop()` passes
    /// all of this package's other tests. What it breaks is an ABA:
    /// generations are minted as `(markGeneration[id] ?? 0) + 1`, so a reset
    /// makes the *next* mark mint the same number the in-flight one is
    /// holding. That mark's clear then matches, deletes the newer mark's
    /// tracking entry, and reopens the in-flight guard while the newer mark is
    /// still running - which both admits a second concurrent mark for one
    /// conversation and makes the newer one unreachable from `markTasks`, so
    /// `stop()` can no longer cancel it. That is the exact
    /// untracked-task-outliving-the-model exposure `markTasks` exists to
    /// close, one level down, and it is what `markGeneration`'s own doc
    /// comment records.
    ///
    /// Reached without restarting the engine: `stop()` empties `markTasks`
    /// and `published` but leaves `selected`, `messages` and `isActive`
    /// alone, so dropping and regaining focus is enough to schedule the
    /// second mark. Driving `start()` again would add a reconnect and a
    /// `gap(.everything)` to the sequence, neither of which it is about.
    ///
    /// `stop()`'s own doc comment calls this unreachable today because a
    /// fresh model is built per session. That is a property of one caller, not
    /// of this class, and the design lists the invariant as one to verify
    /// explicitly rather than by inspection.
    @MainActor
    @Test func aMarkHeldAcrossStopDoesNotClearALaterMarksEntry() async throws {
        let harness = try await makeTracedMarkReadHarness()
        await harness.backend.holdSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let held = try #require(harness.model.markGeneration[autoMarkReadConversation])
        try await Task.sleep(for: pastMarkReadSequenceInterval)
        await settleAutoMarkRead()
        #expect(await harness.backend.heldSubmissionCount == 1)

        await harness.model.stop()

        // Schedules the second mark. Its generation must be a number the
        // held mark is not holding.
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead()
        let expected = held + 1
        #expect(harness.model.markGeneration[autoMarkReadConversation] == expected)
        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)

        // The held mark returns and runs its clear. The second mark is still
        // inside its own wait, and its entry has to survive.
        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead()

        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)
        await harness.model.stop()
    }
}
