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
/// feature suite's, why widening it was the wrong answer, why the submit is
/// held rather than raced, and that every wait here is
/// `settleAutoMarkRead(until:holds:)` rather than a fixed yield budget or a
/// sleep guessed to be past the interval.
@Suite(.timeLimit(.minutes(1)), .serialized)
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
        // The wait is over and the submit is in flight, with the watermark
        // still where it was.
        await settleAutoMarkRead(until: "the wait has ended and the submit is held") {
            await harness.backend.heldSubmissionCount == 1
        }
        #expect(markReadTriggerCount(.submitted, in: harness) == 1)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await harness.model.stop()
        await harness.backend.holdSubmissions(false)
        await harness.backend.releaseHeldSubmission()
        // `markOutcome` is written immediately before the `Task.isCancelled`
        // guard this test is about, with no suspension between the two, so an
        // outcome row observed from another main-actor job means the resumed
        // task has already run all the way past that guard. That is what
        // makes the three assertions below a verdict rather than a snapshot
        // taken while the task was still on its way.
        await settleAutoMarkRead(until: "the resumed mark has recorded its outcome") {
            harness.sink.outcomes.count == 1
        }

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
        await settleAutoMarkRead(until: "the mark for the open conversation is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }
        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)

        harness.model.setActive(false)
        // The wait ended, the post-wait focus guard declined, and the entry
        // it left behind was cleared.
        await settleAutoMarkRead(until: "the post-wait focus guard has declined") {
            markReadTriggerCount(.notFrontmost, in: harness) == 1
        }
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
        #expect(await harness.backend.markReadCount == 0)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        harness.model.setActive(true)
        await settleAutoMarkRead(until: "the second mark has advanced the watermark") {
            harness.model.published[autoMarkReadConversation] != nil
        }

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
        await settleAutoMarkRead(until: "the mark has been scheduled") {
            markReadTriggerCount(.scheduled, in: harness) == 1
        }
        let generation = try #require(harness.model.markGeneration[autoMarkReadConversation])

        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead(until: "the refocus trigger has been declined as in-flight") {
            markReadTriggerCount(.alreadyInFlight, in: harness) == 1
        }

        #expect(harness.model.markGeneration[autoMarkReadConversation] == generation)
        #expect(markReadTriggerCount(.scheduled, in: harness) == 1)

        // The watermark write and the tracking clear sit two statements apart
        // with no suspension between them, so a non-`nil` watermark means the
        // clear has run too - which is why `markTasks == nil` below is a
        // stable assertion rather than a race against the mark completing.
        await settleAutoMarkRead(until: "the one mark has advanced the watermark") {
            harness.model.published[autoMarkReadConversation] != nil
        }

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
        await settleAutoMarkRead(until: "the first mark's submit is held") {
            await harness.backend.heldSubmissionCount == 1
        }
        let held = try #require(harness.model.markGeneration[autoMarkReadConversation])

        await harness.model.stop()

        // Schedules the second mark. Its generation must be a number the
        // held mark is not holding.
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead(until: "the second mark has been installed") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }
        let expected = held + 1
        #expect(harness.model.markGeneration[autoMarkReadConversation] == expected)

        // The held mark returns and runs its clear. The second mark's entry
        // has to survive that.
        //
        // **`holdSubmissions` is deliberately left on**, so the second mark's
        // own submit is held too when its wait ends. The previous version
        // turned holding off and relied on the second mark still being inside
        // its 200ms wait when the assertion was read - a race the
        // whole-branch review measured losing under load. With holding left
        // on, that entry cannot be cleared at all, because the only clear
        // that can match its generation is the one after a submit that never
        // returns.
        await harness.backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the held mark has come back and run its clear") {
            harness.sink.outcomes.count == 1
        }

        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)
        await harness.model.stop()
    }

    // MARK: - Sequence 8: a failing mark with an unacked optimistic row

    /// A mark that keeps failing, in a conversation holding one of this
    /// session's own **unacknowledged** optimistic rows: the number of
    /// `mark_group_readstate` calls must stay bounded.
    ///
    /// **The re-arm's no-retry-loop argument rests on a condition the re-arm
    /// itself did not honour.** The comment above it says that comparing
    /// against a freshly computed newest is what stops a failing backend
    /// looping, because on failure the watermark stays unadvanced *and* the
    /// freshest position is unchanged - so the condition is false. That holds
    /// only while `messages` carries no `local/` row. The position being
    /// published comes from the `local/`-filtered list; the re-arm's
    /// `freshest` did not filter. An optimistic send row carries `Date()`, so
    /// `freshest > position` was permanently true while a send was unacked,
    /// and a *failed* mark never advances the watermark to decline the
    /// re-armed trigger either. The whole-branch review measured 750
    /// `mark_group_readstate` calls in ~300ms at `.zero` in exactly this
    /// state - and 742 against the branch point, so the defect is
    /// pre-existing rather than this branch's, and the two-second interval
    /// mitigates it roughly 5000x without removing it.
    ///
    /// **Asserted two ways, because a bound alone is weak.** The count after
    /// the first settle must be small, and - the stronger half - it must not
    /// have moved at all by the second settle. With the filter applied the
    /// re-arm declines and nothing is running, so the count is frozen; with
    /// the loop present it keeps climbing for as long as the test lets it.
    @MainActor
    @Test func aFailedMarkWithAnUnackedLocalRowDoesNotLoop() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .zero)
        await harness.backend.failSubmissions(true)
        try landUnackedLocalMessage(in: harness.store, id: "local/pending")
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()

        let bound = 4
        let first = await harness.backend.markReadCount
        #expect(first <= bound)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await settleAutoMarkRead()
        #expect(await harness.backend.markReadCount == first)
        await harness.model.stop()
    }
}
