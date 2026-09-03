import Foundation
import GChatBridgeCore
import Network

/// Whether `isUp` is a recovery, given the network's previous state.
///
/// This is the one behaviour in this file with a bug in it if anything is -
/// see `NWPathReachabilityMonitor`'s doc comment on why the *first* path
/// report must never be treated as a recovery. Pulled out as a pure function
/// so it is tested directly, rather than only through a race against a real
/// `NWPathMonitor` - this repo's "a boundary that cannot be unit-tested
/// should be one file wide" rule, applied to the one part of this file that
/// *can* be unit-tested without a real network stack.
func shouldYield(isUp: Bool, wasUp: Bool) -> Bool {
    isUp && !wasUp
}

/// Guards the one piece of mutable state behind `NWPathReachabilityMonitor`:
/// whether the path was last known to be up.
///
/// A standalone object, captured by `pathUpdateHandler` directly rather than
/// through `self` - capturing `self` there would retain-cycle
/// (`self.monitor` retains the closure, and the closure would retain `self`
/// right back), and `deinit` would then never run to call `monitor.cancel()`.
///
/// `NWPathMonitor.pathUpdateHandler` is declared `@Sendable`, so it cannot
/// capture a mutable local variable by reference - only a reference type
/// whose mutation it synchronises itself. `NSLock` is this repo's existing
/// idiom for that job: `StubURLProtocol.Registry`
/// (`GChatBridgeCoreTestSupport`) guards its own mutable dictionaries the
/// same way, with the same `nonisolated`-by-convention justification. That is
/// used here instead of introducing `OSAllocatedUnfairLock` as a second lock
/// idiom - see the file-level note below for what was checked before making
/// that call. `@unchecked Sendable` is justified by the lock being the only
/// door to `wasUp`: every read and write happens inside `withLock`, so no
/// caller ever observes a half-updated value regardless of which thread
/// `NWPathMonitor` calls the handler on.
private final class PathTransitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var wasUp = true

    /// Records `isUp` as the new state and reports whether that update is a
    /// recovery worth yielding for.
    func recordAndShouldYield(isUp: Bool) -> Bool {
        lock.withLock {
            defer { wasUp = isUp }
            return shouldYield(isUp: isUp, wasUp: wasUp)
        }
    }
}

/// `ReachabilityMonitor` over Apple's `NWPathMonitor`.
///
/// Lives here rather than in the core because `Network` is Darwin-only and
/// the core must compile on Linux - the same division `URLSessionTransport`
/// itself exists for. A future bridge server injects no monitor at all and
/// rides `ChannelSession`'s bounded fallback timer instead, which is why this
/// file has no Linux counterpart and needs none.
///
/// **Emits on the transition, not on the state.** `pathUpdateHandler` fires
/// for changes that are not recoveries - a new interface appearing, a shift
/// from Wi-Fi to Ethernet - and yielding on all of them would retry for no
/// reason; only unsatisfied → satisfied is news, which is exactly what
/// `shouldYield(isUp:wasUp:)` decides. `NWPathMonitor` also reports the
/// current path immediately on `start(queue:)`, and that first report is the
/// state, not a transition: `PathTransitionState` seeds `wasUp` as `true` so
/// that report is never mistaken for a recovery. The cost is symmetrical -
/// a launch while genuinely offline needs one real unsatisfied → satisfied
/// edge before its first yield, exactly like every later recovery - so no
/// real recovery is ever missed.
///
/// **`networkReturned` is a single stored stream, not a fresh one per
/// access.** It is a `let`, created once in `init`, so every read of the
/// property returns the same `AsyncStream`. `AsyncStream` delivers each
/// yielded value to exactly one attached iterator - chosen arbitrarily when
/// more than one is attached, not broadcast to all of them - so one instance
/// of this type must back at most one live consumer at a time. Sharing a
/// single instance across two `ChannelSession`s means each network-return
/// signal reaches only one of them, unpredictably, and the other silently
/// falls back to its own timer with no signal ever arriving. Construct a
/// separate `NWPathReachabilityMonitor` per consumer instead of sharing one.
public final class NWPathReachabilityMonitor: ReachabilityMonitor, Sendable {
    public let networkReturned: AsyncStream<Void>
    private let monitor = NWPathMonitor()

    public init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        networkReturned = stream

        let state = PathTransitionState()
        monitor.pathUpdateHandler = { path in
            if state.recordAndShouldYield(isUp: path.status == .satisfied) {
                continuation.yield(())
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.entersprite.gchat.reachability"))
    }

    deinit { monitor.cancel() }
}
