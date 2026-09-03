import Foundation
import Testing
@testable import MacHost

/// Spec §6.4 item 31.
///
/// Google's sign-in URLs carry identifiers and one-time tokens in their query
/// strings, and this trace file is meant to be readable and pasteable. The
/// stripping is the security-relevant half of `LoginTrace` and the only half
/// worth testing; the `FileManager` write is one file wide and deliberately
/// left uncovered.
///
/// `@MainActor`: `LoginTrace` is main-actor isolated (its `flush()` shares
/// mutable state with `note(_:)`), and that isolation reaches `redact(_:)`
/// too even though it touches no shared state itself. Same pattern as
/// `HostMatchingTests` and `DatabasePathTests`.
@MainActor
struct LoginTraceRedactionTests {
    @Test func theQueryIsStrippedAndItsAbsenceIsVisible() {
        let url = URL(string: "https://accounts.google.com/signin/v2?token=SECRET&hl=en")
        let line = LoginTrace.redact(url)

        #expect(!line.contains("SECRET"))
        #expect(!line.contains("token"))
        #expect(line.contains("accounts.google.com"))
        #expect(line.contains("/signin/v2"))
        #expect(line.contains("<stripped>"))
    }

    @Test func aURLWithNoQuerySaysNothingAboutOne() {
        let line = LoginTrace.redact(URL(string: "https://chat.google.com/u/0/"))
        #expect(line == "chat.google.com/u/0/")
    }

    @Test func nothingAtAllIsSaidPlainly() {
        #expect(LoginTrace.redact(nil) == "(no url)")
    }

    /// A `mailto:` has no host. Reporting the scheme is more useful than
    /// reporting the whole URL, which could carry an address.
    @Test func aHostlessURLFallsBackToItsScheme() {
        #expect(LoginTrace.redact(URL(string: "mailto:someone@example.com")) == "mailto")
    }
}
