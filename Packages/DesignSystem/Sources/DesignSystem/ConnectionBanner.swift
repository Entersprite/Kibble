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
    /// Attempts below this may still just be slow; at or above it, roughly a
    /// minute has passed. `RetryPolicy`'s backoff is 0.5, 1, 2, 4, 8 seconds
    /// for attempts 1-5 (capped at 32s per step) - that sums to about 15.5s,
    /// so attempt 6 is the first attempt that starts past a minute of trying.
    /// `DesignSystem` depends on `ChatKit` alone and cannot import
    /// `RetryPolicy` (it lives in `GChatBridgeCore`) to derive this number, so
    /// it is a named constant with the arithmetic spelled out here instead,
    /// for whoever changes the backoff shape to reconcile against.
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
