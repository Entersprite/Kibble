import Foundation
import Testing
@testable import GChatBridgeCore

/// The credential as it is persisted, and what it can honestly say about its
/// own freshness.
struct StoredSessionTests {
    private let now = Date(timeIntervalSince1970: 1_788_166_800)

    private func session(
        expiresAt: Date?,
        capturedAt: Date? = nil,
        names: [String] = ["COMPASS", "OSID"]
    ) -> StoredSession {
        StoredSession(
            credential: SessionCookies(cookies: names.map {
                SessionCookies.Cookie(name: $0, value: "value-for-\($0)")
            })!,
            capturedAt: capturedAt ?? now,
            expiresAt: expiresAt
        )
    }

    // MARK: - Round trip

    /// This is what goes into the Keychain, so a field lost in coding is a
    /// credential that comes back subtly wrong rather than absent.
    @Test func itSurvivesACodingRoundTrip() throws {
        let original = session(expiresAt: now.addingTimeInterval(9 * 86400))
        let decoded = try JSONDecoder().decode(
            StoredSession.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test func aSessionWithNoExpirySurvivesTheRoundTrip() throws {
        let original = session(expiresAt: nil)
        let decoded = try JSONDecoder().decode(
            StoredSession.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.expiresAt == nil)
    }

    @Test func everyCookieSurvivesTheRoundTripInOrder() throws {
        let original = session(expiresAt: nil, names: ["SAPISID", "COMPASS", "__Secure-1PSID"])
        let decoded = try JSONDecoder().decode(
            StoredSession.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded.credential.cookies.map(\.name) == ["SAPISID", "COMPASS", "__Secure-1PSID"])
    }

    // MARK: - Freshness

    @Test func aSessionPastItsExpiryIsExpired() {
        #expect(session(expiresAt: now.addingTimeInterval(-1)).isExpired(at: now))
    }

    @Test func aSessionBeforeItsExpiryIsNot() {
        #expect(!session(expiresAt: now.addingTimeInterval(1)).isExpired(at: now))
    }

    /// Not "fresh". A cookie set can be revoked server-side long before its
    /// stated expiry — `findings.md` §11 watched exactly that happen — so the
    /// only honest reading of an unexpired session is *not yet known to be
    /// expired*.
    @Test func aSessionWithNoStatedExpiryIsNotClaimedExpired() {
        #expect(!session(expiresAt: nil).isExpired(at: now))
    }

    @Test func expiryIsInclusiveOfTheInstantItself() {
        #expect(session(expiresAt: now).isExpired(at: now))
    }

    @Test func remainingLifetimeIsTheGapToExpiry() {
        let stored = session(expiresAt: now.addingTimeInterval(9 * 86400))
        #expect(stored.remainingLifetime(at: now) == 777_600.0) // nine days
    }

    @Test func remainingLifetimeIsNilWithoutAStatedExpiry() {
        #expect(session(expiresAt: nil).remainingLifetime(at: now) == nil)
    }

    @Test func remainingLifetimeDoesNotGoNegative() {
        let stored = session(expiresAt: now.addingTimeInterval(-100))
        #expect(stored.remainingLifetime(at: now) == 0.0)
    }

    @Test func ageIsMeasuredFromCapture() {
        let stored = session(expiresAt: nil, capturedAt: now.addingTimeInterval(-3600))
        #expect(stored.age(at: now) == 3600.0)
    }

    // MARK: - Never printing a credential

    /// This type will reach a log line eventually. When it does, it must carry
    /// names and counts and nothing else.
    @Test func describingItLeaksNoValue() {
        let described = String(describing: session(expiresAt: now))
        #expect(described.contains("COMPASS"))
        #expect(!described.contains("value-for-COMPASS"))
    }

    // MARK: - Domains (findings.md §52.9)

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    @Test("a session's domains and paths survive the round trip")
    func domainsRoundTrip() throws {
        let original = try StoredSession(
            credential: #require(SessionCookies(cookies: [
                SessionCookies.Cookie(name: "SID", value: "lowercasesid", domain: ".google.com", path: "/"),
                SessionCookies.Cookie(
                    name: "COMPASS",
                    value: "lowercasecompass",
                    domain: "chat.google.com",
                    path: "/"
                )
            ])),
            capturedAt: now,
            expiresAt: nil
        )
        let decoded = try Self.decoder.decode(StoredSession.self, from: Self.encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.credential.domainCount == 2)
    }

    /// A literal blob in the format every session stored before §52.9 has,
    /// not one this build encoded: the test that it still decodes has to
    /// start from bytes the new code never wrote.
    @Test("a session stored before domains were kept decodes, with none")
    func legacyBlobDecodes() throws {
        let blob = Data(#"{"cookies":[{"name":"SID","value":"v"}],"capturedAt":1788166800}"#.utf8)
        let decoded = try Self.decoder.decode(StoredSession.self, from: blob)
        #expect(decoded.credential.cookies == [SessionCookies.Cookie(name: "SID", value: "v")])
        #expect(decoded.credential.cookies.first?.domain == nil)
        #expect(decoded.credential.domainCount == 0)
    }

    @Test("a session without domains encodes without the keys")
    func legacyEncodesWithoutKeys() throws {
        let text = try String(decoding: Self.encoder.encode(session(expiresAt: nil)), as: UTF8.self)
        #expect(!text.contains("domain"))
        #expect(!text.contains("path"))
    }
}
