import Foundation
@testable import MacHost

/// A `LoginWebView` with settable answers, so the capture model can be driven
/// through every path with no WebKit, no Google account and no Keychain.
@MainActor
final class FakeLoginWebView: LoginWebView {
    var currentURL: URL?
    var currentTitle: String?
    var cookies: [HTTPCookie] = []
    private(set) var cookieReadCount = 0

    init(url: String? = nil, title: String? = "Google Chat") {
        currentURL = url.flatMap(URL.init(string:))
        currentTitle = title
    }

    func allCookies() async -> [HTTPCookie] {
        cookieReadCount += 1
        return cookies
    }

    /// A cookie the capture report will accept as Chat's own. `COMPASS` and
    /// `OSID` are issued by Chat itself rather than by the accounts host,
    /// which is the whole reason capture waits for Chat to load
    /// (`findings.md` §17.2).
    static func chatCookie(name: String = "COMPASS", value: String = "x") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "chat.google.com",
            .path: "/",
            .secure: "TRUE"
        ])!
    }
}
