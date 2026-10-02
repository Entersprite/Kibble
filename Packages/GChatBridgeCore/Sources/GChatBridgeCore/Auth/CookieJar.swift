import Foundation

/// The live cookie state for one session.
///
/// ## Why this exists, with numbers
///
/// Cookies rotate *during* a session. Over one 100-second observed run:
///
/// - `SIDCC`, `__Secure-1PSIDCC` and `__Secure-3PSIDCC` each rotated on **every**
///   long-poll reopen — four times apiece;
/// - `COMPASS` rotated once on `register` and **grew from 823 to 1029
///   characters**.
///
/// So a transport that replays the captured header forever is replaying a
/// credential that went stale seconds after capture. That is not a theoretical
/// risk: it is the flaw the early probes had, and the most likely reason an
/// earlier attempt received no events at all while reporting a healthy
/// handshake.
///
/// `SessionCookies` is the immutable snapshot a `CredentialStore` hands out.
/// `CookieJar` is the mutable thing a transport carries for the life of a
/// connection, and `snapshot` is what should be written back so the next launch
/// starts from rotated values.
///
/// ## What this deliberately is not
///
/// Not a full RFC 6265 implementation: no expiry clock, no `SameSite`, no
/// public-suffix list. It does keep each cookie's domain and path, send each
/// request only what they admit, and store a `Set-Cookie` where its `Domain`
/// and `Path` say, because sending a host a cookie a browser would not is how
/// every file download was refused (`findings.md` §52.9). The one expiry rule
/// that *is* honoured is deletion, because replaying a cookie the server has
/// just retired is worse than dropping it.
struct CookieJar: Sendable, CustomStringConvertible {
    private var cookies: [SessionCookies.Cookie]
    private(set) var rotations: [CookieRotation] = []

    init(_ cookies: SessionCookies) {
        self.cookies = cookies.cookies
    }

    var count: Int {
        cookies.count
    }

    /// The value for a `Cookie` request header, in the order the cookies were
    /// captured — rotations replace in place rather than moving to the end.
    var headerValue: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The `Cookie` header for one request: what `url` admits, minus `names`
    /// (`SessionCookies.header(for:withholding:)`, the one rule). `nil` when
    /// nothing is admitted.
    func header(for url: URL, withholding names: Set<String> = []) -> String? {
        SessionCookies.header(cookies, for: url, withholding: names)
    }

    subscript(name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    /// The current state as an immutable snapshot, for persisting back to the
    /// credential store. `nil` when the jar has been emptied, which keeps "no
    /// session" distinct from "a session with nothing in it".
    var snapshot: SessionCookies? {
        SessionCookies(cookies: cookies)
    }

    /// Names, counts and lengths only — never a value.
    var description: String {
        "CookieJar(\(count) cookies, \(rotations.count) rotations: "
            + cookies.map(\.name).joined(separator: ", ") + ")"
    }
}

// MARK: - Absorbing Set-Cookie

extension CookieJar {
    /// Applies every `Set-Cookie` value from one response from `url`.
    ///
    /// Takes an array because a single response rotates several at once — the
    /// observed run rotated three in one reopen. Any header representation that
    /// collapses repeated names would silently drop two of the three, which is
    /// why `HTTPResponse` preserves them.
    mutating func absorb(setCookie values: [String], from url: URL) {
        for value in values {
            apply(setCookie: value, from: url)
        }
    }

    private mutating func apply(setCookie raw: String, from url: URL) {
        guard let incoming = Self.parse(raw), let scope = Self.scope(of: incoming, from: url) else { return }
        let name = incoming.name
        let value = incoming.value
        // A cookie captured before domains were kept is matched by name, and
        // keeps `nil`: rotation never invents a domain (findings.md §52.9).
        let existing = cookies.firstIndex { $0.name == name && $0.domain == nil }
            ?? cookies.firstIndex { $0.name == name && $0.domain == scope.domain && $0.path == scope.path }
        if incoming.isDeletion {
            guard let existing else { return }
            rotations.append(CookieRotation(
                name: name, change: .deleted, oldLength: cookies[existing].value.count, newLength: 0
            ))
            cookies.remove(at: existing)
            return
        }
        guard let existing else {
            rotations.append(CookieRotation(name: name, change: .added, oldLength: 0, newLength: value.count))
            cookies.append(SessionCookies.Cookie(
                name: name,
                value: value,
                domain: scope.domain,
                path: scope.path
            ))
            return
        }
        let old = cookies[existing]
        guard old.value != value else { return } // re-sending the same value is not a rotation
        rotations.append(CookieRotation(
            name: name, change: .rotated, oldLength: old.value.count, newLength: value.count
        ))
        // Replaced in place: the capture order is the browser's order, and a
        // rotation is not a reason to reorder the header.
        cookies[existing] = SessionCookies.Cookie(
            name: name,
            value: value,
            domain: old.domain,
            path: old.path
        )
    }

    /// Where a `Set-Cookie` from `url` is stored (RFC 6265 §5.3): host-only
    /// for that host with no `Domain`, otherwise the dotted domain, provided
    /// the host domain-matches it. `nil` means the cookie is ignored whole: a
    /// host may not set a cookie for another site, and a single-label domain
    /// (`com`) stands in for the public-suffix check this client has no list
    /// for. A `Path` that is absent or not absolute is the root.
    private static func scope(of incoming: Incoming, from url: URL) -> (domain: String, path: String)? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let path = incoming.path.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/"
        guard let attribute = incoming.domain else { return (host, path) }
        let bare = String(attribute.lowercased().drop { $0 == "." })
        guard bare.contains("."), host == bare || host.hasSuffix("." + bare) else { return nil }
        return ("." + bare, path)
    }

    /// Splits a `Set-Cookie` value into the pair to store, its `Domain` and
    /// `Path`, and whether it is a deletion.
    ///
    /// A deletion is an **empty value plus** either an expiry in the past or
    /// `Max-Age` of zero or less. The two halves both matter: `OTZ=` with no
    /// expiry is a live cookie with an empty value and has to survive, while
    /// `COMPASS=; Expires=Thu, 01 Jan 1970` must not be replayed as `COMPASS=`.
    private struct Incoming {
        let name: String
        let value: String
        let isDeletion: Bool
        /// The attribute as sent; empty is absent (RFC 6265 §5.2.3).
        let domain: String?
        let path: String?
    }

    private static func parse(_ raw: String) -> Incoming? {
        let segments = raw.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let pair = segments.first, let separator = pair.firstIndex(of: "=") else {
            return nil
        }
        let name = String(pair[pair.startIndex ..< separator]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let value = String(pair[pair.index(after: separator)...])
        let attributes = segments.dropFirst()

        let deleted = value.isEmpty && attributes.contains { isExpiry($0) }
        return Incoming(
            name: name,
            value: value,
            isDeletion: deleted,
            domain: attribute("domain", in: attributes),
            path: attribute("path", in: attributes)
        )
    }

    /// The last value of a named attribute, as RFC 6265 §5.3 takes the last
    /// one; `nil` when absent or empty.
    private static func attribute(_ name: String, in attributes: ArraySlice<String>) -> String? {
        let prefix = name + "="
        let value = attributes.last { $0.lowercased().hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        return value?.isEmpty == false ? value : nil
    }

    private static func isExpiry(_ attribute: String) -> Bool {
        let lowered = attribute.lowercased()
        if lowered.hasPrefix("max-age") {
            let age = lowered.drop { $0 != "=" }.dropFirst()
            return (Int(age.trimmingCharacters(in: .whitespaces)) ?? 1) <= 0
        }
        // Any explicit Expires on an already-empty value is a clear, and the
        // exact date does not need parsing to know that: a server does not send
        // an empty value with a future expiry.
        return lowered.hasPrefix("expires")
    }
}

// MARK: - Rotation log

/// What happened to one cookie, recorded as lengths rather than values.
///
/// This log is evidence: it is what turned "the header went stale somehow" into
/// "`COMPASS` grew by 206 characters on `register`", which in turn is the best
/// explanation available for a probe breaking a browser's Chat session.
///
/// Declared at file scope rather than inside `CookieJar` so that its own `Change`
/// enum is not nested two deep.
struct CookieRotation: Sendable, Hashable, CustomStringConvertible {
    enum Change: String, Sendable, Hashable {
        case added
        case rotated
        case deleted
    }

    let name: String
    let change: Change
    let oldLength: Int
    let newLength: Int

    var description: String {
        "\(name) \(change.rawValue) \(oldLength) -> \(newLength) chars"
    }
}
