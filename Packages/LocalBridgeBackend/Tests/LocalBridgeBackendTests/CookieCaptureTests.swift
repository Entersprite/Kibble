import Foundation
import Testing
@testable import LocalBridgeBackend

/// Turning a browser-shaped cookie store into a credential for one host.
///
/// The capture drains cookies for *several* Google hosts at once. Which of them
/// may be replayed to Chat is `CookieScope`'s question; this is about applying
/// that answer without losing the evidence of what was dropped.
struct CookieCaptureTests {
    private func cookie(
        _ name: String,
        value: String = "v",
        domain: String = ".google.com",
        path: String = "/",
        expiresAt: Date? = nil
    ) -> CapturedCookie {
        CapturedCookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            isSecure: true,
            isHTTPOnly: true,
            expiresAt: expiresAt
        )
    }

    private func capture(_ cookies: [CapturedCookie]) -> CookieCapture {
        CookieCapture(
            cookies: cookies,
            capturedAt: Date(timeIntervalSince1970: 1_788_166_800),
            pageURL: "https://chat.google.com/app/home",
            pageTitle: "Google Chat"
        )
    }

    // MARK: - What reaches the credential

    @Test func aCookieForASiblingHostIsNotReplayedToChat() {
        let capture = capture([
            cookie("COMPASS", domain: "chat.google.com"),
            cookie("LSID", domain: "accounts.google.com")
        ])
        #expect(capture.session?.credential.cookies.map(\.name) == ["COMPASS"])
    }

    @Test func inScopeCookiesKeepTheirCaptureOrder() {
        let capture = capture([
            cookie("SAPISID"),
            cookie("COMPASS", domain: "chat.google.com"),
            cookie("__Secure-1PSID")
        ])
        #expect(capture.session?.credential.cookies.map(\.name) == ["SAPISID", "COMPASS", "__Secure-1PSID"])
    }

    @Test func aCaptureWithNothingInScopeYieldsNoSession() {
        let capture = capture([cookie("LSID", domain: "accounts.google.com")])
        #expect(capture.session == nil)
    }

    @Test func anEmptyCaptureYieldsNoSession() {
        #expect(capture([]).session == nil)
    }

    // MARK: - What the report records

    /// Dropping a cookie silently would make this defect impossible to see
    /// twice. Every captured cookie appears; the report says which were sent.
    @Test func theReportKeepsEveryCookieIncludingTheOnesItExcluded() {
        let report = capture([
            cookie("COMPASS", domain: "chat.google.com"),
            cookie("__Host-GAPS", domain: "accounts.google.com")
        ]).report
        #expect(report.entries.count == 2)
        #expect(report.entries.first { $0.name == "COMPASS" }?.isInScope == true)
        #expect(report.entries.first { $0.name == "__Host-GAPS" }?.isInScope == false)
    }

    @Test func theRenderedReportMarksWhatWasExcluded() {
        let rendered = capture([
            cookie("COMPASS", domain: "chat.google.com"),
            cookie("_ga", domain: "workspace.google.com")
        ]).report.text
        #expect(rendered.contains("_ga"))
        #expect(rendered.contains("excluded"))
    }

    /// The verdict is about the credential being built, not about everything
    /// the store happened to hold. An out-of-scope `COMPASS` is not a pass.
    @Test func theVerdictIgnoresCookiesThatWillNotBeSent() {
        let capture = capture([
            cookie("COMPASS", domain: "accounts.google.com"),
            cookie("OSID", domain: "accounts.google.com"),
            cookie("__Secure-1PSID")
        ])
        #expect(!capture.report.hasChatScopedCookies)
    }

    @Test func headerLengthCountsOnlyWhatWillBeSent() {
        let big = String(repeating: "x", count: 500)
        let small = capture([
            cookie("COMPASS", value: "abc", domain: "chat.google.com"),
            cookie("_ga", value: big, domain: "workspace.google.com")
        ]).report.totalHeaderLength
        #expect(small < 100)
    }

    // MARK: - Expiry

    /// `COMPASS` expires in nine days where the rest last 399, so the earliest
    /// expiry is the one that decides when a person must sign in again.
    @Test func theSessionExpiresWhenItsShortestLivedCookieDoes() {
        let now = Date(timeIntervalSince1970: 1_788_166_800)
        let capture = capture([
            cookie("COMPASS", domain: "chat.google.com", expiresAt: now.addingTimeInterval(9 * 86400)),
            cookie("__Secure-1PSID", expiresAt: now.addingTimeInterval(399 * 86400))
        ])
        #expect(capture.session?.expiresAt == now.addingTimeInterval(9 * 86400))
    }

    @Test func anOutOfScopeCookieDoesNotShortenTheSession() {
        let now = Date(timeIntervalSince1970: 1_788_166_800)
        let capture = capture([
            cookie("COMPASS", domain: "chat.google.com", expiresAt: now.addingTimeInterval(9 * 86400)),
            cookie("SMSV", domain: "accounts.google.com", expiresAt: now.addingTimeInterval(60))
        ])
        #expect(capture.session?.expiresAt == now.addingTimeInterval(9 * 86400))
    }

    @Test func sessionCookiesDoNotGiveTheSessionAnExpiry() {
        let capture = capture([cookie("COMPASS", domain: "chat.google.com", expiresAt: nil)])
        #expect(capture.session?.expiresAt == nil)
    }

    // MARK: - Rendering hostile input

    /// A cookie's expiry is data from a server, and the report's age column used
    /// to convert it with `Int(_:)`, which traps on anything outside `Int`'s
    /// range. Killing the app here would cost a person a second two-factor
    /// login, because the data store is non-persistent by design.
    @Test func anAbsurdExpiryDateRendersInsteadOfTrapping() {
        let rendered = capture([
            cookie("COMPASS", domain: "chat.google.com", expiresAt: .distantFuture),
            cookie("OSID", domain: "chat.google.com", expiresAt: .distantPast)
        ]).report.text
        #expect(rendered.contains("COMPASS"))
        #expect(rendered.contains("OSID"))
    }

    @Test("each stored cookie keeps the domain and path it was captured with")
    func domainsAreKept() throws {
        let capture = capture([
            cookie("SID", domain: ".google.com"),
            cookie("COMPASS", domain: "chat.google.com"),
            cookie("LSID", domain: "accounts.google.com")
        ])
        let cookies = try #require(capture.session?.credential.cookies)
        #expect(cookies.map(\.name) == ["SID", "COMPASS"])
        #expect(cookies.map(\.domain) == [".google.com", "chat.google.com"])
        #expect(cookies.map(\.path) == ["/", "/"])
    }

    @Test("an empty path from the store is the root")
    func emptyPathIsRoot() {
        let capture = capture([cookie("SID", domain: ".google.com", path: "")])
        #expect(capture.session?.credential.cookies.first?.path == "/")
    }

    /// `CookieJar.apply` compares a stored domain against a lowercased
    /// `Set-Cookie` scope; a domain the store capitalised differently would
    /// never match by identity. Lowercasing at capture is what keeps that
    /// comparison robust, and the leading dot - a domain cookie's marker -
    /// is untouched by case.
    @Test("a captured domain is lowercased, keeping the leading dot")
    func domainIsLowercased() throws {
        let capture = capture([cookie("SID", domain: ".Google.COM")])
        let cookie = try #require(capture.session?.credential.cookies.first)
        #expect(cookie.domain == ".google.com")
    }
}
