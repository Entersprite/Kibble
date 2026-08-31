import Foundation

/// Why a bootstrap can fail in a way that is *not* "signed out".
public enum BootstrapFailure: Error, Hashable, CustomStringConvertible {
    /// The server did not answer with 200, so there is no shell to read. Only a
    /// 200 carries one — including when the answer is "sign in".
    case unexpectedStatus(Int)

    /// A 200 arrived and carried no `WIZ_global_data`. Distinct from being
    /// signed out, and more serious: it means the shell's shape changed, so the
    /// protocol moved and the parser needs revisiting.
    case noGlobalData

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
        case .noGlobalData:
            "the app shell carried no WIZ_global_data - its shape has changed"
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
            throw BootstrapFailure.noGlobalData
        }
        return wiz
    }
}
