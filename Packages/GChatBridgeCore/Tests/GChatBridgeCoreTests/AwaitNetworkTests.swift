import Foundation
import Testing
@testable import GChatBridgeCore

/// `.awaitNetwork`'s two exits: the signal, and the fallback.
///
/// The fallback is the one that matters. A monitor is an OS telling us about
/// the world, and this project has already been bitten by an OS that reports
/// something other than the truth - `findings.md` §15's silent User-Agent gate
/// and §19.4's `-34018` are both that shape. A channel whose only exit is a
/// signal it may never receive is a channel that can hang forever.
struct AwaitNetworkTests {
    /// Fires on demand, so a test never waits on a real network.
    final class FakeReachability: ReachabilityMonitor, @unchecked Sendable {
        let networkReturned: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (networkReturned, continuation) = AsyncStream<Void>.makeStream()
        }

        func fire() {
            continuation.yield(())
        }
    }

    /// A monitor that exists and never says anything - the deadlock case.
    struct SilentReachability: ReachabilityMonitor {
        var networkReturned: AsyncStream<Void> {
            AsyncStream { _ in } // never yields, never finishes
        }
    }

    /// Fix round 2 finding (Important): wrapped in `awaitBounded`, the same
    /// helper `aSilentMonitorStillEndsTheWaitViaTheFallback` uses, and for a
    /// reason that only came into existence in fix round 1 - it did not
    /// need this before. Once this test's own fallback closure below
    /// started sleeping for a real hour (to make the happy path
    /// deterministic rather than a coin flip - see that closure's comment),
    /// a broken signal path stopped being "wrong outcome, fast" and became
    /// "wrong outcome, after a real hour": `scripts/test.sh` runs `swift
    /// test` with no timeout, so an hour-long stall is indistinguishable
    /// from a genuine hang in practice. Confirmed mechanically, not just
    /// reasoned about: with `onReady` changed to never call `monitor.fire()`
    /// and `.seconds(3600)` dropped to `.seconds(2)` for the experiment
    /// only, the unguarded version of this test failed correctly on
    /// `#expect(waited == .signal)` - but only after 2.13 real seconds. At
    /// the shipped hour scale that is the same failure mode Finding 1
    /// already exists to cap, just with a much longer fuse.
    @Test func aNetworkSignalEndsTheWaitImmediately() async {
        let monitor = FakeReachability()
        guard let waited = await awaitBounded(
            {
                await ChannelSession.awaitNetwork(
                    monitor: monitor,
                    fallback: .seconds(60),
                    // Entering this closure is not itself a failure. In
                    // production `sleep` is a real, cancellable `Task.sleep`,
                    // and `awaitNetwork` reads `group.next()` exactly once,
                    // so a fallback side that merely starts before the
                    // signal wins the race never has its return value
                    // looked at. `#expect(waited == .signal)` below already
                    // carries the whole property: had the fallback won
                    // instead, `waited` would be `.fallback`.
                    //
                    // This does not use a bare `{ _ in }`, though: measured
                    // over 20 repeated runs, a truly zero-cost fallback wins
                    // the race against `AsyncStream`'s buffered-delivery
                    // latency the *majority* of the time (fix round 1's own
                    // report has the numbers) - an artifact of racing a
                    // synthetic zero-cost path against delivery machinery
                    // that is never actually zero-cost, which no real
                    // fallback (a genuine multi-second `Task.sleep`) ever
                    // does. So this closure sleeps for an hour: `Task.sleep`'s
                    // cancellation is prompt by contract (not tuned), so it
                    // never actually waits that long - `awaitNetwork`
                    // cancels it the instant the signal side wins, the same
                    // instant it would cancel a real 60-second fallback in
                    // production. The only way this closure's `Task.sleep`
                    // ever elapses on its own is a multi-decade-slow
                    // machine, at which point failing this test is the
                    // right outcome anyway - or the signal path being
                    // broken, which is exactly what `awaitBounded`'s
                    // 10-second deadline below is for.
                    sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                    onReady: { monitor.fire() }
                )
            },
            timeoutMessage: """
            timed out waiting for awaitNetwork to return - the signal path may be broken: the fake \
            monitor fires unconditionally, so a signal that never reached group.next() points at the \
            consuming side, not at the fallback (which can only end via cancellation, never on its own).
            """
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(waited == .signal)
    }

    /// Fix round 1 finding (Critical): this test used to `await
    /// ChannelSession.awaitNetwork(...)` directly, with no `.timeLimit`
    /// trait, no deadline, no early-completion check and no `Issue.record`.
    /// The prior implementer's own experiment - deleting the production
    /// fallback branch so only a signal could end the wait - proved this
    /// exact test hangs rather than fails, because `SilentReachability`
    /// never sends one. `awaitBounded` below bounds the call the same way
    /// `ChannelSessionReconnectTests.startAndWait` bounds its condition, so
    /// the identical regression now fails red instead of hanging
    /// `scripts/test.sh`, which invokes `swift test` with no timeout.
    @Test func aSilentMonitorStillEndsTheWaitViaTheFallback() async {
        guard let waited = await awaitBounded(
            {
                await ChannelSession.awaitNetwork(
                    monitor: SilentReachability(),
                    fallback: .seconds(60),
                    sleep: { _ in }, // returns instantly, standing in for 60s
                    onReady: {}
                )
            },
            timeoutMessage: """
            timed out waiting for awaitNetwork to return - the production fallback path may be \
            broken, leaving only a signal a silent monitor never sends.
            """
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(waited == .fallback)
    }

    /// Genuinely cannot hang, unlike the test above: `monitor: nil` takes
    /// `awaitNetwork`'s early `guard let monitor else { ... }` return, which
    /// never enters the `withTaskGroup` race at all - there is no signal
    /// side to fail to arrive, and the injected `sleep` below returns
    /// instantly rather than waiting on a real clock. No guard needed
    /// because there is nothing here for a regression in the race to break.
    @Test func noMonitorAtAllStillEndsTheWait() async {
        let waited = await ChannelSession.awaitNetwork(
            monitor: nil,
            fallback: .seconds(60),
            sleep: { _ in },
            onReady: {}
        )
        #expect(waited == .fallback)
    }
}

/// Runs `body` and bounds it by a deadline, so a regression in the code this
/// guards fails the test instead of hanging `swift test` forever.
///
/// Same shape as `ChannelSessionReconnectTests.startAndWait`, which exists
/// for the identical Critical finding one task earlier: a completion flag is
/// set from *inside* `body`'s own task the instant it returns, and is
/// polled rather than raced against via a sibling task awaiting `.value` -
/// that shape reproducibly hung there (see that helper's doc comment for
/// the isolated repro) rather than bounding anything.
///
/// `timeoutMessage` is a parameter, not a fixed string, because this is now
/// shared by two call sites that time out for opposite reasons - one when a
/// signal never arrives, the other when a fallback never fires - and a
/// generic message would misname whichever one actually failed.
///
/// Deferred, not fixed this round: the `Task { ... }` below is unstructured
/// and is never explicitly cancelled, so a genuine timeout leaks a
/// suspended task rather than being torn down the way
/// `ChannelSessionReconnectTests`'s equivalent path is (that suite's callers
/// call `session.stop()`, which this helper's callers have no analogue of).
/// Low practical cost at rest; recorded for the whole-branch review rather
/// than addressed here.
private func awaitBounded<Value: Sendable>(
    _ body: @escaping @Sendable () async -> Value,
    timeoutMessage: Comment
) async -> Value? {
    let result = ResultBox<Value>()
    Task {
        let value = await body()
        await result.set(value)
    }
    // Ten seconds, matching `startAndWait`'s own bound: every call this
    // guards resolves in well under a millisecond when the code is correct
    // (a fake or silent monitor and an instantly-returning injected
    // `sleep`), so this is a hang guard, not a realistic timing budget.
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        if let value = await result.value {
            return value
        }
        if ContinuousClock.now >= deadline {
            Issue.record(timeoutMessage)
            return nil
        }
        await Task.yield()
    }
}

/// Set by `awaitBounded`'s wrapped `body`, from inside its own task, the
/// instant it returns - the same trade `ChannelSessionReconnectTests`' own
/// `CompletionFlag` makes, and for the same reason (see `awaitBounded`'s
/// doc comment above).
private actor ResultBox<Value: Sendable> {
    private(set) var value: Value?

    func set(_ newValue: Value) {
        value = newValue
    }
}
