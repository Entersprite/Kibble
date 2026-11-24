import Foundation
import Testing
@testable import MacHost

@MainActor
struct SignInRestartTests {
    @Test func expiredSignInRestartsAndRetiresOldNavigationAndCookieResults() async throws {
        let custody = FakeCaptureCustody()
        let model = CookieCaptureModel(autoSaveAllowed: true, custody: custody, reportDirectory: nil)
        let old = FakeLoginWebView(url: "https://chat.google.com/app/")
        old.cookies = [FakeLoginWebView.chatCookie()]
        model.attach(old)
        model.pageSettled(old)
        old.currentURL = URL(string: "https://accounts.google.com/info/sessionexpired?token=SECRET")
        model.pageLocationChanged(old)
        #expect(model.status == "Google sign-in expired.")
        #expect(model.pageURL == "accounts.google.com/info/sessionexpired ?<stripped>")
        #expect(model.canRestartSignIn)

        let attempt = model.browserAttempt
        model.restartSignIn()
        #expect(model.browserAttempt != attempt)
        #expect(!model.canRestartSignIn)
        #expect(model.pageURL.isEmpty)
        let fresh = FakeLoginWebView(url: "https://accounts.google.com/signin/v2")
        model.attach(fresh)
        model.pageSettled(fresh)
        model.failed(old, URLError(.timedOut))
        model.pageSettled(old)
        model.pageLocationChanged(old)

        // The queued capture reads the retired browser, then drops the result.
        try await Task.sleep(for: .milliseconds(50))
        #expect(old.cookieReadCount == 1)
        #expect(custody.saveCount == 0)
        #expect(!model.canSave)
        #expect(model.canRestartSignIn)
        #expect(model.pageURL == "accounts.google.com/signin/v2")
    }

    @Test func anOrdinarySignInPageCanRestartWithoutWaitingForAnError() {
        let model = CookieCaptureModel(custody: FakeCaptureCustody(), reportDirectory: nil)
        let view = FakeLoginWebView(url: "https://accounts.google.com/signin/v2")
        #expect(!model.canRestartSignIn)
        model.attach(view)
        model.pageSettled(view)
        #expect(model.canRestartSignIn)

        view.currentURL = URL(string: "https://chat.google.com/app/")
        model.pageSettled(view)
        #expect(!model.canRestartSignIn)
    }

    @Test func locationFeedbackDescribesTheCurrentStepWithoutCapturing() {
        let model = CookieCaptureModel(custody: FakeCaptureCustody(), reportDirectory: nil)
        let view = FakeLoginWebView(url: "https://accounts.google.com/v3/signin/identifier")
        model.attach(view)
        model.pageSettled(view)
        #expect(model.status == "Enter your email address in the Google form.")

        view.currentURL = URL(string: "https://accounts.google.com/v3/signin/challenge/pwd")
        model.pageLocationChanged(view)
        #expect(model.status == "Enter your password in the Google form.")
        #expect(view.cookieReadCount == 0)

        view.currentURL = URL(string: "about:blank")
        model.pageLocationChanged(view)
        #expect(model.status.contains("Restart Sign-In"))
        #expect(model.canRestartSignIn)
    }

    @Test func navigationFeedbackDoesNotRepeatTheRawError() {
        let model = CookieCaptureModel(custody: FakeCaptureCustody(), reportDirectory: nil)
        let view = FakeLoginWebView(url: "https://accounts.google.com/v3/signin/identifier")
        model.attach(view)
        let error = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET"])
        model.failed(view, error)
        #expect(!model.status.contains("SECRET"))
        #expect(model.canRestartSignIn)
    }
}
