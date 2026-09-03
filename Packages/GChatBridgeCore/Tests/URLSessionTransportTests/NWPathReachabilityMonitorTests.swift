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
/// checks that constructing and tearing one down does not crash - it makes
/// no assertion about the stream ever yielding, so it cannot hang.
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

    @Test("the seeded first report - up, having started up - never yields")
    func seededFirstReportDoesNotYield() {
        // This is `staysUpDoesNotYield`'s case again, spelled out because
        // it is the one `NWPathReachabilityMonitor`'s doc comment calls out
        // by name: `PathTransitionState` seeds `wasUp` as `true`, so
        // `NWPathMonitor`'s immediate first report - up or down - is read as
        // "no transition happened yet" rather than a recovery.
        #expect(shouldYield(isUp: true, wasUp: true) == false)
    }

    @Test("constructing and tearing down does not crash")
    func constructingAndTearingDownDoesNotCrash() {
        var monitor: NWPathReachabilityMonitor? = NWPathReachabilityMonitor()
        _ = monitor?.networkReturned
        monitor = nil
    }
}
