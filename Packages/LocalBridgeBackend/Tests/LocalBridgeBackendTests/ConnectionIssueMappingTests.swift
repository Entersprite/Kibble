import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The one place a wire failure becomes a domain issue.
///
/// Two enums have to agree here - `TransportFailureReason` in the core and
/// `ConnectionIssue` in `ChatKit` - because the core may not import the
/// domain. That is the "one rule, two places" shape this project keeps being
/// bitten by (`findings.md` §24, and
/// `docs/superpowers/specs/2026-09-02-testable-app-layer-design.md` §7d's
/// login origin), so the mapping is an exhaustive `switch` with no `default`:
/// adding a `TransportFailureReason` case stops this package compiling until
/// someone decides what it means on screen. Same idiom as `SyncReducer`'s
/// routing switch, and its doc comment says why.
struct ConnectionIssueMappingTests {
    @Test func everyTransportReasonMaps() {
        let expected: [(TransportFailureReason, ConnectionIssue)] = [
            (.notConnectedToInternet, .noInternet),
            (.timedOut, .unresponsive),
            (.connectionLost, .dropped),
            (.nameResolution, .nameResolution),
            (.refused, .refused),
            (.intercepted, .intercepted)
        ]
        for (reason, issue) in expected {
            #expect(ConnectionIssueMapping.issue(for: .transport(reason)) == issue)
        }
    }

    @Test func anUnclassifiedTransportErrorStillReachesTheScreen() {
        let issue = ConnectionIssueMapping.issue(
            for: .transport(.other(domain: "NSURLErrorDomain", code: -1))
        )
        #expect(issue == .unknown("NSURLErrorDomain -1"))
    }

    @Test func statusesMapToTheirOwnCategories() {
        #expect(ConnectionIssueMapping.issue(for: .unexpectedStatus(429)) == .rateLimited)
        #expect(
            ConnectionIssueMapping.issue(for: .unexpectedStatus(503))
                == .serverError(status: 503)
        )
    }

    /// Fix round 1, Finding 2: 400 is the status `ChannelFailure`'s own doc
    /// comment cites as the live-observed motivating case (the 2026-09-02
    /// lid-close), and the one status besides 429/5xx actually reachable
    /// through the recoverable path - it was unasserted here even though the
    /// mapping treats it the same as any other status this taxonomy does not
    /// name (an `.unknown`, not `.rateLimited` or `.serverError`).
    @Test func status400IsNotRateLimitedOrServerError() {
        #expect(ConnectionIssueMapping.issue(for: .unexpectedStatus(400)) == .unknown("status 400"))
    }

    /// A nil reason is what a transport that could not classify itself hands
    /// over. It must still say something.
    @Test func aTransportFailureWithNoReasonIsStillAnIssue() {
        #expect(ConnectionIssueMapping.issue(for: .transport(nil)) == .unknown("transport"))
    }

    /// Fix round 1, Finding 2: neither of the mapping's two non-`.transport`,
    /// non-status arms was asserted at all - a swapped or mistyped case body
    /// in either would have compiled and passed everything.
    @Test func aMissingSessionIdentifierIsAnUnknownIssueWithItsOwnTag() {
        #expect(ConnectionIssueMapping.issue(for: .noSessionIdentifier) == .unknown("no session identifier"))
    }

    @Test func aMalformedChunkIsAnUnknownIssueCarryingItsDetail() {
        #expect(
            ConnectionIssueMapping.issue(for: .malformedChunk("bad length prefix"))
                == .unknown("malformed chunk: bad length prefix")
        )
    }

    /// `connect()`'s own failure path used to emit `issue: nil` where
    /// `channelStopped` mapped a real one - session 18's "Next" item 2. The
    /// error at that call site is whatever `Bootstrap.run` threw, which is a
    /// `ClassifiedTransportFailure`, a `BootstrapFailure`, or something else
    /// entirely.
    @Test func aClassifiedTransportFailureMapsLikeAnyOther() {
        #expect(
            ConnectionIssueMapping.issue(
                forConnect: ClassifiedTransportFailure(.notConnectedToInternet)
            ) == .noInternet
        )
        #expect(
            ConnectionIssueMapping.issue(
                forConnect: ClassifiedTransportFailure(.timedOut)
            ) == .unresponsive
        )
    }

    @Test func aBootstrapStatusMapsThroughTheStatusTaxonomy() {
        #expect(
            ConnectionIssueMapping.issue(forConnect: BootstrapFailure.unexpectedStatus(429))
                == .rateLimited
        )
        #expect(
            ConnectionIssueMapping.issue(forConnect: BootstrapFailure.unexpectedStatus(503))
                == .serverError(status: 503)
        )
    }

    /// **Not every bootstrap failure is a connectivity problem.** Being asked
    /// to sign in, or refused as an unsupported browser, are not states this
    /// taxonomy has a case for, and inventing one would be a confidently wrong
    /// diagnosis on screen - which `TransportFailureReason.intercepted`'s own
    /// doc comment already argues is worse than an honest vague one.
    @Test func aNonConnectivityBootstrapFailureIsHonestlyUnknown() throws {
        guard case .unknown = try ConnectionIssueMapping.issue(
            forConnect: BootstrapFailure
                .signInRedirect(#require(URL(string: "https://accounts.google.com")))
        ) else {
            Issue.record("expected .unknown")
            return
        }
    }

    @Test func anUnrecognisedErrorIsUnknownRatherThanAGuess() {
        struct Nothing: Error {}
        guard case .unknown = ConnectionIssueMapping.issue(forConnect: Nothing()) else {
            Issue.record("expected .unknown")
            return
        }
    }
}
