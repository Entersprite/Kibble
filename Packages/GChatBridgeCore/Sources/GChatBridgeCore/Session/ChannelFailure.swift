import Foundation

/// Why a channel stopped, or asked to reconnect.
///
/// Two of these four are unconditionally terminal. The inputs that would tell
/// a *recovery* apart from a stop for them — a cookie expiring mid-stream, a
/// truncated payload — are recorded as uncollected in `findings.md` §6, and the
/// experiment that collects them is one someone has to run against a real
/// account over days. Writing a reconnect policy against the reference's
/// guesses and rewriting it when the evidence lands is more work than waiting,
/// so `.noSessionIdentifier` and `.malformedChunk` stop and say why.
///
/// `.transport` recovers unconditionally: a socket that died says nothing
/// about whether the credential is still good, so re-registering is right
/// whatever §6 eventually finds.
///
/// `.unexpectedStatus` recovers for the literal value 400, and — since the
/// reconnect taxonomy design (§4.4) — for 429 and every 5xx too. 400 is not
/// "any 4xx" or "any non-200":
/// `reference/googlechat-master/maugclib/channel.py:408-411` raises
/// `SIDInvalidError` when a long poll answers 400 with `Unknown SID`.
/// `exceptions.py:27-34` makes `SIDInvalidError` and `SIDExpiringError`
/// *siblings* under `SIDError`, not parent and child, so `listen`'s
/// `except SIDExpiringError` clause (`channel.py:233-239`, which re-registers
/// in place) does not catch it — the 400 propagates out of `listen` and the
/// reference rebuilds the channel from a fresh `_register()`, which is
/// exactly what this side's `.retry` transition already does. A 2026-
/// 09-02 lid-close (app open, screen locked, lid closed two minutes, lid
/// opened) produced exactly this: HTTP 400, no other status observed before
/// or since. `[Verify]`: the response body was not read, so "Unknown SID" is
/// the probable cause by mechanism, not a confirmed one. A 401 or 403
/// plausibly means the credential itself is dead, and retrying those is the
/// hammering this classification exists to prevent — see `isRecoverable` and
/// `ChannelState.failed(_:)`.
public enum ChannelFailure: Error, Hashable, Sendable, CustomStringConvertible {
    case unexpectedStatus(Int)
    case noSessionIdentifier
    case malformedChunk(String)
    /// A classification, not a raw description - this request carries the
    /// long-poll's live SID, so `String(describing:)` on an unclassified
    /// `URLError` was a leak. `nil` means `ChannelSession` caught something
    /// that did not classify as a `ClassifiedTransportFailure`.
    case transport(TransportFailureReason?)

    public var description: String {
        switch self {
        case let .unexpectedStatus(status):
            "the channel answered with HTTP \(status)"
        case .noSessionIdentifier:
            "the handshake carried no SID"
        case let .malformedChunk(detail):
            "a chunk could not be read: \(detail)"
        case let .transport(reason):
            "the connection failed: \(reason?.safeDescription ?? "transport error")"
        }
    }

    /// Whether `ChannelState.failed(_:)` should ask to reconnect rather than
    /// stopping outright.
    ///
    /// No longer bounded by `RetryPolicy.default.maxAttempts` inside the
    /// reducer - that bound is the bug the repo owner reported from a live
    /// run (an outage longer than about eight seconds never recovered), and
    /// removing it is this task. See `ChannelState.attempt` for how the
    /// anti-hammering intent survives without a bound on the attempt count.
    ///
    /// `.transport` and `.unexpectedStatus(400)` recover for the reasons the
    /// type's own doc comment gives. **429 and every 5xx recover too, and
    /// that is a decision made on HTTP semantics, not on traffic observed
    /// from Chat** — neither status has actually been seen on this protocol.
    /// The owner took this with the evidence gap in view (design §4.4): 429
    /// means "retry later" by definition, and 5xx is a server-side error
    /// whose standard remedy is a retry. **401 and 403 stay terminal** — a
    /// credential HTTP itself says is rejected or forbidden is not something
    /// a retry can fix, and retrying it is exactly the hammering this
    /// classification exists to prevent.
    var isRecoverable: Bool {
        switch self {
        case .transport, .unexpectedStatus(400), .unexpectedStatus(429):
            true
        case let .unexpectedStatus(status) where (500 ... 599).contains(status):
            true
        default:
            false
        }
    }
}
