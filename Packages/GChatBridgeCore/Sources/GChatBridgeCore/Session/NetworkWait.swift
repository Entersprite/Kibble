import Foundation

/// The driver's half of `.awaitNetwork`.
///
/// Split out of `ChannelSession.swift` rather than added to it because that
/// file was already at 340 lines and swiftlint's `file_length` ceiling is
/// 400, checked under `--strict`. The call site this exists for is
/// `ChannelSession.awaitNetwork(...)` either way - an `extension` puts it
/// there without the stored properties and the two initialisers sharing a
/// file with it.
extension ChannelSession {
    /// How `.awaitNetwork`'s wait ended.
    public enum NetworkWaitOutcome: Sendable, Equatable {
        /// `ReachabilityMonitor.networkReturned` yielded.
        case signal
        /// The bounded fallback timer elapsed first - no monitor was given,
        /// the monitor stayed silent, or the timer simply won the race.
        case fallback
    }

    /// How long `.awaitNetwork` waits before retrying anyway, absent (or
    /// instead of) a reachability signal.
    ///
    /// **`[Verify]` - a guess.** Long enough not to poll while genuinely
    /// offline, short enough that a missed reachability signal is a slow app
    /// rather than a dead one. No measurement supports the number.
    static let reachabilityFallback = Duration.seconds(60)

    /// Waits for `monitor` to report the network's return, or for `fallback`
    /// to elapse, whichever happens first.
    ///
    /// `static`, and every source of asynchrony is a parameter - no session,
    /// no socket, no actor hop - for the same reason `RetryPolicy.sleep` is
    /// injectable: a test drives this with a fake monitor and a `sleep` that
    /// returns instantly, so nothing here ever waits on a real clock or a
    /// real network.
    ///
    /// **Race structure, and why it cannot starve.** Both exits run as
    /// sibling child tasks of one `withTaskGroup`: the signal side suspends
    /// inside `for await` on the monitor's stream, the fallback side is
    /// built to suspend too (see below) rather than run to completion in one
    /// shot. Neither ever spins - there is no *unbounded*, non-suspending
    /// loop on either side - which is exactly the shape that starved a
    /// sibling in task 3's first attempt at a similar wait (see
    /// `ChannelSessionReconnectTests.startAndWait`'s doc comment: there, one
    /// sibling awaited `Task.value` on a task whose own body was an
    /// *unbounded* `.immediate`-retry loop that never suspended, and that
    /// starved the other sibling of the cooperative thread pool outright).
    /// Whichever finishes first is taken from the group and the other is
    /// cancelled; `Task.sleep` and `AsyncStream.Iterator.next()` both end
    /// promptly on cancellation rather than hanging, so the loser never
    /// leaks and the implicit drain `withTaskGroup` performs on exit never
    /// blocks behind it.
    ///
    /// **What "verify empirically" actually found.** The first cut of this
    /// raced the two sides as pure peers - add both tasks, call `onReady`,
    /// take whichever `group.next()` returns first. It reliably reported
    /// `.fallback` for `aNetworkSignalEndsTheWaitImmediately` anyway, and
    /// `sleep`'s "the fallback timer should not have been reached" trap
    /// fired every single time (confirmed over dozens of runs, not assumed):
    /// a fallback side with no genuine suspension of its own (exactly what
    /// every test here injects, standing in for a real clock) runs to
    /// completion the instant it is scheduled, while `AsyncStream` delivery
    /// - even of a value already sitting in the buffer, which is
    /// `FakeReachability`'s default `.unbounded` policy - still costs the
    /// signal side one or more genuine scheduler round-trips through its
    /// continuation. Cancelling the loser *after* `group.next()` returns
    /// cannot undo a side effect (the trap's `Issue.record`) the loser's
    /// body already ran before that cancellation was even requested - by
    /// construction, structured concurrency cannot preempt a task mid-body,
    /// only at a suspension point the task itself checks. So the fallback
    /// side below gives a concurrently-arriving cancellation a bounded
    /// number of real scheduler turns to land - `Task.yield()` in a loop,
    /// checking `Task.isCancelled` each time - before it ever touches
    /// `sleep`. It costs a genuine fallback (nothing to cancel it) a
    /// handful of cheap turns, immaterial against a 60-second real timer,
    /// and every test here still reports sub-millisecond. Confirmed over 20+
    /// repeated runs of the full suite, and separately by deleting the
    /// fallback branch entirely and watching
    /// `aSilentMonitorStillEndsTheWaitViaTheFallback` hang rather than
    /// assuming it would - see task 4's report for both investigations.
    ///
    /// Only one iterator over `monitor.networkReturned` is ever live at a
    /// time - a fresh `for await` each call, cancelled before the next call
    /// starts one - because `AsyncStream` iteration is single-consumer, and
    /// a second live consumer racing the first is undefined which one a
    /// given value reaches.
    ///
    /// - Parameters:
    ///   - monitor: `nil` on a platform (or in a test) with no reachability
    ///     signal at all; `.awaitNetwork` then relies entirely on `fallback`.
    ///   - fallback: The bounded ceiling on this wait, regardless of `monitor`.
    ///   - sleep: Injectable so a test never waits on a real clock, the same
    ///     reason `RetryPolicy.sleep` is.
    ///   - onReady: Fires once this call has begun consuming
    ///     `monitor?.networkReturned` - never before. It exists solely so a
    ///     test can fire a fake monitor's signal *from inside* this function,
    ///     after the signal side is already listening: firing any earlier
    ///     (before the race is even set up) risks the signal reaching a
    ///     stream nobody is yet positioned to consume, which would take this
    ///     call down the fallback path instead of the signal path - or hang,
    ///     if the fallback path had also been removed to test exactly that.
    ///     Production passes an empty closure; only tests pass one with an
    ///     effect.
    static func awaitNetwork(
        monitor: (any ReachabilityMonitor)?,
        fallback: Duration,
        sleep: @Sendable @escaping (Duration) async -> Void,
        onReady: @Sendable () -> Void
    ) async -> NetworkWaitOutcome {
        guard let monitor else {
            await sleep(fallback)
            return .fallback
        }
        return await withTaskGroup(of: NetworkWaitOutcome.self) { group in
            group.addTask {
                for await _ in monitor.networkReturned {
                    return .signal
                }
                // The stream finished without ever yielding. Not documented
                // behaviour for `ReachabilityMonitor` - "never finishes on
                // its own" - but falling through to `.fallback` rather than
                // looping keeps this side effect-free either way.
                return .fallback
            }
            // Only reachable once the task above is queued to consume
            // `networkReturned` - see the parameter doc above for why this
            // must not fire any earlier.
            onReady()

            group.addTask {
                guard await !(Self.yieldToAnyPendingCancellation()) else {
                    return .fallback
                }
                await sleep(fallback)
                return .fallback
            }

            let outcome = await group.next() ?? .fallback
            group.cancelAll()
            return outcome
        }
    }

    /// Gives a concurrently-arriving cancellation up to `turns` cooperative
    /// scheduler turns to land before returning `false` - see the empirical
    /// note on `awaitNetwork` above for exactly why this exists: without it,
    /// a fallback side racing a signal that already fired can still run its
    /// side effect before the signal side's cancellation ever reaches it.
    /// Each turn is a bare `Task.yield()`, so a genuine fallback (nothing
    /// ever cancels this call) pays for at most `turns` of them - cheap
    /// scheduler churn, not a wait on any clock, and immaterial next to the
    /// real `fallback` duration this guards. `turns`' default was tuned
    /// empirically (20-plus repeated runs at 256, none flaky) rather than
    /// derived; a larger number is always safe, a rethink is only warranted
    /// if this ever proves flaky in practice.
    private static func yieldToAnyPendingCancellation(turns: Int = 256) async -> Bool {
        for _ in 0 ..< turns {
            if Task.isCancelled {
                return true
            }
            await Task.yield()
        }
        return Task.isCancelled
    }
}
