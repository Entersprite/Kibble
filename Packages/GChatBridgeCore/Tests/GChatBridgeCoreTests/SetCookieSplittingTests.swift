import Foundation
import Testing
@testable import GChatBridgeCore

/// Foundation collapses repeated response headers into one comma-joined string,
/// and `Set-Cookie` is the field where that hurts.
///
/// This is measured, not assumed. A local server returning three `Set-Cookie`
/// headers, read back through `URLSession`, produced exactly one header field:
///
/// ```
/// SIDCC=aaa; Path=/; Secure, COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/, __Secure-1PSIDCC=bbb;
/// Secure; HttpOnly
/// ```
///
/// **The trap is the date.** `Expires=Thu, 01 Jan 1970 00:00:00 GMT` contains a
/// comma, so splitting on commas shreds a deletion into nonsense — and a
/// deletion misread as a live cookie means replaying a credential the server
/// just retired.
@Suite("Set-Cookie splitting")
struct SetCookieSplittingTests {
    /// Captured verbatim from the experiment above.
    static let observed = "SIDCC=aaa; Path=/; Secure, "
        + "COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/, "
        + "__Secure-1PSIDCC=bbb; Secure; HttpOnly"

    @Test("the observed joined header splits back into its three cookies")
    func splitsTheRealThing() {
        let headers = HTTPHeaders(collapsed: ["Set-Cookie": Self.observed])
        let cookies = headers.setCookies
        #expect(cookies.count == 3)
        #expect(cookies.first == "SIDCC=aaa; Path=/; Secure")
        #expect(cookies.last == "__Secure-1PSIDCC=bbb; Secure; HttpOnly")
    }

    /// The assertion that matters: the date's comma is not a boundary, so the
    /// deletion survives intact and the jar still recognises it.
    @Test("a comma inside an Expires date is not treated as a separator")
    func expiresDateSurvivesIntact() throws {
        let cookies = HTTPHeaders(collapsed: ["Set-Cookie": Self.observed]).setCookies
        let compass = try #require(cookies.first { $0.hasPrefix("COMPASS=") })
        #expect(compass == "COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")

        var jar = try CookieJar(#require(SessionCookies(header: "COMPASS=live; SID=a")))
        jar.absorb(setCookie: cookies)
        #expect(jar["COMPASS"] == nil, "the deletion was not understood")
        #expect(jar["SIDCC"] == "aaa")
    }

    @Test("a single cookie with no comma is returned unchanged")
    func singleCookie() {
        let headers = HTTPHeaders(collapsed: ["Set-Cookie": "SID=only; Path=/"])
        #expect(headers.setCookies == ["SID=only; Path=/"])
    }

    @Test("other headers are carried through untouched")
    func otherHeadersUnaffected() {
        let headers = HTTPHeaders(collapsed: [
            "Content-Type": "text/html",
            "X-HTTP-Initial-Response": #"[[0,["c","SID"]]]"#
        ])
        #expect(headers["Content-Type"] == "text/html")
        #expect(headers["x-http-initial-response"] != nil)
        #expect(headers.setCookies.isEmpty)
    }

    /// A value that is genuinely comma-separated but is *not* a cookie boundary,
    /// because what follows is not `name=`.
    @Test("a comma not followed by a name and equals is not a boundary")
    func commaWithoutAssignment() {
        let joined = "SID=a; Expires=Mon, 02 Jan 2040 00:00:00 GMT"
        #expect(HTTPHeaders(collapsed: ["Set-Cookie": joined]).setCookies == [joined])
    }

    @Test("empty and whitespace-only values yield no cookies")
    func emptyYieldsNothing() {
        #expect(HTTPHeaders(collapsed: ["Set-Cookie": ""]).setCookies.isEmpty)
        #expect(HTTPHeaders(collapsed: ["Set-Cookie": "   "]).setCookies.isEmpty)
    }

    /// Names cannot contain whitespace, so a bare date fragment can never be
    /// mistaken for the start of a cookie even if an `=` appears later in it.
    @Test("a fragment whose name would contain whitespace is not a boundary")
    func nameCannotContainWhitespace() {
        let joined = "A=1; Expires=Thu, 01 Jan 1970 x=y GMT"
        #expect(HTTPHeaders(collapsed: ["Set-Cookie": joined]).setCookies == [joined])
    }

    @Test("three cookies with no attributes still split")
    func plainTriple() {
        let headers = HTTPHeaders(collapsed: ["Set-Cookie": "A=1, B=2, C=3"])
        #expect(headers.setCookies == ["A=1", "B=2", "C=3"])
    }
}
