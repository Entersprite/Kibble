import Foundation

/// A captured `Cookie` header, kept opaque.
///
/// ## Why this is a sequence and not a record of named fields
///
/// The reference implementation declares five required cookies — `COMPASS`,
/// `SSID`, `SID`, `OSID`, `HSID` — and models them as a five-field record.
/// **Those five do not authenticate.** Sending exactly them returns HTTP 200
/// with a sign-in shell, which is indistinguishable from a credential rejection
/// unless you parse `WizGlobalData`. A session that worked carried 26 cookies
/// and roughly 4990 bytes, including the `__Secure-1PSID`, `__Secure-1PSIDTS`,
/// `SAPISID` and `APISID` families that the list omits.
///
/// The lesson generalises past those specific names: the set is Google's to
/// change, and any list compiled here is a guess with a shelf life. So this
/// type captures **every** cookie for the domain and replays it verbatim. It
/// privileges no name, validates no name, and deliberately offers no
/// `isComplete` — there is nothing it could honestly mean.
///
/// ## What this type is not
///
/// It is not a cookie jar. Each cookie keeps the domain and path it was captured with, so a request can be
/// sent only what a browser would send (`findings.md` §52.9), but there is no expiry here and no
/// `Set-Cookie` handling: `register?ignore_compass_cookie=1` does return
/// `Set-Cookie` and does rotate `COMPASS` server-side, so a live session needs
/// somewhere to apply that — but that belongs with the transport that sees the
/// responses, not in the value the credential store hands out. Captured headers
/// are also short-lived, so callers must expect a stored one to go stale and
/// must detect it through `WizGlobalData` rather than by trusting a status code.
public struct SessionCookies: Sendable, Hashable, CustomStringConvertible {
    /// One cookie, exactly as captured. `name` and `value` are never
    /// interpreted; the pair exists so the header can be rebuilt and so a
    /// rotation can find what it needs to replace.
    public struct Cookie: Sendable, Hashable {
        public let name: String
        public let value: String
        /// Where a browser would send it, spelled as the cookie store spelled
        /// it: a leading dot is a domain cookie (`.google.com`), none is
        /// host-only (`chat.google.com`). `nil` for a cookie captured before
        /// domains were kept, which goes to `CookieScope.chat`'s host only
        /// (`findings.md` §52.9).
        public let domain: String?
        /// The cookie's path, `/` when the store reported none. `nil` exactly
        /// when `domain` is.
        public let path: String?

        public init(name: String, value: String, domain: String? = nil, path: String? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
        }
    }

    /// Ordered, because the capture's order is the browser's order and there is
    /// no reason to believe reordering is free. Duplicates are kept for the same
    /// reason: a browser may legitimately send one name twice, and quietly
    /// dropping one would be an edit to a credential.
    public let cookies: [Cookie]

    public init?(cookies: [Cookie]) {
        guard !cookies.isEmpty else { return nil }
        self.cookies = cookies
    }

    public var count: Int {
        cookies.count
    }

    /// How many cookies know their domain. A session stored before §52.9
    /// has none; one captured since has all. Reported as a count only.
    public var domainCount: Int {
        cookies.count { $0.domain != nil }
    }

    /// The size of the header this will produce. A real capture is around 4990
    /// bytes, so this is the cheapest way to see that a capture was truncated or
    /// that only a handful of names were taken.
    public var byteCount: Int {
        headerValue.utf8.count
    }

    /// The value for a `Cookie` request header, rebuilt in capture order.
    public var headerValue: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The first value for `name`, for the narrow cases that genuinely need one
    /// — a rotation replacing `COMPASS`, a test. Reaching for this to decide
    /// whether a session is valid is the mistake this type exists to prevent.
    public subscript(name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    /// Names, counts and lengths — never a value. This type is a credential and
    /// will reach a log line eventually; `Never print cookie values, tokens, or
    /// message content` has to hold when it does.
    public var description: String {
        let names = cookies.map(\.name).joined(separator: ", ")
        return "SessionCookies(\(count) cookies, \(byteCount) bytes: \(names))"
    }
}

// MARK: - Parsing

public extension SessionCookies {
    /// Parses a captured `Cookie` header.
    ///
    /// Returns `nil` when nothing usable is present, so "no session" is a
    /// distinct state from "a session with no cookies in it", which cannot
    /// happen.
    ///
    /// Splitting is on the **first** `=` only: values are base64 and carry
    /// their own padding, so `__Secure-1PSIDCC=abc==` has the value `abc==`. A
    /// fragment with no `=` at all is skipped rather than stored under an empty
    /// name — it cannot be replayed meaningfully either way, and a nameless
    /// entry would corrupt the rebuilt header.
    init?(header: String) {
        let parsed = header
            .split(separator: ";", omittingEmptySubsequences: true)
            .compactMap { fragment -> Cookie? in
                let trimmed = fragment.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: "=") else { return nil }
                let name = String(trimmed[trimmed.startIndex ..< separator])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return Cookie(
                    name: name,
                    value: String(trimmed[trimmed.index(after: separator)...])
                )
            }
        self.init(cookies: parsed)
    }
}

// MARK: - Where each cookie is sent

public extension SessionCookies.Cookie {
    /// Whether a browser would send this cookie with a request to `url`
    /// (`findings.md` §52.9). `https` only: every request in this protocol is
    /// TLS, and `Secure` is not stored, so a cookie is treated as secure.
    func isSent(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return false }
        guard let domain else {
            // Captured before domains were kept, for this host alone.
            return host.lowercased() == CookieScope.chat.host
        }
        let requestPath = url.path(percentEncoded: false)
        return CookieScope(host: host, path: requestPath.isEmpty ? "/" : requestPath, isSecure: true)
            .admits(domain: domain, path: path ?? "/", isSecure: true)
    }
}

public extension SessionCookies {
    /// The `Cookie` header for one request: the cookies `url` admits, in
    /// capture order, minus `names`. `nil` when none is admitted, so a caller
    /// sends no header at all rather than an empty one.
    func header(for url: URL, withholding names: Set<String> = []) -> String? {
        Self.header(cookies, for: url, withholding: names)
    }

    /// The same rule over a jar's live list, so `CookieJar` and a snapshot can
    /// never disagree about it.
    internal static func header(
        _ cookies: [Cookie],
        for url: URL,
        withholding names: Set<String>
    ) -> String? {
        let sent = cookies.filter { !names.contains($0.name) && $0.isSent(to: url) }
        guard !sent.isEmpty else { return nil }
        return sent.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
