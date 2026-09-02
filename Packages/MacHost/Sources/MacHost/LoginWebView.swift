import Foundation
import LocalBridgeBackend

/// The three things the capture model needs from a web view.
///
/// Narrow on purpose, and returning `HTTPCookie` rather than a WebKit type:
/// `HTTPCookie` is Foundation, so the `HTTPCookie` to `CapturedCookie` mapping
/// stays in this package where a test can reach it, and the only `WKWebView`
/// in the repo is one conformance in the app target. Same shape as
/// `SecretStorage` and `HTTPTransport` - a boundary that cannot be unit-tested
/// should be one file wide.
@MainActor
public protocol LoginWebView: AnyObject {
    var currentURL: URL? { get }
    var currentTitle: String? { get }
    func allCookies() async -> [HTTPCookie]
}

/// What the login web view is pointed at, and what it claims to be.
///
/// Exists for two reasons. It is what lets the app target import no backend:
/// `CookieCaptureView` needed exactly one thing from `LocalBridgeBackend`, and
/// this re-spells it. And it stops a drift that was live - the navigation
/// target was hard-coded in the view while the host the capture gate accepted
/// was hard-coded in the model, two files that had to agree about one origin
/// with nothing making them.
public struct LoginWebViewConfiguration: Sendable {
    public let userAgent: String
    public let startURL: URL

    /// The host the capture gate accepts, derived from `startURL` rather than
    /// spelled a second time.
    public var host: String? {
        startURL.host()
    }

    public init(userAgent: String, startURL: URL) {
        self.userAgent = userAgent
        self.startURL = startURL
    }

    /// Chat gates on the User-Agent, and the failure is silent: without an
    /// accepted one it authenticates the session and then serves its
    /// unsupported-browser page (`findings.md` §15).
    public static let chat = LoginWebViewConfiguration(
        userAgent: LocalBridgeBackend.captureUserAgent,
        // Force-unwrapped: a malformed literal here is a programmer error that
        // must not be recoverable, and it is covered by every test that uses
        // `.chat`.
        startURL: URL(string: "https://chat.google.com/")!
    )
}
