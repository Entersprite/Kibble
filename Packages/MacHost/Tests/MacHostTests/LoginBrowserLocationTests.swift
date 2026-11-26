import Foundation
import Testing
import WebKit
@testable import MacHost

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoginBrowserLocationTests {
    @Test func javaScriptAddressChangeReachesTheActiveDelegateAndRetiresOnDetach() async throws {
        let view = LoginBrowser.makeWebView()
        var settled = false
        var observedPaths: [String] = []
        let delegate = LoginBrowserDelegate(
            events: .init(
                attached: { _ in },
                settled: { _ in settled = true },
                locationChanged: { page in
                    if let path = page.currentURL?.path() {
                        observedPaths.append(path)
                    }
                },
                failed: { _, _ in }
            ),
            traces: false,
            pageHost: { _ in }
        )
        delegate.attach(view)
        defer { delegate.detach(view) }
        let base = try #require(URL(string: "https://login.invalid/identifier"))
        view.loadHTMLString("<!doctype html><title>Offline login fixture</title>", baseURL: base)
        try await wait { settled }
        _ = try await view.evaluateJavaScript("history.replaceState(null, '', '/password'); true")
        try await wait { observedPaths.contains("/password") }

        delegate.detach(view)
        _ = try await view.evaluateJavaScript("history.replaceState(null, '', '/retired'); true")
        #expect(!observedPaths.contains("/retired"))
    }

    @Test func onlyAllowlistedSignInStagesAppearInTheTrace() {
        let identifier = URL(string: "https://accounts.google.com/v3/signin/identifier?email=SECRET")
        let challenge = URL(string: "https://accounts.google.com/v3/signin/challenge/SECRET")
        let other = URL(string: "https://accounts.google.com.evil.invalid/v3/signin/identifier")
        #expect(LoginPageLocation(identifier).rawValue == "identifier")
        #expect(LoginPageLocation(challenge).rawValue == "challenge")
        #expect(LoginPageLocation(other).rawValue == "other")
        #expect(LoginPageLocation(URL(string: "about:blank")) == .blank)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
