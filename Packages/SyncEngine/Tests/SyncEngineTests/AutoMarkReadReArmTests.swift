import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The re-arm sequences: what happens when a mark that is *already* a re-arm
/// (installed from inside a previous mark's own completion, because a newer
/// message arrived during its flight) is itself interrupted by a further
/// delivery, or by `stop()`.
///
/// Split out of `AutoMarkReadTests.swift` once these tests pushed that file
/// past swiftlint's `file_length` ceiling; the harness both files share lives
/// in `Support/AutoMarkReadHarness.swift`. These are deliberately *third-step*
/// tests in the sense `findings.md` §25.10 means it:
/// `aMessageArrivingDuringAnInFlightMarkIsNotDropped` (in the other file)
/// drives exactly one re-arm and asserts only `markReadCount`, which cannot
/// see a defect where the re-armed mark's *own* tracking entry gets
/// corrupted - that defect only shows up on the delivery *after* the re-arm,
/// which is what every test here drives.
@Suite(.timeLimit(.minutes(1)))
struct AutoMarkReadReArmTests {
    private typealias Harness = AutoMarkReadHarness

    private var conversation: Conversation.ID {
        autoMarkReadConversation
    }

    @MainActor
    private func harness(capabilities: Capabilities = .fixture) async throws -> Harness {
        try await makeAutoMarkReadHarness(capabilities: capabilities)
    }

    @MainActor
    private func settle() async {
        await settleAutoMarkRead()
    }

    /// Review found: the completing mark's `defer` ran after it had already
    /// installed its replacement, so an unconditional clear there deleted the
    /// replacement's entry - reopening the in-flight guard while the
    /// replacement was still running, letting a second delivery start a
    /// third, concurrent mark. `markGeneration` is what closes it: this test
    /// proves the guard still holds one level down, by holding the gate
    /// across *two* marks (not one) and checking `heldSubmissionCount` -
    /// which a third concurrent call would move to 2 - rather than trusting
    /// `markReadCount` alone to notice.
    @MainActor
    @Test func aDeliveryDuringAReArmedMarksFlightStartsNoThirdCall() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
        let store = harnessResult.store
        await backend.holdSubmissions(true)

        // Mark A: starts on open, blocks in `send(_:)`.
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)
        #expect(await backend.heldSubmissionCount == 1)

        // A newer message during A's flight is suppressed - not a second
        // call, because A's own entry is still occupying `markTasks`.
        let newest = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        var duringA = newest
        duringA.id = Message.ID("fixture-seed-during-a")
        duringA.createdAt = newest.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(duringA)])
        await settle()
        #expect(await backend.markReadCount == 1)
        #expect(await backend.heldSubmissionCount == 1)

        // Releasing A lets it complete and re-arm mark B for `duringA`'s
        // position. The gate is still open, so B blocks too - this is the
        // window the defect lived in: does B's entry survive A's `defer`?
        await backend.releaseHeldSubmission()
        await settle()
        #expect(await backend.markReadCount == 2)
        #expect(await backend.heldSubmissionCount == 1)

        // A second newer message during B's flight. With the defect, A's
        // stale `defer` already erased B's tracking entry, so this delivery
        // would pass the in-flight guard and start a third, concurrent mark -
        // `heldSubmissionCount` would become 2. With `markGeneration` closing
        // it, B's entry is untouched and this delivery is suppressed exactly
        // like the one during A's flight was.
        var duringB = duringA
        duringB.id = Message.ID("fixture-seed-during-b")
        duringB.createdAt = duringA.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(duringB)])
        await settle()
        #expect(await backend.markReadCount == 2)
        #expect(await backend.heldSubmissionCount == 1)

        // Drain the burst: releasing B re-arms once more for `duringB`'s
        // position, and opening the gate lets that final mark actually land.
        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        await settle()

        #expect(await backend.markReadCount == 3)
        await model.stop()
    }

    /// The other half of the same corruption: even when no third delivery
    /// arrives to expose the reopened guard, a re-armed mark that is no
    /// longer reachable from `markTasks` cannot be found and cancelled by
    /// `stop()`. Signing out while it is in flight would leave it running
    /// with `engine` captured strongly, reaching the network for an account
    /// that just signed out and, on failure, recording into a store
    /// `stopAndEraseStore()` has already erased - the exact exposure
    /// `markTasks` exists to close, one level down.
    ///
    /// Asserted on the observable consequence rather than on `markTasks`'
    /// contents (private, and not the guarantee itself): a newer message
    /// arrives during the re-armed mark's flight, so if `stop()` fails to
    /// cancel it, releasing it afterwards re-arms *again* and `markReadCount`
    /// reaches 3. If `stop()` does cancel it, `Task.isCancelled` stops that
    /// mark before it ever re-checks, and no third call follows.
    @MainActor
    @Test func stopCancelsAReArmedMarkInFlight() async throws {
        let harnessResult = try await harness()
        let model = harnessResult.model
        let backend = harnessResult.backend
        let store = harnessResult.store
        await backend.holdSubmissions(true)

        // Mark A: starts on open, blocks.
        model.select(conversation)
        await settle()
        #expect(await backend.markReadCount == 1)

        // A newer message during A's flight - suppressed, and captured as the
        // position mark B (the re-arm) will attempt.
        let newest = try #require(
            FixtureWorld.minimal.messages
                .filter { $0.conversationID == conversation }
                .max { $0.createdAt < $1.createdAt }
        )
        var duringA = newest
        duringA.id = Message.ID("fixture-seed-stop-during-a")
        duringA.createdAt = newest.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(duringA)])
        await settle()
        #expect(await backend.markReadCount == 1)

        // Release A: it completes, re-arms mark B for `duringA`'s position,
        // and B blocks too (the gate is still open).
        await backend.releaseHeldSubmission()
        await settle()
        #expect(await backend.markReadCount == 2)

        // A second newer message while B is in flight - this is the position
        // an uncancelled B would chase after being released below.
        var duringB = duringA
        duringB.id = Message.ID("fixture-seed-stop-during-b")
        duringB.createdAt = duringA.createdAt.addingTimeInterval(60)
        try store.apply([.upsertMessage(duringB)])
        await settle()
        #expect(await backend.markReadCount == 2)

        // Sign out while B is still blocked in flight.
        await model.stop()

        // Release B and open the gate. `engine.submit` itself does not
        // consult cancellation - `stop()`'s own doc comment says as much for
        // `historyTask`, and the same is true here - so B's `send(_:)` still
        // completes. What must not happen is anything *after* that: `stop()`
        // cancelled B's `Task`, so its `Task.isCancelled` guard returns before
        // publishing or re-checking `duringB`'s position.
        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        await settle()

        #expect(await backend.markReadCount == 2)
    }
}
