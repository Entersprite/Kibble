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
/// Not an RFC 6265 implementation. There is no domain or path matching and no
/// expiry clock: every cookie here belongs to one host and is replayed to that
/// host, which is exactly what the reference implementation does by flattening
/// them the same way. The one attribute that *is* honoured is deletion, because
/// replaying a cookie the server has just retired is worse than dropping it.
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

    /// The header without the named cookies, for a host that a browser would
    /// not send them to. The jar keeps no domains, so the caller names them.
    func headerValue(withholding names: Set<String>) -> String {
        cookies.filter { !names.contains($0.name) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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
    /// Applies every `Set-Cookie` value from one response.
    ///
    /// Takes an array because a single response rotates several at once — the
    /// observed run rotated three in one reopen. Any header representation that
    /// collapses repeated names would silently drop two of the three, which is
    /// why `HTTPResponse` preserves them.
    mutating func absorb(setCookie values: [String]) {
        for value in values {
            apply(setCookie: value)
        }
    }

    private mutating func apply(setCookie raw: String) {
        guard let incoming = Self.parse(raw) else { return }
        let name = incoming.name
        let value = incoming.value
        let existing = cookies.firstIndex { $0.name == name }

        if incoming.isDeletion {
            guard let existing else { return }
            rotations.append(
                CookieRotation(
                    name: name,
                    change: .deleted,
                    oldLength: cookies[existing].value.count,
                    newLength: 0
                )
            )
            cookies.remove(at: existing)
            return
        }

        guard let existing else {
            rotations.append(
                CookieRotation(name: name, change: .added, oldLength: 0, newLength: value.count)
            )
            cookies.append(SessionCookies.Cookie(name: name, value: value))
            return
        }

        let old = cookies[existing].value
        guard old != value else { return } // re-sending the same value is not a rotation
        rotations.append(
            CookieRotation(
                name: name,
                change: .rotated,
                oldLength: old.count,
                newLength: value.count
            )
        )
        // Replaced in place: the capture order is the browser's order, and a
        // rotation is not a reason to reorder the header.
        cookies[existing] = SessionCookies.Cookie(name: name, value: value)
    }

    /// Splits a `Set-Cookie` value into the pair to store, and decides whether
    /// it is a deletion.
    ///
    /// A deletion is an **empty value plus** either an expiry in the past or
    /// `Max-Age` of zero or less. The two halves both matter: `OTZ=` with no
    /// expiry is a live cookie with an empty value and has to survive, while
    /// `COMPASS=; Expires=Thu, 01 Jan 1970` must not be replayed as `COMPASS=`.
    private struct Incoming {
        let name: String
        let value: String
        let isDeletion: Bool
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

        let deleted = value.isEmpty && segments.dropFirst().contains { isExpiry($0) }
        return Incoming(name: name, value: value, isDeletion: deleted)
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
