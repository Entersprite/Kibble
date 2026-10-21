import AppKit
import Foundation
import LocalBridgeBackend
import Testing
import WebKit
@testable import MacHost

/// The browser every sign-in window shares: what it must keep from the three
/// it replaced, and the failures, dialogs and subtitle it now gives all of
/// them. No page is ever loaded here.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LoginBrowserTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        try #require(condition())
    }

    private func captureModel() -> CookieCaptureModel {
        CookieCaptureModel(
            autoSaveAllowed: true, custody: FakeCaptureCustody(), reportDirectory: nil, preparesCalls: true
        )
    }

    /// Credential custody depends on these: a store that keeps nothing once
    /// the window is gone, and the user agent Chat accepts.
    @Test func everySignInBrowserIsPrivateAndClaimsTheCaptureUserAgent() {
        let view = LoginBrowser.makeWebView()
        #expect(!view.configuration.websiteDataStore.isPersistent)
        #expect(view.customUserAgent == LoginWebViewConfiguration.chat.userAgent)
        #expect(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(view.allowsBackForwardNavigationGestures)
    }

    /// Add Account stayed blank on a failed load: its browser never told the
    /// model. A navigation replaced by the next, which Google's redirects do
    /// all the time, is not a failure.
    @Test func aFailedLoadReachesTheModelAndASupersededOneDoesNot() {
        let model = captureModel()
        let delegate = LoginBrowser(capturing: model, pageHost: { _ in }).makeCoordinator()
        let view = LoginBrowser.makeWebView()
        delegate.attach(view)
        let loading = model.status
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        let offline = URLError(.notConnectedToInternet)
        delegate.webView(view, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        delegate.webView(view, didFailProvisionalNavigation: nil, withError: interrupted)
        #expect(model.status == loading)
        delegate.webView(view, didFailProvisionalNavigation: nil, withError: offline)
        #expect(model.status.hasPrefix("Navigation failed"))
        let provisional = model.status
        delegate.webView(view, didFail: nil, withError: URLError(.timedOut))
        #expect(model.status.hasPrefix("Navigation failed"))
        #expect(model.status != provisional)
    }

    @Test func onlyRealFailuresAreReported() {
        #expect(!LoginBrowser.reportsFailure(URLError(.cancelled)))
        #expect(!LoginBrowser.reportsFailure(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(LoginBrowser.reportsFailure(NSError(domain: "WebKitErrorDomain", code: 101)))
        #expect(LoginBrowser.reportsFailure(URLError(.notConnectedToInternet)))
        #expect(LoginBrowser.reportsFailure(URLError(.secureConnectionFailed)))
    }

    @Test func callSignInRecoveryHearsOfAFailedLoad() async {
        let model = CallSignInRecovery()
        await model.install(load: { [] }, save: { _ in 1 })
        model.begin { _ in }
        let browser = LoginBrowser(recovering: model, pageHost: { _ in })
        #expect(browser.start == nil)
        browser.events.failed(FakeLoginWebView(), URLError(.notConnectedToInternet))
        #expect(model.status == "Call sign-in couldn't load. Try again, or close this window.")
        await model.finish(restart: false)
    }

    /// The capture model's browser opens Chat itself; recovery's waits for
    /// its saved cookies.
    @Test func theCaptureBrowserOpensChat() {
        let browser = LoginBrowser(capturing: captureModel(), pageHost: { _ in })
        #expect(browser.start == LoginWebViewConfiguration.chat.startURL)
        #expect(!browser.traces)
    }

    @Test func theSubtitleIsThePagesHostWithoutItsPathOrQuery() {
        #expect(LoginBrowser.host(of: URL(string: "https://accounts.google.com/signin/v2?token=SECRET"))
            == "accounts.google.com")
        #expect(LoginBrowser.host(of: URL(string: "https://Chat.Google.com/u/0/")) == "chat.google.com")
        #expect(LoginBrowser.host(of: URL(string: "about:blank")) == "")
        #expect(LoginBrowser.host(of: nil) == "")
    }

    /// The page's question is answered by the person: only OK, the first
    /// button, says yes. Cancel, Esc and a closed window all say no.
    @Test func onlyOKConfirmsAPagesQuestion() {
        let confirm = LoginPageDialog.confirm("Leave?")
        #expect(confirm.answer(.alertFirstButtonReturn, text: nil).confirmed)
        #expect(!confirm.answer(.alertSecondButtonReturn, text: nil).confirmed)
        #expect(!confirm.answer(.cancel, text: nil).confirmed)
        #expect(!confirm.answer(.abort, text: nil).confirmed)
        let prompt = LoginPageDialog.prompt("Name?", defaultText: "Avery")
        #expect(prompt.answer(.alertFirstButtonReturn, text: "Avery Stone").text == "Avery Stone")
        #expect(prompt.answer(.alertFirstButtonReturn, text: nil).text == "")
        #expect(prompt.answer(.alertSecondButtonReturn, text: "Avery Stone").text == nil)
        #expect(prompt.answer(.cancel, text: "Avery Stone").text == nil)
        #expect(!LoginPageDialog.alert("Hello").canCancel)
        #expect(confirm.canCancel && prompt.canCancel)
    }

    /// The first-run window answers the page's dialogs at once, as it always
    /// has, so nothing in the sign-in waits on one; Add Account asks the
    /// person, and with no window to ask in, refuses.
    @Test func onlyTheFirstRunWindowAnswersThePagesDialogsItself() {
        let firstRun = CookieCaptureBrowser(model: captureModel(), traces: true).browser
        #expect(firstRun.dialogs == .answer)
        #expect(firstRun.traces)
        #expect(LoginBrowser(capturing: captureModel(), pageHost: { _ in }).dialogs == .ask)

        // Through the delegate's one route for every dialog; WebKit traps on
        // a frame made outside a page, so the host is given directly.
        let view = LoginBrowser.makeWebView()
        let answering = firstRun.makeCoordinator()
        answering.attach(view)
        var answers: [LoginPageDialog.Answer] = []
        let dialogs: [LoginPageDialog] = [
            .confirm("Leave?"), .alert("Hi"), .prompt("Name?", defaultText: "Avery")
        ]
        for dialog in dialogs {
            answering.handle(dialog, in: view, host: nil) { answers.append($0) }
        }
        #expect(answers.map(\.confirmed) == [true, true, false])
        #expect(answers.map(\.text) == [nil, nil, nil])

        let asking = LoginBrowser(capturing: captureModel(), pageHost: { _ in }).makeCoordinator()
        asking.attach(view)
        var refused: [Bool] = []
        asking.handle(.confirm("Leave?"), in: view, host: nil) { refused.append($0.confirmed) }
        #expect(refused == [false])
    }

    @Test func aDialogNamesThePageThatAsked() {
        #expect(LoginPageDialog.title(host: "accounts.google.com") == "accounts.google.com says")
        #expect(LoginPageDialog.title(host: "") == "This page says")
        #expect(LoginPageDialog.title(host: nil) == "This page says")
    }

    /// WebKit raises if a dialog's completion handler is released unanswered,
    /// so a reply answers exactly once, and refuses if it is let go first.
    @Test func aDialogIsAnsweredOnceAndRefusedIfLetGo() async throws {
        var answers: [Bool] = []
        let reply = LoginDialogReply(dialog: .confirm("Leave?")) { answers.append($0.confirmed) }
        reply.answer(.alertFirstButtonReturn)
        reply.refuse()
        #expect(answers == [true])
        #expect(reply.isAnswered)

        var dropped: [Bool] = []
        do {
            let unanswered = LoginDialogReply(dialog: .confirm("Leave?")) { dropped.append($0.confirmed) }
            #expect(!unanswered.isAnswered)
        }
        try await wait { !dropped.isEmpty }
        #expect(dropped == [false])
    }

    @Test func theWindowShowsCallSetupWhileItRuns() async throws {
        let model = captureModel()
        #expect(model.visibleStatus == model.status)
        let view = FakeLoginWebView(url: "https://chat.google.com/")
        view.cookies = [FakeLoginWebView.chatCookie()]
        model.attach(view)
        model.pageSettled(view)
        let setup = try #require(model.callSetup)
        try await wait { setup.isActive }
        #expect(model.visibleStatus == setup.status)
        #expect(model.visibleStatus != model.status)
    }
}
