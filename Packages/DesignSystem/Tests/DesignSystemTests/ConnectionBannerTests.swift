import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What the banner says, per cause.
///
/// The wording is deliberately vague where the truth is: "Google isn't
/// responding", never "Google is down", because a timeout is byte-identical
/// for "their fault" and "your network is blocking them". `findings.md` §24's
/// `[Verify]` discipline is the precedent - a confidently wrong diagnosis on
/// screen is worse than an honest vague one.
struct ConnectionBannerTests {
    private func banner(_ issue: ConnectionIssue?) -> String? {
        ConnectionBanner.text(
            for: .reconnecting(attempt: 1, issue: issue, detail: nil)
        )
    }

    @Test func everyIssueHasItsOwnSentence() {
        #expect(banner(.noInternet) == "No internet connection.")
        #expect(banner(.nameResolution) == "Can't look up Google's address.")
        #expect(banner(.refused) == "Google's servers refused the connection.")
        #expect(banner(.intercepted) ==
            "Something is intercepting the connection — a captive portal, proxy or VPN.")
        #expect(banner(.unresponsive) == "Google isn't responding.")
        #expect(banner(.dropped) == "Reconnecting…")
        #expect(banner(.rateLimited) == "Google is asking us to slow down.")
        #expect(banner(.serverError(status: 503)) == "Google Chat is having problems.")
    }

    /// An unknown *issue* still reports a problem - we know something is
    /// wrong, just not what.
    @Test func anUnknownIssueStillSaysSomething() {
        #expect(banner(.unknown("newThing")) != nil)
    }

    /// An unknown *state* is different: we do not know that anything is wrong.
    /// Degrade toward optimism rather than alarm someone about a state this
    /// build does not understand (design §3.4).
    @Test func anUnknownStateRendersAsConnecting() {
        #expect(ConnectionBanner.text(for: .unknown("hibernating")) == "Connecting…")
    }

    @Test func aConnectedSessionSaysNothing() {
        #expect(ConnectionBanner.text(for: .connected) == nil)
    }

    /// Immediately for interception, because that class genuinely needs a
    /// human - leave the portal, kill the proxy - and waiting a minute to
    /// offer help is unkind when a retry provably will not fix it.
    @Test func theReconnectControlAppearsAtOnceForInterception() {
        #expect(ConnectionBanner.offersReconnect(
            for: .reconnecting(attempt: 1, issue: .intercepted, detail: nil)
        ))
    }

    /// After about a minute for everything else. Never because we gave up -
    /// nothing gives up - only ever an accelerant, because the user may know
    /// something we cannot.
    @Test func theReconnectControlWaitsForEverythingElse() {
        #expect(!ConnectionBanner.offersReconnect(
            for: .reconnecting(attempt: 1, issue: .unresponsive, detail: nil)
        ))
        #expect(ConnectionBanner.offersReconnect(
            for: .reconnecting(attempt: 6, issue: .unresponsive, detail: nil)
        ))
    }

    @Test func aHealthySessionOffersNoReconnect() {
        #expect(!ConnectionBanner.offersReconnect(for: .connected))
    }

    // MARK: - detail(for:)

    /// `detail` is diagnostic only, never the headline - CLAUDE.md's protocol
    /// rules say it carries an error domain and code, or a status number,
    /// never a URL or message content. These tests only check it round-trips
    /// what `ConnectionState` already carries; they cannot enforce that
    /// callers keep feeding it safe values.
    @Test func reconnectingCarriesItsDetailVerbatim() {
        #expect(ConnectionBanner.detail(
            for: .reconnecting(attempt: 1, issue: .unresponsive, detail: "NSURLErrorDomain -1001")
        ) == "NSURLErrorDomain -1001")
    }

    @Test func reconnectingWithNoDetailShowsNone() {
        #expect(ConnectionBanner.detail(
            for: .reconnecting(attempt: 1, issue: .unresponsive, detail: nil)
        ) == nil)
    }

    /// The raw tag an unknown state carries was captured and decoded but
    /// never shown anywhere until now (`ConnectionState.unknown`'s own doc
    /// comment) - this is where it goes: the secondary line, not the
    /// headline `text(for:)` already renders as "Connecting…".
    @Test func anUnknownStatesRawTagAppearsAsDetail() {
        #expect(ConnectionBanner.detail(for: .unknown("hibernating")) == "hibernating")
    }

    @Test func aHealthySessionHasNoDetail() {
        #expect(ConnectionBanner.detail(for: .connected) == nil)
    }

    /// Every other state has nothing to add on a second line either -
    /// `.idle`, `.connecting` and `.disconnected` carry no field this
    /// function reads from.
    @Test func statesWithNoDiagnosticFieldShowNoDetail() {
        #expect(ConnectionBanner.detail(for: .idle) == nil)
        #expect(ConnectionBanner.detail(for: .connecting) == nil)
        #expect(ConnectionBanner.detail(for: .disconnected(reason: "closed", issue: nil)) == nil)
    }
}
