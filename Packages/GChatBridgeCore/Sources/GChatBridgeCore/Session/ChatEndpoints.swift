import Foundation

/// Where the Chat web client's endpoints live, and under which signed-in account.
///
/// ## The account index is configuration, not a constant
///
/// The reference implementation hardcodes `/u/0`. That is a latent bug: a browser
/// signed into several Google accounts addresses Chat as `/u/0`, `/u/1`, … and
/// **a wrong index fails identically to bad credentials** — HTTP 200 carrying the
/// sign-in shell. Someone debugging that would reasonably conclude their cookies
/// were rejected and go re-capture them, forever.
///
/// One observed account's Chat URL showed no `/u/N` at all, and `/u/0` still
/// worked. So both shapes have to be expressible, and which one to use is a
/// setting a host can change without a rebuild.
public struct ChatEndpoints: Sendable, Hashable {
    /// Which signed-in account to address.
    public enum Account: Sendable, Hashable {
        /// `/u/N`.
        case index(Int)
        /// No account segment. A real, observed configuration, not a fallback.
        case none
    }

    public let host: URL
    public let account: Account

    /// **Chat gates on this.** A request without a browser `User-Agent` is
    /// authenticated normally and then served `/error/browser-not-supported` —
    /// so the cookies work, the status is 200, and nothing functions. There is
    /// no error message and no clue in the status; the only symptom is a page
    /// titled "Chat: Unsupported Browser", which itself carries a
    /// `WIZ_global_data` blob and so looks superficially like a real shell.
    ///
    /// Configurable because the accepted set is Google's to change, and pinning
    /// a version string in source that cannot be overridden would make a future
    /// rejection require a rebuild.
    public let userAgent: String

    /// A current desktop Chrome, matching what the reference implementation
    /// sends. Not an attempt to be sneaky — Chat's web client *is* a browser
    /// client, and this is the client it expects to be talking to.
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    public init(
        host: URL = URL(string: "https://chat.google.com")!,
        account: Account = .index(0),
        userAgent: String = ChatEndpoints.defaultUserAgent
    ) {
        self.host = host
        self.account = account
        self.userAgent = userAgent
    }

    /// The base every path hangs off, with the account segment if there is one.
    public var base: URL {
        switch account {
        case let .index(index):
            host.appendingPathComponent("u").appendingPathComponent(String(index))
        case .none:
            host
        }
    }

    /// The Gmail-hosted "mole" that serves the Chat app shell. This is the
    /// request whose `WIZ_global_data` says whether the session is signed in.
    public var moleWorld: URL {
        var components = URLComponents(
            url: base.appendingPathComponent("mole").appendingPathComponent("world"),
            resolvingAgainstBaseURL: false
        )!
        // Values are taken from the reference implementation. `hs` is an opaque
        // JSON array the server expects verbatim; it is not ours to tidy.
        components.percentEncodedQuery = Self.query([
            ("origin", "https://mail.google.com"),
            ("shell", "9"),
            ("hl", "en"),
            ("wfi", "gtn-roster-iframe-id"),
            ("hs", Self.handshakeBlob)
        ])
        return components.url!
    }

    /// Builds a query string, encoding everything outside the unreserved set.
    ///
    /// `URLComponents` is deliberately not trusted with this. It leaves `:`,
    /// `/` and `,` unescaped in query values — legal per RFC 3986, and *not*
    /// what the reference implementation sends: its `urlencode` produces
    /// `origin=https%3A%2F%2Fmail.google.com` and `%2C` for every comma.
    ///
    /// The encoded form is the only one observed to work against the live
    /// server; the relaxed form is untested there. On a protocol where `$req`
    /// turns out to need *double* percent-encoding, guessing that a laxer
    /// encoding is equivalent is not a risk worth taking for tidier code — and
    /// matching byte-for-byte keeps a request diffable against a capture, which
    /// is the only debugging tool available here.
    private static func query(_ items: [(String, String)]) -> String {
        items
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")
    }

    private static func encode(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let handshakeBlob = #"["h_hs",null,null,[1,0],null,null,"#
        + #""gmail.pinto-server_20230730.06_p0",1,null,"#
        + #"[15,38,36,35,26,30,41,18,24,11,21,14,6],null,null,"#
        + #""3Mu86PSulM4.en..es5",0,null,null,[0]]"#

    /// The referer the mole expects. It is served in a Gmail context, so this is
    /// load-bearing rather than politeness.
    public static let mailReferer = "https://mail.google.com/"
}
