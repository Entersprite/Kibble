import Foundation
import Testing
@testable import MacHost

/// Spec §7a. `CookieScope.domainMatches` gets this right and says why in its
/// own doc comment: the label boundary is load-bearing, and `hasSuffix` alone
/// admits `oogle.com` for `chat.google.com`. The capture gate used
/// `contains`, which is strictly worse than `hasSuffix` - it admits
/// `chat.google.com.evil.example`.
///
/// The consequence is bounded: this decides *when* a capture fires, not what
/// is replayed, because `CookieScope` still filters the header that reaches
/// Chat. So it is a capture and auto-save taken at a hostile moment rather
/// than cookies posted to an attacker. Worth fixing because it is the same
/// defect class the project already fixed once, in the file one hop from the
/// credential.
///
/// `@MainActor` because `accepts(host:for:)` is a static member of
/// `CookieCaptureModel`, which is itself `@MainActor` - same reason
/// `CookieCaptureModelTests` carries the same annotation.
@MainActor
struct HostMatchingTests {
    private let configuration = LoginWebViewConfiguration.chat

    @Test func theRealHostIsAccepted() {
        #expect(CookieCaptureModel.accepts(host: "chat.google.com", for: configuration))
    }

    @Test func aSubdomainIsAccepted() {
        // Matching `CookieScope.domainMatches` rather than inventing a second
        // rule for the same question.
        #expect(CookieCaptureModel.accepts(host: "foo.chat.google.com", for: configuration))
    }

    @Test func aSuffixAttackIsRejected() {
        #expect(!CookieCaptureModel.accepts(host: "chat.google.com.evil.example", for: configuration))
    }

    @Test func aPrefixedLabelIsRejected() {
        #expect(!CookieCaptureModel.accepts(host: "notchat.google.com", for: configuration))
    }

    @Test func anUnrelatedGoogleHostIsRejected() {
        #expect(!CookieCaptureModel.accepts(host: "accounts.google.com", for: configuration))
    }

    @Test func theBareParentDomainIsRejected() {
        #expect(!CookieCaptureModel.accepts(host: "google.com", for: configuration))
    }
}
