import Foundation
import Testing
@testable import GChatBridgeCore

/// The finding this type exists for: **auth failure returns HTTP 200.**
///
/// An incomplete or stale cookie set does not produce a 401, a 403, or a
/// redirect. It produces a well-formed app shell — *larger* than the
/// authenticated one, so body size is not a signal either — whose
/// `WIZ_global_data.qwAQke` reads `"AccountsSignInUi"` instead of
/// `"DynamiteWebUi"`. Every auth decision in this package therefore comes from
/// parsing that blob, never from a status code.
@Suite("WIZ global data")
struct WizGlobalDataTests {
    /// Shaped like the real shell — the blob wrapped in `({…});` inside a
    /// script tag — with invented values. `SMqcke` is 42 characters because the
    /// real token is.
    static func shell(app: String, extraKeys: Int = 0) -> String {
        var fields = [
            "\"qwAQke\":\"\(app)\"",
            "\"SMqcke\":\"\(String(repeating: "x", count: 42))\"",
            "\"cfb2h\":\"boq_dynamiteuiserver\""
        ]
        for index in 0 ..< extraKeys {
            fields.append("\"k\(index)\":\(index)")
        }
        return """
        <script nonce="abc">window.WIZ_global_data = {\(fields.joined(separator: ","))};</script>
        """
    }

    // MARK: - The signal

    @Test("the authenticated shell is recognised by its positive value, not by absence")
    func authenticated() throws {
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi")))
        #expect(wiz.appName == "DynamiteWebUi")
        #expect(wiz.signInState == .signedIn)
        #expect(wiz.isSignedIn)
    }

    @Test("the sign-in shell is recognised")
    func signedOut() throws {
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "AccountsSignInUi")))
        #expect(wiz.signInState == .signedOut)
        #expect(wiz.isSignedIn == false)
    }

    /// maugclib tests only for the negative (`== "AccountsSignInUi"`), which
    /// means any third value it has never seen reads as *signed in*. That is the
    /// wrong direction: an unrecognised shell must not be treated as a working
    /// session.
    @Test("an unrecognised app name is not treated as signed in")
    func unrecognisedAppName() throws {
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "SomeFutureUi")))
        #expect(wiz.signInState == .unknown("SomeFutureUi"))
        #expect(wiz.isSignedIn == false)
    }

    // MARK: - The token and the health signal

    @Test("the xsrf token is recovered")
    func xsrfToken() throws {
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi")))
        #expect(wiz.xsrfToken?.count == 42)
    }

    /// 128 keys authenticated versus ~68 signed out. Not an auth check on its
    /// own — it is the number that tells a human whether the shell they got is
    /// the shape they expected.
    @Test("the key count is reported, because the two shells differ in size")
    func keyCount() throws {
        let small = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi")))
        let large = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi", extraKeys: 10)))
        #expect(small.keyCount == 3)
        #expect(large.keyCount == 13)
    }

    // MARK: - Malformed input

    @Test("a page with no WIZ blob at all is nil, not a signed-out session")
    func missingBlob() {
        #expect(WizGlobalData(html: "<html><body>nothing here</body></html>") == nil)
    }

    @Test("a truncated blob is nil rather than a crash")
    func truncatedBlob() {
        #expect(WizGlobalData(html: "<script>window.WIZ_global_data = {\"qwAQke\":\"Dyn") == nil)
    }

    @Test("a blob that is not an object is nil")
    func notAnObject() {
        #expect(WizGlobalData(html: "<script>window.WIZ_global_data = [1,2,3];</script>") == nil)
    }

    /// The blob is megabyte-scale and the shell contains other script tags, so
    /// the scan has to find the assignment rather than the first brace.
    @Test("the blob is found even when other script content precedes it")
    func findsBlobAmongOtherScripts() throws {
        let html = """
        <script>var x = ({"qwAQke":"Decoy"});</script>
        \(Self.shell(app: "DynamiteWebUi"))
        """
        let wiz = try #require(WizGlobalData(html: html))
        #expect(wiz.appName == "DynamiteWebUi")
    }

    // MARK: - The hard rule

    /// `Never print cookie values, tokens, or message content.` A type that
    /// holds a token and gets interpolated into a log line is exactly how that
    /// rule gets broken by accident, so the description is asserted to describe
    /// rather than reveal.
    @Test("the description reports the token's length and never its value")
    func descriptionNeverLeaksTheToken() throws {
        let secret = String(repeating: "x", count: 42)
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi")))
        let rendered = "\(wiz)"
        #expect(!rendered.contains(secret))
        #expect(rendered.contains("42"))
        #expect(rendered.contains("DynamiteWebUi"))
    }

    // MARK: - The Punctual key

    /// `findings.md` §47: the API key every Punctual request carries as `key=`
    /// is `WIZ_global_data.Tzliq` on `/app/home`. The value here is invented;
    /// 39 characters because the real one is.
    @Test("the Punctual key is read from Tzliq, and described by its length only")
    func thePunctualKeyIsReadFromTzliq() throws {
        let key = String(repeating: "k", count: 39)
        let html = #"<script>window.WIZ_global_data = {"qwAQke":"DynamiteWebUi","Tzliq":""#
            + key + #""};</script>"#
        let wiz = try #require(WizGlobalData(html: html))
        #expect(wiz.punctualKey == key)
        #expect(!"\(wiz)".contains(key))
        #expect("\(wiz)".contains("punctual key: 39 chars"))
    }

    @Test("a shell without Tzliq has no Punctual key")
    func aShellWithoutTzliqHasNoPunctualKey() throws {
        let wiz = try #require(WizGlobalData(html: Self.shell(app: "DynamiteWebUi")))
        #expect(wiz.punctualKey == nil)
        #expect("\(wiz)".contains("punctual key: none"))
    }

    // MARK: - The assignment's punctuation

    /// **Regression, from a real signed-in shell.**
    ///
    /// The anchor used to be the literal text `WIZ_global_data = (`,
    /// transcribed from the reference Python's
    /// `r">window.WIZ_global_data = ({.+?});</script>"` - where the parentheses
    /// are a regex capture group, not characters on the page. Every fixture in
    /// this suite was written to match that mistake, so 133 tests passed
    /// against a page shape Google has never sent.
    ///
    /// The byte sequence below is what a live shell actually contains, taken
    /// from a capture on 2026-09-01. The key name is real; the value is not.
    @Test("the real shell's syntax has no parenthesis, and it parses")
    func theRealAssignmentSyntaxParses() {
        let html = """
        <script nonce="pS3B">window.WIZ_global_data = {"AB33kc":"https://example.invalid",\
        "qwAQke":"DynamiteWebUi"};</script>
        """
        let wiz = WizGlobalData(html: html)
        #expect(wiz?.isSignedIn == true)
        #expect(wiz?.keyCount == 2)
    }

    /// Tolerated, not required. If Google ever wraps it in parentheses again,
    /// the anchor should not care - being strict about punctuation is the
    /// mistake this test exists to prevent recurring.
    @Test("a parenthesised assignment still parses")
    func aParenthesisedAssignmentStillParses() {
        let html = #"<script>window.WIZ_global_data = ({"qwAQke":"DynamiteWebUi"});</script>"#
        #expect(WizGlobalData(html: html)?.isSignedIn == true)
    }

    @Test("a minified assignment with no spaces still parses")
    func aMinifiedAssignmentStillParses() {
        let html = #"<script>window.WIZ_global_data={"qwAQke":"DynamiteWebUi"}</script>"#
        #expect(WizGlobalData(html: html)?.isSignedIn == true)
    }
}
