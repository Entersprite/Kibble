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
///
/// ## The contract `networkReturned` must satisfy - stated explicitly because
/// its absence is exactly how this project shipped a monitor that broke it
///
/// `NWPathReachabilityMonitor` used to declare `networkReturned` as a single
/// stream, stored once and handed back on every access - a shape this
/// protocol never actually required, because nothing here said otherwise.
/// `NetworkWait.awaitNetwork` raced that stream against a bounded fallback
/// timer and cancelled whichever side lost; cancelling a task suspended in
/// `AsyncStream.Iterator.next()` finishes the stream it was iterating, and
/// with one stream shared across every call, that finish was permanent -
/// every `.awaitNetwork` wait after the first fallback win returned
/// `.fallback` in microseconds, never actually waiting again. The identical
/// sharing also let a transition that fired while nothing was waiting sit
/// buffered and be handed to whichever wait came next, however much later,
/// as a false instant `.signal`. Both defects trace to the same one-stream
/// shape, is why both are fixed the same way:
///
/// - **Every access returns a fresh, independent stream.** `networkReturned`
///   is a computed property, not a stored one - each read is a new
///   subscription, seeing only transitions that occur after that read.
/// - **Concurrent accesses are multicast, not competed for.** Two live
///   streams both created before a transition both receive it; neither
///   consumes the value at the other's expense the way two iterators over
///   one `AsyncStream` would.
/// - **Cancelling one stream's consumer affects only that stream.** A
///   conforming type must let a cancelled or otherwise-abandoned consumer
///   tear down its own subscription without finishing any other stream this
///   property has ever handed out, past or future.
/// - **A transition with nobody currently subscribed reaches nobody.** It is
///   not queued for the next access to redeem; a fresh stream created after
///   the fact starts empty.
/// - Still emits once each time the path becomes satisfied after having been
///   unsatisfied, and never finishes on its own.
///
/// `NWPathReachabilityMonitor` implements this via a set of live
/// continuations, yielding each transition to all of them; see its own doc
/// comment for the mechanism.
public protocol ReachabilityMonitor: Sendable {
    var networkReturned: AsyncStream<Void> { get }
}
