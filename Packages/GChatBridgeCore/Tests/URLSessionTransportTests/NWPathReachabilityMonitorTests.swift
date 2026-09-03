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
