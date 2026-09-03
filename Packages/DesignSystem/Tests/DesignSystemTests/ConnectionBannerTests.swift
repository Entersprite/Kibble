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
}
