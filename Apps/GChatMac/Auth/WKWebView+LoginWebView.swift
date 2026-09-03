import Foundation
import MacHost
import WebKit

/// The only `WKWebView` in the repo, and the whole of what the capture model
/// needs from one.
///
/// This file is the untestable residue by design: it needs a web view, and
/// everything that decides anything sits behind `LoginWebView` in `MacHost`
/// where it is covered. Same shape as the `SecItem` calls behind
/// `SecretStorage`.
extension WKWebView: MacHost.LoginWebView {
    public var currentURL: URL? {
        url
    }

    public var currentTitle: String? {
        title
    }

    public func allCookies() async -> [HTTPCookie] {
        await configuration.websiteDataStore.httpCookieStore.allCookies()
    }
}
