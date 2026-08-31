import Foundation
import Testing
@testable import GChatBridgeCore

/// The finding that makes this type mandatory rather than an optimisation:
/// **cookies rotate mid-session.** In a 100-second run, `SIDCC`,
/// `__Secure-1PSIDCC` and `__Secure-3PSIDCC` each rotated on *every* long-poll
/// reopen — four times — and `register` grew `COMPASS` from 823 to 1029
/// characters. A transport that sends the captured header forever is sending a
/// credential that expired seconds after it was captured, which is the flaw the
/// earlier probes had and the likeliest reason take 2 saw no events at all.
///
/// `SessionCookies` is the snapshot the credential store hands out. This is the
/// live state that moves.
@Suite("Cookie jar")
struct CookieJarTests {
    static func jar(_ header: String = "SID=a; COMPASS=old; SIDCC=one") -> CookieJar {
        CookieJar(SessionCookies(header: header)!)
    }

    // MARK: - Seeding

    @Test("a jar starts as its snapshot and produces the same header")
    func seeding() throws {
        let cookies = try #require(SessionCookies(header: "SID=a; SSID=b"))
        #expect(CookieJar(cookies).headerValue == cookies.headerValue)
    }

    // MARK: - Absorbing Set-Cookie

    /// `Set-Cookie` carries attributes the request header must never echo back.
    @Test("attributes are stripped, so only the name and value are replayed")
    func stripsAttributes() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["SIDCC=two; Path=/; Secure; HttpOnly; Max-Age=63072000"])
        #expect(jar["SIDCC"] == "two")
        #expect(!jar.headerValue.contains("HttpOnly"))
        #expect(!jar.headerValue.contains("Path"))
    }

    @Test("a rotated cookie replaces the old value in place, keeping its position")
    func rotationKeepsOrder() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=new"])
        #expect(jar.headerValue == "SID=a; COMPASS=new; SIDCC=one")
        #expect(jar.count == 3)
    }

    @Test("a cookie the jar has never seen is appended rather than dropped")
    func newCookieIsAppended() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["__Secure-1PSIDCC=fresh"])
        #expect(jar.count == 4)
        #expect(jar["__Secure-1PSIDCC"] == "fresh")
    }

    /// A response sets several cookies at once — the observed run rotated three
    /// in a single reopen. A dictionary-shaped header type would collapse them,
    /// which is why `HTTPResponse` keeps repeated names.
    @Test("every Set-Cookie in one response is absorbed, not just the first")
    func absorbsAllOfThem() {
        var jar = Self.jar()
        jar.absorb(setCookie: [
            "SIDCC=two; Path=/",
            "__Secure-1PSIDCC=x; Secure",
            "__Secure-3PSIDCC=y; Secure"
        ])
        #expect(jar.count == 5)
        #expect(jar["SIDCC"] == "two")
        #expect(jar["__Secure-3PSIDCC"] == "y")
    }

    // MARK: - Deletion

    /// A server clearing a cookie sends an empty value with an expiry in the
    /// past. Replaying `NAME=` afterwards would send a credential the server has
    /// just retired.
    @Test("a cookie cleared with an expired date is removed, not stored empty")
    func expiredCookieIsRemoved() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT"])
        #expect(jar["COMPASS"] == nil)
        #expect(jar.count == 2)
    }

    @Test("Max-Age=0 also deletes")
    func maxAgeZeroDeletes() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["SIDCC=; Max-Age=0"])
        #expect(jar["SIDCC"] == nil)
    }

    /// `OTZ=` with no expiry is a real cookie with an empty value, which is
    /// different from a deletion and must survive.
    @Test("an empty value without an expiry is kept")
    func emptyValueWithoutExpiryIsKept() {
        var jar = Self.jar("SID=a; OTZ=x")
        jar.absorb(setCookie: ["OTZ="])
        #expect(jar["OTZ"] == "")
        #expect(jar.count == 2)
    }

    // MARK: - The rotation log

    /// The log is evidence, not decoration: it is what turned "the header went
    /// stale somehow" into "`COMPASS` grew by 206 characters on `register`".
    @Test("a rotation is recorded with old and new lengths, never values")
    func rotationIsLogged() throws {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=\(String(repeating: "n", count: 1029))"])
        #expect(jar.rotations.count == 1)
        let rotation = try #require(jar.rotations.first)
        #expect(rotation.name == "COMPASS")
        #expect(rotation.change == .rotated)
        #expect(rotation.oldLength == 3)
        #expect(rotation.newLength == 1029)
    }

    @Test("an unchanged value is not logged as a rotation")
    func unchangedIsNotARotation() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["SIDCC=one"])
        #expect(jar.rotations.isEmpty)
    }

    @Test("additions and deletions are logged distinctly from rotations")
    func additionsAndDeletionsAreLogged() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["NEWONE=z", "SID=; Max-Age=0"])
        #expect(jar.rotations.map(\.change) == [.added, .deleted])
    }

    /// Same hard rule as everywhere else in this package.
    @Test("neither the log nor the description ever contains a cookie value")
    func neverLeaksValues() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=supersecretvalue"])
        let rendered = "\(jar)" + jar.rotations.map { "\($0)" }.joined()
        #expect(!rendered.contains("supersecretvalue"))
        #expect(rendered.contains("COMPASS"))
    }

    // MARK: - Malformed input

    @Test("a malformed Set-Cookie is ignored without disturbing the jar")
    func malformedIsIgnored() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["", "   ", "novalue", "=orphan"])
        #expect(jar.headerValue == "SID=a; COMPASS=old; SIDCC=one")
        #expect(jar.rotations.isEmpty)
    }

    /// The snapshot the credential store should persist after a session, so the
    /// next launch starts from rotated values rather than the stale capture.
    @Test("the jar can hand back a snapshot for the credential store")
    func snapshotRoundTrip() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=new"])
        let snapshot = jar.snapshot
        #expect(snapshot?.headerValue == "SID=a; COMPASS=new; SIDCC=one")
    }
}
