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
    /// particular reconnect attempt - `ChannelSession` pairs it with the
    /// effect that produces this event at the moment the effect is enqueued
    /// (`QueuedEffect`), not by reading a stored "last failure" back later
    /// when the effect is handled; fix round 1's Finding 1 is the reason that
    /// distinction matters (two failures can be applied back-to-back before
    /// either one's effect is dequeued, and reading a shared property at
    /// dequeue time can pair the wrong one with the wrong attempt).
    /// `failure` is distinct from `ChannelSession.failure` (the property),
    /// which is only ever set by a *terminal* `.report` and stays `nil`
    /// throughout a recoverable run. `LocalBridgeBackend`'s
    /// `ConnectionIssueMapping` is the one place this becomes a
    /// `ChatKit.ConnectionIssue`, behind an exhaustive switch - this package
    /// may not import `ChatKit` to do that translation itself.
    case reconnecting(attempt: Int, failure: ChannelFailure?)

    /// A stream opened again after a reconnect. Sent only after a recovery,
    /// never on the first connection - a host that showed "resumed" on a cold
    /// start would be reporting a recovery that never happened.
    case resumed
}
