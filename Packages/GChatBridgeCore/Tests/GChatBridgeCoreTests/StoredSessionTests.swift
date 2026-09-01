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
}
