import Foundation
import Testing
@testable import GChatBridgeCore

/// The finding this type is shaped by: **never name a required cookie set.**
///
/// maugclib declares five — `COMPASS, SSID, SID, OSID, HSID` — and encodes them
/// as a five-field record. In 2026 those five authenticate nothing: they return
/// HTTP 200 carrying the sign-in shell, which looks exactly like a credential
/// rejection and is not one. A real session needed 26 cookies, including the
/// `__Secure-1PSID` / `SAPISID` / `APISID` families that list omits entirely.
///
/// So this type is deliberately dumb: an ordered, opaque sequence that is
/// captured whole and replayed verbatim. It privileges no name, validates no
/// name, and has no notion of a complete set — because any such notion is a
/// guess about Google's internals that has already been wrong once.
@Suite("Session cookies")
struct SessionCookiesTests {
    /// Names taken from a real working header; values invented.
    static let realistic = [
        "SID", "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PSIDTS",
        "SAPISID", "APISID", "HSID", "SSID", "OSID", "COMPASS",
        "NID", "AEC", "OTZ", "SOCS", "SEARCH_SAMESITE", "SIDCC"
    ]

    static var realisticHeader: String {
        realistic.enumerated()
            .map { "\($0.element)=value\($0.offset)" }
            .joined(separator: "; ")
    }

    // MARK: - Verbatim replay

    /// The whole design in one assertion: what was captured is what gets sent.
    @Test("a captured header is replayed byte-for-byte, in order")
    func replaysVerbatim() throws {
        let cookies = try #require(SessionCookies(header: Self.realisticHeader))
        #expect(cookies.headerValue == Self.realisticHeader)
        #expect(cookies.count == 16)
    }

    @Test("a value containing an equals sign survives, because base64 padding does that")
    func valuesMayContainEquals() throws {
        let header = "__Secure-1PSIDCC=abc==; SID=plain"
        let cookies = try #require(SessionCookies(header: header))
        #expect(cookies.headerValue == header)
        #expect(cookies["__Secure-1PSIDCC"] == "abc==")
    }

    @Test("whitespace after a semicolon is tolerated and normalised on the way out")
    func tolerantOfSpacing() throws {
        let cookies = try #require(SessionCookies(header: "A=1;B=2;   C=3"))
        #expect(cookies.count == 3)
        #expect(cookies.headerValue == "A=1; B=2; C=3")
    }

    /// Browsers do send the same name twice for different paths. Dropping one
    /// would be a silent edit to a credential.
    @Test("a repeated cookie name is preserved rather than deduplicated")
    func duplicatesArePreserved() throws {
        let cookies = try #require(SessionCookies(header: "SID=one; SID=two"))
        #expect(cookies.count == 2)
        #expect(cookies.headerValue == "SID=one; SID=two")
    }

    // MARK: - No name is privileged

    /// A header with none of maugclib's five is still a perfectly good header as
    /// far as this type is concerned. Deciding otherwise is what produced the
    /// original bug.
    @Test("a header missing every cookie maugclib requires still parses")
    func noNameIsRequired() throws {
        let cookies = try #require(SessionCookies(header: "__Secure-1PSID=a; SAPISID=b"))
        #expect(cookies.count == 2)
        #expect(cookies["SID"] == nil)
    }

    /// The inverse, and the one that matters: holding exactly maugclib's five is
    /// not a signal of anything. There is no `isComplete`, and this test exists
    /// so that adding one is a visible decision rather than a quiet convenience.
    @Test("maugclib's five carry no special status")
    func maugclibsFiveAreNotSpecial() throws {
        let five = "COMPASS=a; SSID=b; SID=c; OSID=d; HSID=e"
        let cookies = try #require(SessionCookies(header: five))
        #expect(cookies.count == 5)
        #expect(cookies.headerValue == five)
    }

    // MARK: - Malformed input

    @Test("an empty or whitespace-only header is nil, not an empty session")
    func emptyIsNil() {
        #expect(SessionCookies(header: "") == nil)
        #expect(SessionCookies(header: "   ") == nil)
        #expect(SessionCookies(header: ";;") == nil)
    }

    @Test("a fragment with no equals sign is skipped, not stored as a nameless cookie")
    func fragmentWithoutEqualsIsSkipped() throws {
        let cookies = try #require(SessionCookies(header: "SID=a; garbage; SSID=b"))
        #expect(cookies.count == 2)
        #expect(cookies.headerValue == "SID=a; SSID=b")
    }

    @Test("a cookie with an empty value is kept, because the server sends those")
    func emptyValuesAreKept() throws {
        let cookies = try #require(SessionCookies(header: "SID=a; OTZ=; SSID=b"))
        #expect(cookies.count == 3)
        #expect(cookies["OTZ"] == "")
    }

    // MARK: - The hard rule

    /// `Never print cookie values, tokens, or message content.` Report names,
    /// counts and lengths — the things that make a bug diagnosable — and never
    /// the credential itself.
    @Test("the description reports names and lengths but never a single value")
    func descriptionNeverLeaksAValue() throws {
        let cookies = try #require(SessionCookies(header: "SID=supersecret; SSID=alsosecret"))
        let rendered = "\(cookies)"
        #expect(!rendered.contains("supersecret"))
        #expect(!rendered.contains("alsosecret"))
        #expect(rendered.contains("SID"))
        #expect(rendered.contains("2 cookies"))
    }

    /// The byte size is what distinguishes "I captured the whole header" from
    /// "I captured the five names in the reference implementation": a real one
    /// is around 4990 bytes.
    @Test("the byte count is reported so a truncated capture is visible")
    func byteCountIsReported() throws {
        let cookies = try #require(SessionCookies(header: Self.realisticHeader))
        #expect(cookies.byteCount == Self.realisticHeader.utf8.count)
    }
}
