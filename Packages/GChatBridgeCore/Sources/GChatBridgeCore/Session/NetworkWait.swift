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
    /// **Race structure, and why the loser's side effects don't matter.**
    /// Both exits run as sibling child tasks of one `withTaskGroup`: the
    /// signal side suspends inside `for await` on the monitor's stream, the
    /// fallback side suspends inside `sleep`. `group.next()` is awaited
    /// exactly once, so whichever child finishes first supplies the single
    /// returned outcome; the loser is cancelled by `group.cancelAll()`
    /// afterwards and its own return value is never read. In production
    /// `sleep` is a real, cancellable `Task.sleep` (see the `.awaitNetwork`
    /// effect arm in `ChannelSession.handle(_:)`), so a fallback side that
    /// has merely started sleeping when the signal wins just gets cancelled
    /// mid-sleep - harmless, because nothing downstream ever looks at what
    /// it would have returned. A test's injected `sleep` may likewise be
    /// entered before it loses the race; entering it is not itself a
    /// failure - see `AwaitNetworkTests.aNetworkSignalEndsTheWaitImmediately`'s
    /// own comment for why that test asserts correctly on the outcome alone.
    ///
    /// `monitor.networkReturned` is read exactly once per call, here, before
    /// either child task is spawned - not from inside the signal-consuming
    /// child. Two things depend on that ordering:
    ///
    /// 1. **Isolation.** `ReachabilityMonitor.networkReturned` now hands out
    ///    a fresh, independent stream on every access (see that protocol's
    ///    own doc comment for the contract, and `NWPathReachabilityMonitor`
    ///    for why a stored, shared stream was a bug this project shipped).
    ///    Reading it here, once, means this call's stream is entirely its
    ///    own: when the race ends and the losing child is cancelled,
    ///    finishing *this* stream can never finish a stream some other call
    ///    - past, concurrent, or future - is depending on.
    /// 2. **No lost signal.** A conforming monitor registers this call's
    ///    subscription the instant `networkReturned` is read - synchronously,
    ///    on the calling task - not whenever the child task that will
    ///    iterate it happens to get scheduled. Reading it before `onReady()`
    ///    runs is what guarantees a signal fired inside `onReady` (a test
    ///    hook) or by a real path transition can never land in a gap where
    ///    nothing is subscribed yet; see `onReady`'s own doc below for what
    ///    used to fill that role and why it no longer needs to.
    ///
    /// - Parameters:
    ///   - monitor: `nil` on a platform (or in a test) with no reachability
    ///     signal at all; `.awaitNetwork` then relies entirely on `fallback`.
    ///   - fallback: The bounded ceiling on this wait, regardless of `monitor`.
    ///   - sleep: Injectable so a test never waits on a real clock, the same
    ///     reason `RetryPolicy.sleep` is.
    ///   - onReady: A test hook so a fake monitor's signal can be fired from
    ///     inside this call, once the race has been assembled. `addTask`
    ///     only *schedules* the signal-consuming child - it does not wait
    ///     for that child to start running before returning control - so
    ///     this is not "after the child is listening" in any ordering sense.
    ///     What keeps a signal fired here from being lost is that this call
    ///     already subscribed to the monitor before `onReady` ever runs (see
    ///     this function's own doc comment above) together with
    ///     `AsyncStream`'s default `.unbounded` buffering on that specific
    ///     subscription, which retains a yielded value whether or not the
    ///     consuming child has started running yet. Production passes an
    ///     empty closure; only tests pass one with an effect.
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
        // Subscribed here, synchronously, before either child task exists -
        // see this function's own doc comment above for why that ordering,
        // not just buffering, is what keeps a signal from being lost.
        let signal = monitor.networkReturned
        return await withTaskGroup(of: NetworkWaitOutcome.self) { group in
            group.addTask {
                for await _ in signal {
                    return .signal
                }
                // The stream finished without ever yielding. Not documented
                // behaviour for `ReachabilityMonitor` - "never finishes on
                // its own" - but falling through to `.fallback` rather than
                // looping keeps this side effect-free either way.
                return .fallback
            }
            // `addTask` only schedules the child above; it does not wait
            // for it to start running before returning control here. See
            // the `onReady` parameter doc above for what actually keeps a
            // signal fired at this point from being lost.
            onReady()

            group.addTask {
                await sleep(fallback)
                return .fallback
            }

            let outcome = await group.next() ?? .fallback
            group.cancelAll()
            return outcome
        }
    }
}
