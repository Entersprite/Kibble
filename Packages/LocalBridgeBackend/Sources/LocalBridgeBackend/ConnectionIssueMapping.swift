import ChatKit
import GChatBridgeCore

/// The one place a wire failure becomes a domain issue.
///
/// Two enums have to agree here - `TransportFailureReason` in the core and
/// `ConnectionIssue` in `ChatKit` - because `GChatBridgeCore` may not import
/// `ChatKit` (it must stay portable to a future Linux bridge server, and the
/// domain is a client concern). That is the "one rule, two places" shape this
/// project keeps being bitten by (`findings.md` §24, and session 17 §7d's
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
