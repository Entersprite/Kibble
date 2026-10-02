import Foundation

/// One request's origin, and the rule for which captured cookies may be
/// replayed to it.
///
/// ## Why this exists
///
/// A login capture drains a browser-shaped cookie store, and such a store holds
/// cookies for *several* Google hosts at once. The first capture this repo
/// shipped kept everything whose domain contained `google.com`, which swept in
/// `accounts.google.com`-only credentials (`LSID`, `SMSV`, `__Host-GAPS`,
/// `__Host-1PLSID`) and `workspace.google.com` analytics (`__utma`, `_ga`) and
/// sent them all to Chat. It also collected five `OTZ` cookies, one per host,
/// which collapse to a single name in a flat header — so four of the five were
/// being silently discarded anyway.
///
/// **It authenticated regardless** (`findings.md` §17.3), so this is a latent
/// defect rather than a live one. It is still worth removing: a `__Host-`
/// prefixed cookie is host-locked *by definition*, and shipping one to another
/// host is the kind of detail a server begins rejecting without an
/// announcement — at which point the symptom is a login that stops working and
/// looks exactly like bad credentials.
///
/// ## What this is not
///
/// Not an RFC 6265 implementation. There is no expiry clock, no `SameSite`, no
/// public-suffix list, and no cookie ordering. It answers one question —
/// *would a browser send this cookie to this origin* — for the two attributes
/// that actually partitioned the observed capture, plus `Secure` because it is
/// free. `CookieJar` remains the thing that tracks a live session; this
/// decides what a cookie may reach, and at more than one moment: what a
/// capture may persist at all (`CookieCapture`), what a domain-less legacy
/// cookie is sent on every later request (`SessionCookies.Cookie.isSent(to:)`),
/// and which `Set-Cookie` answers may rotate one (`CookieJar.apply`'s
/// legacy-scope guard) — not only what first goes into the jar. A domain
/// without a leading dot is host-only, the way a cookie store spells it; a
/// `Set-Cookie` attribute is normalised to the dotted spelling before it
/// reaches here (`CookieJar`).
public struct CookieScope: Sendable, Hashable {
    /// The host a request is going to, e.g. `chat.google.com`. Compared
    /// case-insensitively; a stored value keeps whatever case it was given.
    public let host: String

    /// The path a request is going to. A cookie's own path must be this or an
    /// ancestor of it.
    public let path: String

    /// Whether the request is over TLS. A `Secure` cookie is withheld when it
    /// is not.
    public let isSecure: Bool

    public init(host: String, path: String, isSecure: Bool) {
        self.host = host
        self.path = path
        self.isSecure = isSecure
    }

    /// The origin every request in this protocol is aimed at.
    ///
    /// Root path on purpose: it is the *least* selective request path, so a
    /// cookie admitted here is admitted for every deeper Chat URL as well.
    /// Scoping tighter would drop cookies that later requests legitimately
    /// need. Used at capture time to decide what may be persisted at all
    /// (`CookieCapture`) - and, past capture, as the one host a domain-less
    /// legacy cookie is still sent to on every request
    /// (`SessionCookies.Cookie.isSent(to:)`) and the one a `Set-Cookie`
    /// answer must cover to rotate such a cookie at all
    /// (`CookieJar.apply`'s legacy-scope guard). Not only what first goes
    /// into the jar.
    public static let chat = CookieScope(host: "chat.google.com", path: "/", isSecure: true)

    /// Whether a cookie with these attributes would be sent to this origin.
    ///
    /// Takes the three attributes as plain values rather than any cookie type:
    /// this package must compile where the platform's cookie types do not
    /// exist, and the caller that has them is a host, not the core.
    public func admits(domain: String, path cookiePath: String, isSecure cookieIsSecure: Bool) -> Bool {
        guard !cookieIsSecure || isSecure else { return false }
        return domainMatches(domain) && pathMatches(cookiePath)
    }

    /// RFC 6265 §5.1.3, minus the IP-address case, with the cookie *store's*
    /// spelling of the host-only flag (§5.3 step 6): a leading dot is a domain
    /// cookie, sent to the domain and its subdomains; no dot is host-only,
    /// sent to that exact host (`findings.md` §52.9).
    ///
    /// The label boundary is load-bearing rather than pedantic. `hasSuffix`
    /// alone would admit a cookie scoped to `oogle.com` for a request to
    /// `chat.google.com`, which is a credential handed to whoever registers the
    /// near-miss. The suffix has to begin after a dot.
    private func domainMatches(_ domain: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        guard domain.hasPrefix(".") else {
            return !domain.isEmpty && host == domain
        }
        let candidate = domain.drop { $0 == "." }
        guard !candidate.isEmpty else { return false }
        return host == candidate || host.hasSuffix("." + candidate)
    }

    /// RFC 6265 §5.1.4: the cookie's path is the request path, or an ancestor
    /// of it that ends at a separator.
    private func pathMatches(_ cookiePath: String) -> Bool {
        // An unset path is the root, not the empty string. A store that reports
        // "" would otherwise match nothing at all.
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard path != cookiePath else { return true }
        guard path.hasPrefix(cookiePath) else { return false }
        // "/u" is a prefix of "/underscore" and is not an ancestor of it.
        return cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")
    }
}
