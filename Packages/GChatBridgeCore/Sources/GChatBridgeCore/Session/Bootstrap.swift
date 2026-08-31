import Foundation

/// Safe facts about a response that failed to yield a shell.
///
/// **Deliberately carries no page content.** It is printed by a diagnostic tool,
/// and the body of a signed-in shell contains real names and messages. A page
/// title is the one exception, capped in length: titles are `Google Chat` or
/// `Sign in - Google Accounts`, and knowing which is most of the diagnosis.
public struct ShellDiagnosis: Sendable, Hashable, CustomStringConvertible {
    /// Substrings whose presence says "this really was an app shell". If these
    /// appear and no blob came out, the scanner is at fault rather than the page.
    static let shellMarkers = ["WIZ_global_data", "qwAQke", "DynamiteWebUi", "AccountsSignInUi"]

    public let status: Int
    public let finalURL: URL?
    public let byteCount: Int
    public let contentType: String?
    public let title: String?
    public let markersFound: [String]

    /// Whether this looked like a shell despite yielding nothing.
    ///
    /// `true` means **the parser is the problem**, not the credentials — the page
    /// carried the markers and the scanner still came away empty.
    public var looksLikeAShell: Bool {
        !markersFound.isEmpty
    }

    init(response: HTTPResponse) {
        let body = String(decoding: response.body, as: UTF8.self)
        status = response.status
        finalURL = response.url
        byteCount = response.body.count
        contentType = response.headers["Content-Type"]
        title = Self.title(in: body)
        markersFound = Self.shellMarkers.filter { body.contains($0) }
    }

    /// The `<title>`, capped. Not a general HTML parser: it only has to
    /// distinguish a handful of Google pages from each other.
    private static func title(in body: String) -> String? {
        guard
            let open = body.range(of: "<title>"),
            let close = body.range(of: "</title>", range: open.upperBound ..< body.endIndex)
        else { return nil }
        return String(body[open.upperBound ..< close.lowerBound].prefix(80))
    }

    public var description: String {
        var parts = ["HTTP \(status)", "\(byteCount) bytes"]
        if let contentType {
            parts.append(contentType)
        }
        if let title {
            parts.append("title: \(title)")
        }
        if let finalURL {
            parts.append("from: \(finalURL.host() ?? "?")\(finalURL.path)")
        }
        parts.append(
            looksLikeAShell
                ? "markers present (\(markersFound.joined(separator: ", "))) - THE PARSER IS AT FAULT"
                : "no shell markers - this was not an app shell"
        )
        return parts.joined(separator: " | ")
    }
}

/// Why a bootstrap can fail in a way that is *not* "signed out".
public enum BootstrapFailure: Error, Hashable, CustomStringConvertible {
    /// The server did not answer with 200, so there is no shell to read. Only a
    /// 200 carries one — including when the answer is "sign in".
    case unexpectedStatus(Int)

    /// A 200 arrived and carried no `WIZ_global_data`.
    ///
    /// Carries a diagnosis because "no blob" has two completely different causes
    /// with completely different fixes: the response was not an app shell at all,
    /// or it was one and the scanner failed on it. Guessing between them wastes
    /// the only thing that is scarce here — a live session to test against.
    case noGlobalData(ShellDiagnosis)

    /// The request was redirected to Google's own sign-in page, which carries no
    /// `WIZ_global_data` at all.
    ///
    /// This is the **third** outcome, and it is not the same as `AccountsSignInUi`.
    /// A cookie set that is merely incomplete still identifies a session, so Chat
    /// answers it with its own sign-in shell. A cookie set that is unusable does
    /// not get that far: it is bounced to `accounts.google.com`. Observed
    /// directly - a request with invented cookies ended at
    /// `accounts.google.com/v3/signin/identifier`.
    ///
    /// Worth its own case because reporting it as `noGlobalData` would send
    /// someone hunting a protocol break when their header is simply bad.
    case signInRedirect(URL)

    public var description: String {
        switch self {
        case let .unexpectedStatus(status):
            "bootstrap got HTTP \(status); only 200 carries an app shell"
        case let .noGlobalData(diagnosis):
            "no WIZ_global_data in the response. \(diagnosis)"
        case let .signInRedirect(url):
            "redirected to \(url.host() ?? url.absoluteString) - the cookies are not usable"
        }
    }
}

/// The first call of the connect sequence: fetch the app shell and read what it
/// says about the session.
///
/// This is the **only** honest way to answer "am I signed in?" on this protocol.
/// An incomplete or stale cookie set is answered with HTTP 200 and a well-formed
/// shell that renders the sign-in page — and that shell is *larger* than the
/// authenticated one, so neither the status code nor the body size can tell them
/// apart. Only `WIZ_global_data` can.
///
/// It takes an `HTTPTransport`, so it is fully testable with no network: the
/// suite drives it with scripted responses.
public struct Bootstrap: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// Fetches the shell and returns what it says.
    ///
    /// **Being signed out is a return value, not an error.** A caller has to
    /// distinguish "the credentials are stale, go re-acquire them" from "the
    /// network failed, retry" — and throwing for both would collapse two
    /// different recoveries into one.
    public func run(
        cookies: SessionCookies,
        endpoints: ChatEndpoints = ChatEndpoints()
    ) async throws -> WizGlobalData {
        let request = HTTPRequest(
            url: endpoints.moleWorld,
            headers: HTTPHeaders([
                ("Cookie", cookies.headerValue),
                ("referer", ChatEndpoints.mailReferer)
            ])
        )

        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw BootstrapFailure.unexpectedStatus(response.status)
        }
        guard
            let wiz = WizGlobalData(html: String(decoding: response.body, as: UTF8.self))
        else {
            // Where the response came from is the diagnosis. A bounce to the
            // accounts host means the credentials never got as far as Chat.
            if let url = response.url, url.host()?.contains("accounts.google.com") == true {
                throw BootstrapFailure.signInRedirect(url)
            }
            throw BootstrapFailure.noGlobalData(ShellDiagnosis(response: response))
        }
        return wiz
    }
}
