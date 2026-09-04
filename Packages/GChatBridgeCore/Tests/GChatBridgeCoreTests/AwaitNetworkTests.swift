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
    ///
    /// Mirrors `ReachabilityMonitor`'s contract exactly, the same shape
    /// `NWPathReachabilityMonitor` implements: `networkReturned` hands out a
    /// fresh, independent stream on every access and `fire()` broadcasts to
    /// every stream currently subscribed - never to a single, stored stream
    /// a second access would keep re-consuming.
    ///
    /// Before the fix for the whole-slice review's Critical 1, this was a
    /// `let networkReturned: AsyncStream<Void>` - a single stored stream,
    /// matching production's own bug precisely - and
    /// `aSecondWaitOnTheSameMonitorStillHonoursASignal` below failed against
    /// it: a cancelled first wait finished that one shared stream forever,
    /// so the second wait's `for await` returned nothing and fell through to
    /// `.fallback` in well under a millisecond (measured as low as 37
    /// microseconds), never reaching `sleep` even though `fire()` was
    /// called. `aSignalWithNobodyWaitingIsNotRedeemedByALaterWait` failed the
    /// same way, for Important 3: a fire with nobody subscribed stayed
    /// buffered on that one shared stream and was wrongly redeemed as an
    /// instant `.signal` by whichever wait came next.
    final class FakeReachability: ReachabilityMonitor, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
        private var nextID = 0

        var networkReturned: AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let id: Int = lock.withLock {
                nextID += 1
                continuations[nextID] = continuation
                return nextID
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = continuations.removeValue(forKey: id) }
            }
            return stream
        }

        /// Broadcasts to every stream currently subscribed - possibly zero,
        /// if nothing is waiting right now. A fire with nobody subscribed is
        /// simply not observed by anyone.
        func fire() {
            let current = lock.withLock { Array(continuations.values) }
            for continuation in current {
                continuation.yield(())
            }
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

    /// Whole-slice review, Critical 1 - the worst of the two findings, and
    /// worse than the bug the whole slice exists to fix, on the same input.
    /// Every other test in this file calls `awaitNetwork` exactly once on a
    /// fresh monitor; this is the one that calls it twice on the *same*
    /// instance, which is what a real `ChannelSession` does on every
    /// `.awaitNetwork` reconnect attempt against its one stored
    /// `reachability` monitor.
    ///
    /// The first wait below ends via the fallback - nothing ever fires, so
    /// the always-instant `sleep` wins the race and `group.cancelAll()`
    /// cancels the signal-side child, which was suspended inside `for await
    /// _ in monitor.networkReturned`. Before the fix, cancelling a task
    /// suspended in `AsyncStream.Iterator.next()` finished the stream it was
    /// iterating, and `FakeReachability.networkReturned` was a single stored
    /// stream - the same shape `NWPathReachabilityMonitor` had - so that
    /// finish was permanent for the life of the fake, not just for this one
    /// wait. The second wait then found the stream already finished: `for
    /// await` returned with no value, `awaitNetwork`'s signal-side child fell
    /// through to `.fallback` without ever reaching `sleep`, and `group.next()`
    /// resolved to that fallen-through `.fallback` before the deliberately
    /// hour-long fallback sleep on the other child ever had a chance to run -
    /// all in well under a millisecond, even though `monitor.fire()` was
    /// called.
    @Test func aSecondWaitOnTheSameMonitorStillHonoursASignal() async {
        let monitor = FakeReachability()

        // First wait: engineered to end via the fallback, which is the one
        // that poisons a single shared stream.
        guard let first = await awaitBounded(
            {
                await ChannelSession.awaitNetwork(
                    monitor: monitor,
                    fallback: .seconds(60),
                    sleep: { _ in }, // instant, so the fallback always wins here
                    onReady: {}
                )
            },
            timeoutMessage: "first wait (expected to end via the fallback) never returned"
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(first == .fallback)

        // Second wait, same monitor instance. Before the fix this returned
        // `.fallback` in well under a millisecond - timed in this suite at
        // as little as 37 microseconds - because the shared stream was
        // already finished and `monitor.fire()` below had nowhere to land.
        let clock = ContinuousClock()
        var second: ChannelSession.NetworkWaitOutcome?
        let elapsed = await clock.measure {
            second = await awaitBounded(
                {
                    await ChannelSession.awaitNetwork(
                        monitor: monitor,
                        fallback: .seconds(60),
                        sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                        onReady: { monitor.fire() }
                    )
                },
                timeoutMessage: """
                timed out waiting for the second awaitNetwork call to return - Critical 1's regression: a \
                monitor whose networkReturned stream is shared rather than fresh per access has its stream \
                finished by the first call's cancelled wait, so a signal fired here is never observed.
                """
            )
        }
        guard let second else {
            return // awaitBounded already recorded why.
        }
        #expect(
            second == .signal,
            """
            second wait returned \(String(describing: second)) after \(elapsed) - a fresh signal was fired \
            via onReady, so anything but .signal means the monitor's stream did not survive the first \
            wait's cancellation
            """
        )
    }

    /// Whole-slice review, Important 3 - the same root cause as Critical 1,
    /// seen from the other side. `NWPathReachabilityMonitor` yields into an
    /// `.unbounded` stream, so before the fix a transition firing while
    /// nothing was waiting stayed buffered and was handed to whichever
    /// `awaitNetwork` call came next - however much later, and with no real
    /// wait behind it. Fixed, a fire with nobody currently subscribed reaches
    /// zero continuations and is simply not observed by anyone; the next
    /// wait gets its own fresh, empty stream rather than inheriting a stale
    /// buffered value.
    ///
    /// The fallback here is a real, short `Task.sleep` rather than the
    /// instant `{ _ in }` most other tests in this file use, and that is
    /// deliberate, not an oversight: a buffered stale value delivers in
    /// well under a millisecond, but so does an instant fallback closure -
    /// `aNetworkSignalEndsTheWaitImmediately`'s own doc comment already
    /// measured an instant fallback winning that race the *majority* of the
    /// time. An instant fallback here would make this test pass whether or
    /// not the stale value was wrongly redeemed, which is not a test at all.
    /// A real sleep long enough for `AsyncStream` delivery to reliably win
    /// if - and only if - something is actually buffered is what makes
    /// `.fallback` a meaningful result rather than a coin flip.
    @Test func aSignalWithNobodyWaitingIsNotRedeemedByALaterWait() async {
        let monitor = FakeReachability()

        // Fired with nothing subscribed yet - no `awaitNetwork` call is in
        // progress, so there is no stream registered to receive this.
        monitor.fire()

        guard let waited = await awaitBounded(
            {
                await ChannelSession.awaitNetwork(
                    monitor: monitor,
                    fallback: .milliseconds(300),
                    sleep: { try? await Task.sleep(for: $0) },
                    onReady: {}
                )
            },
            timeoutMessage: "awaitNetwork never returned after a stale, unrelated fire()"
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(
            waited == .fallback,
            "a fire() from before this wait started must not be redeemed as an instant .signal: \(waited)"
        )
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
