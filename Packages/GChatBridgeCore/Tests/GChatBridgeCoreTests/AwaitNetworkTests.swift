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

    @Test func aNetworkSignalEndsTheWaitImmediately() async {
        let monitor = FakeReachability()
        let waited = await ChannelSession.awaitNetwork(
            monitor: monitor,
            fallback: .seconds(60),
            sleep: { _ in
                Issue.record("the fallback timer should not have been reached")
            },
            onReady: { monitor.fire() }
        )
        #expect(waited == .signal)
    }

    @Test func aSilentMonitorStillEndsTheWaitViaTheFallback() async {
        let waited = await ChannelSession.awaitNetwork(
            monitor: SilentReachability(),
            fallback: .seconds(60),
            sleep: { _ in }, // returns instantly, standing in for 60s
            onReady: {}
        )
        #expect(waited == .fallback)
    }

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
