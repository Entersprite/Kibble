import AppKit
import Foundation

/// Whether this app is frontmost, as macOS actually reports it.
///
/// Lives in `MacHost` rather than `AppCore` for the same reason
/// `NWPathReachabilityMonitor` lives in `URLSessionTransport` rather than
/// `GChatBridgeCore`: it is platform-specific, and `AppCore` is the half a
/// future iOS app links. SwiftUI's `scenePhase` was measured first and does
/// not distinguish "open but not frontmost" on macOS 26 - across app launch
/// plus two full frontmost-loss/gain cycles, `didBecomeActiveNotification`
/// and `willResignActiveNotification` fired on every transition while
/// `scenePhase` printed nothing at all - which is why this exists instead of
/// an `.onChange(of: scenePhase)` in the app shell.
///
/// One stream per access, broadcast to every live subscriber. **Not a single
/// stored stream handed back repeatedly** - `findings.md` §25.10 is the whole
/// reason: cancelling a task suspended in `AsyncStream.Iterator.next()`
/// finishes the stream it was iterating, permanently and for every other
/// consumer, and a shared stream turned that into a worse bug than the one
/// being fixed. This type only ever expects one live consumer (the app
/// shell's own `.task`), but a fresh stream per access costs nothing and
/// keeps this file honest with the pattern the reachability monitor already
/// established, rather than being a second idiom for the same problem.
@MainActor
public final class AppActivityMonitor {
    public init() {}

    /// The current value, not a transition - read once at wiring time so a
    /// consumer that launches already-frontmost learns that immediately,
    /// rather than waiting for a notification that will never fire because
    /// nothing changed. Mirrors `NWPathReachabilityMonitor`'s own documented
    /// behaviour that the first path report is state, not a recovery.
    ///
    /// **Untestable without a real, frontmost-capable `NSApplication`** - it
    /// reads live OS state directly and there is no fake for "the OS says
    /// this process is frontmost." That is narrower than it looks: `changes`
    /// below registers against ordinary notification names a test can post
    /// directly, and `AppActivityMonitorTests` does exactly that.
    public var isActive: Bool {
        NSApplication.shared.isActive
    }

    /// Every subsequent transition, one fresh stream per access.
    ///
    /// **This is testable, and tested** (`AppActivityMonitorTests`), unlike
    /// `isActive` above: `didBecomeActiveNotification` and
    /// `willResignActiveNotification` are ordinary notification names, and a
    /// test can `NotificationCenter.default.post(name:object:)` them with no
    /// app activation, no window server and no account. `findings.md` §25.10
    /// is a Critical that shipped specifically because nothing tested a
    /// *second* call against the *same* reachability monitor - the fresh
    /// stream / broadcast / isolated-cancellation mechanism below is the
    /// identical shape, so it gets the identical test coverage rather than
    /// being waved through as "the same kind of untestable" as `isActive`.
    ///
    /// Each stream registers its own pair of `NotificationCenter` observers
    /// and removes them in `onTermination` - never touching `self`, so this
    /// closure needs no actor isolation to be safe: `center` and `tokens` are
    /// both local captures, and `center.removeObserver` is the only thing
    /// `onTermination` does. That is what lets a `@Sendable`, non-isolated
    /// `onTermination` tear down state this `@MainActor` class owns without
    /// needing `MainActor.assumeIsolated` or an unsafe escape hatch - it
    /// never reaches back into `self` at all.
    ///
    /// **`ObserverTokens` exists only because `NSObjectProtocol` itself is
    /// not `Sendable`.** The token `addObserver` returns is opaque and never
    /// mutated - it exists solely to be handed back to `removeObserver` - so
    /// wrapping the pair in an `@unchecked Sendable` box is safe for the same
    /// reason `NWPathReachabilityMonitor`'s `PathTransitionState` is: nothing
    /// here is actually shared mutable state, only a value the compiler
    /// cannot otherwise see is safe to move across the isolation boundary.
    public var changes: AsyncStream<Bool> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let became = center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in continuation.yield(true) }
            let resigned = center.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in continuation.yield(false) }
            let tokens = ObserverTokens(became: became, resigned: resigned)
            continuation.onTermination = { _ in
                center.removeObserver(tokens.became)
                center.removeObserver(tokens.resigned)
            }
        }
    }
}

/// A box for the two opaque `NSObjectProtocol` tokens `addObserver` returns,
/// solely so they can cross into a `@Sendable` `onTermination` closure - see
/// `changes`'s own doc comment for why this is safe despite `NSObjectProtocol`
/// not being `Sendable` itself.
private final class ObserverTokens: @unchecked Sendable {
    let became: NSObjectProtocol
    let resigned: NSObjectProtocol

    init(became: NSObjectProtocol, resigned: NSObjectProtocol) {
        self.became = became
        self.resigned = resigned
    }
}
