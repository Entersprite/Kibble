import ChatKit

/// What to tell a person about the connection, and whether to offer them a
/// way to hurry it along.
///
/// A pure `enum` namespace over `ConnectionState`, not a view - that is the
/// whole reason the wording does not live inline in `ChatWindow`'s
/// `StatusStrip`: `ConnectionBannerTests` exercises every sentence without a
/// window in sight.
///
/// The wording is deliberately vague where the truth is: "Google isn't
/// responding," never "Google is down" - a timeout is byte-identical for
/// "their fault" and "your network is blocking them." `.intercepted` names
/// what is observable, not a captive portal or a VPN specifically, because
/// nothing distinguishes them. `findings.md` §24's `[Verify]` discipline is
/// the precedent: a confidently wrong diagnosis on screen is worse than an
/// honest vague one.
public enum ConnectionBanner {
    /// Attempts below this may still just be slow. `RetryPolicy`'s backoff is
    /// 0.5, 1, 2, 4, 8 seconds for attempts 1-5 (capped at 32s per step) -
    /// that sums to about 15.5s elapsed by the time attempt 6 begins, which
    /// is **sooner** than spec §8.1's "roughly a minute," not the "first
    /// attempt past a minute" an earlier draft of this comment claimed (the
    /// 60-second mark is not actually crossed until partway through attempt
    /// 7). Deliberately kept at 6 rather than moved to 7 anyway (ruling
    /// R19): the threshold's real job is only to avoid flashing the control
    /// during an ordinary blip, and a healthy poll reopens within seconds, so
    /// ~15s of failure already clears that bar. Offering the accelerant
    /// sooner than the spec's rough number costs nothing and is kinder,
    /// because it is never framed as giving up - see `offersReconnect`'s own
    /// doc comment. `DesignSystem` depends on `ChatKit` alone and cannot
    /// import `RetryPolicy` (it lives in `GChatBridgeCore`) to derive this
    /// number, so it is a named constant with the arithmetic spelled out here
    /// instead, for whoever changes the backoff shape to reconcile against.
    private static let attemptsPastAMinute = 6

    /// What to show for `state`. `nil` means there is nothing to say - either
    /// the connection is healthy, or (for `.idle`) it has not been asked to
    /// try.
    public static func text(for state: ConnectionState) -> String? {
        switch state {
        case .connected:
            nil
        case .idle:
            "Not connected."
        case .connecting:
            "Connecting…"
        case let .reconnecting(attempt, issue, _):
            text(forReconnectAttempt: attempt, issue: issue)
        case let .disconnected(reason, _):
            reason.map { "Disconnected: \($0)" } ?? "Disconnected."
        case .unknown:
            // Degrades toward optimism rather than alarming someone about a
            // state this build does not understand (design §3.4).
            "Connecting…"
        }
    }

    /// A diagnostic second line for `state`, or `nil` when there is none.
    ///
    /// Rendered as secondary text, never in the headline `text(for:)`
    /// produces (spec §8) - and diagnostic only. It carries an error domain
    /// and code, or a status number, never a URL or message content; callers
    /// must keep it that way, because this function only relays what
    /// `ConnectionState` already decided to carry.
    public static func detail(for state: ConnectionState) -> String? {
        switch state {
        case .connected, .idle, .connecting, .disconnected:
            nil
        case let .reconnecting(_, _, detail):
            detail
        case let .unknown(raw):
            // Captured and decoded but never shown until now - this is where
            // it goes. See `ConnectionState.unknown`'s own doc comment.
            raw
        }
    }

    /// Whether to offer a manual "reconnect now" control for `state`.
    ///
    /// Never because we gave up - nothing gives up any more. This is only
    /// ever an accelerant, the same role the reachability monitor plays for
    /// `.noInternet`, because the person looking at the screen may know
    /// something the app cannot: they just left the café wifi.
    public static func offersReconnect(for state: ConnectionState) -> Bool {
        guard case let .reconnecting(attempt, issue, _) = state else { return false }
        // Immediately for interception: that class genuinely needs a human -
        // leave the portal, kill the proxy - and waiting a minute to offer
        // help is unkind when a retry provably will not fix it.
        if issue == .intercepted {
            return true
        }
        return attempt >= attemptsPastAMinute
    }

    private static func text(forReconnectAttempt attempt: Int, issue: ConnectionIssue?) -> String {
        guard let issue else {
            // What a peer predating the `issue` field sends, and what the
            // fixture backend still emits.
            return "Reconnecting, attempt \(attempt)…"
        }
        switch issue {
        case .noInternet:
            return "No internet connection."
        case .nameResolution:
            return "Can't look up Google's address."
        case .refused:
            return "Google's servers refused the connection."
        case .intercepted:
            return "Something is intercepting the connection — a captive portal, proxy or VPN."
        case .unresponsive:
            return "Google isn't responding."
        case .dropped:
            return "Reconnecting…"
        case .rateLimited:
            return "Google is asking us to slow down."
        case .serverError:
            // Not "Server error \(status)": the status is diagnostic, not
            // headline material - see `ConnectionIssue`'s own doc comment.
            return "Google Chat is having problems."
        case .unknown:
            // An unknown issue still reports a problem - we know something is
            // wrong, just not what.
            return "Reconnecting…"
        }
    }
}
