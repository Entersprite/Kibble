import Foundation
import GChatBridgeCore

/// One cookie as a login capture found it.
///
/// Plain values rather than the platform's cookie type, for the same reason
/// `LocalBridgeBackend.capturing(header:)` exists: a host that constructs these
/// does not have to import `GChatBridgeCore`, and this package stays the only
/// one that does. It is also what makes the partitioning below testable without
/// a web view, a Google account or a network.
public struct CapturedCookie: Sendable, Hashable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    public let expiresAt: Date?

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        isSecure: Bool,
        isHTTPOnly: Bool,
        expiresAt: Date?
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expiresAt = expiresAt
    }
}

/// A login capture, split into the credential that will be replayed and the
/// report of what was found.
///
/// ## Two outputs, because they have opposite rules
///
/// `session` carries values and must never be printed. `report` carries none
/// and is meant to be pasted into an issue. Producing them from one
/// partitioning is what stops the two disagreeing about what was captured — a
/// report that described a different cookie set than the one being sent would
/// be worse than no report.
///
/// ## Why the excluded cookies stay in the report
///
/// A capture drains several hosts' cookies at once and most of them must not go
/// to Chat (`CookieScope`). Dropping them silently would make the *next*
/// scoping defect invisible, and the first one already shipped. The report
/// keeps every cookie the store held and marks which ones were sent.
public struct CookieCapture: Sendable {
    /// Safe to display, log and paste. Names, counts and lengths only.
    public let report: CookieCaptureReport

    /// The credential to persist, or `nil` when nothing in the capture may be
    /// replayed to Chat — which is a different thing from a capture that
    /// produced no cookies at all, and both are handled the same way by a
    /// caller: there is nothing to store.
    public let session: StoredSession?

    /// The origin the capture is scoped to. Fixed rather than injected: a
    /// capture for a host this protocol never talks to is not a thing this type
    /// should make expressible.
    static let scope = CookieScope.chat

    public init(
        cookies: [CapturedCookie],
        capturedAt: Date,
        pageURL: String,
        pageTitle: String
    ) {
        func admits(_ cookie: CapturedCookie) -> Bool {
            Self.scope.admits(
                domain: cookie.domain,
                path: cookie.path,
                isSecure: cookie.isSecure
            )
        }
        let admitted = cookies.filter(admits)

        report = CookieCaptureReport(
            capturedAt: capturedAt,
            pageURL: pageURL,
            pageTitle: pageTitle,
            entries: cookies.map { cookie in
                CookieCaptureReport.Entry(
                    name: cookie.name,
                    domain: cookie.domain,
                    path: cookie.path,
                    valueLength: cookie.value.count,
                    isHTTPOnly: cookie.isHTTPOnly,
                    isSecure: cookie.isSecure,
                    expiresInDays: Self.days(until: cookie.expiresAt, from: capturedAt),
                    // Per cookie, not per name: one real capture held five
                    // `OTZ` cookies on five different hosts, and only one of
                    // them belongs to Chat.
                    isInScope: admits(cookie)
                )
            }
        )

        session = SessionCookies(
            cookies: admitted.map { SessionCookies.Cookie(name: $0.name, value: $0.value) }
        ).map { credential in
            StoredSession(
                credential: credential,
                capturedAt: capturedAt,
                // The shortest fuse governs. `COMPASS` lasts nine days where
                // most of the set lasts 399, so anything but the minimum would
                // describe a session that stops working well before it claims
                // to. Session cookies contribute no expiry rather than an
                // immediate one - they die with the browser, not with a clock.
                expiresAt: admitted.compactMap(\.expiresAt).min()
            )
        }
    }

    /// Days until expiry, or `nil` for a session cookie.
    ///
    /// Clamped rather than converted directly. `Int(someDouble)` traps on NaN
    /// and on anything outside `Int`'s range, and an expiry date is data from a
    /// server - exactly the kind of value that must not be able to kill a
    /// capture someone just spent a two-factor login on. The data store is
    /// non-persistent by design, so a crash here costs a second login.
    static func days(until expiry: Date?, from now: Date) -> Int? {
        guard let expiry else { return nil }
        let days = expiry.timeIntervalSince(now) / 86400
        guard days.isFinite else { return nil }
        return Int(min(max(days, -3_650_000), 3_650_000))
    }
}
