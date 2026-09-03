import Foundation

/// A signal that the network came back.
///
/// Declared here and implemented outside, the same shape as `HTTPTransport`
/// and for the same reason: this package must compile on Linux and `Network`
/// is Darwin-only. `URLSessionTransport` supplies the `NWPathMonitor`
/// conformance; a future bridge server supplies nothing at all.
///
/// **This is an accelerant, never the mechanism.** `ChannelSession` waits on
/// this *or* a bounded fallback timer, whichever comes first, so a monitor
/// that never fires - a platform without one, an OS that lies about
/// connectivity - makes recovery slower rather than impossible. Correctness
/// lives in the reducer's policy; this only ever removes waiting.
public protocol ReachabilityMonitor: Sendable {
    /// Emits once each time the path becomes satisfied after having been
    /// unsatisfied. Never finishes on its own.
    var networkReturned: AsyncStream<Void> { get }
}
