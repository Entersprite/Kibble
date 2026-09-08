import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The wait before a read position is published, and the sequences that break
/// a naive version of it.
///
/// Every test drives a *sequence*. `findings.md` §25.10 is a Critical in this
/// repo that passed every test because each test called the thing once, and
/// this slice's own re-arm fix reintroduced its own finding the same way.
///
/// **Every wait here is a predicate, not a yield budget.** The whole-branch
/// review measured `settleAutoMarkRead()`'s fixed 200 yields consuming part
/// of the debounce interval under CPU load, so the interleaved event a test
/// was about landed *after* the wait it was meant to land inside;
/// `settleAutoMarkRead(until:holds:)`'s own doc comment carries the numbers.
/// The `.zero` tests below keep the plain settle, because they are waiting
/// for the main actor to drain rather than for an interval to pass.
///
/// **`.serialized`, and it is the other half of that fix.** Swift Testing
/// runs this package's tests in parallel and every test here is `@MainActor`,
/// so they queue on one actor. Under load that measured out as GRDB's
/// store-write-to-`messages` delivery stalling for hundreds of milliseconds -
/// against ~1.5ms for the same harness run alone under the same external
/// CPU load - which no waiting strategy can help, because the event a test
/// has to place inside the wait has not happened yet. Serializing the three
/// debounce suites drops the concurrent main-actor debounce tests from
/// seventeen to three and is what took the stressed failure rate to zero.
/// The trace-token half of this suite lives in `MarkReadDebounceTraceTests`,
/// split on `file_length`.
///
/// **Two intervals are used deliberately.** Most tests pass `.zero`, because
/// they are about guards and cancellation and a real wait would only slow the
/// suite. The two coalescing tests pass `.milliseconds(50)` and then wait for
/// it, because coalescing is *defined* as "messages arriving during the wait"
/// and `.zero` leaves no wait to arrive during - with `.zero` those messages
/// land during the submit instead, hit `already-in-flight`, and are picked up
/// by the re-arm as a second mark. That would test the re-arm, not the
/// debounce, and would pass while the coalescing was entirely absent.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct MarkReadDebounceTests {
    /// A burst during the wait produces ONE mark, not one per message.
    ///
    /// **The verdict is the whole published list, not a count**, and that is
    /// what makes stopping on a predicate safe here: `[newest + 30]` says
    /// both that exactly one mark happened and that it carried the coalesced
    /// position. A bare `count == 1`, read the instant the first mark lands,
    /// would also pass in a world where two more were on their way behind it.
    @MainActor
    @Test func aBurstDuringTheWaitProducesOneMark() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the mark for the open conversation is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }

        // One transaction, three messages - `landAutoMarkReadBurst`'s doc
        // comment says why the number of observation deliveries this test has
        // to survive inside the interval is the thing worth minimising.
        try landAutoMarkReadBurst(in: harness.store, [
            (id: "srv-a", secondsAfterFixture: 10),
            (id: "srv-b", secondsAfterFixture: 20),
            (id: "srv-c", secondsAfterFixture: 30)
        ])
        // The precondition, asserted rather than assumed. Both readings are
        // main-actor-local, so they describe one instant: the newest of the
        // three is in `messages` **and** no `submitted` row exists yet, which
        // is what "the burst landed inside the wait" means. Without this, a
        // machine that lost the race reports the value assertion below going
        // red and reads as broken coalescing.
        await settleAutoMarkRead(until: "the newest of the burst has reached the model") {
            harness.model.messages.contains { $0.id.rawValue == "srv-c" }
        }
        #expect(markReadTriggerCount(.submitted, in: harness) == 0)

        await settleAutoMarkRead(until: "a read position has been published") {
            await markReadPositions(from: harness.backend).count == 1
        }

        let expected = try autoMarkReadFixtureNewest.addingTimeInterval(30)
        #expect(await markReadPositions(from: harness.backend) == [expected])
        await harness.model.stop()
    }

    /// The position published is the newest at the END of the wait, not the
    /// one that scheduled it. This is the only test that proves the value
    /// moved rather than merely that one call happened.
    @MainActor
    @Test func thePublishedPositionIsTheNewestAtTheEndOfTheWait() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the mark for the open conversation is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }

        try landAutoMarkReadMessage(in: harness.store, id: "srv-late", secondsAfterFixture: 42)
        // The same precondition `aBurstDuringTheWaitProducesOneMark` asserts,
        // and for the same reason: the late message reached the model while
        // the mark was still waiting. Both readings are main-actor-local, so
        // they describe one instant, and a machine that lost the race says so
        // here instead of reporting the value below as wrong.
        await settleAutoMarkRead(until: "the late message has reached the model") {
            harness.model.messages.contains { $0.id.rawValue == "srv-late" }
        }
        #expect(markReadTriggerCount(.submitted, in: harness) == 0)

        await settleAutoMarkRead(until: "a read position has been published") {
            await markReadPositions(from: harness.backend).count == 1
        }

        let expected = try autoMarkReadFixtureNewest.addingTimeInterval(42)
        #expect(await markReadPositions(from: harness.backend) == [expected])
        await harness.model.stop()
    }

    /// Losing focus during the wait publishes nothing. The gate is re-checked
    /// after the wait as well as before it, because two seconds is long enough
    /// for the user to leave.
    ///
    /// **The settle before `setActive(false)` is what makes this test about
    /// the post-wait guard at all**, and its first version did not have one.
    /// `isActive` starts `true`, so dropping focus in the same synchronous
    /// run as `select(_:)` means no mark is ever scheduled and the *pre*-wait
    /// guard declines - deleting `publishReadPosition`'s own `guard isActive`
    /// left that version green, which is the definition of no coverage.
    /// Settling first schedules the mark, and focus then goes away while it
    /// is waiting, which is the sequence the doc comment claims.
    @MainActor
    @Test func losingFocusDuringTheWaitPublishesNothing() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the mark for the open conversation is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }
        // The positive control. Without it, "nothing was published" and
        // "nothing was ever scheduled" are the same observation, and this
        // test cannot tell the guard working from the guard being absent.
        // Read synchronously, and the `markReadPositions` control below is
        // read *after* focus is dropped rather than before it: that call is
        // an actor hop, and a suspension between the settle and
        // `setActive(false)` puts the shared main actor back in play inside
        // the one window this sequence depends on. Measured - it is the last
        // load-induced failure that survived serializing these suites.
        #expect(harness.model.markTasks[autoMarkReadConversation] != nil)

        harness.model.setActive(false)
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        // The observable consequence of the wait having ended on the
        // post-wait focus guard, rather than a sleep guessed to be past it:
        // that return goes through the task's `defer`, which is the only
        // thing that clears the entry on this path.
        await settleAutoMarkRead(until: "the wait has ended and cleared its tracking entry") {
            harness.model.markTasks[autoMarkReadConversation] == nil
        }

        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    /// Switching conversation during the wait publishes the position captured
    /// at schedule time, and must NOT publish some other conversation's newest
    /// timestamp against this conversation's id - after the wait, `messages`
    /// belongs to whatever is selected now.
    @MainActor
    @Test func switchingConversationDuringTheWaitPublishesTheCapturedPosition() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the first conversation's mark is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }

        let other = try #require(
            harness.model.conversations.first { $0.id != autoMarkReadConversation }
        )
        harness.model.select(other.id)
        await settleAutoMarkRead(until: "both conversations' marks have been published") {
            await markReads(from: harness.backend).count >= 2
        }

        // The first mark is the one scheduled for the original conversation,
        // and it carries that conversation's own newest position.
        let marks = await markReads(from: harness.backend)
        let forOriginal = marks.filter { $0.conversation == autoMarkReadConversation }
        #expect(forOriginal.count == 1)
        #expect(try forOriginal.first?.position == autoMarkReadFixtureNewest)
        await harness.model.stop()
    }

    /// `stop()` during the wait publishes nothing, advances no watermark, and
    /// leaves no entry behind to wedge the conversation.
    ///
    /// **Driven through the traced harness so the negative has something
    /// observable behind it.** "Nothing was published" is not a state a test
    /// can wait *for*, and the previous version slept a guessed 150ms past
    /// the interval instead - one of the waits the whole-branch review
    /// measured failing under load. `cancelledDuringWait` is the row the
    /// cancelled task writes on its way out, so waiting for it means the
    /// wait genuinely ended before these three assertions are read, rather
    /// than probably having ended.
    @MainActor
    @Test func stopDuringTheWaitPublishesNothingAndWedgesNothing() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .milliseconds(50))
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead(until: "the mark for the open conversation is waiting") {
            harness.model.markTasks[autoMarkReadConversation] != nil
        }

        await harness.model.stop()
        await settleAutoMarkRead(until: "the cancelled wait has recorded its own row") {
            markReadTriggerCount(.cancelledDuringWait, in: harness) == 1
        }

        #expect(await markReadPositions(from: harness.backend).isEmpty)
        #expect(harness.model.published[autoMarkReadConversation] == nil)
        #expect(harness.model.markTasks[autoMarkReadConversation] == nil)
    }

    /// A failed submit leaves the watermark unadvanced so a later trigger
    /// retries - the rule the whole re-arm rests on, and the one a debounce
    /// could plausibly break by advancing on schedule rather than on success.
    ///
    /// **Named for what it actually drives.** It runs with `.zero`, so there
    /// is no wait in it and it claims nothing about one: it is a regression
    /// guard that the pre-existing watermark rule survived moving the submit
    /// behind a suspension point. `AutoMarkReadTests.aFailedMarkIsRetriedByTheNextTrigger`
    /// is the same invariant from the other side; this one additionally
    /// asserts `published` itself rather than only the call count.
    @MainActor
    @Test func aFailedSubmitLeavesTheWatermarkUnadvanced() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .zero)
        await harness.backend.failSubmissions(true)
        harness.model.select(autoMarkReadConversation)
        await settleAutoMarkRead()
        let afterFailure = await markReadPositions(from: harness.backend).count
        #expect(afterFailure == 1)
        #expect(harness.model.published[autoMarkReadConversation] == nil)

        await harness.backend.failSubmissions(false)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead()

        #expect(await markReadPositions(from: harness.backend).count == afterFailure + 1)
        await harness.model.stop()
    }
}
