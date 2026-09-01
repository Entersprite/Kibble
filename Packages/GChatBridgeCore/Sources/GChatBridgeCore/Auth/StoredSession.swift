import Foundation

/// A captured credential, plus the two facts about it that decide when someone
/// has to sign in again.
///
/// ## Why a stored session is more than its cookies
///
/// `SessionCookies` is deliberately opaque: it privileges no name and offers no
/// `isComplete`, because there is nothing such a flag could honestly mean. That
/// is right for the value a transport replays, and not enough for the value a
/// credential store persists — something has to answer *should we still be
/// using this*, and the answer cannot come from the cookie list alone.
///
/// Two attributes carry it:
///
/// - `capturedAt`, because a session's age is the only thing known about it
///   before a request is made.
/// - `expiresAt`, the **earliest** expiry among the cookies being replayed.
///   `COMPASS` expires in nine days where most of the set lasts 399
///   (`findings.md` §17.2), so the shortest fuse is what actually governs, and
///   averaging or taking the longest would describe a session that has already
///   stopped working.
///
/// ## What this cannot tell you
///
/// **Not expired does not mean valid.** `findings.md` §11 watched a header stop
/// authenticating minutes after capture, long inside every stated expiry — a
/// session can be revoked server-side, rotated out from under you, or
/// invalidated by another client. Expiry is a lower bound on trouble and never
/// a guarantee of health, and the only test that settles it is a request whose
/// `WizGlobalData` comes back signed in. This type exists to skip work that is
/// certainly pointless, not to authorise work that will certainly succeed.
public struct StoredSession: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The cookies to replay, exactly as captured.
    public let credential: SessionCookies

    /// When the capture was taken.
    public let capturedAt: Date

    /// The earliest expiry among the captured cookies, or `nil` when every one
    /// of them is a session cookie with no stated expiry.
    public let expiresAt: Date?

    public init(credential: SessionCookies, capturedAt: Date, expiresAt: Date?) {
        self.credential = credential
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
    }

    /// Whether the stated expiry has passed.
    ///
    /// Inclusive of the instant itself, and `false` when nothing was stated —
    /// an absent expiry is an absence of evidence, and refusing to use a
    /// session on that basis would refuse every session cookie set there is.
    public func isExpired(at instant: Date) -> Bool {
        guard let expiresAt else { return false }
        return instant >= expiresAt
    }

    /// How long the stated expiry leaves, floored at zero, or `nil` when
    /// nothing was stated.
    ///
    /// Floored rather than allowed to go negative so a caller rendering "signs
    /// you out in N" cannot print a negative countdown for a session that is
    /// simply finished.
    public func remainingLifetime(at instant: Date) -> TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(instant))
    }

    /// How long ago the capture was taken.
    public func age(at instant: Date) -> TimeInterval {
        instant.timeIntervalSince(capturedAt)
    }

    /// Names, counts and dates — never a value, because this type is a
    /// credential and will reach a log line eventually.
    public var description: String {
        let expiry = expiresAt.map { "expires \($0.formatted(.iso8601))" } ?? "no stated expiry"
        return "StoredSession(captured \(capturedAt.formatted(.iso8601)), \(expiry), \(credential))"
    }
}

// MARK: - Coding

/// Hand-written rather than synthesised, for the same reason the seam's frames
/// are: this is a format written to disk by one version of the app and read by
/// the next. `SessionCookies` also has a failable initialiser guarding a
/// non-empty invariant, and synthesis would route around it and produce a
/// credential the type says cannot exist.
public extension StoredSession {
    private enum CodingKeys: String, CodingKey {
        case cookies
        case capturedAt
        case expiresAt
    }

    private struct CookiePair: Codable {
        let name: String
        let value: String
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pairs = try container.decode([CookiePair].self, forKey: .cookies)
        guard let credential = SessionCookies(
            cookies: pairs.map { SessionCookies.Cookie(name: $0.name, value: $0.value) }
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cookies,
                in: container,
                debugDescription: "a stored session with no cookies in it is not a session"
            )
        }
        try self.init(
            credential: credential,
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            credential.cookies.map { CookiePair(name: $0.name, value: $0.value) },
            forKey: .cookies
        )
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
    }
}
