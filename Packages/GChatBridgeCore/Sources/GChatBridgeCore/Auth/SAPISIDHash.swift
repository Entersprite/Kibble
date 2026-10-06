import Foundation

/// The `Authorization` header Google's web clients send to their
/// `*.clients6.google.com` APIs: a proof of holding the `SAPISID` cookie.
///
/// `<timestamp>_<SHA-1 of "<timestamp> <cookie> <origin>">`, the timestamp in
/// seconds. That much is widely documented. Which variant a host accepts is
/// not, and the owner's capture could not show it, because a sanitized HAR
/// drops `Authorization`. So the probe tries each (`findings.md` §57) `[Verify]`.
///
/// SHA-1 is passed in: this package compiles on Linux and imports
/// Foundation only, so it has no hash of its own.
public enum SAPISIDHash {
    public enum Variant: String, CaseIterable, Sendable {
        /// `SAPISIDHASH` alone, from `SAPISID`.
        case sapisidOnly
        /// Plus `SAPISID1PHASH` from `__Secure-1PAPISID` and `SAPISID3PHASH`
        /// from `__Secure-3PAPISID`.
        case firstAndThirdParty
        /// All three names carrying the one `SAPISID` hash.
        case sameHashThrice
    }

    /// What every variant hashes: the jar, the request's URL (which picks the
    /// cookies), the page's origin and the time in seconds.
    public struct Input: Sendable {
        public let cookies: [SessionCookies.Cookie]
        public let url: URL
        public let origin: String
        public let timestamp: Int

        public init(cookies: [SessionCookies.Cookie], url: URL, origin: String, timestamp: Int) {
            self.cookies = cookies
            self.url = url
            self.origin = origin
            self.timestamp = timestamp
        }
    }

    /// `nil` when the cookie a variant needs is not one this URL's host would
    /// be sent.
    public static func authorization(
        _ variant: Variant,
        for input: Input,
        sha1: (String) -> String
    ) -> String? {
        func hash(_ name: String) -> String? {
            value(of: name, in: input.cookies, for: input.url).map { cookie in
                "\(input.timestamp)_\(sha1("\(input.timestamp) \(cookie) \(input.origin)"))"
            }
        }
        guard let primary = hash("SAPISID") else { return nil }
        switch variant {
        case .sapisidOnly:
            return "SAPISIDHASH \(primary)"
        case .firstAndThirdParty:
            guard let first = hash("__Secure-1PAPISID"),
                  let third = hash("__Secure-3PAPISID") else { return nil }
            return "SAPISIDHASH \(primary) SAPISID1PHASH \(first) SAPISID3PHASH \(third)"
        case .sameHashThrice:
            return "SAPISIDHASH \(primary) SAPISID1PHASH \(primary) SAPISID3PHASH \(primary)"
        }
    }

    /// The named cookie as this URL's host would be sent it: scoped like a
    /// browser, so a same-named cookie for another host is never hashed.
    public static func value(of name: String, in cookies: [SessionCookies.Cookie], for url: URL) -> String? {
        guard let host = url.host else { return nil }
        let scope = CookieScope(host: host, path: url.path.isEmpty ? "/" : url.path, isSecure: true)
        return cookies.first { cookie in
            cookie.name == name
                && scope.admits(domain: cookie.domain ?? host, path: cookie.path ?? "/", isSecure: true)
        }?.value
    }
}
