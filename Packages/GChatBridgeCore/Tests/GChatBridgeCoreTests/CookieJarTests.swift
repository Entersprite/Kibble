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
        jar.absorb(setCookie: ["SIDCC=two; Path=/; Secure; HttpOnly; Max-Age=63072000"], from: Self.chat)
        #expect(jar["SIDCC"] == "two")
        #expect(!jar.headerValue.contains("HttpOnly"))
        #expect(!jar.headerValue.contains("Path"))
    }

    @Test("a rotated cookie replaces the old value in place, keeping its position")
    func rotationKeepsOrder() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=new"], from: Self.chat)
        #expect(jar.headerValue == "SID=a; COMPASS=new; SIDCC=one")
        #expect(jar.count == 3)
    }

    @Test("a cookie the jar has never seen is appended rather than dropped")
    func newCookieIsAppended() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["__Secure-1PSIDCC=fresh"], from: Self.chat)
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
        ], from: Self.chat)
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
        jar.absorb(setCookie: ["COMPASS=; Expires=Thu, 01 Jan 1970 00:00:00 GMT"], from: Self.chat)
        #expect(jar["COMPASS"] == nil)
        #expect(jar.count == 2)
    }

    @Test("Max-Age=0 also deletes")
    func maxAgeZeroDeletes() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["SIDCC=; Max-Age=0"], from: Self.chat)
        #expect(jar["SIDCC"] == nil)
    }

    /// `OTZ=` with no expiry is a real cookie with an empty value, which is
    /// different from a deletion and must survive.
    @Test("an empty value without an expiry is kept")
    func emptyValueWithoutExpiryIsKept() {
        var jar = Self.jar("SID=a; OTZ=x")
        jar.absorb(setCookie: ["OTZ="], from: Self.chat)
        #expect(jar["OTZ"] == "")
        #expect(jar.count == 2)
    }

    // MARK: - The rotation log

    /// The log is evidence, not decoration: it is what turned "the header went
    /// stale somehow" into "`COMPASS` grew by 206 characters on `register`".
    @Test("a rotation is recorded with old and new lengths, never values")
    func rotationIsLogged() throws {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=\(String(repeating: "n", count: 1029))"], from: Self.chat)
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
        jar.absorb(setCookie: ["SIDCC=one"], from: Self.chat)
        #expect(jar.rotations.isEmpty)
    }

    @Test("additions and deletions are logged distinctly from rotations")
    func additionsAndDeletionsAreLogged() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["NEWONE=z", "SID=; Max-Age=0"], from: Self.chat)
        #expect(jar.rotations.map(\.change) == [.added, .deleted])
    }

    /// Same hard rule as everywhere else in this package.
    @Test("neither the log nor the description ever contains a cookie value")
    func neverLeaksValues() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=supersecretvalue"], from: Self.chat)
        let rendered = "\(jar)" + jar.rotations.map { "\($0)" }.joined()
        #expect(!rendered.contains("supersecretvalue"))
        #expect(rendered.contains("COMPASS"))
    }

    // MARK: - Malformed input

    @Test("a malformed Set-Cookie is ignored without disturbing the jar")
    func malformedIsIgnored() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["", "   ", "novalue", "=orphan"], from: Self.chat)
        #expect(jar.headerValue == "SID=a; COMPASS=old; SIDCC=one")
        #expect(jar.rotations.isEmpty)
    }

    /// The snapshot the credential store should persist after a session, so the
    /// next launch starts from rotated values rather than the stale capture.
    @Test("the jar can hand back a snapshot for the credential store")
    func snapshotRoundTrip() {
        var jar = Self.jar()
        jar.absorb(setCookie: ["COMPASS=new"], from: Self.chat)
        let snapshot = jar.snapshot
        #expect(snapshot?.headerValue == "SID=a; COMPASS=new; SIDCC=one")
    }

    // MARK: - Domains and paths (findings.md §52.9)

    static let chat = URL(string: "https://chat.google.com/u/0/api/x")!
    static let download = URL(string: "https://chat.usercontent.google.com/download")!

    static func scopedJar() -> CookieJar {
        CookieJar(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SIDCC", value: "one", domain: ".google.com", path: "/"),
            SessionCookies.Cookie(name: "COMPASS", value: "old", domain: "chat.google.com", path: "/")
        ])!)
    }

    @Test("a Set-Cookie with no Domain is host-only, for the host that answered")
    func noDomainIsHostOnly() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["NEW=v; Path=/"], from: Self.download)
        #expect(jar.header(for: Self.download) == "SIDCC=one; NEW=v")
        #expect(jar.header(for: Self.chat) == "SIDCC=one; COMPASS=old")
    }

    @Test("COMPASS rotated by the chat host replaces the captured one in place")
    func hostOnlyRotationReplaces() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["COMPASS=new; Path=/; Secure; HttpOnly"], from: Self.chat)
        #expect(jar.header(for: Self.chat) == "SIDCC=one; COMPASS=new")
        #expect(jar.count == 2)
    }

    @Test("Domain=google.com and Domain=.google.com are the same domain cookie")
    func domainAttributeIsNormalised() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["SIDCC=two; Domain=google.com; Path=/"], from: Self.chat)
        jar.absorb(setCookie: ["SIDCC=three; Domain=.google.com; Path=/"], from: Self.chat)
        #expect(jar.header(for: Self.download) == "SIDCC=three")
        #expect(jar.count == 2)
    }

    @Test(arguments: [
        "X=v; Domain=example.com",
        "X=v; Domain=com",
        "X=v; Domain=.com",
        "X=v; Domain=oogle.com"
    ])
    func aDomainTheHostCannotSetIsIgnored(_ header: String) {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: [header], from: Self.chat)
        #expect(jar.count == 2)
    }

    @Test("two cookies with one name on two domains are two cookies")
    func sameNameTwoDomains() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["SIDCC=host; Path=/"], from: Self.chat)
        #expect(jar.count == 3)
        #expect(jar.header(for: Self.chat) == "SIDCC=one; COMPASS=old; SIDCC=host")
        #expect(jar.header(for: Self.download) == "SIDCC=one")
    }

    @Test("a cookie with no recorded domain is rotated by name and stays without one")
    func legacyRotationStaysLegacy() throws {
        var jar = try CookieJar(#require(SessionCookies(header: "SID=a; COMPASS=old")))
        jar.absorb(setCookie: ["COMPASS=new; Domain=.google.com; Path=/"], from: Self.chat)
        #expect(jar.snapshot?.cookies.map(\.domain) == [nil, nil])
        #expect(jar.header(for: Self.chat) == "SID=a; COMPASS=new")
        #expect(jar.header(for: Self.download) == nil)
    }

    @Test("a deletion removes the cookie with that name, domain and path, and no other")
    func scopedDeletion() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["SIDCC=host; Path=/"], from: Self.chat)
        jar.absorb(setCookie: ["SIDCC=; Path=/; Max-Age=0"], from: Self.chat)
        #expect(jar.header(for: Self.chat) == "SIDCC=one; COMPASS=old")
    }

    @Test("a Path that is not absolute is the root")
    func relativePathIsRoot() {
        var jar = Self.scopedJar()
        jar.absorb(setCookie: ["NEW=v; Path=api"], from: Self.chat)
        #expect(jar.snapshot?.cookies.last?.path == "/")
    }
}
