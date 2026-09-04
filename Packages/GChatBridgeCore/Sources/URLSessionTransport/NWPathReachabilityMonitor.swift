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

/// Fans one reachability transition out to every stream currently
/// subscribed - and only those.
///
/// This is the fix for the whole-slice review's Critical 1 and Important 3,
/// both traced to the same root cause: `networkReturned` used to be a single
/// stream, stored once in `init` and handed back on every access.
/// `AsyncStream.Iterator.next()` finishes the stream it is iterating when its
/// consuming task is cancelled - and `NetworkWait.awaitNetwork`'s losing
/// child is cancelled exactly there on every call where the fallback timer
/// wins. With one shared stream, that finish was permanent: every
/// `awaitNetwork` call after the first fallback win found the stream already
/// finished and fell through to `.fallback` in microseconds, never actually
/// waiting again (Critical 1). And because the same shared stream kept its
/// `.unbounded` buffer between calls, a transition that fired while nothing
/// was waiting stayed queued and was redeemed as an instant `.signal` by
/// whatever `awaitNetwork` call happened to come next, however much later
/// (Important 3).
///
/// A fresh stream per `subscribe()` call fixes both: cancelling one stream's
/// iteration tears down only that stream's own continuation (removed here
/// via `onTermination`), leaving every other subscription untouched, and a
/// transition that fires while the registry is empty reaches nobody and is
/// simply not observed - not buffered for whoever subscribes next.
///
/// `@unchecked Sendable` for the same reason `PathTransitionState` above is:
/// `lock` is the only door to `continuations` and `nextID`, so every access
/// is synchronised regardless of which thread reaches it.
final class ReachabilityBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextID = 0

    /// A brand-new stream, registered the instant this returns - not when its
    /// first `for await` runs. That distinction is load-bearing:
    /// `NetworkWait.awaitNetwork` calls this once, synchronously, before
    /// spawning either racing child task, specifically so a `broadcast()`
    /// from a real path transition (or a test's `onReady`) can never land in
    /// the gap between "this stream exists" and "something is listening to
    /// it" - there is no such gap, because registration happens here,
    /// regardless of when the task that will actually iterate the stream
    /// gets scheduled to run.
    func subscribe() -> AsyncStream<Void> {
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

    /// Yields once to every stream currently subscribed. Zero live
    /// subscribers is a normal outcome, not an error: it means nothing is
    /// inside `.awaitNetwork` right now, and the whole point of the fix is
    /// that such a transition is not kept around for whichever wait comes
    /// next.
    func broadcast() {
        let current = lock.withLock { Array(continuations.values) }
        for continuation in current {
            continuation.yield(())
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
/// **`networkReturned` hands out a fresh stream on every access, not a
/// stored one** - see `ReachabilityMonitor`'s own doc comment for the
/// contract this now states explicitly, and `ReachabilityBroadcaster` above
/// for why a stored stream was a bug. Multiple concurrent accesses each get
/// an independent stream and each is delivered every subsequent transition -
/// `ReachabilityBroadcaster.broadcast()` fans out to all of them - rather
/// than the two competing for one value the way two iterators over one
/// `AsyncStream` would. Sharing one `NWPathReachabilityMonitor` instance
/// across two `ChannelSession`s is still not what this is for: the OS-level
/// `NWPathMonitor` underneath is one subscription to one path, which is the
/// right shape for one session. Construct a separate instance per session.
public final class NWPathReachabilityMonitor: ReachabilityMonitor, Sendable {
    public var networkReturned: AsyncStream<Void> {
        broadcaster.subscribe()
    }

    private let monitor = NWPathMonitor()
    private let broadcaster = ReachabilityBroadcaster()

    public init() {
        let state = PathTransitionState()
        // Captured directly, the same reason `state` above is: closing over
        // `self.broadcaster` through `self` would retain-cycle exactly the
        // way this file's own header warns `pathUpdateHandler` must not -
        // `self.monitor` retains the closure, and the closure would retain
        // `self` right back, so `deinit` would never run to call
        // `monitor.cancel()`. Binding the already-initialised property to a
        // like-named local shadows it for the rest of this initialiser,
        // which is what lets the closure below capture the broadcaster
        // instance itself rather than a path back to `self`.
        let broadcaster = broadcaster
        monitor.pathUpdateHandler = { path in
            if state.recordAndShouldYield(isUp: path.status == .satisfied) {
                broadcaster.broadcast()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.entersprite.gchat.reachability"))
    }

    deinit { monitor.cancel() }
}
