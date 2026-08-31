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
/// It is not a cookie jar. There is no domain, path or expiry here, and no
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

        public init(name: String, value: String) {
            self.name = name
            self.value = value
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
