import Foundation

/// What the channel tells its host about its own recovery.
///
/// Separate from the event stream because these are not events on the wire -
/// nothing in Google's protocol says "I am reconnecting". They are facts about
/// this client's own state, and putting them in `AsyncStream<ChannelArray>`
/// would mean inventing array shapes the server never sends, which is the one
/// thing `ChannelEventMapping` must be able to trust it never sees.
///
/// A callback rather than a second stream, matching `onRotation`: there is one
/// consumer, it is set at construction, and a stream would need its own
/// lifetime management for two cases.
public enum ChannelLifecycle: Sendable, Hashable {
    /// The socket died and a fresh registration is coming. `attempt` counts
    /// from 1. `failure` is the `ChannelFailure` that triggered this
    /// reconnect - `ChannelSession` retains the most recent one it applied
    /// specifically to populate this, since `failure` (the property) is only
    /// ever set by a *terminal* `.report` and is `nil` throughout a
    /// recoverable run. `LocalBridgeBackend`'s `ConnectionIssueMapping` is
    /// the one place this becomes a `ChatKit.ConnectionIssue`, behind an
    /// exhaustive switch - this package may not import `ChatKit` to do that
    /// translation itself.
    case reconnecting(attempt: Int, failure: ChannelFailure?)

    /// A stream opened again after a reconnect. Sent only after a recovery,
    /// never on the first connection - a host that showed "resumed" on a cold
    /// start would be reporting a recovery that never happened.
    case resumed
}
