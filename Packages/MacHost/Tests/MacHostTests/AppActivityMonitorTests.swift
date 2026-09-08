import AppKit
import Foundation
import Testing
@testable import MacHost

/// `AppActivityMonitor.changes`, driven with plain `NotificationCenter` posts
/// rather than a real app activation - no `NSApplication` needs to become
/// frontmost for `didBecomeActiveNotification`/`willResignActiveNotification`
/// to be observable, they are ordinary notification names.
///
/// This suite exists because of `findings.md` §25.10, not merely to pad
/// coverage: that Critical shipped in `NWPathReachabilityMonitor` because
/// "no per-task test caught it - every existing test called `awaitNetwork`
/// exactly once; the regression needs a *second* call on the *same* monitor,
/// a scenario no single task's own scope ever required writing."
/// `AppActivityMonitor.changes` is built to the identical fresh-stream /
/// broadcast / isolated-cancellation shape, so it gets the identical class of
/// regression test: a second, independent stream, and a cancellation of one
/// stream's consumer that must not touch the other's.
///
/// **Every test here is `@MainActor`, and that is load-bearing, not
/// decoration.** `AppActivityMonitor` is itself `@MainActor`, and its
/// observers are registered with `queue: .main` - delivery is therefore
/// always posted asynchronously onto the main actor's queue, even when the
/// post itself happens on the main actor. `AutoMarkReadHarness
/// .settleAutoMarkRead()`'s own doc comment records the exact failure mode a
/// nonisolated wait loop hits here: "a nonisolated `Task.yield()` loop never
/// handed the main thread back... within the 200-iteration budget: every
/// test... measured zero messages loaded... deterministically, on every
/// run." `awaitBounded` below is that same idiom, kept `@MainActor` for that
/// reason, and used instead of `Task.sleep` throughout - the fixed sleep in
/// `NWPathReachabilityMonitorTests` only gives a *producer* task a head start
/// before cancelling it, it does not wait for a *result*, which is the
/// distinction this file's own `settleUntilSuspended` observes below.
/// `.serialized`: every observer here is registered with `object: nil`
/// against `NotificationCenter.default` - the same shared, process-global
/// center production code posts to - so a notification one test posts is
/// visible to every `AppActivityMonitor` instance live anywhere in the
/// process, not just this test's own. Swift Testing parallelises tests
/// within a suite by default, and running these three concurrently really
/// did cross-contaminate: a `didBecomeActiveNotification` from one test
/// landed on another test's stream mid-run, observed as a flaky
/// `survived == true` failure (`survived → false`) roughly half the time
/// across repeated runs. `.serialized` is the fix, not a broader filter on
/// `object:` - the production code posts with `object: nil` too (it is
/// AppKit's own notification, not something this file controls), so the
/// tests have to run one at a time to match.
@MainActor
@Suite("AppActivityMonitor.changes", .serialized)
struct AppActivityMonitorTests {
    @Test("a posted transition reaches a consumer, mapped to the right booleans")
    func postedTransitionReachesConsumer() async {
        let monitor = AppActivityMonitor()
        let consumer = IteratorBox(monitor.changes)

        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
        guard let resigned = await awaitBounded(
            timeoutMessage: "willResignActiveNotification never reached the consumer",
            { await consumer.next() }
        ) else { return }
        #expect(resigned == false)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        guard let became = await awaitBounded(
            timeoutMessage: "didBecomeActiveNotification never reached the consumer",
            { await consumer.next() }
        ) else { return }
        #expect(became == true)
    }

    @Test("two independently-obtained streams both receive the same broadcast")
    func twoStreamsBothReceive() async {
        // A stored-stream implementation - the exact bug `findings.md` §25.10
        // fixed in the reachability monitor - would split one notification's
        // delivery between these two arbitrarily rather than delivering it to
        // both, because there would only be one continuation to hand it to.
        let monitor = AppActivityMonitor()
        let first = IteratorBox(monitor.changes)
        let second = IteratorBox(monitor.changes)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        guard let firstValue = await awaitBounded(
            timeoutMessage: "the first stream never received the broadcast",
            { await first.next() }
        ) else { return }
        guard let secondValue = await awaitBounded(
            timeoutMessage: "the second stream never received the broadcast",
            { await second.next() }
        ) else { return }
        #expect(firstValue == true)
        #expect(secondValue == true)
    }

    @Test("cancelling one consumer's task leaves an unrelated stream working - the §25.10 regression itself")
    func cancellingOneConsumerLeavesAnotherIntact() async {
        let monitor = AppActivityMonitor()
        let cancelledBox = IteratorBox(monitor.changes)
        let survivorBox = IteratorBox(monitor.changes)

        // Suspend a task inside `AsyncStream.Iterator.next()` for `cancelled`
        // the same way `NetworkWait.awaitNetwork` suspends its race's loser,
        // then cancel it - this is the exact sequence a stored, shared stream
        // gets wrong: cancelling the suspended iteration would finish the
        // stream for every consumer, not just this task's own.
        let task = Task { @MainActor in
            _ = await cancelledBox.next()
        }
        await settleUntilSuspended()
        task.cancel()
        _ = await awaitBounded(
            timeoutMessage: "the cancelled task never actually finished after being cancelled",
            { await task.value }
        )

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        guard let survived = await awaitBounded(
            timeoutMessage: """
            the surviving stream never received the broadcast after an unrelated stream's consumer was \
            cancelled - cancellation must be isolated per stream, not shared
            """,
            { await survivorBox.next() }
        ) else { return }
        #expect(survived == true)
    }
}

/// One `AsyncStream<Bool>.Iterator`, boxed so the same iterator can be
/// advanced across multiple `await`s from test code without needing `inout`
/// captures across a `Task` boundary. `@MainActor` because everything that
/// calls it in this file is itself `@MainActor`.
///
/// **`next(isolation:)`, not the isolation-less `next()`.** Plain `next()` on
/// `AsyncStream.Iterator` is `nonisolated`, and Swift 6's sending-analysis
/// refuses to hand a main-actor-isolated iterator across into it even from
/// within a `@MainActor` method - "sending main actor-isolated 'iterator' to
/// nonisolated instance method 'next()' risks causing data races." Passing
/// `#isolation` (this method's own isolation, `MainActor` here) tells the
/// compiler the call stays on the actor it is already isolated to, which is
/// exactly what is true: the `NotificationCenter` callback that resumes this
/// continuation runs on `queue: .main` too.
private final class IteratorBox {
    private var iterator: AsyncStream<Bool>.Iterator

    init(_ stream: AsyncStream<Bool>) {
        iterator = stream.makeAsyncIterator()
    }

    @MainActor
    func next() async -> Bool? {
        await iterator.next(isolation: #isolation)
    }
}

/// A bounded, `@MainActor` wait for a task suspended inside
/// `AsyncStream.Iterator.next()` to actually reach that suspension point,
/// before this file cancels it - proving cancellation tears down only its own
/// stream rather than nothing at all. A fixed iteration count of `Task.yield`
/// rather than `Task.sleep`, for the same reason `awaitBounded` below is
/// `@MainActor`: yielding is what hands control back to the main actor's own
/// queue, which is where the `NotificationCenter` observer's
/// `queue: .main` callback and the iterator's continuation resumption both
/// run. There is nothing to poll a *value* for here - unlike `awaitBounded` -
/// so this is a fixed budget, the same shape
/// `AutoMarkReadHarness.settleAutoMarkRead()` already uses, not an unbounded
/// loop.
@MainActor
private func settleUntilSuspended() async {
    for _ in 0 ..< 200 {
        await Task.yield()
    }
}

/// Runs `body` and bounds it by a wall-clock deadline, so a regression in the
/// code this guards fails the test instead of hanging `swift test` forever.
/// `@MainActor`, unlike `URLSessionTransportTests.NWPathReachabilityMonitorTests`'s
/// own `awaitBounded` (which needs no actor at all, since
/// `ReachabilityBroadcaster` isn't isolated to one): `AppActivityMonitor` is
/// `@MainActor` and its notification delivery lands on the main actor's own
/// queue, so both the child task running `body` and this polling loop must
/// themselves run on the main actor for delivery to ever actually happen -
/// see this file's header for the nonisolated-loop failure mode this avoids.
@MainActor
private func awaitBounded<Value: Sendable>(
    timeoutMessage: Comment,
    _ body: @escaping @MainActor () async -> Value
) async -> Value? {
    let box = ResultBox<Value>()
    Task { @MainActor in
        let value = await body()
        box.value = value
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while box.value == nil {
        if ContinuousClock.now >= deadline {
            Issue.record(timeoutMessage)
            return nil
        }
        await Task.yield()
    }
    return box.value
}

@MainActor
private final class ResultBox<Value> {
    var value: Value?
}
