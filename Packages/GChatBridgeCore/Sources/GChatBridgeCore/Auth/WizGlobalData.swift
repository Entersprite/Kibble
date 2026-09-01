import Foundation

/// The `window.WIZ_global_data` blob from a Chat app-shell response, reduced to
/// the three things this package needs from it.
///
/// ## Why this type exists at all
///
/// **Auth failure on this protocol returns HTTP 200.** A request with an
/// incomplete or stale cookie set is answered with a well-formed app shell that
/// renders the sign-in page — no 401, no 403, no redirect. The signed-out shell
/// is also *larger* than the authenticated one, so neither the status code nor
/// the body size can tell a caller whether it is signed in. This blob can.
///
/// The keys are Google's obfuscated names, and they are load-bearing rather
/// than incidental:
///
/// - `qwAQke` — the UI bundle the server chose. `"DynamiteWebUi"` means signed
///   in ("Dynamite" is Chat's internal codename); `"AccountsSignInUi"` means
///   signed out.
/// - `SMqcke` — the xsrf token, needed by later requests.
///
/// Names this opaque will change without notice. When they do, the failure is a
/// `nil` here rather than a misparse somewhere later, which is the point of
/// pulling them out in one place.
public struct WizGlobalData: Sendable, Hashable, CustomStringConvertible {
    /// Which UI bundle the server decided to serve — the raw `qwAQke` value.
    public let appName: String?

    /// The xsrf token (`SMqcke`), or `nil` when the shell carries none, as the
    /// signed-out shell does.
    public let xsrfToken: String?

    /// How many keys the blob had. Around 128 for an authenticated shell and
    /// around 68 signed out; not a decision input, but the number a human wants
    /// when a shell is not the shape they expected.
    public let keyCount: Int

    /// What the shell says about the session.
    ///
    /// An unrecognised value is `.unknown` and is **not** signed in.
    /// maugclib tests only for the negative — `qwAQke == "AccountsSignInUi"` —
    /// which silently treats every value it has never seen as a working
    /// session. An unrecognised shell is precisely the case where assuming less
    /// is correct.
    public enum SignInState: Sendable, Hashable {
        case signedIn
        case signedOut
        case unknown(String)
        case absent
    }

    public let signInState: SignInState

    public var isSignedIn: Bool {
        signInState == .signedIn
    }

    /// Describes without revealing: the token is reported as a length, never as
    /// a value. This type holds a credential and will end up in a log line one
    /// day, and `Never print cookie values, tokens, or message content` has to
    /// survive that.
    public var description: String {
        let token = xsrfToken.map { "\($0.count) chars" } ?? "none"
        return "WizGlobalData(app: \(appName ?? "none"), xsrf: \(token), keys: \(keyCount))"
    }
}

// MARK: - Parsing

public extension WizGlobalData {
    /// The name only, with **no punctuation after it**.
    ///
    /// This anchor was `"WIZ_global_data = ("` and could never match a real
    /// page. The reference Python is
    /// `r">window.WIZ_global_data = ({.+?});</script>"`, where those
    /// parentheses are a **regex capture group** - and they were transcribed
    /// into Swift as literal text. A real shell sends
    /// `window.WIZ_global_data = {"AB33kc":…`, with no paren at all.
    ///
    /// Anchoring on the name alone also absorbs a minified `WIZ_global_data={`
    /// and a future reintroduced paren, because `objectText` scans forward to
    /// the next `{` regardless. The punctuation was never worth being strict
    /// about; being strict about it cost a session.
    private static let assignment = "WIZ_global_data"
    private static let appNameKey = "qwAQke"
    private static let xsrfTokenKey = "SMqcke"

    private static let signedInApp = "DynamiteWebUi"
    private static let signedOutApp = "AccountsSignInUi"

    /// Extracts the blob from a full app-shell response.
    ///
    /// Returns `nil` when the assignment is missing, truncated, or not a JSON
    /// object — all of which mean "this is not a shell I understand", which a
    /// caller must not confuse with "this is a signed-out shell".
    ///
    /// The shell is roughly a megabyte with many other script tags in it, so the
    /// scan anchors on the assignment text rather than on the first brace, and
    /// the object is located by counting brackets rather than by regex: the blob
    /// contains braces inside string values.
    init?(html: String) {
        guard
            let assignmentRange = html.range(of: Self.assignment),
            let object = Self.objectText(in: html, after: assignmentRange.upperBound),
            let parsed = try? JSONSerialization.jsonObject(with: Data(object.utf8)),
            let fields = parsed as? [String: Any]
        else { return nil }

        let appName = fields[Self.appNameKey] as? String
        self.init(
            appName: appName,
            xsrfToken: fields[Self.xsrfTokenKey] as? String,
            keyCount: fields.count,
            signInState: Self.state(ofApp: appName)
        )
    }

    private static func state(ofApp appName: String?) -> SignInState {
        switch appName {
        case .none: .absent
        case signedInApp: .signedIn
        case signedOutApp: .signedOut
        case let .some(other): .unknown(other)
        }
    }

    /// Returns the `{…}` starting at or after `start`, balanced.
    ///
    /// Braces inside string literals are skipped, and so is anything a
    /// backslash escapes, because the blob's values contain both.
    private static func objectText(
        in html: String,
        after start: String.Index
    ) -> Substring? {
        guard let open = html[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var insideString = false
        var escaped = false

        for index in html.indices[open...] {
            let character = html[index]
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\" where insideString:
                escaped = true
            case "\"":
                insideString.toggle()
            case "{" where !insideString:
                depth += 1
            case "}" where !insideString:
                depth -= 1
                if depth == 0 {
                    return html[open ... index]
                }
            default:
                break
            }
        }
        return nil // truncated
    }
}
