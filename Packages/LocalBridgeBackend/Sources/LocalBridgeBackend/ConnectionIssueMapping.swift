import ChatKit
import GChatBridgeCore

/// The one place a wire failure becomes a domain issue.
///
/// Two enums have to agree here - `TransportFailureReason` in the core and
/// `ConnectionIssue` in `ChatKit` - because `GChatBridgeCore` may not import
/// `ChatKit` (it must stay portable to a future Linux bridge server, and the
/// domain is a client concern). That is the "one rule, two places" shape this
/// project keeps being bitten by (`findings.md` §24, and
/// `docs/superpowers/specs/2026-09-02-testable-app-layer-design.md` §7d's
/// login origin), so both switches below are exhaustive **with no `default`
/// clause**: adding a case to either source enum stops this package
/// compiling until someone decides what it means on screen. Same idiom as
/// `SyncReducer`'s routing switch, whose own doc comment makes the same
/// argument for `ChatEvent`.
///
/// The compiler only catches the drift in one direction. A `ConnectionIssue`
/// case with no producer here compiles fine and simply never fires - that is
/// a gap to watch for by reading, not something an exhaustive switch over the
/// *other* enum can catch.
public enum ConnectionIssueMapping {
    /// Maps a channel failure onto the domain's connection issue.
    public static func issue(for failure: ChannelFailure) -> ConnectionIssue {
        switch failure {
        case let .transport(reason):
            issue(forTransport: reason)
        case let .unexpectedStatus(status):
            issue(forStatus: status)
        case .noSessionIdentifier:
            .unknown("no session identifier")
        case let .malformedChunk(detail):
            .unknown("malformed chunk: \(detail)")
        }
    }

    /// `nil` is what a transport that could not classify its own error hands
    /// over (`ChannelSession`'s generic `catch` arms) - it must still say
    /// something, rather than the mapping silently having no case for it.
    private static func issue(forTransport reason: TransportFailureReason?) -> ConnectionIssue {
        guard let reason else {
            return .unknown("transport")
        }
        switch reason {
        case .notConnectedToInternet:
            return .noInternet
        case .timedOut:
            return .unresponsive
        case .connectionLost:
            return .dropped
        case .nameResolution:
            return .nameResolution
        case .refused:
            return .refused
        case .intercepted:
            return .intercepted
        case let .other(domain, code):
            return .unknown("\(domain) \(code)")
        }
    }

    /// Maps a `connect()` failure onto the domain's connection issue.
    ///
    /// A second entry point rather than a widening of `issue(for:)`, because
    /// the inputs are genuinely different: `channelStopped` has a
    /// `ChannelFailure`, and `connect()` has whatever `Bootstrap.run` threw.
    /// Both funnel into the same two private helpers, so the taxonomy stays in
    /// one place.
    ///
    /// **Not every bootstrap failure is a connectivity problem.** Being asked
    /// to sign in, refused as an unsupported browser, or handed a shell with
    /// no `WIZ_global_data` are all real failures with no `ConnectionIssue` of
    /// their own, and they map to `.unknown` on purpose - the reason is
    /// carried separately in `.disconnected(reason:)`, which is where a
    /// person reads what actually happened.
    public static func issue(forConnect error: any Error) -> ConnectionIssue {
        if let classified = error as? ClassifiedTransportFailure {
            return issue(forTransport: classified.reason)
        }
        guard let failure = error as? BootstrapFailure else {
            return .unknown("connect")
        }
        switch failure {
        case let .unexpectedStatus(status):
            return issue(forStatus: status)
        // Exhaustive with no `default`, the same as every other switch in this
        // file: a new `BootstrapFailure` case stops this compiling until
        // someone decides whether it is a connectivity issue.
        case .signInRedirect:
            return .unknown("sign-in required")
        case .unsupportedClient:
            return .unknown("client refused")
        case .noGlobalData:
            return .unknown("no app shell")
        }
    }

    /// 429 and every 5xx are `ChannelFailure.isRecoverable`'s own two
    /// non-`.transport` recoverable classes (alongside 400, which is not
    /// distinguished here - it has no `ConnectionIssue` of its own and falls
    /// through to `.unknown`, the same as any other status this taxonomy does
    /// not name).
    private static func issue(forStatus status: Int) -> ConnectionIssue {
        switch status {
        case 429: .rateLimited
        case 500 ... 599: .serverError(status: status)
        default: .unknown("status \(status)")
        }
    }
}
