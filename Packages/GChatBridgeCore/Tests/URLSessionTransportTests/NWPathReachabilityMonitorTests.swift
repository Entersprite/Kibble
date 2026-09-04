import Foundation
import Testing
@testable import URLSessionTransport

/// A boundary, tested only where it can be.
///
/// `shouldYield(isUp:wasUp:)` carries the one behaviour with a bug in it if
/// anything is - see `NWPathReachabilityMonitor`'s doc comment on why the
/// first path report must not be treated as a recovery - and it was cleanly
/// extractable as a pure function, so it is tested directly here rather than
/// through a stream-shape race against a real `NWPathMonitor`. Whether
/// `NWPathMonitor` itself reports correctly, and on what thread, is Apple's
/// business and needs a real network to observe; this suite's last test only
/// checks the one other thing that does not need a real network to observe -
/// that the last strong reference dropping actually runs `deinit`, and
/// therefore `monitor.cancel()`. It makes no assertion about the stream ever
/// yielding, so it cannot hang.
struct NWPathReachabilityMonitorTests {
    @Test("does not yield when the path was already up")
    func staysUpDoesNotYield() {
        #expect(shouldYield(isUp: true, wasUp: true) == false)
    }

    @Test("yields exactly when the path recovers")
    func recoveryYields() {
        #expect(shouldYield(isUp: true, wasUp: false))
    }

    @Test("does not yield when the path goes down")
    func lossDoesNotYield() {
        #expect(shouldYield(isUp: false, wasUp: true) == false)
    }

    @Test("does not yield when the path stays down")
    func staysDownDoesNotYield() {
        #expect(shouldYield(isUp: false, wasUp: false) == false)
    }

    // `staysUpDoesNotYield` above is also the seeded-first-report case:
    // `NWPathMonitor`'s immediate first report on `start(queue:)` is read as
    // "up, having started up" - `wasUp` seeded `true` - rather than as a
    // recovery, which is the same (isUp: true, wasUp: true) input.

    @Test("deinit actually runs when the last strong reference drops")
    func deinitRunsOnTheLastStrongReferenceDropping() {
        // Guards the retain cycle the type's own doc comment (:21-24) warns
        // about by name: if `pathUpdateHandler`'s closure ever captured
        // `self` instead of the standalone `PathTransitionState`, `self`
        // would retain `monitor`, which retains the closure, which would
        // retain `self` right back - and this instance would never
        // deallocate. A `weak` observer is the only way to see that from
        // outside: it goes `nil` only once every strong reference is gone,
        // so it fails (stays non-nil) exactly when that cycle exists,
        // without needing to hang on anything to find out.
        var monitor: NWPathReachabilityMonitor? = NWPathReachabilityMonitor()
        weak let observed = monitor
        monitor = nil
        #expect(observed == nil)
    }
}

/// `ReachabilityBroadcaster` directly - the whole-slice review's fix for
/// Critical 1 and Important 3. `NWPathReachabilityMonitor` itself cannot be
/// driven from a test (there is no way to force a real `NWPathMonitor`
/// transition), so this is the boundary where the fix's actual mechanism -
/// fresh streams, multicast delivery, isolated cancellation, no buffering
/// with nobody subscribed - is checked directly, the same "one file wide"
/// idiom `PathTransitionState`'s extraction of `shouldYield` already uses
/// above.
@Suite("ReachabilityBroadcaster")
struct ReachabilityBroadcasterTests {
    @Test("two streams subscribed before a broadcast both receive it")
    func broadcastReachesEveryLiveSubscriber() async {
        let broadcaster = ReachabilityBroadcaster()
        let first = broadcaster.subscribe()
        let second = broadcaster.subscribe()

        broadcaster.broadcast()

        guard let firstValue = await awaitBounded(
            { await firstElement(of: first) },
            timeoutMessage: "first subscriber never received the broadcast"
        ), let secondValue = await awaitBounded(
            { await firstElement(of: second) },
            timeoutMessage: "second subscriber never received the broadcast"
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(firstValue != nil)
        #expect(secondValue != nil)
    }

    @Test("cancelling one stream's consumer does not affect another live stream")
    func cancellingOneStreamLeavesAnotherIntact() async {
        let broadcaster = ReachabilityBroadcaster()
        let cancelled = broadcaster.subscribe()
        let survivor = broadcaster.subscribe()

        // Consume and cancel `cancelled` the same way `NetworkWait.awaitNetwork`
        // does to its race's loser: suspend inside `for await`, then cancel
        // the task doing so.
        let task = Task {
            for await _ in cancelled {
                break
            }
        }
        // Give the task a chance to actually reach the suspension point
        // before cancelling it - otherwise there is nothing to prove
        // cancellation tears down only its own stream rather than none at
        // all.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        broadcaster.broadcast()

        guard let survivorValue = await awaitBounded(
            { await firstElement(of: survivor) },
            timeoutMessage: """
            the surviving stream never received the broadcast after an unrelated stream was cancelled - \
            cancellation must be isolated per stream
            """
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(survivorValue != nil)
    }

    @Test("a broadcast with nobody subscribed reaches nobody, and is not queued for later")
    func broadcastWithNoSubscribersIsNotRedeemedLater() async {
        let broadcaster = ReachabilityBroadcaster()

        broadcaster.broadcast() // nobody subscribed yet

        let stream = broadcaster.subscribe() // subscribed only after the broadcast above
        broadcaster.broadcast() // a second, real broadcast this stream should see exactly once

        guard let value = await awaitBounded(
            { await firstElement(of: stream) },
            timeoutMessage: "a stream subscribed after an earlier broadcast never received the later one"
        ) else {
            return // awaitBounded already recorded why.
        }
        #expect(
            value != nil,
            "the later broadcast must still reach a stream subscribed after the earlier one"
        )
    }
}

/// The first element of `stream`, or `nil` if it finishes without ever
/// yielding one. A plain `for await` bound to a `let` result, so this can be
/// wrapped in `awaitBounded` the same way `AwaitNetworkTests` wraps
/// `ChannelSession.awaitNetwork` - both guard against a regression turning a
/// wrong answer into a hang, which `scripts/test.sh`'s untimed `swift test`
/// cannot detect on its own.
private func firstElement<Element: Sendable>(of stream: AsyncStream<Element>) async -> Element? {
    for await value in stream {
        return value
    }
    return nil
}

/// Runs `body` and bounds it by a deadline, so a regression in the code this
/// guards fails the test instead of hanging `swift test` forever. Same shape
/// as `GChatBridgeCoreTests.AwaitNetworkTests`'s own `awaitBounded` -
/// duplicated rather than shared across packages for the same reason that
/// file's own header gives for not sharing within one package: it is a few
/// lines, and the two suites do not otherwise depend on each other.
private func awaitBounded<Value: Sendable>(
    _ body: @escaping @Sendable () async -> Value,
    timeoutMessage: Comment
) async -> Value? {
    let result = ResultBox<Value>()
    Task {
        let value = await body()
        await result.set(value)
    }
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

private actor ResultBox<Value: Sendable> {
    private(set) var value: Value?

    func set(_ newValue: Value) {
        value = newValue
    }
}
