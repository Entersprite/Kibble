import Foundation
import Testing
@testable import LocalBridgeBackend

/// The report the login spike reads its answer off.
struct CookieCaptureReportTests {
    private func entry(
        _ name: String,
        domain: String = ".google.com",
        length: Int = 100,
        httpOnly: Bool = true
    ) -> CookieCaptureReport.Entry {
        CookieCaptureReport.Entry(
            name: name,
            domain: domain,
            valueLength: length,
            isHTTPOnly: httpOnly,
            isSecure: true,
            expiresInDays: 30
        )
    }

    private func report(_ entries: [CookieCaptureReport.Entry]) -> CookieCaptureReport {
        CookieCaptureReport(
            capturedAt: Date(timeIntervalSince1970: 1_788_166_800),
            pageURL: "https://chat.google.com/app/home",
            pageTitle: "Google Chat",
            entries: entries
        )
    }

    /// The test this type was moved into a package to have.
    ///
    /// Rendering used `String(format:)` with `%s`, which expects a C string;
    /// passing a Swift `String` segfaulted the app the first time a real login
    /// reached it. Nothing here asserts beauty - only that it renders at all.
    @Test func renderingDoesNotCrashAndIncludesEveryCookieName() {
        let rendered = report([
            entry("COMPASS", domain: "chat.google.com", length: 1029),
            entry("__Secure-1PSID"),
            entry("a-very-long-cookie-name-that-overflows-its-column"),
            entry("OTZ", httpOnly: false)
        ]).text

        #expect(rendered.contains("COMPASS"))
        #expect(rendered.contains("__Secure-1PSID"))
        #expect(rendered.contains("a-very-long-cookie-name-that-overflows-its-column"))
        #expect(rendered.contains("OTZ"))
        #expect(rendered.contains("1029"))
    }

    @Test func anEmptyReportStillRenders() {
        #expect(report([]).text.contains("NOT SIGNED IN"))
    }

    /// A name longer than its column is not truncated: the name is the answer.
    @Test func aLongNameIsNotCutShort() {
        let long = String(repeating: "x", count: 60)
        #expect(report([entry(long)]).text.contains(long))
    }

    @Test func noValueCanReachTheReportBecauseNoneIsStored() {
        // Structural, not a string search: Entry has no value field at all, so
        // there is nothing to leak. Asserted here so that adding one breaks a
        // test with an explanation attached.
        let rendered = report([entry("SID", length: 71)]).text
        #expect(rendered.contains("71"))
        #expect(!rendered.contains("secret"))
    }

    // MARK: - The verdict, which is the whole point

    @Test func chatScopedPlusModernAuthIsAPass() {
        let verdict = report([
            entry("COMPASS", domain: "chat.google.com"),
            entry("OSID", domain: "chat.google.com"),
            entry("__Secure-1PSID")
        ]).verdict
        #expect(verdict.hasPrefix("PASS"))
    }

    /// The convincing-looking failure: everything modern present, and the two
    /// cookies Chat itself issues missing. Distinguishing this from bad
    /// credentials is why the report exists.
    @Test func theModernFamilyWithoutChatsOwnCookiesIsTooEarly() {
        let verdict = report([
            entry("__Secure-1PSID"),
            entry("__Secure-3PSID"),
            entry("SAPISID"),
            entry("HSID")
        ]).verdict
        #expect(verdict.hasPrefix("TOO EARLY"))
    }

    @Test func chatCookiesWithoutTheModernFamilyIsFlaggedAsOdd() {
        let verdict = report([
            entry("COMPASS", domain: "chat.google.com"),
            entry("OSID", domain: "chat.google.com")
        ]).verdict
        #expect(verdict.hasPrefix("ODD"))
    }

    @Test func neitherFamilyIsNotSignedIn() {
        #expect(report([entry("OTZ", httpOnly: false)]).verdict.hasPrefix("NOT SIGNED IN"))
    }

    @Test func onlyOneOfTheSecurePSIDPairIsNeeded() {
        #expect(report([entry("__Secure-3PSID")]).hasModernAuthFamily)
        #expect(report([entry("__Secure-1PSID")]).hasModernAuthFamily)
        #expect(!report([entry("SAPISID")]).hasModernAuthFamily)
    }

    // MARK: - Counts

    @Test func theHeaderLengthAccountsForTheSeparators() {
        // "SID=<10 bytes>; " is 3 + 1 + 10 + 2 = 16
        #expect(report([entry("SID", length: 10)]).totalHeaderLength == 16)
    }

    @Test func httpOnlyCookiesAreCountedBecauseTheyAreTheEvidence() {
        let subject = report([
            entry("COMPASS", httpOnly: true),
            entry("OSID", httpOnly: true),
            entry("OTZ", httpOnly: false)
        ])
        #expect(subject.httpOnlyCount == 2)
    }
}
